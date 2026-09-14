// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
        controller?.workspaceManager.clearExternalFocusIdentity(
            matching: WindowToken(pid: pid, windowId: windowId)
        )
    }

    func handleAppDeactivated(pid: pid_t) {
        guard let controller else { return }
        let workspaceManager = controller.workspaceManager
        workspaceManager.clearExternalFocusIdentity(pid: pid)

        guard let focusedToken = workspaceManager.nativeManagedFocusToken,
              focusedToken.pid == pid,
              let entry = workspaceManager.entry(for: focusedToken),
              entry.mode == .floating
        else { return }

        workspaceManager.suppressFocusBorder(for: focusedToken)
    }

    func handleAppHidden(pid: pid_t, source: WMEventSource = .ax) {
        guard let controller = acceptAppVisibilityChange(hidden: true, pid: pid, source: source) else { return }
        let entries = controller.workspaceManager.entries(forPid: pid)
        let affectedWorkspaceIds = Set(entries.map(\.workspaceId))
        controller.dwindleLayoutHandler.groupReveals.cancelPendingGroupReveals(pid: pid)
        for entry in entries {
            controller.layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
        }
        controller.mouseEventHandler.handleAppVisibilityChanged()
        for workspaceId in affectedWorkspaceIds {
            controller.layoutRefreshController.cancelActiveAnimations(for: workspaceId)
        }
        controller.layoutRefreshController.stopAllDwindleAnimations()
        controller.layoutRefreshController.cancelFrameAnimations(forPID: pid)
        controller.axManager.setMacOSAppHidden(
            true,
            pid: pid,
            entries: entries.map { (pid: $0.pid, windowId: $0.windowId) }
        )
        controller.workspaceManager.setAppHidden(true, pid: pid, source: source)

        if let activeRequest = controller.intentLedger.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            _ = controller.intentLedger.cancelManagedRequest(requestId: activeRequest.requestId)
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId,
                requestId: activeRequest.requestId
            )
            controller.scratchpadStacking.abortScratchpadStacking(matching: activeRequest.requestId)
            controller.intentLedger.discardPendingFocus(activeRequest.token)
        }
        if controller.workspaceManager.renderableFocusToken?.pid == pid {
            _ = controller.workspaceManager.clearNativeFocusOwner()
        }
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds
        )

        requestAppHideRefresh(
            pid: pid,
            source: source,
            managedWindowCount: entries.count,
            affectedWorkspaceIds: affectedWorkspaceIds,
            controller: controller
        )
        controller.surfaceReconciler.noteWorldChanged()
    }

    func handleAppUnhidden(pid: pid_t, source: WMEventSource = .ax) {
        guard let controller = acceptAppVisibilityChange(hidden: false, pid: pid, source: source) else { return }
        let entries = controller.workspaceManager.entries(forPid: pid)
        let affectedWorkspaceIds = Set(entries.map(\.workspaceId))
        let revealIntent = controller.intentLedger.openAppRevealFocusIntent(pid: pid)
        controller.workspaceManager.setAppHidden(false, pid: pid, source: source)
        controller.axManager.setMacOSAppHidden(
            false,
            pid: pid,
            entries: entries.map { (pid: $0.pid, windowId: $0.windowId) }
        )
        controller.reconcileScratchpadMembersAfterAppUnhide(pid: pid)
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds
        )
        let completeReveal = appRevealCompletion(revealIntent, pid: pid, controller: controller)
        let activeAffectedWorkspaceIds = activeWorkspaceIds(
            in: affectedWorkspaceIds,
            controller: controller
        )
        AppVisibilityTrace.record(
            .refresh,
            pid: pid,
            visibility: .visible,
            outcome: .requested,
            generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
            managedWindowCount: entries.count,
            affectedWorkspaceCount: affectedWorkspaceIds.count,
            activeWorkspaceCount: activeAffectedWorkspaceIds.count,
            source: source
        )
        controller.layoutRefreshController.requestVisibilityRefresh(
            reason: .appUnhidden,
            affectedWorkspaceIds: activeAffectedWorkspaceIds,
            postLayout: completeReveal,
            postLayoutInvalidated: completeReveal
        )
        controller.surfaceReconciler.noteWorldChanged()
    }

    private func activeWorkspaceIds(
        in workspaceIds: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        Set(workspaceIds.filter { workspaceId in
            guard let monitorId = controller.workspaceManager.monitorId(for: workspaceId) else {
                return false
            }
            return controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
        })
    }

    private func acceptAppVisibilityChange(hidden: Bool, pid: pid_t, source: WMEventSource) -> WMController? {
        let visibility: AppVisibilityTrace.Visibility = hidden ? .hidden : .visible
        guard let controller else {
            AppVisibilityTrace.record(
                .stateTransition,
                pid: pid,
                visibility: visibility,
                outcome: .rejected,
                reason: .controllerUnavailable,
                source: source
            )
            return nil
        }
        guard controller.workspaceManager.isAppHidden(pid: pid) != hidden else {
            AppVisibilityTrace.record(
                .stateTransition,
                pid: pid,
                visibility: visibility,
                outcome: .duplicate,
                generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
                source: source
            )
            return nil
        }
        return controller
    }

    private func requestAppHideRefresh(
        pid: pid_t,
        source: WMEventSource,
        managedWindowCount: Int,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) {
        let activeAffectedWorkspaceIds = activeWorkspaceIds(
            in: affectedWorkspaceIds,
            controller: controller
        )
        if !activeAffectedWorkspaceIds.isEmpty {
            AppVisibilityTrace.record(
                .refresh,
                pid: pid,
                visibility: .hidden,
                outcome: .requested,
                generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
                managedWindowCount: managedWindowCount,
                affectedWorkspaceCount: affectedWorkspaceIds.count,
                activeWorkspaceCount: activeAffectedWorkspaceIds.count,
                source: source
            )
            controller.layoutRefreshController.requestVisibilityRefresh(
                reason: .appHidden,
                affectedWorkspaceIds: activeAffectedWorkspaceIds
            )
        } else {
            AppVisibilityTrace.record(
                .refresh,
                pid: pid,
                visibility: .hidden,
                outcome: .skipped,
                generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
                managedWindowCount: managedWindowCount,
                affectedWorkspaceCount: affectedWorkspaceIds.count,
                activeWorkspaceCount: 0,
                reason: .noActiveWorkspace,
                source: source
            )
        }
    }

    private func appRevealCompletion(
        _ revealIntent: (intent: Intent, payload: AppRevealFocusPayload)?,
        pid: pid_t,
        controller: WMController
    ) -> LayoutRefreshController.PostLayoutAction? {
        let revealReady = revealIntent.flatMap { revealIntent in
            controller.intentLedger.drainAppRevealFocus(
                intentId: revealIntent.intent.id,
                pid: pid,
                appVisibilityGeneration: controller.workspaceManager.appVisibilityGeneration(for: pid)
            )
        } == .ready
        if revealReady, let revealIntentId = revealIntent?.intent.id {
            return { [weak controller] in
                _ = controller?.windowActionHandler.completeAppRevealFocus(intentId: revealIntentId)
            }
        } else {
            return nil
        }
    }
}
