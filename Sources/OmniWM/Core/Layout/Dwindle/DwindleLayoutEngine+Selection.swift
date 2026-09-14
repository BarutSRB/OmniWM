// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func activeToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        selectedNode(in: workspaceId)?.windowToken
    }

    func projectedActiveToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let state = existingState(for: workspaceId) else { return nil }
        if let tile = selectedNode(in: workspaceId)?.tile,
           let member = visibleMember(in: tile, excluding: state.excludedTokens)
        {
            return member.token
        }
        guard let leaf = firstVisibleLeaf(in: state.root, excluding: state.excludedTokens),
              let tile = leaf.tile
        else {
            return nil
        }
        return visibleMember(in: tile, excluding: state.excludedTokens)?.token
    }

    func reconcileProjectedSelection(in state: DwindleWorkspaceState) {
        if let selectedNodeId = state.selectedNodeId,
           let selected = findNodeById(selectedNodeId, in: state.root),
           visibleMember(in: selected.tile, excluding: state.excludedTokens) != nil
        {
            return
        }
        state.selectedNodeId = firstVisibleLeaf(
            in: state.root,
            excluding: state.excludedTokens
        )?.id
    }

    func reconcileProjectedSelection(
        preferredToken: WindowToken?,
        in state: DwindleWorkspaceState
    ) {
        if let preferredToken,
           !state.excludedTokens.contains(preferredToken),
           let preferredNode = state.leafByToken[preferredToken]
        {
            state.selectedNodeId = preferredNode.id
            return
        }
        reconcileProjectedSelection(in: state)
    }

    func activeTileMember(
        containing token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let state = existingState(for: workspaceId),
              let tile = state.leafByToken[token]?.tile
        else {
            return nil
        }
        return visibleMember(in: tile, excluding: state.excludedTokens)?.token
    }

    @discardableResult
    func activateWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        activateWindowOutcome(token, in: workspaceId) == .activated
    }

    @discardableResult
    func activateWindowOutcome(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleWindowActivationOutcome {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let leaf = state.leafByToken[token],
              let tile = leaf.tile
        else {
            return .missing
        }

        state.selectedNodeId = leaf.id
        return tile.activate(token) ? .activated : .selected
    }
}
