import AppKit
import Foundation

extension NiriLayoutEngine {
    func hitTestResize(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        threshold: CGFloat? = nil
    ) -> ResizeHitTestResult? {
        guard let root = roots[workspaceId] else { return nil }

        let threshold = threshold ?? resizeConfiguration.edgeThreshold
        guard let hit = NiriLayoutZigKernel.hitTestResize(
            columns: root.columns,
            point: point,
            threshold: threshold
        ) else {
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
        guard let root = roots[workspaceId] else { return nil }
        return NiriLayoutZigKernel.hitTestTiled(
            columns: root.columns,
            point: point
        )
    }

    func interactiveResizeBegin(
        windowId: NodeId,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        viewOffset: CGFloat? = nil
    ) -> Bool {
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }
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
        guard let resize = interactiveResize else { return false }

        guard let windowNode = findNode(by: resize.windowId) as? NiriWindow else {
            clearInteractiveResize()
            return false
        }

        guard let column = findColumn(containing: windowNode, in: resize.workspaceId) else {
            clearInteractiveResize()
            return false
        }

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

        let result = NiriLayoutZigKernel.computeResize(
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

        if let windowNode = findNode(by: resize.windowId) as? NiriWindow {
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
