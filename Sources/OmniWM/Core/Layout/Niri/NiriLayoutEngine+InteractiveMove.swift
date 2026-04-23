// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

extension NiriLayoutEngine {
    func interactiveMoveBegin(
        windowId: NodeId,
        windowHandle: WindowHandle,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowHandle: windowHandle,
            workspaceId: workspaceId,
            startMouseLocation: startLocation,
            originalColumnIndex: colIdx,
            originalFrame: windowNode.renderedFrame ?? windowNode.frame ?? .zero,
            isInsertMode: isInsertMode,
            currentHoverTarget: nil
        )

        let cols = columns(in: workspaceId)
        let settings = effectiveSettings(in: workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            gap: gaps,
            viewportWidth: workingFrame.width,
            motion: motion,
            animate: false,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn
        )

        return true
    }

    func interactiveMoveUpdate(
        currentLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard var move = interactiveMove else { return nil }

        let dragDistance = hypot(
            currentLocation.x - move.startMouseLocation.x,
            currentLocation.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else {
            return nil
        }

        let hoverTarget = hitTestMoveTarget(
            point: currentLocation,
            excludingWindowId: move.windowId,
            isInsertMode: move.isInsertMode,
            in: workspaceId
        )

        move.currentHoverTarget = hoverTarget
        interactiveMove = move

        return hoverTarget
    }

    func interactiveMoveEnd(
        at _: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = move.currentHoverTarget else {
            return false
        }

        switch target {
        case let .window(targetNodeId, _, position):
            switch position {
            case .swap:
                return swapWindowsByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    in: workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            case .after, .before:
                return insertWindowByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    position: position,
                    in: workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }

        case .columnGap, .workspaceEdge:
            return false
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard let root = roots[workspaceId] else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      window.id != excludingWindowId,
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    let position: InsertPosition = if isInsertMode {
                        point.y < frame.midY ? .before : .after
                    } else {
                        .swap
                    }
                    return .window(
                        nodeId: window.id,
                        handle: window.handle,
                        insertPosition: position
                    )
                }
            }
        }

        return nil
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        fromColumnIndex: Int? = nil
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        let sourceSize = sourceWindow.size
        let sourceHeight = sourceWindow.height
        let targetSize = targetWindow.size
        let targetHeight = targetWindow.height

        guard let plan = callTopologyKernel(
            operation: .swapWindows,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            subject: sourceWindow,
            target: targetWindow,
            fromColumnIndex: fromColumnIndex,
            motion: motion
        ), plan.effectKind != .none else {
            return false
        }

        let swapsAcrossColumns = plan.result.source_column_index != plan.result.target_column_index
        _ = applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)

        if swapsAcrossColumns {
            sourceWindow.size = targetSize
            sourceWindow.height = targetHeight
            targetWindow.size = sourceSize
            targetWindow.height = sourceHeight
        }

        return true
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        if position == .swap {
            return swapWindowsByMove(
                sourceWindowId: sourceWindowId,
                targetWindowId: targetWindowId,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let plan = callTopologyKernel(
            operation: .insertWindowByMove,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            subject: sourceWindow,
            target: targetWindow,
            insertIndex: topologyInsertIndex(for: position),
            motion: motion
        ), plan.effectKind != .none else {
            return false
        }

        _ = applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
        sourceWindow.size = 1.0
        sourceWindow.height = .default

        return true
    }

    func insertionDropzoneFrame(
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        gaps: CGFloat
    ) -> CGRect? {
        guard let targetWindow = findNode(by: targetWindowId) as? NiriWindow,
              let targetFrame = targetWindow.renderedFrame ?? targetWindow.frame,
              let column = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return nil
        }

        let windows = column.windowNodes
        let n = windows.count
        let postInsertionCount = n + 1
        let firstFrame = windows.first?.renderedFrame ?? windows.first?.frame
        let lastFrame = windows.last?.renderedFrame ?? windows.last?.frame
        guard let bottom = firstFrame?.minY, let top = lastFrame?.maxY else { return nil }

        let columnHeight = top - bottom
        let totalGaps = CGFloat(postInsertionCount - 1) * gaps
        let newHeight = max(0, (columnHeight - totalGaps) / CGFloat(postInsertionCount))
        let x = targetFrame.minX
        let width = targetFrame.width

        let y: CGFloat = switch position {
        case .before:
            max(top, targetFrame.minY - gaps - newHeight)
        case .after:
            targetFrame.maxY + gaps
        case .swap:
            targetFrame.minY
        }

        return CGRect(x: x, y: y, width: width, height: newHeight)
    }
}
