import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct ColumnTransferResult {
        let insertedTileIndex: Int
        let sourceBecameEmpty: Bool
        let sourceColumnIndexBeforeCleanup: Int
        let targetColumnIndexAfterInsert: Int
    }

    private enum TargetColumnInsertionPolicy {
        case append
        case visualBottom

        func insertionIndex(in targetColumn: NiriContainer) -> Int {
            switch self {
            case .append:
                targetColumn.children.count
            case .visualBottom:
                visualBottomInsertionIndex(in: targetColumn)
            }
        }

        private func visualBottomInsertionIndex(in _: NiriContainer) -> Int {
            // Current child ordering renders index 0 at the visual bottom of a column.
            0
        }
    }

    @discardableResult
    private func moveWindowToColumn(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        to targetColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        targetInsertionPolicy: TargetColumnInsertionPolicy = .append,
        activateInsertedWindowInTabbedTarget: Bool = false
    ) -> ColumnTransferResult {
        let sourceColumnIndexBeforeCleanup = columnIndex(of: sourceColumn, in: workspaceId) ?? 0
        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: node)

        node.detach()
        let insertedIndex = targetInsertionPolicy
            .insertionIndex(in: targetColumn)
            .clamped(to: 0 ... targetColumn.children.count)
        targetColumn.insertChild(node, at: insertedIndex)

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        if targetColumn.displayMode == .tabbed {
            if activateInsertedWindowInTabbedTarget {
                targetColumn.setActiveTileIdx(insertedIndex)
            }
            updateTabbedColumnVisibility(column: targetColumn)
        } else {
            node.isHiddenInTabbedMode = false
        }

        return ColumnTransferResult(
            insertedTileIndex: insertedIndex,
            sourceBecameEmpty: sourceColumn.children.isEmpty,
            sourceColumnIndexBeforeCleanup: sourceColumnIndexBeforeCleanup,
            targetColumnIndexAfterInsert: columnIndex(of: targetColumn, in: workspaceId) ?? sourceColumnIndexBeforeCleanup
        )
    }

    func createColumnAndMove(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        guard let root = roots[workspaceId] else { return }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: node)

        let newColumn = NiriContainer()
        initializeNewColumnWidth(newColumn, in: workspaceId)

        if direction == .right {
            root.insertAfter(newColumn, reference: sourceColumn)
        } else {
            root.insertBefore(newColumn, reference: sourceColumn)
        }

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            if newColIdx == state.activeColumnIndex + 1 {
                state.activatePrevColumnOnRemoval = state.stationary()
            }
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingAreaWidth
            )
        }

        node.detach()
        newColumn.appendChild(node)

        node.isHiddenInTabbedMode = false

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)
    }

    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        guard let sourceColumn = findColumn(containing: window, in: workspaceId) else { return false }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        initializeNewColumnWidth(newColumn, in: workspaceId)

        let cols = columns(in: workspaceId)
        let clampedIndex = insertIndex.clamped(to: 0 ... cols.count)
        if clampedIndex >= cols.count {
            root.appendChild(newColumn)
        } else {
            root.insertBefore(newColumn, reference: cols[clampedIndex])
        }

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )
        }

        window.detach()
        newColumn.appendChild(window)
        window.isHiddenInTabbedMode = false

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

        return true
    }

    func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard column.children.isEmpty else { return }

        column.remove()

        if let root = roots[workspaceId], root.columns.isEmpty {
            let emptyColumn = NiriContainer()
            root.appendChild(emptyColumn)
        }
    }

    func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
        let cols = columns(in: workspaceId)
        guard cols.count > 1 else { return }

        let totalSize = cols.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(cols.count)

        for col in cols {
            let normalized = col.size / avgSize
            col.size = max(0.5, min(2.0, normalized))
        }
    }

    func normalizeWindowSizes(in column: NiriContainer) {
        let windows = column.children.compactMap { $0 as? NiriWindow }
        guard !windows.isEmpty else { return }

        let totalSize = windows.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(windows.count)

        for window in windows {
            let normalized = window.size / avgSize
            window.size = max(0.5, min(2.0, normalized))
        }
    }

    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        workingAreaWidth: CGFloat,
        gaps: CGFloat
    ) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        let balancedWidth = 1.0 / CGFloat(effectiveMaxVisibleColumns(in: workspaceId))
        let targetPixels = (workingAreaWidth - gaps) * balancedWidth

        for column in cols {
            column.width = .proportion(balancedWidth)
            column.isFullWidth = false
            column.savedWidth = nil
            column.presetWidthIdx = nil

            column.animateWidthTo(
                newWidth: targetPixels,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )

            for window in column.windowNodes {
                window.size = 1.0
            }
        }
    }

    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        let cols = columns(in: workspaceId)
        guard let currentIdx = columnIndex(of: column, in: workspaceId) else { return false }

        let currentColX = state.columnX(at: currentIdx, columns: cols, gap: gaps)
        let nextColX = currentIdx + 1 < cols.count
            ? state.columnX(at: currentIdx + 1, columns: cols, gap: gaps)
            : currentColX + (
                column.cachedWidth > 0
                    ? column.cachedWidth
                    : workingFrame.width / CGFloat(effectiveMaxVisibleColumns(in: workspaceId))
            ) + gaps

        let step = (direction == .right) ? 1 : -1
        guard let targetIdx = wrapIndex(currentIdx + step, total: cols.count, in: workspaceId) else { return false }

        if targetIdx == currentIdx { return false }

        let targetColumn = cols[targetIdx]

        guard let root = roots[workspaceId] else { return false }
        root.swapChildren(column, targetColumn)

        let newCols = columns(in: workspaceId)
        let viewOffsetDelta = -state.columnX(at: currentIdx, columns: newCols, gap: gaps) + currentColX
        state.offsetViewport(by: viewOffsetDelta)

        let newColX = state.columnX(at: targetIdx, columns: newCols, gap: gaps)
        column.animateMoveFrom(
            displacement: CGPoint(x: currentColX - newColX, y: 0),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        let othersXOffset = nextColX - currentColX
        if currentIdx < targetIdx {
            for i in currentIdx ..< targetIdx {
                let col = newCols[i]
                if col.id != column.id {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        } else {
            for i in (targetIdx + 1) ... currentIdx {
                let col = newCols[i]
                if col.id != column.id {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: -othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        }

        ensureColumnVisible(
            column,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animationConfig: windowMovementAnimationConfig,
            fromContainerIndex: currentIdx
        )

        return true
    }

    func consumeOrExpelWindow(
        _ window: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let currentIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        if currentColumn.windowNodes.count > 1 {
            return expelWindow(
                window,
                to: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        let cols = columns(in: workspaceId)
        let step = (direction == .right) ? 1 : -1
        guard let neighborIdx = wrapIndex(currentIdx + step, total: cols.count, in: workspaceId) else { return false }

        if neighborIdx == currentIdx { return false }

        let neighborColumn = cols[neighborIdx]
        guard neighborColumn.id != currentColumn.id else { return false }
        guard neighborColumn.children.count < effectiveMaxWindowsPerColumn(in: workspaceId) else { return false }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let previousActiveColumnIndex = state.activeColumnIndex
        let previousActiveColumnPosition = state.columnX(
            at: previousActiveColumnIndex,
            columns: cols,
            gap: gaps
        )
        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourceColX = state.columnX(at: currentIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceTileIdx, gaps: gaps)

        let transfer = moveWindowToColumn(
            window,
            from: currentColumn,
            to: neighborColumn,
            in: workspaceId,
            targetInsertionPolicy: .visualBottom,
            activateInsertedWindowInTabbedTarget: neighborColumn.displayMode == .tabbed
        )

        state.selectedNodeId = window.id

        if transfer.sourceBecameEmpty {
            _ = animateColumnsForRemoval(
                columnIndex: transfer.sourceColumnIndexBeforeCleanup,
                in: workspaceId,
                state: &state,
                gaps: gaps
            )
            cleanupEmptyColumn(currentColumn, in: workspaceId, state: &state)
        }

        let newCols = columns(in: workspaceId)
        let targetColIdx = columnIndex(of: neighborColumn, in: workspaceId) ?? transfer.targetColumnIndexAfterInsert
        let targetColX = state.columnX(at: targetColIdx, columns: newCols, gap: gaps)
        let targetColRenderOffset = neighborColumn.renderOffset()
        let targetTileOffset = computeTileOffset(
            column: neighborColumn,
            tileIdx: transfer.insertedTileIndex,
            gaps: gaps
        )

        let displacement = CGPoint(
            x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
            y: sourceTileOffset - targetTileOffset
        )
        if displacement.x != 0 || displacement.y != 0 {
            window.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )
        }

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            fromContainerIndex: previousActiveColumnIndex,
            previousActiveContainerPosition: previousActiveColumnPosition
        )

        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let root = roots[workspaceId],
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)

        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourceColX = state.columnX(at: currentColIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceTileIdx, gaps: gaps)

        let wasTabbed = currentColumn.displayMode == .tabbed
        currentColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        initializeNewColumnWidth(newColumn, in: workspaceId)

        if direction == .right {
            root.insertAfter(newColumn, reference: currentColumn)
        } else {
            root.insertBefore(newColumn, reference: currentColumn)
        }

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )
        }

        window.detach()
        newColumn.appendChild(window)

        window.isHiddenInTabbedMode = false

        let newCols = columns(in: workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            let targetColX = state.columnX(at: newColIdx, columns: newCols, gap: gaps)
            let targetColRenderOffset = newColumn.renderOffset(at: now)

            let displacement = CGPoint(
                x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
                y: sourceTileOffset
            )

            if displacement.x != 0 || displacement.y != 0 {
                window.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate
                )
            }
        }

        if wasTabbed, !currentColumn.children.isEmpty {
            currentColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: currentColumn)
        }

        cleanupEmptyColumn(currentColumn, in: workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

        return true
    }

    private func ensureColumnVisible(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil
    ) {
        if let firstWindow = column.windowNodes.first {
            ensureSelectionVisible(
                node: firstWindow,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex
            )
        }
    }
}
