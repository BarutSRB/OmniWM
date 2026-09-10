// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState,
        allowEdgeWrap: Bool = true
    ) -> Bool {
        assertSanctionedMutation()
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )

        if let step = direction.primaryStep(for: context.orientation) {
            return consumeOrExpelWindow(
                node,
                direction: step > 0 ? .right : .left,
                context: context,
                state: &state,
                allowEdgeWrap: allowEdgeWrap
            )
        }

        guard let step = direction.secondaryStep(for: context.orientation) else { return false }
        return moveWindowWithinContainer(node, step: step, in: context.workspaceId)
    }

    func moveWindowWithinContainer(
        _ node: NiriWindow,
        step: Int,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let column = node.parent as? NiriContainer else {
            return false
        }
        guard !isExcludedFromProjection(node.token, in: workspaceId) else {
            return false
        }

        let visibleWindows = projectedWindows(in: column, workspaceId: workspaceId)
        guard let visibleIndex = visibleWindows.firstIndex(where: { $0 === node }) else { return false }
        let siblingIndex = visibleIndex + step
        guard visibleWindows.indices.contains(siblingIndex) else {
            return false
        }
        let targetSibling = visibleWindows[siblingIndex]

        let nodeIdx = column.windowNodes.firstIndex { $0 === node }
        let siblingIdx = column.windowNodes.firstIndex { $0 === targetSibling }

        node.swapWith(targetSibling)

        if column.displayMode == .tabbed, let nIdx = nodeIdx, let sIdx = siblingIdx {
            if nIdx == column.activeTileIdx {
                column.setActiveTileIdx(sIdx)
            } else if sIdx == column.activeTileIdx {
                column.setActiveTileIdx(nIdx)
            }
        }

        return true
    }
}
