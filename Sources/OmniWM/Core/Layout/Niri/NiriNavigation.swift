import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveSelectionByColumns(
        steps: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriNode? {
        guard steps != 0 else { return currentSelection }

        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }

        guard let currentColumn = column(of: currentSelection),
              let currentIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return nil
        }

        let currentRowIndex = currentColumn.children.firstIndex { $0.id == currentSelection.id } ?? 0

        let len = cols.count
        let targetIdx: Int

        if infiniteLoop {
            let raw = currentIdx + steps
            targetIdx = ((raw % len) + len) % len
        } else {
            let raw = currentIdx + steps
            guard raw >= 0, raw < len else { return nil }
            targetIdx = raw
        }

        let targetColumn = cols[targetIdx]
        let targetRows = targetColumn.windowNodes
        guard !targetRows.isEmpty else { return targetColumn.firstChild() }

        let clampedRowIndex = min(currentRowIndex, targetRows.count - 1)
        return targetRows[clampedRowIndex]
    }

    func moveSelectionHorizontal(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        let step = (direction == .right) ? 1 : -1
        guard let newSelection = moveSelectionByColumns(
            steps: step,
            currentSelection: currentSelection,
            in: workspaceId
        ) else {
            return nil
        }

        let edge: NiriRevealEdge = (direction == .right) ? .right : .left
        ensureSelectionVisible(
            node: newSelection,
            in: workspaceId,
            state: &state,
            edge: edge
        )

        return newSelection
    }

    func moveSelectionVertical(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        guard let currentColumn = column(of: currentSelection) else {
            switch direction {
            case .up:
                return currentSelection.nextSibling()
            case .down:
                return currentSelection.prevSibling()
            default:
                return nil
            }
        }

        if currentColumn.isTabbed {
            return moveSelectionVerticalTabbed(
                direction: direction,
                in: currentColumn,
                workspaceId: workspaceId
            )
        }

        switch direction {
        case .up:
            return currentSelection.nextSibling()
        case .down:
            return currentSelection.prevSibling()
        default:
            return nil
        }
    }

    private func moveSelectionVerticalTabbed(
        direction: Direction,
        in column: NiriContainer,
        workspaceId _: WorkspaceDescriptor.ID?
    ) -> NiriNode? {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return nil }

        let currentIdx = column.activeTileIdx
        let newIdx: Int

        switch direction {
        case .up:
            guard currentIdx < windows.count - 1 else { return nil }
            newIdx = currentIdx + 1
        case .down:
            guard currentIdx > 0 else { return nil }
            newIdx = currentIdx - 1
        default:
            return nil
        }

        column.setActiveTileIdx(newIdx)
        updateTabbedColumnVisibility(column: column)

        return windows[newIdx]
    }

    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        edge: NiriRevealEdge = .left
    ) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        guard let col = column(of: node),
              let targetIdx = columnIndex(of: col, in: workspaceId)
        else {
            return
        }

        let total = cols.count
        let visibleCap = min(maxVisibleColumns, total)

        let shouldCenter = computeShouldCenter(
            targetColumnIndex: targetIdx,
            totalColumns: total,
            visibleCap: visibleCap,
            state: state
        )

        if visibleCap >= total {
            if shouldCenter, total == 1 {
                state.setViewportStart(
                    0,
                    totalColumns: total,
                    visibleCap: visibleCap,
                    infiniteLoop: infiniteLoop
                )
            } else {
                state.setViewportStart(
                    0,
                    totalColumns: total,
                    visibleCap: visibleCap,
                    infiniteLoop: infiniteLoop
                )
            }
            state.selectionProgress = 0.0
            return
        }

        let isVisible: Bool
        if infiniteLoop {
            isVisible = isColumnVisibleInViewport(
                columnIndex: targetIdx,
                viewportStart: state.firstVisibleColumn,
                visibleCap: visibleCap,
                totalColumns: total
            )
        } else {
            let viewportEnd = state.firstVisibleColumn + visibleCap
            isVisible = targetIdx >= state.firstVisibleColumn && targetIdx < viewportEnd
        }

        if isVisible, !shouldCenter {
            return
        }

        let newStart: CGFloat

        if shouldCenter {
            let centeredStart = CGFloat(targetIdx) - CGFloat(visibleCap - 1) / 2.0

            if infiniteLoop {
                newStart = centeredStart
            } else {
                let maxStart = CGFloat(max(0, total - visibleCap))
                newStart = centeredStart.clamped(to: 0 ... maxStart)
            }
        } else {
            if infiniteLoop {
                switch edge {
                case .left:
                    newStart = CGFloat(targetIdx)
                case .right:
                    newStart = CGFloat(targetIdx) - CGFloat(visibleCap - 1)
                }
            } else {
                let maxStart = CGFloat(max(0, total - visibleCap))
                switch edge {
                case .left:
                    newStart = CGFloat(targetIdx).clamped(to: 0 ... maxStart)
                case .right:
                    let trailing = CGFloat(visibleCap - 1)
                    newStart = (CGFloat(targetIdx) - trailing).clamped(to: 0 ... maxStart)
                }
            }
        }

        state.setViewportStart(
            newStart,
            totalColumns: total,
            visibleCap: visibleCap,
            infiniteLoop: infiniteLoop
        )

        state.selectionProgress = 0.0
    }

    private func computeShouldCenter(
        targetColumnIndex: Int,
        totalColumns: Int,
        visibleCap: Int,
        state: ViewportState
    ) -> Bool {
        if alwaysCenterSingleColumn, totalColumns == 1 {
            return true
        }

        switch centerFocusedColumn {
        case .never:
            return false

        case .always:
            return true

        case .onOverflow:
            let currentStart = state.firstVisibleColumn
            let currentEnd = currentStart + visibleCap

            let isAtLeftEdge = targetColumnIndex == currentStart
            let isAtRightEdge = targetColumnIndex == currentEnd - 1

            let isVisible: Bool = if infiniteLoop {
                isColumnVisibleInViewport(
                    columnIndex: targetColumnIndex,
                    viewportStart: currentStart,
                    visibleCap: visibleCap,
                    totalColumns: totalColumns
                )
            } else {
                targetColumnIndex >= currentStart && targetColumnIndex < currentEnd
            }

            return !isVisible || isAtLeftEdge || isAtRightEdge
        }
    }

    private func isColumnVisibleInViewport(
        columnIndex: Int,
        viewportStart: Int,
        visibleCap: Int,
        totalColumns: Int
    ) -> Bool {
        for i in 0 ..< visibleCap {
            let visibleIdx = (viewportStart + i) % totalColumns
            if visibleIdx == columnIndex {
                return true
            }
        }
        return false
    }

    func dndScrollBegin(
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard !columns(in: workspaceId).isEmpty else { return }
        state.dndScrollBegin()
    }

    func dndScrollUpdate(
        _ delta: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> Int? {
        let total = columns(in: workspaceId).count
        guard total > 0 else { return nil }
        let visibleCap = min(maxVisibleColumns, total)

        return state.dndScrollUpdate(
            delta: delta,
            totalColumns: total,
            visibleCap: visibleCap,
            infiniteLoop: infiniteLoop
        )
    }

    func dndScrollEnd(
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        let total = columns(in: workspaceId).count
        guard total > 0 else { return }
        let visibleCap = min(maxVisibleColumns, total)
        state.dndScrollEnd(
            totalColumns: total,
            visibleCap: visibleCap,
            infiniteLoop: infiniteLoop
        )
    }

    func focusTarget(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        switch direction {
        case .left, .right:
            return moveSelectionHorizontal(
                direction: direction,
                currentSelection: currentSelection,
                in: workspaceId,
                state: &state
            )
        case .down, .up:
            let target = moveSelectionVertical(
                direction: direction,
                currentSelection: currentSelection
            )

            if let target {
                ensureSelectionVisible(
                    node: target,
                    in: workspaceId,
                    state: &state,
                    edge: .left
                )
            }
            return target
        }
    }

    func focusDownOrLeft(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        if let target = moveSelectionVertical(direction: .down, currentSelection: currentSelection) {
            ensureSelectionVisible(node: target, in: workspaceId, state: &state, edge: .left)
            return target
        }

        return moveSelectionHorizontal(
            direction: .left,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state
        )
    }

    func focusUpOrRight(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        if let target = moveSelectionVertical(direction: .up, currentSelection: currentSelection) {
            ensureSelectionVisible(node: target, in: workspaceId, state: &state, edge: .left)
            return target
        }

        return moveSelectionHorizontal(
            direction: .right,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state
        )
    }

    func focusColumnFirst(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }

        let currentRowIndex: Int = if let currentColumn = column(of: currentSelection) {
            currentColumn.children.firstIndex { $0.id == currentSelection.id } ?? 0
        } else {
            0
        }

        let firstColumn = cols[0]
        let windows = firstColumn.windowNodes
        guard !windows.isEmpty else { return firstColumn.firstChild() }

        let target = windows[min(currentRowIndex, windows.count - 1)]
        ensureSelectionVisible(node: target, in: workspaceId, state: &state, edge: .left)
        return target
    }

    func focusColumnLast(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }

        let currentRowIndex: Int = if let currentColumn = column(of: currentSelection) {
            currentColumn.children.firstIndex { $0.id == currentSelection.id } ?? 0
        } else {
            0
        }

        let lastColumn = cols[cols.count - 1]
        let windows = lastColumn.windowNodes
        guard !windows.isEmpty else { return lastColumn.firstChild() }

        let target = windows[min(currentRowIndex, windows.count - 1)]
        ensureSelectionVisible(node: target, in: workspaceId, state: &state, edge: .right)
        return target
    }

    func focusColumn(
        _ columnIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        let cols = columns(in: workspaceId)
        guard cols.indices.contains(columnIndex) else { return nil }

        let currentRowIndex: Int = if let currentColumn = column(of: currentSelection) {
            currentColumn.children.firstIndex { $0.id == currentSelection.id } ?? 0
        } else {
            0
        }

        let targetColumn = cols[columnIndex]
        let windows = targetColumn.windowNodes
        guard !windows.isEmpty else { return targetColumn.firstChild() }

        let target = windows[min(currentRowIndex, windows.count - 1)]
        ensureSelectionVisible(node: target, in: workspaceId, state: &state, edge: .left)
        return target
    }

    func focusWindowInColumn(
        _ windowIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        guard let currentColumn = column(of: currentSelection) else { return nil }

        let windows = currentColumn.windowNodes
        guard windows.indices.contains(windowIndex) else { return nil }

        if currentColumn.isTabbed {
            currentColumn.setActiveTileIdx(windowIndex)
            updateTabbedColumnVisibility(column: currentColumn)
        }

        let target = windows[windowIndex]
        ensureSelectionVisible(node: target, in: workspaceId, state: &state, edge: .left)
        return target
    }

    func focusWindowTop(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        focusWindowInColumn(0, currentSelection: currentSelection, in: workspaceId, state: &state)
    }

    func focusWindowBottom(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        guard let currentColumn = column(of: currentSelection) else { return nil }
        let windows = currentColumn.windowNodes
        guard !windows.isEmpty else { return nil }
        return focusWindowInColumn(
            windows.count - 1,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state
        )
    }

    func focusPrevious(
        currentNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        limitToWorkspace: Bool = true
    ) -> NiriWindow? {
        let searchWorkspaceId = limitToWorkspace ? workspaceId : nil
        guard let previousWindow = findMostRecentlyFocusedWindow(
            excluding: currentNodeId,
            in: searchWorkspaceId
        ) else {
            return nil
        }

        ensureSelectionVisible(
            node: previousWindow,
            in: workspaceId,
            state: &state,
            edge: .left
        )

        return previousWindow
    }
}
