// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func handleRemoved(
        pid: pid_t,
        winId: Int,
        axRef: AXWindowRef? = nil,
        callbackGeneration: UInt64? = nil
    ) {
        guard let windowId = UInt32(exactly: winId) else { return }
        if let axRef,
           !acceptsManagedDestroyCallback(
               .init(token: .init(pid: pid, windowId: winId), axRef: axRef),
               callbackGeneration: callbackGeneration
           ) { return }
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        rejectDeferredReplacement(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(
            windowId: windowId,
            pidHint: pid,
            expectedWindow: axRef,
            callbackGeneration: callbackGeneration,
            evidence: .transientLifecycle
        )
    }

    private func acceptsManagedDestroyCallback(
        _ identity: AXManagedWindowIdentity, callbackGeneration: UInt64?
    ) -> Bool {
        let token = identity.token
        let axRef = identity.axRef
        let windowId = UInt32(token.windowId)
        switch managedWindowDestroyDisposition(windowId: token.windowId, axRef: axRef) {
        case .current:
            return true
        case .stale:
            recordStaleDestroyCallback(identity, callbackGeneration: callbackGeneration)
            return false
        case let .waitingIdentityRebindTarget(
            retryGeneration,
            oldWindow,
            newWindow
        ):
            guard cancelDestroyedWaitingManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                oldWindow: oldWindow,
                newWindow: newWindow,
                axRef: axRef
            ) else {
                requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
                return false
            }
            discardDestroyedIdentityRebindTarget(identity, callbackGeneration: callbackGeneration)
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return false
        case let .pendingIdentityRebindTarget(
            retryGeneration,
            executionOwner,
            oldWindow,
            newWindow
        ):
            if deferDestroyedPendingManagedWindowIdentityRebind(
                execution: .init(
                    windowId: windowId,
                    generation: retryGeneration,
                    executionOwner: executionOwner
                ),
                oldWindow: oldWindow,
                newWindow: newWindow,
                axRef: axRef
            ) {
                discardDestroyedIdentityRebindTarget(identity, callbackGeneration: callbackGeneration)
                requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
                return false
            }
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return false
        }
    }

    private func recordStaleDestroyCallback(
        _ identity: AXManagedWindowIdentity, callbackGeneration: UInt64?
    ) {
        let token = identity.token
        let axRef = identity.axRef
        WindowAdmissionTrace.record(
            .init(
                action: .admissionIgnored,
                pid: token.pid,
                windowId: token.windowId,
                reason: "stale_destroy_callback",
                callbackGeneration: callbackGeneration,
                axRef: axRef
            )
        )
    }

    private func discardDestroyedIdentityRebindTarget(
        _ identity: AXManagedWindowIdentity, callbackGeneration: UInt64?
    ) {
        let token = identity.token
        let axRef = identity.axRef
        let windowId = UInt32(token.windowId)
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        WindowAdmissionTrace.record(
            .init(
                action: .admissionDisappeared,
                pid: token.pid,
                windowId: token.windowId,
                reason: "identity_rebind_target_destroyed",
                callbackGeneration: callbackGeneration,
                axRef: axRef
            )
        )
    }

    func handleRemoved(token: WindowToken) {
        handleRemoved(token: token, evidence: .transientLifecycle)
    }

    func handleRemoved(token: WindowToken, evidence: WindowDestroyEvidence) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            discardRemovedWindowRuntimeState(token)
            scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
            return
        }

        if handleNativeFullscreenDestroy(token, evidence: evidence) {
            discardRemovedWindowRuntimeState(token)
            return
        }

        let recovery = prepareManagedWindowRemoval(entry)
        retireManagedWindow(
            entry,
            reason: .destroyed(
                shouldRecoverFocus: recovery.shouldRecoverFocus,
                allowsPreferredRecoveryToken: recovery.closeRecoveryArmed
            )
        )
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
    }

    private func discardRemovedWindowRuntimeState(_ token: WindowToken) {
        clearTerminalFrameFailure(windowId: token.windowId)
        if let windowId = UInt32(exactly: token.windowId) {
            cancelCreatedWindowRetry(windowId: windowId)
        }
        guard let controller else { return }
        if controller.workspaceManager.entry(forWindowId: token.windowId) == nil {
            controller.axManager.removeWindowLedgerState(pid: token.pid, windowId: token.windowId)
            controller.axManager.bindManagedWindows(
                controller.workspaceManager.entries(forPid: token.pid)
            )
        }
        requestTargetedFullRescan(for: [token.pid])
    }

    private func prepareManagedWindowRemoval(
        _ entry: WindowState
    ) -> (shouldRecoverFocus: Bool, closeRecoveryArmed: Bool) {
        guard let controller else { return (false, false) }
        let shouldRecoverFocus = controller.workspaceManager.nativeManagedFocusToken == entry.token
        let closeRecoveryArmed: Bool
        if shouldRecoverFocus {
            closeRecoveryArmed = beginWindowCloseFocusRecovery(
                in: entry.workspaceId,
                closedToken: entry.token
            )
        } else {
            _ = activeWindowCloseFocusRecoveryWorkspaceId()
            closeRecoveryArmed = false
        }
        let layoutType = controller.workspaceManager.descriptor(for: entry.workspaceId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) } ?? .defaultLayout
        guard layoutType != .dwindle,
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
              controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        else {
            return (shouldRecoverFocus, closeRecoveryArmed)
        }
        let shouldAnimate = controller.niriEngine?
            .findNode(for: entry.token, in: entry.workspaceId)?.isHiddenInTabbedMode != true
        if shouldAnimate {
            controller.layoutRefreshController.startWindowCloseAnimation(entry: entry, monitor: monitor)
        }
        return (shouldRecoverFocus, closeRecoveryArmed)
    }
}
