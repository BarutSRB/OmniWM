// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
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

        let snapshot = prepareColumnMutation(context: context)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: context.workspaceId)
        let sourceSample = sampleTransferredWindow(
            window, in: (sourceColumn, sourceColumnIdx), columns: cols, state: state,
            sampling: ColumnRenderSampling(geometry: snapshot.geometry, time: now, context: context)
        )
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

        animateInsertedColumn(newColumn, snapshot: snapshot, context: context, state: state)

        let currentGeometry = completeColumnMutation(from: snapshot, context: context)
        animateExpelledWindow(
            window, into: newColumn,
            sample: WindowTransferAnimationSample(
                source: sourceSample, geometry: currentGeometry, time: now, context: context
            ), state: state
        )

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

        let snapshot = prepareColumnMutation(context: context)
        let previousProjectedAnchor = projectedViewportAnchor(
            state: state,
            geometry: snapshot.geometry,
            in: context.workspaceId
        )
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: context.workspaceId)

        let sourceSample = sampleTransferredWindow(
            window, in: (currentColumn, currentColIdx), columns: cols, state: state,
            sampling: ColumnRenderSampling(geometry: snapshot.geometry, time: now, context: context)
        )

        let wasTabbed = currentColumn.displayMode == .tabbed
        let newColumn = expelIntoNewColumn(window, from: currentColumn, root: root, direction: direction)

        animateInsertedColumn(newColumn, snapshot: snapshot, context: context, state: state)

        let currentGeometry = completeColumnMutation(from: snapshot, context: context)
        animateExpelledWindow(
            window, into: newColumn,
            sample: WindowTransferAnimationSample(
                source: sourceSample, geometry: currentGeometry, time: now, context: context
            ), state: state
        )

        if wasTabbed, !currentColumn.children.isEmpty {
            currentColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: currentColumn)
        }

        cleanupEmptyColumn(currentColumn, in: context.workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            context: context,
            state: &state,
            previousProjectedAnchor: previousProjectedAnchor
        )

        return true
    }

    private func expelIntoNewColumn(
        _ window: NiriWindow,
        from currentColumn: NiriContainer,
        root: NiriRoot,
        direction: Direction
    ) -> NiriContainer {
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

        return newColumn
    }
}
