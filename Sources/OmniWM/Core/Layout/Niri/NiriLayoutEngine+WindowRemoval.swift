// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    struct NiriRemovalResult {
        let removedTokens: Set<WindowToken>
        let removedNodeIds: Set<NodeId>
        let removedColumnIndicesBefore: [Int]
        let activeIndexBefore: Int?
        let activeIndexAfter: Int?
        let finalSelectionId: NodeId?
        let viewportNeedsRecalc: Bool
        let fromIndexForVisibility: Int?
        let visibilityWasCorrected: Bool
    }

    struct RemovalBatch {
        let root: NiriRoot
        let tokens: Set<WindowToken>
        let nodeIds: Set<NodeId>
    }

    struct TileRemovalStep {
        var removedTokens: Set<WindowToken> = []
        var removedNodeIds: Set<NodeId> = []
        var removedColumnIndexBefore: Int?
        var fallbackSelectionId: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false
    }

    @discardableResult
    func removeWindows(
        _ tokens: Set<WindowToken>,
        context: NiriInteractionContext,
        state: inout ViewportState,
        selectedNodeId: NodeId?,
        removedNodeIds externallyRemovedNodeIds: [NodeId]
    ) -> NiriRemovalResult {
        assertSanctionedMutation()
        guard !tokens.isEmpty,
              let workspaceState = states[context.workspaceId]
        else {
            return emptyRemovalResult(
                activeIndexBefore: columns(in: context.workspaceId).isEmpty ? nil : state.activeColumnIndex,
                activeIndexAfter: columns(in: context.workspaceId).isEmpty ? nil : state.activeColumnIndex
            )
        }

        let root = workspaceState.root
        let activeIndexBefore = root.columns.isEmpty ? nil : state.activeColumnIndex
        let removalTokens = tokens.intersection(root.windowIdSet)
        guard !removalTokens.isEmpty else {
            return emptyRemovalResult(
                activeIndexBefore: activeIndexBefore,
                activeIndexAfter: root.columns.isEmpty ? nil : state.activeColumnIndex
            )
        }

        let batch = RemovalBatch(
            root: root,
            tokens: removalTokens,
            nodeIds: Set(externallyRemovedNodeIds).union(
                removalTokens.compactMap { workspaceState.nodesByToken[$0]?.id }
            )
        )
        var progress = applyWindowRemovals(batch, context: context, state: &state)

        let finalSelection = selectionAfterRemoval(
            state.selectedNodeId ?? selectedNodeId, batch: batch, fallback: progress.latestFallback,
            context: context, state: state
        )

        state.selectedNodeId = finalSelection

        finishRemovalVisibility(finalSelection, batch: batch, progress: &progress, context: context, state: &state)

        return removalResult(
            progress,
            batch: batch,
            activeIndices: (
                activeIndexBefore,
                columns(in: context.workspaceId).isEmpty ? nil : state.activeColumnIndex
            ),
            finalSelectionId: finalSelection
        )
    }

    private struct RemovalProgress {
        var removedTokens: Set<WindowToken> = []
        var removedNodeIds: Set<NodeId> = []
        var removedColumnIndicesBefore: [Int] = []
        var latestFallback: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false
    }

    private func emptyRemovalResult(activeIndexBefore: Int?, activeIndexAfter: Int?) -> NiriRemovalResult {
        NiriRemovalResult(
            removedTokens: [], removedNodeIds: [], removedColumnIndicesBefore: [],
            activeIndexBefore: activeIndexBefore, activeIndexAfter: activeIndexAfter,
            finalSelectionId: nil, viewportNeedsRecalc: false,
            fromIndexForVisibility: nil, visibilityWasCorrected: false
        )
    }

    private func applyWindowRemovals(
        _ batch: RemovalBatch,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> RemovalProgress {
        var remainingTokens = batch.tokens
        var progress = RemovalProgress()

        while let window = batch.root.allWindows.first(where: { remainingTokens.contains($0.token) }) {
            guard let column = column(of: window),
                  let columnIndex = columnIndex(of: column, in: context.workspaceId),
                  let tileIndex = column.windowNodes.firstIndex(where: { $0 === window })
            else {
                remainingTokens.remove(window.token)
                continue
            }

            let step = removeTileByIdx(
                columnIndex: columnIndex,
                tileIndex: tileIndex,
                context: context,
                state: &state,
                batch: batch
            )

            progress.removedTokens.formUnion(step.removedTokens)
            progress.removedNodeIds.formUnion(step.removedNodeIds)
            remainingTokens.subtract(step.removedTokens)
            if let removedColumnIndex = step.removedColumnIndexBefore {
                progress.removedColumnIndicesBefore.append(removedColumnIndex)
            }
            if let fallback = step.fallbackSelectionId {
                progress.latestFallback = fallback
            }
            progress.viewportNeedsRecalc = progress.viewportNeedsRecalc || step.viewportNeedsRecalc
            if progress.fromIndexForVisibility == nil {
                progress.fromIndexForVisibility = step.fromIndexForVisibility
            }
            progress.visibilityWasCorrected = progress.visibilityWasCorrected || step.visibilityWasCorrected
        }

        return progress
    }

    private func selectionAfterRemoval(
        _ selectedNodeId: NodeId?, batch: RemovalBatch, fallback: NodeId?,
        context: NiriInteractionContext, state: ViewportState
    ) -> NodeId? {
        let currentSelection = selectedNodeId
        let finalSelection: NodeId?
        if let currentSelection,
           !batch.nodeIds.contains(currentSelection),
           batch.root.findNode(by: currentSelection) != nil
        {
            finalSelection = currentSelection
        } else {
            finalSelection = fallback
                ?? fallbackSelectionFromActiveColumn(
                    in: context.workspaceId,
                    activeIndex: state.activeColumnIndex,
                    excluding: batch.nodeIds
                )
                ?? validateSelection(nil, in: context.workspaceId)
        }

        return finalSelection
    }

    private func finishRemovalVisibility(
        _ finalSelection: NodeId?, batch: RemovalBatch, progress: inout RemovalProgress,
        context: NiriInteractionContext, state: inout ViewportState
    ) {
        if let finalSelection,
           !progress.visibilityWasCorrected,
           let fromIndexForVisibility = progress.fromIndexForVisibility,
           let selectedNode = batch.root.findNode(by: finalSelection),
           progress.viewportNeedsRecalc
        {
            ensureSelectionVisible(
                node: selectedNode,
                context: context,
                state: &state,
                fromContainerIndex: fromIndexForVisibility
            )
            progress.visibilityWasCorrected = true
        }

        if !progress.removedColumnIndicesBefore.isEmpty,
           correctViewportAfterColumnRemoval(
               context: context,
               state: &state
           )
        {
            progress.viewportNeedsRecalc = true
        }
    }

    private func removalResult(
        _ progress: RemovalProgress, batch: RemovalBatch,
        activeIndices: (before: Int?, after: Int?), finalSelectionId: NodeId?
    ) -> NiriRemovalResult {
        return NiriRemovalResult(
            removedTokens: progress.removedTokens,
            removedNodeIds: progress.removedNodeIds.union(batch.nodeIds),
            removedColumnIndicesBefore: progress.removedColumnIndicesBefore,
            activeIndexBefore: activeIndices.before,
            activeIndexAfter: activeIndices.after,
            finalSelectionId: finalSelectionId,
            viewportNeedsRecalc: progress.viewportNeedsRecalc,
            fromIndexForVisibility: progress.visibilityWasCorrected ? nil : progress.fromIndexForVisibility,
            visibilityWasCorrected: progress.visibilityWasCorrected
        )
    }

    private func removeTileByIdx(
        columnIndex: Int,
        tileIndex: Int,
        context: NiriInteractionContext,
        state: inout ViewportState,
        batch: RemovalBatch
    ) -> TileRemovalStep {
        let cols = columns(in: context.workspaceId)
        guard columnIndex >= 0, columnIndex < cols.count else { return TileRemovalStep() }

        let column = cols[columnIndex]
        let windows = column.windowNodes
        guard tileIndex >= 0, tileIndex < windows.count else { return TileRemovalStep() }

        if windows.count == 1 {
            return removeColumnByIdx(
                columnIndex,
                context: context,
                state: &state,
                batch: batch
            )
        }

        let node = windows[tileIndex]
        let removedToken = node.token
        let removedNodeId = node.id

        cancelInteractions(for: Set([removedNodeId]), in: context.workspaceId)

        column.adjustActiveTileIdxForRemoval(of: node)
        states[context.workspaceId]?.unindex(node)
        node.remove()

        if column.displayMode == .tabbed {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.windowNodes.count == 1,
           let remaining = column.windowNodes.first,
           remaining.height.isAuto
        {
            remaining.height = .auto(weight: 1.0)
        }

        let fallback = fallbackSelectionInColumn(
            column,
            excluding: batch.nodeIds
        )

        return TileRemovalStep(
            removedTokens: [removedToken],
            removedNodeIds: [removedNodeId],
            fallbackSelectionId: fallback
        )
    }
}
