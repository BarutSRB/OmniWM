import AppKit
import CZigLayout
import Foundation

extension NiriLayoutEngine {
    private func column(
        for columnId: NodeId,
        snapshot: NiriStateZigKernel.Snapshot
    ) -> NiriContainer? {
        snapshot.columnEntries.first(where: { $0.column.id == columnId })?.column
    }

    private func applyNavigationResultSideEffects(
        snapshot: NiriStateZigKernel.Snapshot,
        outcome: NiriStateZigKernel.NavigationApplyOutcome
    ) {
        if let sourceUpdate = outcome.sourceActiveTileUpdate,
           let column = column(for: sourceUpdate.columnId, snapshot: snapshot)
        {
            column.setActiveTileIdx(sourceUpdate.activeTileIdx)
        }

        if let targetUpdate = outcome.targetActiveTileUpdate,
           let column = column(for: targetUpdate.columnId, snapshot: snapshot)
        {
            column.setActiveTileIdx(targetUpdate.activeTileIdx)
        }

        for columnId in navigationRefreshColumnIds(
            sourceColumnId: outcome.refreshSourceColumnId,
            targetColumnId: outcome.refreshTargetColumnId
        ) {
            guard let column = column(for: columnId, snapshot: snapshot) else { continue }
            updateTabbedColumnVisibility(column: column)
        }
    }

    private func resolveNavigationTargetWithTransientRuntime(
        snapshot: NiriStateZigKernel.Snapshot,
        request: NiriStateZigKernel.NavigationRequest
    ) -> NiriNode? {
        guard let context = NiriLayoutZigKernel.LayoutContext() else {
            return nil
        }

        let seedRC = NiriStateZigKernel.seedRuntimeState(
            context: context,
            snapshot: snapshot
        )
        guard seedRC == OMNI_OK else {
            return nil
        }

        let outcome = NiriStateZigKernel.applyNavigation(
            context: context,
            request: .init(
                request: request,
                snapshot: snapshot
            )
        )
        guard outcome.rc == OMNI_OK else {
            return nil
        }

        applyNavigationResultSideEffects(
            snapshot: snapshot,
            outcome: outcome
        )

        guard let targetWindowId = outcome.targetWindowId else {
            return nil
        }
        return snapshot.windowEntries.first(where: { $0.window.id == targetWindowId })?.window
    }

    private func resolveNavigationTargetNode(
        snapshot: NiriStateZigKernel.Snapshot,
        workspaceId: WorkspaceDescriptor.ID?,
        op: NiriStateZigKernel.NavigationOp,
        currentSelection: NiriNode,
        direction: Direction? = nil,
        orientation: Monitor.Orientation = .horizontal,
        step: Int = 0,
        targetRowIndex: Int = -1,
        targetColumnIndex: Int = -1,
        targetWindowIndex: Int = -1,
        allowMissingSelection: Bool = false
    ) -> NiriNode? {
        let selection = NiriStateZigKernel.makeSelectionContext(node: currentSelection, snapshot: snapshot)
        if selection == nil, !allowMissingSelection {
            return nil
        }

        let request = NiriStateZigKernel.NavigationRequest(
            op: op,
            selection: selection,
            direction: direction,
            orientation: orientation,
            infiniteLoop: infiniteLoop,
            step: step,
            targetRowIndex: targetRowIndex,
            targetColumnIndex: targetColumnIndex,
            targetWindowIndex: targetWindowIndex
        )

        guard let workspaceId else {
            return resolveNavigationTargetWithTransientRuntime(
                snapshot: snapshot,
                request: request
            )
        }

        guard let context = prepareSeededRuntimeContext(
            for: workspaceId,
            snapshot: snapshot
        ) else {
            return nil
        }

        let outcome = NiriStateZigKernel.applyNavigation(
            context: context,
            request: .init(
                request: request,
                snapshot: snapshot
            )
        )
        guard outcome.rc == OMNI_OK else {
            return nil
        }

        guard applyProjectedRuntimeExport(
            context: context,
            workspaceId: workspaceId,
            delta: outcome.delta
        ) != nil else {
            return nil
        }

        guard let targetWindowId = outcome.targetWindowId else {
            return nil
        }
        return root(for: workspaceId)?.findNode(by: targetWindowId)
    }

