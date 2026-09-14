// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func managedReplacementFocusKey(
        pid: pid_t,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedReplacementFocusKey {
        ManagedReplacementFocusKey(pid: pid, workspaceId: workspaceId)
    }

    func managedReplacementFocusKey(_ key: ManagedReplacementKey) -> ManagedReplacementFocusKey {
        ManagedReplacementFocusKey(pid: key.pid, workspaceId: key.workspaceId)
    }

    private func selectedNiriWindowToken(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let controller else { return nil }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let selectedNodeId = state.selectedNodeId else { return nil }
        return controller.workspaceManager.layoutTopology(for: workspaceId).token(for: selectedNodeId)
    }

    private func niriManagedFocusAnchor(
        for key: ManagedReplacementFocusKey
    ) -> WindowToken? {
        guard let controller else { return nil }
        let topology = controller.workspaceManager.layoutTopology(for: key.workspaceId)

        func eligible(_ token: WindowToken?) -> Bool {
            guard let token,
                  token.pid == key.pid,
                  let entry = controller.workspaceManager.entry(for: token),
                  entry.workspaceId == key.workspaceId,
                  entry.mode == .tiling,
                  topology.containsNiriWindow(token)
            else {
                return false
            }
            return true
        }

        if let selected = selectedNiriWindowToken(in: key.workspaceId),
           eligible(selected)
        {
            return selected
        }

        if let focusedToken = controller.workspaceManager.selectedManagedToken,
           eligible(focusedToken)
        {
            return focusedToken
        }

        return nil
    }

    func armManagedReplacementFocusTransaction(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        if let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId) {
            controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
                payload.isBurstOpen = true
                payload.protectedTokens.insert(token)
            }
            return
        }

        let key = managedReplacementFocusKey(pid: token.pid, workspaceId: workspaceId)
        guard let anchor = niriManagedFocusAnchor(for: key) else { return }
        _ = controller.intentLedger.registerReplacementFocus(
            ReplacementFocusPayload(
                pid: token.pid,
                workspaceId: workspaceId,
                anchorToken: anchor,
                protectedTokens: [anchor, token],
                isBurstOpen: true
            )
        )
    }

    func markManagedReplacementFocusBurstClosed(for key: ManagedReplacementKey) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: key.pid, workspaceId: key.workspaceId)
        else {
            return
        }
        controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
            payload.isBurstOpen = false
        }
    }

    func rekeyManagedReplacementFocusTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: oldToken.pid, workspaceId: workspaceId)
        else {
            return
        }
        controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
            payload.rekey(from: oldToken, to: newToken)
            payload.protectedTokens.insert(newToken)
            payload.pid = newToken.pid
        }
    }

    func clearManagedReplacementFocusTransaction(
        containing token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        reason: String
    ) {
        guard let transaction = managedReplacementFocusTransaction(for: token, workspaceId: workspaceId),
              transaction.protects(token)
        else {
            return
        }
        clearManagedReplacementFocusTransaction(
            for: managedReplacementFocusKey(pid: token.pid, workspaceId: workspaceId),
            reason: reason
        )
    }

    func clearManagedReplacementFocusTransaction(
        for key: ManagedReplacementFocusKey,
        reason _: String
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: key.pid, workspaceId: key.workspaceId)
        else {
            return
        }
        _ = controller.intentLedger.cancel(id: open.id)
    }

    func clearManagedReplacementFocusTransactions(
        pid: pid_t,
        reason _: String
    ) {
        guard let controller else { return }
        for intent in controller.intentLedger.openReplacementFocusIntents(pid: pid) {
            _ = controller.intentLedger.cancel(id: intent.id)
        }
    }

    func managedReplacementFocusTransaction(
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ReplacementFocusPayload? {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId),
              case let .replacementFocus(payload) = open.kind
        else {
            return nil
        }
        return payload
    }

    func isProtectedManagedReplacementFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        managedReplacementFocusTransaction(for: token, workspaceId: workspaceId)?.protects(token) == true
    }

    func completeManagedReplacementFocusTransactionIfNeeded(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId),
              case let .replacementFocus(payload) = open.kind,
              payload.protects(token),
              !payload.isBurstOpen
        else {
            return
        }
        _ = controller.intentLedger.confirm(id: open.id)
    }
}
