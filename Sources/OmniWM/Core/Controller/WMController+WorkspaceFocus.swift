// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    @discardableResult
    func resolveAndSetWorkspaceFocusToken(for workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        )
    }

    func reassignManagedWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID
    ) {
        workspaceManager.setWorkspace(for: token, to: workspaceId)
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId? = nil,
        preferredToken: WindowToken? = nil
    ) {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            if let engine = niriEngine {
                let preferredTokenNode: NiriWindow? = preferredToken.flatMap { token in
                    guard !isManagedWindowSuppressedByMacOSHide(token) else { return nil }
                    return engine.findNode(for: token, in: workspaceId)
                }
                let preferredNode = preferredNodeId
                    .flatMap { engine.findNode(by: $0, in: workspaceId) as? NiriWindow }
                    .flatMap { node in
                        isManagedWindowSuppressedByMacOSHide(node.token) ? nil : node
                    }
                if let node = preferredTokenNode ?? preferredNode {
                    _ = workspaceManager.commitWorkspaceSelection(
                        nodeId: node.id,
                        focusedToken: node.token,
                        in: workspaceId,
                        onMonitor: monitorId
                    )
                    return
                }
            }
        case .dwindle:
            if let token = dwindleEngine?.selectedNode(in: workspaceId)?.windowToken,
               !isManagedWindowSuppressedByMacOSHide(token)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: nil,
                    focusedToken: token,
                    in: workspaceId,
                    onMonitor: monitorId
                )
                return
            }
            if let preferredToken,
               !isManagedWindowSuppressedByMacOSHide(preferredToken),
               dwindleEngine?.findNode(for: preferredToken, in: workspaceId) != nil
            {
                commitWorkspaceFocusCandidate(preferredToken, in: workspaceId)
                return
            }
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    @discardableResult
    private func commitWorkspaceFocusCandidate(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        focusDwindleCandidate: Bool = false
    ) -> Bool {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            if let engine = niriEngine,
               let node = engine.findNode(for: token, in: workspaceId)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: token,
                    in: workspaceId,
                    onMonitor: monitorId
                )
                return false
            }
        case .dwindle:
            if let engine = dwindleEngine,
               engine.findNode(for: token, in: workspaceId) != nil
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: nil,
                    focusedToken: token,
                    in: workspaceId,
                    onMonitor: monitorId
                )
                let activation = dwindleLayoutHandler.activateWindow(
                    token,
                    in: workspaceId,
                    focusAfterLayout: focusDwindleCandidate
                )
                return focusDwindleCandidate && activation != .missing
            }
        }

        _ = workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token,
                plannedSeq: workspaceManager.worldSeq
            )
        )
        return false
    }

    func ensureFocusedTokenValid(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredRecoveryToken: WindowToken? = nil
    ) {
        guard !shouldSuppressManagedFocusRecovery else { return }
        guard !workspaceManager.hasPendingNativeFullscreenTransition(in: workspaceId) else { return }

        if let pendingFocusedToken = workspaceManager.pendingFocusedToken,
           workspaceManager.pendingFocusedWorkspaceId == workspaceId,
           !isManagedWindowSuppressedByMacOSHide(pendingFocusedToken)
        {
            commitWorkspaceFocusCandidate(pendingFocusedToken, in: workspaceId)
            return
        }

        if let preferredRecoveryToken {
            if let entry = workspaceManager.entry(for: preferredRecoveryToken),
               entry.workspaceId == workspaceId,
               !isManagedWindowSuppressedByMacOSHide(preferredRecoveryToken)
            {
                let routedDwindleFocus = commitWorkspaceFocusCandidate(
                    preferredRecoveryToken,
                    in: workspaceId,
                    focusDwindleCandidate: true
                )
                if !routedDwindleFocus {
                    focusWindow(preferredRecoveryToken)
                }
                return
            }
        }

        if let focusedToken = workspaceManager.selectedManagedToken,
           workspaceManager.entry(for: focusedToken)?.workspaceId == workspaceId,
           !isManagedWindowSuppressedByMacOSHide(focusedToken)
        {
            commitWorkspaceFocusCandidate(focusedToken, in: workspaceId)
            return
        }

        guard let nextFocusToken = workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        ) else {
            return
        }

        let routedDwindleFocus = commitWorkspaceFocusCandidate(
            nextFocusToken,
            in: workspaceId,
            focusDwindleCandidate: true
        )
        if !routedDwindleFocus {
            focusWindow(nextFocusToken)
        }
    }
}
