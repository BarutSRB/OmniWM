import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct WindowMutationPreparedRequest {
        let snapshot: NiriStateZigKernel.Snapshot
        let request: NiriStateZigKernel.MutationRequest
    }

    private struct WindowMutationApplyOutcome {
        let applied: Bool
        let targetWindow: NiriWindow?
        let delegatedMoveColumn: (column: NiriContainer, direction: Direction)?
    }

    private struct HorizontalSwapAnimationCapture {
        let sourceWindow: NiriWindow
        let targetWindow: NiriWindow
        let sourcePoint: CGPoint
        let targetPoint: CGPoint
    }

    private func prepareWindowMutationRequest(
        op: NiriStateZigKernel.MutationOp,
        sourceWindow: NiriWindow,
        targetWindow: NiriWindow? = nil,
        direction: Direction? = nil,
        insertPosition: InsertPosition? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowMutationPreparedRequest? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard let sourceWindowIndex = snapshot.windowIndexByNodeId[sourceWindow.id] else {
            return nil
        }

        let targetWindowIndex: Int
        if let targetWindow {
            guard let resolvedTargetWindowIndex = snapshot.windowIndexByNodeId[targetWindow.id] else {
                return nil
            }
            targetWindowIndex = resolvedTargetWindowIndex
        } else {
            targetWindowIndex = -1
        }

        let request = NiriStateZigKernel.MutationRequest(
            op: op,
            sourceWindowIndex: sourceWindowIndex,
            targetWindowIndex: targetWindowIndex,
            direction: direction,
            infiniteLoop: infiniteLoop,
            insertPosition: insertPosition,
            maxWindowsPerColumn: maxWindowsPerColumn
        )

        return WindowMutationPreparedRequest(snapshot: snapshot, request: request)
    }

    private func applyRuntimeWindowMutation(
        _ prepared: WindowMutationPreparedRequest,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowMutationApplyOutcome? {
        guard let context = prepareSeededRuntimeContext(
            for: workspaceId,
            snapshot: prepared.snapshot
        ) else {
            return nil
        }

        let applyOutcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(
                request: prepared.request,
                snapshot: prepared.snapshot
            )
        )
        guard applyOutcome.rc == 0 else {
            return nil
        }
        guard applyOutcome.applied else {
            return WindowMutationApplyOutcome(
                applied: false,
                targetWindow: nil,
                delegatedMoveColumn: nil
            )
        }

        guard applyProjectedRuntimeExport(
            context: context,
            workspaceId: workspaceId,
            delta: applyOutcome.delta
        ) != nil else {
            return nil
        }

        var runtimeOutcome = WindowMutationApplyOutcome(
            applied: true,
            targetWindow: nil,
            delegatedMoveColumn: nil
        )
        if let targetWindowId = applyOutcome.targetWindowId {
            guard let resolvedTarget = root(for: workspaceId)?.findNode(by: targetWindowId) as? NiriWindow else {
                return nil
            }
            runtimeOutcome = WindowMutationApplyOutcome(
                applied: true,
                targetWindow: resolvedTarget,
                delegatedMoveColumn: nil
            )
        }
        if let delegated = applyOutcome.delta?.delegatedMoveColumn {
            guard let resolvedColumn = root(for: workspaceId)?.findNode(by: delegated.columnId) as? NiriContainer else {
                return nil
            }
            runtimeOutcome = WindowMutationApplyOutcome(
                applied: true,
                targetWindow: runtimeOutcome.targetWindow,
                delegatedMoveColumn: (resolvedColumn, delegated.direction)
            )
        }

        return runtimeOutcome
    }

    private func executePreparedWindowMutation(
        _ prepared: WindowMutationPreparedRequest,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowMutationApplyOutcome? {
        applyRuntimeWindowMutation(prepared, in: workspaceId)
    }

    func applyWindowMutation(
        op: NiriStateZigKernel.MutationOp,
        sourceWindow: NiriWindow,
        targetWindow: NiriWindow? = nil,
        direction: Direction? = nil,
        insertPosition: InsertPosition? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> (applied: Bool, targetWindow: NiriWindow?, delegatedMoveColumn: (column: NiriContainer, direction: Direction)?)? {
        guard let prepared = prepareWindowMutationRequest(
            op: op,
            sourceWindow: sourceWindow,
            targetWindow: targetWindow,
            direction: direction,
            insertPosition: insertPosition,
            in: workspaceId
        ) else {
            return nil
        }
        guard let outcome = executePreparedWindowMutation(prepared, in: workspaceId) else {
            return nil
        }
        return (
            applied: outcome.applied,
            targetWindow: outcome.targetWindow,
            delegatedMoveColumn: outcome.delegatedMoveColumn
        )
    }

    private func captureHorizontalSwapAnimation(
        snapshot: NiriStateZigKernel.Snapshot,
        sourceWindow: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        gaps: CGFloat,
        now: CFTimeInterval
    ) -> HorizontalSwapAnimationCapture? {
        guard direction == .left || direction == .right else {
            return nil
        }
        guard let sourceWindowIndex = snapshot.windowIndexByNodeId[sourceWindow.id],
              snapshot.windowEntries.indices.contains(sourceWindowIndex)
        else {
            return nil
        }

        let sourceEntry = snapshot.windowEntries[sourceWindowIndex]
        guard snapshot.columns.indices.contains(sourceEntry.columnIndex) else {
            return nil
        }
        let sourceColumn = snapshot.columns[sourceEntry.columnIndex]
        let sourceCount = Int(sourceColumn.window_count)
        guard sourceCount > 0 else {
            return nil
        }

        let step = direction == .right ? 1 : -1
        guard let targetColumnIndex = wrapIndex(sourceEntry.columnIndex + step, total: snapshot.columns.count),
              targetColumnIndex != sourceEntry.columnIndex,
              snapshot.columns.indices.contains(targetColumnIndex)
        else {
            return nil
        }

        let targetColumn = snapshot.columns[targetColumnIndex]
        let targetCount = Int(targetColumn.window_count)
        guard targetCount > 0 else {
            return nil
        }

        let sourceActiveRow = min(Int(sourceColumn.active_tile_idx), sourceCount - 1)
        let targetActiveRow = min(Int(targetColumn.active_tile_idx), targetCount - 1)
        let sourceActiveWindowIndex = Int(sourceColumn.window_start) + sourceActiveRow
        let targetActiveWindowIndex = Int(targetColumn.window_start) + targetActiveRow
        guard snapshot.windowEntries.indices.contains(sourceActiveWindowIndex),
              snapshot.windowEntries.indices.contains(targetActiveWindowIndex)
        else {
            return nil
        }

        let sourceActiveEntry = snapshot.windowEntries[sourceActiveWindowIndex]
        let targetActiveEntry = snapshot.windowEntries[targetActiveWindowIndex]
        let preColumns = columns(in: workspaceId)
        guard preColumns.indices.contains(sourceActiveEntry.columnIndex),
              preColumns.indices.contains(targetActiveEntry.columnIndex)
        else {
            return nil
        }

        let sourceColX = state.columnX(
            at: sourceActiveEntry.columnIndex,
            columns: preColumns,
            gap: gaps
        )
        let targetColX = state.columnX(
            at: targetActiveEntry.columnIndex,
            columns: preColumns,
            gap: gaps
        )
        let sourceColRenderOffset = sourceActiveEntry.column.renderOffset(at: now)
        let targetColRenderOffset = targetActiveEntry.column.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(
            column: sourceActiveEntry.column,
            tileIdx: sourceActiveEntry.rowIndex,
            gaps: gaps
        )
        let targetTileOffset = computeTileOffset(
            column: targetActiveEntry.column,
            tileIdx: targetActiveEntry.rowIndex,
            gaps: gaps
        )

        return HorizontalSwapAnimationCapture(
            sourceWindow: sourceActiveEntry.window,
            targetWindow: targetActiveEntry.window,
            sourcePoint: CGPoint(
                x: sourceColX + sourceColRenderOffset.x,
                y: sourceTileOffset
            ),
            targetPoint: CGPoint(
                x: targetColX + targetColRenderOffset.x,
                y: targetTileOffset
            )
        )
    }

    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let latencyToken = NiriLatencyProbe.begin(.windowMove)
        defer { NiriLatencyProbe.end(latencyToken) }

        return switch direction {
        case .down, .up:
            moveWindowVertical(node, direction: direction, in: workspaceId)
        case .left, .right:
            moveWindowHorizontal(
                node,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    func swapWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        switch direction {
        case .down, .up:
            swapWindowVertical(node, direction: direction, in: workspaceId)
        case .left, .right:
            swapWindowHorizontal(
                node,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func moveWindowVertical(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let applyOutcome = applyWindowMutation(
            op: .moveWindowVertical,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }
        return applyOutcome.applied
    }

    private func swapWindowVertical(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let applyOutcome = applyWindowMutation(
            op: .swapWindowVertical,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }
        return applyOutcome.applied
    }

    private func moveWindowHorizontal(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let applyOutcome = applyWindowMutation(
            op: .moveWindowHorizontal,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }
        guard applyOutcome.applied else {
            return false
        }

        let targetNode = applyOutcome.targetWindow ?? node
        ensureSelectionVisible(
            node: targetNode,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    private func swapWindowHorizontal(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let prepared = prepareWindowMutationRequest(
            op: .swapWindowHorizontal,
            sourceWindow: node,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let animationCapture = captureHorizontalSwapAnimation(
            snapshot: prepared.snapshot,
            sourceWindow: node,
            direction: direction,
            in: workspaceId,
            state: state,
            gaps: gaps,
            now: now
        )
        guard let applyOutcome = executePreparedWindowMutation(
            prepared,
            in: workspaceId
        )
        else {
            return false
        }
        guard applyOutcome.applied else {
            return false
        }

        if let delegated = applyOutcome.delegatedMoveColumn {
            return moveColumn(
                delegated.column,
                direction: delegated.direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        if let animationCapture,
           let sourceColumn = column(of: animationCapture.sourceWindow),
           let targetColumn = column(of: animationCapture.targetWindow),
           let newSourceColIdx = columnIndex(of: sourceColumn, in: workspaceId),
           let newTargetColIdx = columnIndex(of: targetColumn, in: workspaceId)
        {
            let sourceWindowForAnimation = animationCapture.sourceWindow
            let targetWindowForAnimation = animationCapture.targetWindow
            let sourcePt = animationCapture.sourcePoint
            let targetPt = animationCapture.targetPoint
            let newCols = columns(in: workspaceId)
            let newSourceTileIdx = sourceColumn.windowNodes.firstIndex(where: { $0 === sourceWindowForAnimation }) ?? 0
            let newTargetTileIdx = targetColumn.windowNodes.firstIndex(where: { $0 === targetWindowForAnimation }) ?? 0
            let newSourceColX = state.columnX(at: newSourceColIdx, columns: newCols, gap: gaps)
            let newTargetColX = state.columnX(at: newTargetColIdx, columns: newCols, gap: gaps)
            let newSourceTileOffset = computeTileOffset(column: sourceColumn, tileIdx: newSourceTileIdx, gaps: gaps)
            let newTargetTileOffset = computeTileOffset(column: targetColumn, tileIdx: newTargetTileIdx, gaps: gaps)

            let newSourcePt = CGPoint(x: newSourceColX, y: newSourceTileOffset)
            let newTargetPt = CGPoint(x: newTargetColX, y: newTargetTileOffset)

            targetWindowForAnimation.stopMoveAnimations()
            targetWindowForAnimation.animateMoveFrom(
                displacement: CGPoint(x: targetPt.x - newSourcePt.x, y: targetPt.y - newSourcePt.y),
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )

            sourceWindowForAnimation.stopMoveAnimations()
            sourceWindowForAnimation.animateMoveFrom(
                displacement: CGPoint(x: sourcePt.x - newTargetPt.x, y: sourcePt.y - newTargetPt.y),
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )
        }

        let targetNode = applyOutcome.targetWindow ?? node
        ensureSelectionVisible(
            node: targetNode,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }
}
