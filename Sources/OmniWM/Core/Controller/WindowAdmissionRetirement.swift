// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension AXEventHandler {
    func clearTerminalFrameFailure(windowId: Int) {
        terminalFrameFailureStateByWindowId.removeValue(forKey: windowId)
    }

    func discardStaleManagedWindowIncarnation(_ entry: WindowState) {
        retireManagedWindow(entry, reason: .staleIncarnation)
    }

    func retireManagedWindow(
        _ entry: WindowState,
        reason: ManagedWindowRetirementReason
    ) {
        guard let controller else { return }
        let token = entry.token
        let workspaceId = entry.workspaceId
        let layoutType = controller.workspaceManager.descriptor(for: workspaceId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        let policy = retirementPolicy(for: reason)

        var oldFrames: [WindowToken: CGRect] = [:]
        var removedNodeId: NodeId?
        if layoutType != .dwindle, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: workspaceId)
            removedNodeId = engine.findNode(for: token, in: workspaceId)?.id
        }

        clearTerminalFrameFailure(windowId: token.windowId)
        if let windowId = UInt32(exactly: token.windowId) {
            cancelCreatedWindowRetry(windowId: windowId)
        }
        cancelPostCreateLifecycleVerification(for: token)
        cancelSameAppCloseProbe(matchingFocusedToken: token, reason: policy.traceReason)
        clearManagedFocusState(matching: token, workspaceId: workspaceId)
        controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
        controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
        controller.clearManualWindowOverride(for: token)
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        if policy.removesIdentityAliases {
            identityAliasesByWindowId.removeValue(forKey: token.windowId)
        }

        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
            layoutType: layoutType,
            removedNodeId: removedNodeId,
            niriOldFrames: oldFrames,
            shouldRecoverFocus: policy.shouldRecoverFocus,
            allowsPreferredRecoveryToken: policy.allowsPreferredRecoveryToken
        )
    }

    func retireManagedWindowFromAuthoritativeRescan(_ entry: WindowState) {
        let shouldRecoverFocus = controller?.workspaceManager.focusedToken == entry.token
        retireManagedWindow(
            entry,
            reason: .destroyed(
                shouldRecoverFocus: shouldRecoverFocus,
                allowsPreferredRecoveryToken: false
            )
        )
    }

    private func retirementPolicy(
        for reason: ManagedWindowRetirementReason
    ) -> ManagedWindowRetirementPolicy {
        switch reason {
        case let .destroyed(shouldRecoverFocus, allowsPreferredRecoveryToken):
            return ManagedWindowRetirementPolicy(
                shouldRecoverFocus: shouldRecoverFocus,
                allowsPreferredRecoveryToken: allowsPreferredRecoveryToken,
                traceReason: "focused_token_removed",
                removesIdentityAliases: true
            )
        case .staleIncarnation:
            return ManagedWindowRetirementPolicy(
                shouldRecoverFocus: false,
                allowsPreferredRecoveryToken: false,
                traceReason: "stale_ax_incarnation",
                removesIdentityAliases: true
            )
        case .terminalFrameRefusal:
            return ManagedWindowRetirementPolicy(
                shouldRecoverFocus: false,
                allowsPreferredRecoveryToken: false,
                traceReason: "admission_quarantine",
                removesIdentityAliases: false
            )
        }
    }

}
