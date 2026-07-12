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
        let rebasingGroupRevealFocusTransactionIds = controller.dwindleLayoutHandler
            .currentPendingGroupRevealFocusTransactionIds(for: oldToken)
        let entry: WindowState? = controller.withRuntimeFrameJobCancellationSuppressed {
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
            controller.axManager.rekeyWindowState(
                pid: newToken.pid,
                oldWindowId: oldToken.windowId,
                newWindow: axRef
            )
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
                rebasingFocusTransactionIds: rebasingGroupRevealFocusTransactionIds
            )
            return entry
        }
        guard let entry else { return nil }

        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldToken.windowId), windowId])
        subscribeToWindows([windowId])
        controller.requestWorkspaceBarRefresh()
        controller.surfaceReconciler.noteRestackOccurred()

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller, controller.hasStartedServices else { return }
            if let app = NSRunningApplication(processIdentifier: newToken.pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        return entry
    }
}
