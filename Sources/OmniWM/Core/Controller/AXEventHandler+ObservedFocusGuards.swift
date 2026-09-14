// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    private func isTiledInActiveLayout(_ entry: WindowState) -> Bool {
        guard let controller, entry.mode == .tiling else { return false }
        switch controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) {
        case .niri:
            return controller.niriEngine?.findNode(for: entry.token, in: entry.workspaceId) != nil
        case .dwindle:
            return controller.dwindleEngine?.containsWindow(entry.token, in: entry.workspaceId) == true
        }
    }

    private func shouldDeferSameAppActivationForCloseProbe(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64
    ) -> Bool {
        guard source == .focusedWindowChanged, origin == .external else { return false }
        guard case .unrelatedNoRequest = requestDisposition else { return false }
        guard let controller else { return false }
        guard !hasRecentMouseFocusIntent(for: observedEntry.token) else { return false }
        guard isTiledInActiveLayout(observedEntry) else { return false }

        guard let focusedToken = controller.workspaceManager.selectedManagedToken,
              focusedToken != observedEntry.token,
              focusedToken.pid == observedEntry.pid,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              isTiledInActiveLayout(focusedEntry)
        else {
            return false
        }

        deferSameAppCloseProbe(
            focusedToken: focusedToken,
            focusedWorkspaceId: focusedEntry.workspaceId,
            observedToken: observedEntry.token,
            source: source,
            observationGeneration: observationGeneration
        )
        return true
    }

    func shouldSuppressObservedManagedActivation(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64
    ) -> Bool {
        if hasRecentMouseFocusIntent(for: observedEntry.token) {
            clearManagedReplacementFocusTransaction(
                for: managedReplacementFocusKey(
                    pid: observedEntry.pid,
                    workspaceId: observedEntry.workspaceId
                ),
                reason: "mouse_focus_intent"
            )
            return false
        }

        if shouldSuppressObservedActivationDuringManagedReplacementFocusTransaction(
            entry: observedEntry,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin
        ) {
            return true
        }

        if shouldDeferSameAppActivationForCloseProbe(
            entry: observedEntry,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin,
            observationGeneration: observationGeneration
        ) {
            return true
        }

        if shouldSuppressObservedActivationDuringWindowCloseRecovery(
            observedToken: observedEntry.token,
            requestDisposition: requestDisposition
        ) {
            return true
        }
        return false
    }

    private func shouldSuppressObservedActivationDuringManagedReplacementFocusTransaction(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        let key = managedReplacementFocusKey(pid: observedEntry.pid, workspaceId: observedEntry.workspaceId)
        guard let transaction = managedReplacementFocusTransaction(
            for: observedEntry.token,
            workspaceId: observedEntry.workspaceId
        ) else { return false }

        guard case .unrelatedNoRequest = requestDisposition else {
            if !transaction.protects(observedEntry.token) {
                clearManagedReplacementFocusTransaction(for: key, reason: "managed_focus_request")
            }
            return false
        }

        guard source == .focusedWindowChanged else {
            clearManagedReplacementFocusTransaction(for: key, reason: "app_activation")
            return false
        }

        guard transaction.suppressesUnrelatedActivation(
            token: observedEntry.token,
            workspaceId: observedEntry.workspaceId
        ) else {
            return false
        }

        cancelSameAppCloseProbe(
            matchingFocusedToken: transaction.anchorToken,
            reason: "managed_replacement_focus_transaction"
        )
        return true
    }

    func finishMouseFocusIntent(_ token: WindowToken) {
        if let controller,
           let entry = controller.workspaceManager.entry(for: token)
        {
            clearManagedReplacementFocusTransaction(
                for: managedReplacementFocusKey(pid: token.pid, workspaceId: entry.workspaceId),
                reason: "mouse_focus_intent"
            )
        }
        if let open = controller?.intentLedger.openSameAppCloseProbe(),
           open.payload.observedToken == token
        {
            cancelSameAppCloseProbe(reason: "mouse_focus_intent")
        }
    }
}
