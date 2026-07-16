// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowState? {
        guard let controller else { return nil }
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken),
              oldToken == newToken || controller.workspaceManager.entry(for: newToken) == nil
        else {
            return nil
        }
        if let collision = controller.workspaceManager.entry(forWindowId: newToken.windowId),
           collision.token != oldToken
        {
            return nil
        }
        let oldWindow = AXManagedWindowIdentity(token: oldToken, axRef: oldEntry.axRef)
        let newWindow = AXManagedWindowIdentity(token: newToken, axRef: axRef)
        if controller.hasStartedServices,
           AppAXContext.contexts[newToken.pid] == nil
        {
            scheduleManagedWindowIdentityRebind(
                from: oldWindow,
                to: newWindow,
                managedReplacementMetadata: managedReplacementMetadata
            )
            return nil
        }
        guard controller.axManager.rebindWindowState(from: oldWindow, to: newWindow) else {
            scheduleManagedWindowIdentityRebind(
                from: oldWindow,
                to: newWindow,
                managedReplacementMetadata: managedReplacementMetadata
            )
            return nil
        }
        guard let entry = commitManagedWindowIdentityRebind(
            from: oldToken,
            to: newToken,
            axRef: axRef,
            managedReplacementMetadata: managedReplacementMetadata
        ) else { return nil }

        finishAdmissionRetryAfterTracking(windowId: windowId)
        cancelPostCreateLifecycleVerification(for: oldToken)
        cancelSameAppCloseProbe(matchingFocusedToken: oldToken, reason: "identity_rebind")
        clearTerminalFrameFailure(windowId: oldToken.windowId)
        admissionQuarantineByWindowId.removeValue(forKey: oldToken.windowId)
        identityAliasesByWindowId.removeValue(forKey: oldToken.windowId)
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldToken.windowId), windowId])
        subscribeToWindows([windowId])
        controller.requestWorkspaceBarRefresh()
        controller.surfaceReconciler.noteRestackOccurred()
        return entry
    }

    private func commitManagedWindowIdentityRebind(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata?
    ) -> WindowState? {
        guard let controller else { return nil }
        let focusTransactionIds = controller.dwindleLayoutHandler
            .currentPendingGroupRevealFocusTransactionIds(for: oldToken)
        return controller.withRuntimeFrameJobCancellationSuppressed {
            guard let entry = controller.workspaceManager.rekeyWindow(
                from: oldToken,
                to: newToken,
                newAXRef: axRef,
                managedReplacementMetadata: managedReplacementMetadata
            )
            else {
                return nil
            }

            controller.intentLedger.rekeyManagedRequest(from: oldToken, to: newToken)
            controller.rekeyScratchpadWindowResources(from: oldToken, to: newToken, axRef: axRef)
            controller.layoutRefreshController.rekeyPendingRevealTransaction(
                from: oldToken,
                to: newToken,
                entry: entry
            )
            controller.dwindleLayoutHandler.rekeyPendingGroupRevealTransaction(
                from: oldToken,
                to: newToken,
                entry: entry,
                rebasingFocusTransactionIds: focusTransactionIds
            )
            return entry
        }
    }

    private func scheduleManagedWindowIdentityRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        managedReplacementMetadata: ManagedReplacementMetadata?
    ) {
        guard let windowId = UInt32(exactly: newWindow.token.windowId) else { return }
        _ = scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: newWindow.token,
            axRef: newWindow.axRef,
            reason: .factsDeferred,
            trigger: .identityRebind(
                oldWindow: oldWindow,
                newWindow: newWindow,
                managedReplacementMetadata: managedReplacementMetadata
            )
        )
        Task { @MainActor [weak self] in
            guard let self,
                  let controller = self.controller,
                  controller.hasStartedServices,
                  AppAXContext.contexts[newWindow.token.pid] == nil,
                  let app = NSRunningApplication(processIdentifier: newWindow.token.pid)
            else {
                return
            }
            _ = await controller.axManager.windowsForApp(app)
        }
    }
}
