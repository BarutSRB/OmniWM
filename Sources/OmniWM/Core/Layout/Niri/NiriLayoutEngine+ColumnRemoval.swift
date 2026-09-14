// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    func removeColumnByIdx(
        _ removedIdx: Int,
        context: NiriInteractionContext,
        state: inout ViewportState,
        batch: RemovalBatch
    ) -> TileRemovalStep {
        let cols = columns(in: context.workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else { return TileRemovalStep() }

        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )

        let column = cols[removedIdx]
        let removedWindows = column.windowNodes
        let removedTokens = Set(removedWindows.map(\.token)).intersection(batch.tokens)
        let removedNodeIds = Set(removedWindows.map(\.id))
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, cols.count - 1))
        let postRemovalCount = cols.count - 1
        let primarySpan = switch context.orientation {
        case .horizontal: column.cachedWidth
        case .vertical: column.cachedHeight
        }
        let offset = primarySpan + context.gaps

        animateColumnsAroundRemoval(
            columns: cols,
            removedIdx: removedIdx,
            activeIdx: activeIdx,
            offset: offset,
            context: context
        )

        cancelInteractions(for: Set(removedWindows.map(\.id)), in: context.workspaceId)

        let pendingPreviousOffset = state.activatePrevColumnOnRemoval
        if removedIdx + 1 == activeIdx {
            state.activatePrevColumnOnRemoval = nil
        }
        if removedIdx == activeIdx {
            state.viewOffsetToRestore = nil
        }

        for window in removedWindows {
            states[context.workspaceId]?.unindex(window)
            window.detach()
        }
        column.remove()

        var step = TileRemovalStep(
            removedTokens: removedTokens, removedNodeIds: removedNodeIds, removedColumnIndexBefore: removedIdx
        )
        updateViewportForColumnRemoval(
            ColumnRemovalTransition(
                removedIndex: removedIdx, activeIndex: activeIdx, remainingCount: postRemovalCount,
                offset: offset, previousOffset: pendingPreviousOffset
            ), batch: batch, context: context, state: &state, step: &step
        )
        return step
    }

    private struct ColumnRemovalTransition {
        let removedIndex: Int
        let activeIndex: Int
        let remainingCount: Int
        let offset: CGFloat
        let previousOffset: CGFloat?
    }

    private func updateViewportForColumnRemoval(
        _ transition: ColumnRemovalTransition, batch: RemovalBatch,
        context: NiriInteractionContext, state: inout ViewportState, step: inout TileRemovalStep
    ) {
        if transition.remainingCount <= 0 {
            state.activeColumnIndex = 0
            state.activatePrevColumnOnRemoval = nil
            state.selectedNodeId = nil
        } else if transition.removedIndex < transition.activeIndex {
            state.activeColumnIndex = transition.activeIndex - 1
            state.rebaseOffset(by: transition.offset)
            state.activatePrevColumnOnRemoval = nil
            step.viewportNeedsRecalc = true
            step.fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: context.workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: batch.nodeIds
            )
        } else if transition.removedIndex == transition.activeIndex,
                  let previousOffset = transition.previousOffset,
                  transition.removedIndex > 0
        {
            state.activeColumnIndex = transition.activeIndex - 1
            state.activatePrevColumnOnRemoval = nil
            state.jumpOffset(to: previousOffset)
            step.viewportNeedsRecalc = true
            step.fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: context.workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: batch.nodeIds
            )
            step.visibilityWasCorrected = revealRemovalFallback(
                step.fallbackSelectionId,
                context: context,
                state: &state
            )
        } else if transition.removedIndex == transition.activeIndex {
            state.activeColumnIndex = min(transition.activeIndex, transition.remainingCount - 1)
            state.activatePrevColumnOnRemoval = nil
            step.viewportNeedsRecalc = true
            step.fromIndexForVisibility = transition.removedIndex
            step.fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: context.workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: batch.nodeIds
            )
        } else {
            state.activatePrevColumnOnRemoval = nil
        }
    }

    private func revealRemovalFallback(
        _ selectionId: NodeId?, context: NiriInteractionContext, state: inout ViewportState
    ) -> Bool {
        guard let selectionId,
              let selectedNode = findNode(by: selectionId, in: context.workspaceId)
        else { return false }
        state.selectedNodeId = selectionId
        ensureSelectionVisible(
            node: selectedNode, context: context, state: &state,
            fromContainerIndex: state.activeColumnIndex
        )
        return true
    }

    func fallbackSelectionInColumn(
        _ column: NiriContainer,
        excluding removedNodeIds: Set<NodeId>
    ) -> NodeId? {
        if let activeWindow = column.activeWindow,
           !removedNodeIds.contains(activeWindow.id)
        {
            return activeWindow.id
        }

        return column.windowNodes.first(where: { !removedNodeIds.contains($0.id) })?.id
    }

    func fallbackSelectionFromActiveColumn(
        in workspaceId: WorkspaceDescriptor.ID,
        activeIndex: Int,
        excluding removedNodeIds: Set<NodeId>
    ) -> NodeId? {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }
        let idx = activeIndex.clamped(to: 0 ... (cols.count - 1))
        return fallbackSelectionInColumn(cols[idx], excluding: removedNodeIds)
    }
}