    func moveSelectionByColumns(
        steps: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        let latencyToken = NiriLatencyProbe.begin(.navigationStep)
        defer { NiriLatencyProbe.end(latencyToken) }

        guard steps != 0 else { return currentSelection }

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        return resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .moveByColumns,
            currentSelection: currentSelection,
            step: steps,
            targetRowIndex: targetRowIndex ?? -1
        )
    }

    func moveSelectionHorizontal(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        moveSelectionCrossContainer(
            direction: direction,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal,
            targetSiblingIndex: targetRowIndex
        )
    }

    private func moveSelectionCrossContainer(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        targetSiblingIndex: Int? = nil
    ) -> NiriNode? {
        guard let step = direction.primaryStep(for: orientation) else { return nil }

        guard let newSelection = moveSelectionByColumns(
            steps: step,
            currentSelection: currentSelection,
            in: workspaceId,
            targetRowIndex: targetSiblingIndex
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: newSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            orientation: orientation
        )

        return newSelection
    }

    func moveSelectionVertical(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        moveSelectionWithinContainer(
            direction: direction,
            currentSelection: currentSelection,
            orientation: .horizontal,
            workspaceId: workspaceId
        )
    }

    private func moveSelectionWithinContainer(
        direction: Direction,
        currentSelection: NiriNode,
        orientation: Monitor.Orientation,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        guard let step = direction.secondaryStep(for: orientation) else { return nil }

        guard let container = column(of: currentSelection) else {
            return step > 0 ? currentSelection.nextSibling() : currentSelection.prevSibling()
        }

        if let resolvedWorkspaceId = workspaceId ?? currentSelection.findRoot()?.workspaceId {
            let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: resolvedWorkspaceId))
            guard !snapshot.columnEntries.isEmpty else { return nil }

            return resolveNavigationTargetNode(
                snapshot: snapshot,
                workspaceId: resolvedWorkspaceId,
                op: .moveVertical,
                currentSelection: currentSelection,
                direction: direction,
                orientation: orientation
            )
        }

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: [container])
        return resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: nil,
            op: .moveVertical,
            currentSelection: currentSelection,
            direction: direction,
            orientation: orientation
        )
    }

    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        alwaysCenterSingleColumn: Bool,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil
    ) {
        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else { return }

        guard let container = column(of: node),
              let targetIdx = columnIndex(of: container, in: workspaceId)
        else {
            return
        }

        let prevIdx = fromContainerIndex ?? state.activeColumnIndex

        let sizeKeyPath: KeyPath<NiriContainer, CGFloat>
        let viewportSpan: CGFloat
        switch orientation {
        case .horizontal:
            sizeKeyPath = \.cachedWidth
            viewportSpan = workingFrame.width
        case .vertical:
            sizeKeyPath = \.cachedHeight
            viewportSpan = workingFrame.height
        }

        let oldActivePos = state.containerPosition(at: state.activeColumnIndex, containers: containers, gap: gaps, sizeKeyPath: sizeKeyPath)
        let newActivePos = state.containerPosition(at: targetIdx, containers: containers, gap: gaps, sizeKeyPath: sizeKeyPath)
        state.viewOffsetPixels.offset(delta: Double(oldActivePos - newActivePos))

        state.activeColumnIndex = targetIdx
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil

        state.ensureContainerVisible(
            containerIndex: targetIdx,
            containers: containers,
            gap: gaps,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            animate: true,
            centerMode: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            animationConfig: animationConfig,
            fromContainerIndex: prevIdx
        )

        state.selectionProgress = 0.0
    }

    func focusTarget(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusTarget,
            currentSelection: currentSelection,
            direction: direction,
            orientation: orientation
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            orientation: orientation
        )

        return target
    }

    func focusDownOrLeft(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusDownOrLeft,
            currentSelection: currentSelection
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusUpOrRight(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusUpOrRight,
            currentSelection: currentSelection
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusColumnFirst(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        state.activatePrevColumnOnRemoval = nil

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusColumnFirst,
            currentSelection: currentSelection,
            allowMissingSelection: true
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusColumnLast(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        state.activatePrevColumnOnRemoval = nil

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusColumnLast,
            currentSelection: currentSelection,
            allowMissingSelection: true
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusColumn(
        _ columnIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard snapshot.columnEntries.indices.contains(columnIndex) else { return nil }

        state.activatePrevColumnOnRemoval = nil

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusColumnIndex,
            currentSelection: currentSelection,
            targetColumnIndex: columnIndex,
            allowMissingSelection: true
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusWindowInColumn(
        _ windowIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusWindowIndex,
            currentSelection: currentSelection,
            targetWindowIndex: windowIndex
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusWindowTop(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusWindowTop,
            currentSelection: currentSelection
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusWindowBottom(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        guard !snapshot.columnEntries.isEmpty else { return nil }

        guard let target = resolveNavigationTargetNode(
            snapshot: snapshot,
            workspaceId: workspaceId,
            op: .focusWindowBottom,
            currentSelection: currentSelection
        )
        else {
            return nil
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return target
    }

    func focusPrevious(
        currentNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        limitToWorkspace: Bool = true
    ) -> NiriWindow? {
        let searchWorkspaceId = limitToWorkspace ? workspaceId : nil
        guard let previousWindow = findMostRecentlyFocusedWindow(
            excluding: currentNodeId,
            in: searchWorkspaceId
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: previousWindow,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return previousWindow
    }
}
