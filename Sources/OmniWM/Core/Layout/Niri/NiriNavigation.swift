import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveSelectionByColumns(
        steps: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        guard steps != 0 else { return currentSelection }

        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }

        guard let currentColumn = column(of: currentSelection),
              let currentIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return nil
        }

        let currentWindowNodes = currentColumn.windowNodes
        let currentRowIndex = currentWindowNodes.firstIndex(where: { $0.id == currentSelection.id }) ?? 0
        currentColumn.setActiveTileIdx(currentRowIndex)

        let len = cols.count
        let targetIdx: Int

        if infiniteLoop {
            let raw = currentIdx + steps
            targetIdx = ((raw % len) + len) % len
        } else {
            let raw = currentIdx + steps
            guard raw >= 0, raw < len else {
                return nil
            }
            targetIdx = raw
        }

        let targetColumn = cols[targetIdx]
        let targetRows = targetColumn.windowNodes
        guard !targetRows.isEmpty else { return targetColumn.firstChild() }

        let clampedRowIndex = min(targetRowIndex ?? targetColumn.activeTileIdx, targetRows.count - 1)
        return targetRows[clampedRowIndex]
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
        let step = (direction == .right) ? 1 : -1
        guard let newSelection = moveSelectionByColumns(
            steps: step,
            currentSelection: currentSelection,
            in: workspaceId,
            targetRowIndex: targetRowIndex
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        let edge: NiriRevealEdge = (direction == .right) ? .right : .left
        ensureSelectionVisible(
            node: newSelection,
            in: workspaceId,
            state: &state,
            edge: edge,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
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

        let target: NiriNode?
        switch direction {
        case .up:
            target = currentSelection.nextSibling()
        case .down:
            target = currentSelection.prevSibling()
        default:
            target = nil
        }

        if let target {
            let windowNodes = currentColumn.windowNodes
            if let idx = windowNodes.firstIndex(where: { $0.id == target.id }) {
                currentColumn.setActiveTileIdx(idx)
            }
        }

        return target
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
        edge: NiriRevealEdge = .left,
        workingFrame: CGRect,
        gaps: CGFloat,
        alwaysCenterSingleColumn: Bool,
        animationConfig: SpringConfig? = nil,
        fromColumnIndex: Int? = nil
    ) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        guard let col = column(of: node),
              let targetIdx = columnIndex(of: col, in: workspaceId)
        else {
            return
        }

        let prevIdx = fromColumnIndex ?? state.activeColumnIndex

        state.transitionToColumn(
            targetIdx,
            columns: cols,
            gap: gaps,
            viewportWidth: workingFrame.width,
            animate: true,
            centerMode: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromColumnIndex: prevIdx
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
        switch orientation {
        case .horizontal:
            focusTargetHorizontal(
                direction: direction,
                currentSelection: currentSelection,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        case .vertical:
            focusTargetVertical(
                direction: direction,
                currentSelection: currentSelection,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusTargetHorizontal(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        switch direction {
        case .left, .right:
            return moveSelectionHorizontal(
                direction: direction,
                currentSelection: currentSelection,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
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
                    edge: .left,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    alwaysCenterSingleColumn: alwaysCenterSingleColumn
                )
            }
            return target
        }
    }

    private func focusTargetVertical(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        switch direction {
        case .down, .up:
            let mappedDirection: Direction = (direction == .up) ? .left : .right
            return moveSelectionVerticalOrientation(
                direction: mappedDirection,
                currentSelection: currentSelection,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        case .left, .right:
            let target = moveSelectionWithinRow(
                direction: direction,
                currentSelection: currentSelection
            )

            if let target {
                ensureSelectionVisibleVertical(
                    node: target,
                    in: workspaceId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    alwaysCenterSingleColumn: alwaysCenterSingleColumn
                )
            }
            return target
        }
    }

    private func moveSelectionVerticalOrientation(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        targetWindowIndex: Int? = nil
    ) -> NiriNode? {
        let step = (direction == .right) ? 1 : -1
        guard let newSelection = moveSelectionByColumns(
            steps: step,
            currentSelection: currentSelection,
            in: workspaceId,
            targetRowIndex: targetWindowIndex
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisibleVertical(
            node: newSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return newSelection
    }

    private func moveSelectionWithinRow(
        direction: Direction,
        currentSelection: NiriNode
    ) -> NiriNode? {
        guard let currentRow = column(of: currentSelection) else {
            switch direction {
            case .left:
                return currentSelection.prevSibling()
            case .right:
                return currentSelection.nextSibling()
            default:
                return nil
            }
        }

        if currentRow.isTabbed {
            return moveSelectionWithinRowTabbed(
                direction: direction,
                in: currentRow
            )
        }

        switch direction {
        case .left:
            return currentSelection.prevSibling()
        case .right:
            return currentSelection.nextSibling()
        default:
            return nil
        }
    }

    private func moveSelectionWithinRowTabbed(
        direction: Direction,
        in row: NiriContainer
    ) -> NiriNode? {
        let windows = row.windowNodes
        guard !windows.isEmpty else { return nil }

        let currentIdx = row.activeTileIdx
        let newIdx: Int

        switch direction {
        case .right:
            guard currentIdx < windows.count - 1 else { return nil }
            newIdx = currentIdx + 1
        case .left:
            guard currentIdx > 0 else { return nil }
            newIdx = currentIdx - 1
        default:
            return nil
        }

        row.setActiveTileIdx(newIdx)
        updateTabbedColumnVisibility(column: row)

        return windows[newIdx]
    }

    func ensureSelectionVisibleVertical(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        alwaysCenterSingleColumn: Bool,
        animationConfig: SpringConfig? = nil,
        fromRowIndex: Int? = nil
    ) {
        let rows = columns(in: workspaceId)
        guard !rows.isEmpty else { return }

        guard let row = column(of: node),
              let targetIdx = columnIndex(of: row, in: workspaceId)
        else {
            return
        }

        let prevIdx = state.activeColumnIndex
        state.activeColumnIndex = targetIdx
        state.activatePrevColumnOnRemoval = nil

        state.ensureRowVisible(
            rowIndex: targetIdx,
            rows: rows,
            gap: gaps,
            viewportHeight: workingFrame.height,
            animate: true,
            centerMode: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            animationConfig: animationConfig,
            fromRowIndex: fromRowIndex ?? prevIdx
        )

        state.selectionProgress = 0.0
    }

    func focusDownOrLeft(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        if let target = moveSelectionVertical(direction: .down, currentSelection: currentSelection) {
            ensureSelectionVisible(
                node: target,
                in: workspaceId,
                state: &state,
                edge: .left,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
            return target
        }

        return moveSelectionHorizontal(
            direction: .left,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            targetRowIndex: Int.max
        )
    }

    func focusUpOrRight(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        if let target = moveSelectionVertical(direction: .up, currentSelection: currentSelection) {
            ensureSelectionVisible(
                node: target,
                in: workspaceId,
                state: &state,
                edge: .left,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
            return target
        }

        return moveSelectionHorizontal(
            direction: .right,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func focusColumnFirst(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }

        if let currentColumn = column(of: currentSelection) {
            let windowNodes = currentColumn.windowNodes
            let idx = windowNodes.firstIndex(where: { $0.id == currentSelection.id }) ?? 0
            currentColumn.setActiveTileIdx(idx)
        }

        state.activatePrevColumnOnRemoval = nil

        let firstColumn = cols[0]
        let windows = firstColumn.windowNodes
        guard !windows.isEmpty else { return firstColumn.firstChild() }

        let target = windows[min(firstColumn.activeTileIdx, windows.count - 1)]
        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            edge: .left,
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
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }

        if let currentColumn = column(of: currentSelection) {
            let windowNodes = currentColumn.windowNodes
            let idx = windowNodes.firstIndex(where: { $0.id == currentSelection.id }) ?? 0
            currentColumn.setActiveTileIdx(idx)
        }

        state.activatePrevColumnOnRemoval = nil

        let lastColumn = cols[cols.count - 1]
        let windows = lastColumn.windowNodes
        guard !windows.isEmpty else { return lastColumn.firstChild() }

        let target = windows[min(lastColumn.activeTileIdx, windows.count - 1)]
        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            edge: .right,
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
        let cols = columns(in: workspaceId)
        guard cols.indices.contains(columnIndex) else { return nil }

        if let currentColumn = column(of: currentSelection) {
            let windowNodes = currentColumn.windowNodes
            let idx = windowNodes.firstIndex(where: { $0.id == currentSelection.id }) ?? 0
            currentColumn.setActiveTileIdx(idx)
        }

        state.activatePrevColumnOnRemoval = nil

        let targetColumn = cols[columnIndex]
        let windows = targetColumn.windowNodes
        guard !windows.isEmpty else { return targetColumn.firstChild() }

        let target = windows[min(targetColumn.activeTileIdx, windows.count - 1)]
        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            edge: .left,
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
        guard let currentColumn = column(of: currentSelection) else { return nil }

        let windows = currentColumn.windowNodes
        guard windows.indices.contains(windowIndex) else { return nil }

        currentColumn.setActiveTileIdx(windowIndex)
        if currentColumn.isTabbed {
            updateTabbedColumnVisibility(column: currentColumn)
        }

        let target = windows[windowIndex]
        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            state: &state,
            edge: .left,
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
        focusWindowInColumn(
            0,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func focusWindowBottom(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        guard let currentColumn = column(of: currentSelection) else { return nil }
        let windows = currentColumn.windowNodes
        guard !windows.isEmpty else { return nil }
        return focusWindowInColumn(
            windows.count - 1,
            currentSelection: currentSelection,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
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
            edge: .left,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return previousWindow
    }
}
