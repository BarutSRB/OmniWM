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

        for (colIdx, column) in root.columns.enumerated() {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      let frame = window.frame else { continue }

                if window.isFullscreen {
                    continue
                }

                let edges = detectEdges(point: point, frame: frame, threshold: threshold)
                if !edges.isEmpty {
                    return ResizeHitTestResult(
                        windowHandle: window.handle,
                        nodeId: window.id,
                        edges: edges,
                        columnIndex: colIdx,
                        windowFrame: frame
                    )
                }
            }
        }

        return nil
    }

    func hitTestTiled(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let root = roots[workspaceId] else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      let frame = window.frame else { continue }

                if frame.contains(point) {
                    return window
                }
            }
        }

        return nil
    }

    private func detectEdges(point: CGPoint, frame: CGRect, threshold: CGFloat) -> ResizeEdge {
        var edges: ResizeEdge = []

        let expandedFrame = frame.insetBy(dx: -threshold, dy: -threshold)
        guard expandedFrame.contains(point) else {
            return []
        }

        let innerFrame = frame.insetBy(dx: threshold, dy: threshold)
        if innerFrame.contains(point) {
            return []
        }

        if point.x <= frame.minX + threshold, point.x >= frame.minX - threshold {
            edges.insert(.left)
        }
        if point.x >= frame.maxX - threshold, point.x <= frame.maxX + threshold {
            edges.insert(.right)
        }
        if point.y <= frame.minY + threshold, point.y >= frame.minY - threshold {
            edges.insert(.bottom)
        }
        if point.y >= frame.maxY - threshold, point.y <= frame.maxY + threshold {
            edges.insert(.top)
        }

        return edges
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

        let delta = CGPoint(
            x: currentLocation.x - resize.startMouseLocation.x,
            y: currentLocation.y - resize.startMouseLocation.y
        )

        var changed = false

        if resize.edges.hasHorizontal, let originalWidth = resize.originalColumnWidth {
            var dx = delta.x

            if resize.edges.contains(.left) {
                dx = -dx
            }

            let minWidth = column.windowNodes.map(\.constraints.minSize.width).max() ?? 50
            let maxWidth = monitorFrame.width - gaps.horizontal

            let newWidth = originalWidth + dx
            column.cachedWidth = newWidth.clamped(to: minWidth ... maxWidth)
            column.width = .fixed(column.cachedWidth)
            changed = true

            if resize.edges.contains(.left), let origOffset = resize.originalViewOffset {
                let widthDelta = column.cachedWidth - originalWidth
                viewportState { state in
                    state.viewOffsetPixels = .static(origOffset - widthDelta)
                }
            }
        }

        if resize.edges.hasVertical, let originalHeight = resize.originalWindowHeight {
            var dy = delta.y

            if resize.edges.contains(.bottom) {
                dy = -dy
            }

            let pixelsPerWeight = calculateVerticalPixelsPerWeightUnit(
                column: column,
                monitorFrame: monitorFrame,
                gaps: gaps
            )

            if pixelsPerWeight > 0 {
                let weightDelta = dy / pixelsPerWeight
                let newWeight = originalHeight + weightDelta
                windowNode.size = newWeight.clamped(
                    to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                )
                changed = true
            }
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
