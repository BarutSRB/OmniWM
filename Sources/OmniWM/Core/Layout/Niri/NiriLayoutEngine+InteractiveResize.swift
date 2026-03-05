import AppKit
import Foundation

extension NiriLayoutEngine {
    private func resolveRuntimeWindowAndColumn(
        windowId: NodeId,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (
        window: NiriWindow,
        windowView: NiriRuntimeWorkspaceView.WindowView,
        column: NiriContainer
    )? {
        guard let view = runtimeWorkspaceView(for: workspaceId),
              let windowView = view.window(for: windowId),
              let handle = windowView.handle,
              let window = handleToNode[handle],
              let column = runtimeColumnNode(for: windowView.columnId, in: workspaceId)
        else {
            return nil
        }

        return (window: window, windowView: windowView, column: column)
    }

    func hitTestResize(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        threshold: CGFloat? = nil
    ) -> ResizeHitTestResult? {
        let threshold = threshold ?? resizeConfiguration.edgeThreshold
        guard let interaction = interactionState(for: workspaceId) else { return nil }
        let hitResult: NiriLayoutZigKernel.ResizeHitResult?
        do {
            hitResult = try NiriLayoutZigKernel.hitTestResize(
                context: interaction.context,
                interaction: interaction.index,
                point: point,
                threshold: threshold
            )
        } catch {
            return nil
        }
        guard let hit = hitResult else {
            return nil
        }

        return ResizeHitTestResult(
            windowHandle: hit.window.handle,
            nodeId: hit.window.id,
            edges: hit.edges,
            columnIndex: hit.columnIndex,
            windowFrame: hit.frame
        )
    }

    func hitTestTiled(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let interaction = interactionState(for: workspaceId) else { return nil }
        do {
            return try NiriLayoutZigKernel.hitTestTiled(
                context: interaction.context,
                interaction: interaction.index,
                point: point
            )
        } catch {
            return nil
        }
    }

    func interactiveResizeBegin(
        windowId: NodeId,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        viewOffset: CGFloat? = nil
    ) -> Bool {
        guard interactiveResize == nil else { return false }

        guard let resolved = resolveRuntimeWindowAndColumn(
            windowId: windowId,
            workspaceId: workspaceId
        ) else {
            return false
        }
        let windowNode = resolved.window
        let column = resolved.column
        let colIdx = resolved.windowView.columnOrderIndex
        if windowNode.isFullscreen {
            return false
        }

        if windowNode.constraints.isFixed {
            return false
        }

        let originalColumnWidth = edges.hasHorizontal ? column.cachedWidth : nil
        let originalWindowHeight = edges.hasVertical ? windowNode.size : nil

        interactiveResize = InteractiveResize(
            windowId: windowId,
            workspaceId: workspaceId,
            originalColumnWidth: originalColumnWidth,
            originalWindowHeight: originalWindowHeight,
            edges: edges,
            startMouseLocation: startLocation,
            columnIndex: colIdx,
            originalViewOffset: edges.contains(.left) ? viewOffset : nil
        )

        return true
    }

    func interactiveResizeUpdate(
        currentLocation: CGPoint,
        monitorFrame: CGRect,
        gaps: LayoutGaps,
        viewportState: ((inout ViewportState) -> Void) -> Void = { _ in }
    ) -> Bool {
        let latencyToken = NiriLatencyProbe.begin(.resizeDragUpdate)
        defer { NiriLatencyProbe.end(latencyToken) }

        guard let resize = interactiveResize else { return false }

        guard let resolved = resolveRuntimeWindowAndColumn(
            windowId: resize.windowId,
            workspaceId: resize.workspaceId
        ) else {
            clearInteractiveResize()
            return false
        }
        let windowNode = resolved.window
        let column = resolved.column

        let hasHorizontal = resize.edges.hasHorizontal && resize.originalColumnWidth != nil
        let minColumnWidth: CGFloat = hasHorizontal
            ? (column.windowNodes.map(\.constraints.minSize.width).max() ?? 50)
            : 0
        let maxColumnWidth: CGFloat = hasHorizontal
            ? (monitorFrame.width - gaps.horizontal)
            : 0

        let hasVertical = resize.edges.hasVertical && resize.originalWindowHeight != nil
        let pixelsPerWeight: CGFloat = hasVertical
            ? calculateVerticalPixelsPerWeightUnit(
                column: column,
                monitorFrame: monitorFrame,
                gaps: gaps
            )
            : 0

        let result: NiriLayoutZigKernel.ResizeComputationResult
        do {
            result = try NiriLayoutZigKernel.computeResize(
                .init(
                    edges: resize.edges,
                    startLocation: resize.startMouseLocation,
                    currentLocation: currentLocation,
                    originalColumnWidth: resize.originalColumnWidth ?? 0,
                    minColumnWidth: minColumnWidth,
                    maxColumnWidth: maxColumnWidth,
                    originalWindowWeight: resize.originalWindowHeight ?? 0,
                    minWindowWeight: resizeConfiguration.minWindowWeight,
                    maxWindowWeight: resizeConfiguration.maxWindowWeight,
                    pixelsPerWeight: pixelsPerWeight,
                    originalViewOffset: resize.originalViewOffset
                )
            )
        } catch {
            return false
        }

        var changed = false
        if hasHorizontal, result.changedWidth {
            column.cachedWidth = result.newColumnWidth
            column.width = .fixed(result.newColumnWidth)
            changed = true
        }

        if result.adjustViewOffset {
            viewportState { state in
                state.viewOffsetPixels = .static(result.newViewOffset)
            }
        }

        if hasVertical, result.changedWeight {
            windowNode.size = result.newWindowWeight
            changed = true
        }

        // Keep drag updates lightweight; runtime commit happens once in `interactiveResizeEnd`.
        return changed
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func interactiveResizeEnd(
        windowId: NodeId? = nil,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let resize = interactiveResize else { return }

        if let windowId, windowId != resize.windowId {
            return
        }

        if let resolved = resolveRuntimeWindowAndColumn(
            windowId: resize.windowId,
            workspaceId: resize.workspaceId
        ) {
            let windowNode = resolved.window
            let runtimeStore = runtimeStore(for: resize.workspaceId)
            if resize.edges.hasHorizontal,
               let column = runtimeColumnNode(
                   for: resolved.windowView.columnId,
                   in: resize.workspaceId
               )
            {
                _ = runtimeStore.executeMutation(
                    .setColumnWidth(
                        sourceColumnId: column.id,
                        width: column.width,
                        isFullWidth: column.isFullWidth,
                        savedWidth: column.savedWidth
                    )
                )
            }
            if resize.edges.hasVertical {
                _ = runtimeStore.executeMutation(
                    .setWindowHeight(
                        sourceWindowId: windowNode.id,
                        height: windowNode.height
                    )
                )
            }

            ensureSelectionVisible(
                node: windowNode,
                in: resize.workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
        }

        interactiveResize = nil
    }
}
