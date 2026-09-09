// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct ColumnTransferResult {
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

    private func resetMovedWindowColumnLocalSizing(_ window: NiriWindow) {
        window.height = .default
        window.windowWidth = .default
        window.resolvedHeight = nil
        window.resolvedWidth = nil
        window.heightFixedByConstraint = false
        window.widthFixedByConstraint = false
    }

    private func primarySizeKeyPath(
        for orientation: Monitor.Orientation
    ) -> KeyPath<NiriContainer, CGFloat> {
        switch orientation {
        case .horizontal: \.cachedWidth
        case .vertical: \.cachedHeight
        }
    }

    private func primaryDisplacement(
        _ primary: CGFloat,
        secondary: CGFloat = 0,
        orientation: Monitor.Orientation
    ) -> CGPoint {
        switch orientation {
        case .horizontal: CGPoint(x: primary, y: secondary)
        case .vertical: CGPoint(x: secondary, y: primary)
        }
    }

    private func transferDisplacement(
        sourcePosition: CGFloat,
        sourceRenderOffset: CGPoint,
        targetPosition: CGFloat,
        targetRenderOffset: CGPoint,
        secondary: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGPoint {
        let sourceRender = switch orientation {
        case .horizontal: sourceRenderOffset.x
        case .vertical: sourceRenderOffset.y
        }
        let targetRender = switch orientation {
        case .horizontal: targetRenderOffset.x
        case .vertical: targetRenderOffset.y
        }
        return primaryDisplacement(
            sourcePosition + sourceRender - targetPosition - targetRender,
            secondary: secondary,
            orientation: orientation
        )
    }

    @discardableResult
    private func moveWindowToColumn(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        to targetColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        targetInsertionPolicy: TargetColumnInsertionPolicy = .append,
        activateInsertedWindowInTarget: Bool = false
    ) -> ColumnTransferResult {
        let sourceColumnIndexBeforeCleanup = columnIndex(of: sourceColumn, in: workspaceId) ?? 0
        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        let targetActiveTileIdxBeforeInsert = targetColumn.activeTileIdx
        sourceColumn.adjustActiveTileIdxForRemoval(of: node)

        node.detach()
        let insertedIndex = targetInsertionPolicy
            .insertionIndex(in: targetColumn)
            .clamped(to: 0 ... targetColumn.children.count)
        targetColumn.insertChild(node, at: insertedIndex)
        NiriLayoutTrace.record(
            .insertion,
            workspaceId: workspaceId,
            "moveToColumn index=\(insertedIndex) policy=\(String(describing: targetInsertionPolicy)) count=\(targetColumn.children.count)"
        )
        resetMovedWindowColumnLocalSizing(node)

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        if activateInsertedWindowInTarget {
            targetColumn.setActiveTileIdx(insertedIndex)
        } else if insertedIndex <= targetActiveTileIdxBeforeInsert {
            targetColumn.setActiveTileIdx(targetActiveTileIdxBeforeInsert + 1)
        }

        if targetColumn.displayMode == .tabbed {
            updateTabbedColumnVisibility(column: targetColumn)
        } else {
            node.isHiddenInTabbedMode = false
        }

        return ColumnTransferResult(
            sourceBecameEmpty: sourceColumn.children.isEmpty,
            sourceColumnIndexBeforeCleanup: sourceColumnIndexBeforeCleanup,
            targetColumnIndexAfterInsert: columnIndex(of: targetColumn, in: workspaceId) ??
                sourceColumnIndexBeforeCleanup
        )
    }

    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        context: NiriInteractionContext,
        state: inout ViewportState,
        sizingPolicy: NewContainerSizingPolicy = .workspaceDefault
    ) -> Bool {
        assertSanctionedMutation()
        guard let root = root(for: context.workspaceId) else { return false }
        guard let sourceColumn = findColumn(containing: window, in: context.workspaceId) else { return false }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        switch sizingPolicy {
        case .workspaceDefault:
            initializeNewContainerSizing(newColumn, in: context.workspaceId)
        case .inheritSource:
            copyContainerSizingState(from: sourceColumn, to: newColumn)
        }

        let cols = columns(in: context.workspaceId)
        let clampedIndex = insertIndex.clamped(to: 0 ... cols.count)
        if clampedIndex >= cols.count {
            root.appendChild(newColumn)
        } else {
            root.insertBefore(newColumn, reference: cols[clampedIndex])
        }

        if let newColIdx = columnIndex(of: newColumn, in: context.workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: context.workspaceId,
                motion: context.motion,
                state: state,
                gaps: context.gaps,
                workingFrame: context.workingFrame,
                orientation: context.orientation
            )
        }

        window.detach()
        newColumn.appendChild(window)
        window.isHiddenInTabbedMode = false

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        cleanupEmptyColumn(sourceColumn, in: context.workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: context.workspaceId,
            motion: context.motion,
            state: &state,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )

        return true
    }

    func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard column.children.isEmpty else { return }

        // Window-close removals use removeWindows(...); this is structural cleanup for move/consume paths.
        column.remove()
    }

    private func clampedSpan(
        _ span: CGFloat,
        to bounds: (min: CGFloat, max: CGFloat?)
    ) -> CGFloat {
        let lowerBounded = max(span, bounds.min)
        return bounds.max.map { min(lowerBounded, $0) } ?? lowerBounded
    }

    @discardableResult
    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        let columns = projectedColumns(in: workspaceId)
        guard !columns.isEmpty else { return false }

        let resolvedWidth = resolvedContainerResetPrimarySpan(in: workspaceId)
        switch orientation {
        case .horizontal:
            let targetPixels = (workingFrame.width - gaps) * resolvedWidth.proportion - gaps
            for projectedColumn in columns {
                let column = projectedColumn.column
                column.width = .proportion(resolvedWidth.proportion)
                column.isFullWidth = false
                column.savedWidth = nil
                column.presetWidthIdx = resolvedWidth.presetWidthIdx
                column.hasManualSingleWindowWidthOverride = false

                column.animateWidthTo(
                    newWidth: clampedSpan(
                        targetPixels,
                        to: projectedWidthBounds(for: column, workspaceId: workspaceId)
                    ),
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )

                for window in projectedColumn.windows {
                    window.size = 1.0
                }
            }
        case .vertical:
            let targetPixels = (workingFrame.height - gaps) * resolvedWidth.proportion - gaps
            for projectedColumn in columns {
                let column = projectedColumn.column
                column.height = .proportion(resolvedWidth.proportion)
                column.isFullHeight = false
                column.savedHeight = nil
                column.hasManualSingleWindowHeightOverride = false
                column.cachedHeight = clampedSpan(
                    targetPixels,
                    to: projectedHeightBounds(for: column, workspaceId: workspaceId)
                )

                for window in projectedColumn.windows {
                    window.windowWidth = .auto(weight: 1)
                }
            }
        }
        return true
    }

    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let step = direction.primaryStep(for: context.orientation) else { return false }

        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard let currentProjectedIndex = projectedColumns.firstIndex(where: { $0.column === column }) else {
            return false
        }
        let targetProjectedIndex = currentProjectedIndex + step
        guard projectedColumns.indices.contains(targetProjectedIndex) else { return false }
        let targetIdx = projectedColumns[targetProjectedIndex].durableIndex
        return moveColumn(
            column,
            to: targetIdx,
            context: context,
            state: &state
        )
    }

    func moveColumnToFirst(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        return moveColumnToIndex(
            column,
            1,
            context: context,
            state: &state
        )
    }

    func moveColumnToLast(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        return moveColumnToIndex(
            column,
            Int.max,
            context: context,
            state: &state
        )
    }

    func moveColumnToIndex(
        _ column: NiriContainer,
        _ oneBasedIndex: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard !projectedColumns.isEmpty,
              projectedColumns.contains(where: { $0.column === column })
        else {
            return false
        }

        let projectedTargetIndex = min(oneBasedIndex <= 1 ? 0 : oneBasedIndex - 1, projectedColumns.count - 1)
        let targetIdx = projectedColumns[projectedTargetIndex].durableIndex
        return moveColumn(
            column,
            to: targetIdx,
            context: context,
            state: &state
        )
    }

    private func moveColumn(
        _ column: NiriContainer,
        to targetIdx: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let cols = columns(in: context.workspaceId)
        guard let currentIdx = columnIndex(of: column, in: context.workspaceId),
              cols.indices.contains(targetIdx)
        else { return false }
        if targetIdx == currentIdx { return false }

        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let previousGeometry = if projectionExclusions(in: context.workspaceId).isEmpty {
            Optional<NiriProjectedGeometrySnapshot>.none
        } else {
            projectedGeometrySnapshot(
                in: context.workspaceId,
                workingFrame: context.workingFrame,
                gaps: context.gaps,
                orientation: context.orientation
            )
        }
        let previousProjectedAnchor = previousGeometry.flatMap {
            projectedViewportAnchor(state: state, geometry: $0, in: context.workspaceId)
        }
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        let currentPosition = state.containerPosition(
            at: currentIdx,
            containers: cols,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let nextPosition = currentIdx + 1 < cols.count
            ? state.containerPosition(
                at: currentIdx + 1,
                containers: cols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
            : currentPosition + (
                column[keyPath: sizeKeyPath] > 0
                    ? column[keyPath: sizeKeyPath]
                    : (context.orientation == .horizontal ? context.workingFrame.width : context.workingFrame.height)
                    / CGFloat(effectiveVisibleContainerCount(in: context.workspaceId))
            ) + context.gaps

        guard let root = root(for: context.workspaceId) else { return false }
        cancelInteractiveResizeForMovedColumn(column, in: context.workspaceId)
        root.insertChild(column, at: targetIdx)

        let newCols = columns(in: context.workspaceId)
        if let previousGeometry {
            let currentGeometry = projectedGeometrySnapshot(
                in: context.workspaceId,
                workingFrame: context.workingFrame,
                gaps: context.gaps,
                orientation: context.orientation
            )
            animateProjectedColumns(
                from: previousGeometry,
                to: currentGeometry,
                in: context.workspaceId,
                motion: context.motion,
                orientation: context.orientation
            )
        } else {
            let positionAtOldIndex = state.containerPosition(
                at: currentIdx,
                containers: newCols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
            let viewOffsetDelta = currentPosition - positionAtOldIndex
            state.offsetViewport(by: viewOffsetDelta)

            let newPosition = state.containerPosition(
                at: targetIdx,
                containers: newCols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
            column.animateMoveFrom(
                displacement: primaryDisplacement(
                    currentPosition - newPosition,
                    orientation: context.orientation
                ),
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )

            let othersOffset = nextPosition - currentPosition
            if currentIdx < targetIdx {
                for i in currentIdx ..< targetIdx {
                    let col = newCols[i]
                    if col.id != column.id {
                        col.animateMoveFrom(
                            displacement: primaryDisplacement(
                                othersOffset,
                                orientation: context.orientation
                            ),
                            clock: animationClock,
                            config: windowMovementAnimationConfig,
                            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                            animated: context.motion.animationsEnabled
                        )
                    }
                }
            } else {
                for i in (targetIdx + 1) ... currentIdx {
                    let col = newCols[i]
                    if col.id != column.id {
                        col.animateMoveFrom(
                            displacement: primaryDisplacement(
                                -othersOffset,
                                orientation: context.orientation
                            ),
                            clock: animationClock,
                            config: windowMovementAnimationConfig,
                            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                            animated: context.motion.animationsEnabled
                        )
                    }
                }
            }
        }

        ensureColumnVisible(
            column,
            context: context,
            state: &state,
            animationConfig: windowMovementAnimationConfig,
            fromContainerIndex: currentIdx,
            previousProjectedAnchor: previousProjectedAnchor
        )

        return true
    }

    private func cancelInteractiveResizeForMovedColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId, in: workspaceId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }

    func consumeOrExpelWindow(
        _ window: NiriWindow,
        direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState,
        allowEdgeWrap: Bool = true
    ) -> Bool {
        assertSanctionedMutation()
        guard direction == .left || direction == .right else { return false }
        guard !isExcludedFromProjection(window.token, in: context.workspaceId) else { return false }

        guard let currentColumn = findColumn(containing: window, in: context.workspaceId)
        else {
            return false
        }

        let visibleMembers = projectedWindows(in: currentColumn, workspaceId: context.workspaceId)
        if visibleMembers.count > 1 {
            return expelWindow(
                window,
                to: direction,
                context: context,
                state: &state
            )
        }

        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard let currentIdx = projectedColumns.firstIndex(where: { $0.column === currentColumn }) else {
            return false
        }
        let step = (direction == .right) ? 1 : -1
        let neighborIdx: Int
        if allowEdgeWrap {
            guard let wrappedIdx = wrapIndex(
                currentIdx + step,
                total: projectedColumns.count,
                in: context.workspaceId
            ) else {
                return false
            }
            neighborIdx = wrappedIdx
        } else {
            let adjacentIdx = currentIdx + step
            guard projectedColumns.indices.contains(adjacentIdx) else {
                return false
            }
            neighborIdx = adjacentIdx
        }

        if neighborIdx == currentIdx { return false }

        let neighborColumn = projectedColumns[neighborIdx].column
        guard neighborColumn.id != currentColumn.id else { return false }

        return consumeWindow(
            window,
            into: neighborColumn,
            enteringFrom: direction,
            context: context,
            state: &state
        )
    }

    func columnCanAcceptTransfer(
        _ column: NiriContainer,
        adding window: NiriWindow,
        removing removedWindow: NiriWindow? = nil,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        guard !column.isTabbed else { return true }
        let axisSpace = orientation == .horizontal ? workingFrame.height : workingFrame.width
        func axisMinimum(_ tile: NiriWindow) -> CGFloat {
            let minSize = tile.constraints.normalized().minSize
            return orientation == .horizontal ? minSize.height : minSize.width
        }
        let remaining = projectedWindows(in: column, workspaceId: workspaceId).filter { $0 !== removedWindow }
        let minSum = remaining.reduce(axisMinimum(window)) { $0 + axisMinimum($1) }
        let gapSum = gaps * CGFloat(remaining.count + 2)
        return minSum + gapSum <= axisSpace + 0.5
    }

    @discardableResult
    func consumeWindow(
        _ window: NiriWindow,
        into targetColumn: NiriContainer,
        enteringFrom direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let currentColumn = findColumn(containing: window, in: context.workspaceId),
              let currentIdx = columnIndex(of: currentColumn, in: context.workspaceId),
              currentColumn.id != targetColumn.id
        else {
            return false
        }

        guard columnCanAcceptTransfer(
            targetColumn,
            adding: window,
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        ) else {
            return false
        }

        let targetInsertionPolicy: TargetColumnInsertionPolicy = direction == .down ? .append : .visualBottom

        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let hasProjectionExclusions = !projectionExclusions(in: context.workspaceId).isEmpty
        let previousGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let previousProjectedAnchor = projectedViewportAnchor(
            state: state,
            geometry: previousGeometry,
            in: context.workspaceId
        )
        let cols = columns(in: context.workspaceId)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let previousActiveColumnIndex = state.activeColumnIndex
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        let previousActiveColumnPosition = state.containerPosition(
            at: previousActiveColumnIndex,
            containers: cols,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourcePosition = previousGeometry.column(containing: currentColumn)?.primaryPosition
            ?? state.containerPosition(
                at: currentIdx,
                containers: cols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = previousGeometry.secondaryOffset(of: window, in: currentColumn) ?? context.gaps

        let transfer = moveWindowToColumn(
            window,
            from: currentColumn,
            to: targetColumn,
            in: context.workspaceId,
            targetInsertionPolicy: targetInsertionPolicy,
            activateInsertedWindowInTarget: true
        )

        state.selectedNodeId = window.id

        if transfer.sourceBecameEmpty {
            if !hasProjectionExclusions {
                _ = animateColumnsForRemoval(
                    columnIndex: transfer.sourceColumnIndexBeforeCleanup,
                    in: context.workspaceId,
                    motion: context.motion,
                    state: &state,
                    gaps: context.gaps,
                    orientation: context.orientation
                )
            }
            cleanupEmptyColumn(currentColumn, in: context.workspaceId, state: &state)
        }

        let currentGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        if hasProjectionExclusions {
            animateProjectedColumns(
                from: previousGeometry,
                to: currentGeometry,
                in: context.workspaceId,
                motion: context.motion,
                orientation: context.orientation
            )
        }
        let newCols = columns(in: context.workspaceId)
        let targetColIdx = columnIndex(of: targetColumn, in: context.workspaceId) ?? transfer
            .targetColumnIndexAfterInsert
        let targetPosition = currentGeometry.column(containing: targetColumn)?.primaryPosition
            ?? state.containerPosition(
                at: targetColIdx,
                containers: newCols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
        let targetColRenderOffset = targetColumn.renderOffset(at: now)
        let targetTileOffset = currentGeometry.secondaryOffset(of: window, in: targetColumn) ?? context.gaps

        let displacement = transferDisplacement(
            sourcePosition: sourcePosition,
            sourceRenderOffset: sourceColRenderOffset,
            targetPosition: targetPosition,
            targetRenderOffset: targetColRenderOffset,
            secondary: sourceTileOffset - targetTileOffset,
            orientation: context.orientation
        )
        if displacement.x != 0 || displacement.y != 0 {
            window.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }

        ensureSelectionVisible(
            node: window,
            in: context.workspaceId,
            motion: context.motion,
            state: &state,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation,
            fromContainerIndex: previousActiveColumnIndex,
            previousActiveContainerPosition: previousActiveColumnPosition,
            previousProjectedAnchor: previousProjectedAnchor
        )

        return true
    }

    func consumeWindowIntoColumn(
        focusedColumn targetColumn: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard let targetProjectedIndex = projectedColumns.firstIndex(where: { $0.column === targetColumn }),
              projectedColumns.indices.contains(targetProjectedIndex + 1)
        else {
            return false
        }

        let sourceProjectedColumn = projectedColumns[targetProjectedIndex + 1]
        let sourceColumn = sourceProjectedColumn.column
        let sourceColumnIdx = sourceProjectedColumn.durableIndex
        let targetColumnIdx = projectedColumns[targetProjectedIndex].durableIndex
        let cols = columns(in: context.workspaceId)
        guard let window = sourceProjectedColumn.windows.last else {
            return false
        }

        guard columnCanAcceptTransfer(
            targetColumn,
            adding: window,
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        ) else {
            return false
        }

        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let hasProjectionExclusions = !projectionExclusions(in: context.workspaceId).isEmpty
        let previousGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let sourcePosition = previousGeometry.column(containing: sourceColumn)?.primaryPosition
            ?? state.containerPosition(
                at: sourceColumnIdx,
                containers: cols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
        let sourceColRenderOffset = sourceColumn.renderOffset(at: now)
        let sourceTileOffset = previousGeometry.secondaryOffset(of: window, in: sourceColumn) ?? context.gaps

        let transfer = moveWindowToColumn(
            window,
            from: sourceColumn,
            to: targetColumn,
            in: context.workspaceId,
            targetInsertionPolicy: .visualBottom
        )

        if transfer.sourceBecameEmpty {
            if !hasProjectionExclusions {
                _ = animateColumnsForRemoval(
                    columnIndex: transfer.sourceColumnIndexBeforeCleanup,
                    in: context.workspaceId,
                    motion: context.motion,
                    state: &state,
                    gaps: context.gaps,
                    orientation: context.orientation
                )
            }
            cleanupEmptyColumn(sourceColumn, in: context.workspaceId, state: &state)
        }

        let currentGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        if hasProjectionExclusions {
            animateProjectedColumns(
                from: previousGeometry,
                to: currentGeometry,
                in: context.workspaceId,
                motion: context.motion,
                orientation: context.orientation
            )
        }
        let newCols = columns(in: context.workspaceId)
        let targetColIdx = columnIndex(of: targetColumn, in: context.workspaceId) ?? targetColumnIdx
        let targetPosition = currentGeometry.column(containing: targetColumn)?.primaryPosition
            ?? state.containerPosition(
                at: targetColIdx,
                containers: newCols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
        let targetColRenderOffset = targetColumn.renderOffset(at: now)
        let targetTileOffset = currentGeometry.secondaryOffset(of: window, in: targetColumn) ?? context.gaps

        let displacement = transferDisplacement(
            sourcePosition: sourcePosition,
            sourceRenderOffset: sourceColRenderOffset,
            targetPosition: targetPosition,
            targetRenderOffset: targetColRenderOffset,
            secondary: sourceTileOffset - targetTileOffset,
            orientation: context.orientation
        )
        if displacement.x != 0 || displacement.y != 0 {
            window.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }

        return true
    }

    func expelWindowFromColumn(
        focusedColumn sourceColumn: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        let visibleWindows = projectedWindows(in: sourceColumn, workspaceId: context.workspaceId)
        guard visibleWindows.count > 1,
              let root = root(for: context.workspaceId),
              let sourceColumnIdx = columnIndex(of: sourceColumn, in: context.workspaceId),
              let window = visibleWindows.first
        else {
            return false
        }

        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let hasProjectionExclusions = !projectionExclusions(in: context.workspaceId).isEmpty
        let previousGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: context.workspaceId)
        let sourcePosition = previousGeometry.column(containing: sourceColumn)?.primaryPosition
            ?? state.containerPosition(
                at: sourceColumnIdx,
                containers: cols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
        let sourceColRenderOffset = sourceColumn.renderOffset(at: now)
        let sourceTileOffset = previousGeometry.secondaryOffset(of: window, in: sourceColumn) ?? context.gaps
        let replacementSelectionId = visibleWindows.dropFirst().first?.id
        let selectedExpelledWindow = state.selectedNodeId == window.id

        let newColumn = NiriContainer()
        copyContainerSizingState(from: sourceColumn, to: newColumn)
        root.insertAfter(newColumn, reference: sourceColumn)

        _ = moveWindowToColumn(
            window,
            from: sourceColumn,
            to: newColumn,
            in: context.workspaceId
        )

        if !hasProjectionExclusions,
           let newColIdx = columnIndex(of: newColumn, in: context.workspaceId)
        {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: context.workspaceId,
                motion: context.motion,
                state: state,
                gaps: context.gaps,
                workingFrame: context.workingFrame,
                orientation: context.orientation
            )
        }

        let currentGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        if hasProjectionExclusions {
            animateProjectedColumns(
                from: previousGeometry,
                to: currentGeometry,
                in: context.workspaceId,
                motion: context.motion,
                orientation: context.orientation
            )
        }
        let newCols = columns(in: context.workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: context.workspaceId) {
            let targetPosition = currentGeometry.column(containing: newColumn)?.primaryPosition
                ?? state.containerPosition(
                    at: newColIdx,
                    containers: newCols,
                    gap: context.gaps,
                    sizeKeyPath: sizeKeyPath
                )
            let targetColRenderOffset = newColumn.renderOffset(at: now)
            let displacement = transferDisplacement(
                sourcePosition: sourcePosition,
                sourceRenderOffset: sourceColRenderOffset,
                targetPosition: targetPosition,
                targetRenderOffset: targetColRenderOffset,
                secondary: sourceTileOffset,
                orientation: context.orientation
            )

            if displacement.x != 0 || displacement.y != 0 {
                window.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                    animated: context.motion.animationsEnabled
                )
            }
        }

        if selectedExpelledWindow {
            state.selectedNodeId = replacementSelectionId
        }

        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: context.workspaceId),
              let root = root(for: context.workspaceId),
              let currentColIdx = columnIndex(of: currentColumn, in: context.workspaceId)
        else {
            return false
        }

        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let hasProjectionExclusions = !projectionExclusions(in: context.workspaceId).isEmpty
        let previousGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let previousProjectedAnchor = projectedViewportAnchor(
            state: state,
            geometry: previousGeometry,
            in: context.workspaceId
        )
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: context.workspaceId)

        let sourcePosition = previousGeometry.column(containing: currentColumn)?.primaryPosition
            ?? state.containerPosition(
                at: currentColIdx,
                containers: cols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = previousGeometry.secondaryOffset(of: window, in: currentColumn) ?? context.gaps

        let wasTabbed = currentColumn.displayMode == .tabbed
        currentColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        copyContainerSizingState(from: currentColumn, to: newColumn)

        if direction == .right {
            root.insertAfter(newColumn, reference: currentColumn)
        } else {
            root.insertBefore(newColumn, reference: currentColumn)
        }

        window.detach()
        newColumn.appendChild(window)
        resetMovedWindowColumnLocalSizing(window)
        window.isHiddenInTabbedMode = false

        if !hasProjectionExclusions,
           let newColIdx = columnIndex(of: newColumn, in: context.workspaceId)
        {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: context.workspaceId,
                motion: context.motion,
                state: state,
                gaps: context.gaps,
                workingFrame: context.workingFrame,
                orientation: context.orientation
            )
        }

        let currentGeometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        if hasProjectionExclusions {
            animateProjectedColumns(
                from: previousGeometry,
                to: currentGeometry,
                in: context.workspaceId,
                motion: context.motion,
                orientation: context.orientation
            )
        }
        let newCols = columns(in: context.workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: context.workspaceId) {
            let targetPosition = currentGeometry.column(containing: newColumn)?.primaryPosition
                ?? state.containerPosition(
                    at: newColIdx,
                    containers: newCols,
                    gap: context.gaps,
                    sizeKeyPath: sizeKeyPath
                )
            let targetColRenderOffset = newColumn.renderOffset(at: now)

            let displacement = transferDisplacement(
                sourcePosition: sourcePosition,
                sourceRenderOffset: sourceColRenderOffset,
                targetPosition: targetPosition,
                targetRenderOffset: targetColRenderOffset,
                secondary: sourceTileOffset,
                orientation: context.orientation
            )

            if displacement.x != 0 || displacement.y != 0 {
                window.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                    animated: context.motion.animationsEnabled
                )
            }
        }

        if wasTabbed, !currentColumn.children.isEmpty {
            currentColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: currentColumn)
        }

        cleanupEmptyColumn(currentColumn, in: context.workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: context.workspaceId,
            motion: context.motion,
            state: &state,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation,
            previousProjectedAnchor: previousProjectedAnchor
        )

        return true
    }

    private func ensureColumnVisible(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousProjectedAnchor: NiriProjectedViewportAnchor? = nil
    ) {
        if let firstWindow = projectedWindows(in: column, workspaceId: context.workspaceId).first {
            ensureSelectionVisible(
                node: firstWindow,
                in: context.workspaceId,
                motion: context.motion,
                state: &state,
                workingFrame: context.workingFrame,
                gaps: context.gaps,
                orientation: context.orientation,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex,
                previousProjectedAnchor: previousProjectedAnchor
            )
        }
    }
}
