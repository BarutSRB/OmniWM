import AppKit
import Foundation

extension NiriLayoutEngine {
    @discardableResult
    func toggleColumnTabbed(in workspaceId: WorkspaceDescriptor.ID, state: ViewportState) -> Bool {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId),
              let column = column(of: selectedNode)
        else {
            return false
        }

        let newMode: ColumnDisplay = column.displayMode == .normal ? .tabbed : .normal
        return setColumnDisplay(newMode, for: column)
    }

    @discardableResult
    func setColumnDisplay(_ mode: ColumnDisplay, for column: NiriContainer, gaps: CGFloat = 0) -> Bool {
        guard column.displayMode != mode else { return false }

        if let resize = interactiveResize,
           let resizeWindow = findNode(by: resize.windowId) as? NiriWindow,
           let resizeColumn = findColumn(containing: resizeWindow, in: resize.workspaceId),
           resizeColumn.id == column.id
        {
            clearInteractiveResize()
        }

        let windows = column.windowNodes
        guard !windows.isEmpty else {
            column.displayMode = mode
            return true
        }

        let prevOrigin = tilesOrigin(column: column)

        column.displayMode = mode
        let newOrigin = tilesOrigin(column: column)
        let originDelta = CGPoint(x: prevOrigin.x - newOrigin.x, y: prevOrigin.y - newOrigin.y)

        column.displayMode = .normal
        let tileOffsets = computeTileOffsets(column: column, gaps: gaps)

        for (idx, window) in windows.enumerated() {
            var yDelta = idx < tileOffsets.count ? tileOffsets[idx] : 0
            yDelta -= prevOrigin.y

            if mode == .normal {
                yDelta *= -1
            }

            let delta = CGPoint(x: originDelta.x, y: originDelta.y + yDelta)
            if delta.x != 0 || delta.y != 0 {
                window.animateMoveFrom(
                    displacement: delta,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    animationsEnabled: animationsEnabled
                )
            }
        }

        column.displayMode = mode
        updateTabbedColumnVisibility(column: column)

        return true
    }

    func updateTabbedColumnVisibility(column: NiriContainer) {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return }

        column.clampActiveTileIdx()

        if column.displayMode == .tabbed {
            for (idx, window) in windows.enumerated() {
                let isActive = idx == column.activeTileIdx
                window.isHiddenInTabbedMode = !isActive
            }
        } else {
            for window in windows {
                window.isHiddenInTabbedMode = false
            }
        }
    }

    @discardableResult
    func activateTab(at index: Int, in column: NiriContainer) -> Bool {
        guard column.displayMode == .tabbed else { return false }

        let prevIdx = column.activeTileIdx
        column.setActiveTileIdx(index)

        if prevIdx != column.activeTileIdx {
            updateTabbedColumnVisibility(column: column)
            return true
        }
        return false
    }

    func activeColumn(in _: WorkspaceDescriptor.ID, state: ViewportState) -> NiriContainer? {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId)
        else {
            return nil
        }
        return column(of: selectedNode)
    }
}
