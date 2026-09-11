// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func handleCGSEvent(_ event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, spaceId):
            beginWindowSubscriptionIdentityTransition()
            WindowAdmissionTrace.record(
                .init(action: .cgsCreated, windowId: Int(windowId))
            )
            handleCGSWindowCreated(windowId: windowId, spaceId: spaceId)
            controller.spaceTracker.noteWindowSpace(windowId: Int(windowId), spaceId: spaceId)
            refreshWindowSubscriptions()

        case let .destroyed(windowId, _):
            beginWindowSubscriptionIdentityTransition()
            WindowAdmissionTrace.record(
                .init(action: .cgsDestroyed, windowId: Int(windowId), reason: "destroyed")
            )
            handleCGSSpaceWindowDestroyed(windowId: windowId)
            refreshWindowSubscriptions()

        case let .closed(windowId):
            beginWindowSubscriptionIdentityTransition()
            WindowAdmissionTrace.record(
                .init(action: .cgsDestroyed, windowId: Int(windowId), reason: "closed")
            )
            handleCGSWindowDestroyed(windowId: windowId, evidence: .windowClosed)
            refreshWindowSubscriptions()

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            if WindowAdmissionTrace.shared.isActive, !isOwnProcessPid(pid) {
                WindowAdmissionTrace.record(
                    .init(
                        action: .frontmostObserved,
                        pid: pid,
                        bundleId: resolveBundleId(pid)
                    )
                )
            }
            handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        case let .orderChanged(windowId):
            handleWindowOrderChanged(windowId: windowId)

        case let .titleChanged(windowId):
            guard case let .exact(token, windowInfo) = resolveWindowServerIdentity(windowId),
                  controller.workspaceManager.entry(for: token) != nil
            else {
                return
            }
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            controller.requestWorkspaceBarRefresh()
            updateManagedReplacementTitle(windowInfo: windowInfo, token: token)
            scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)])
        }
    }

    private func handleWindowOrderChanged(windowId: UInt32) {
        guard let controller else { return }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        guard case let .exact(token, _) = resolveWindowServerIdentity(windowId),
              controller.workspaceManager.entry(for: token) != nil
        else {
            return
        }
        controller.surfaceReconciler.noteRestackOccurred()
    }

    private func handleCGSWindowCreated(windowId: UInt32, spaceId: UInt64) {
        captureCreatePlacementContext(windowId: windowId, spaceId: spaceId)
        recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
        if shouldDeferCreateForInactiveNativeSpace(spaceId) {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    windowId: Int(windowId),
                    reason: "inactive_native_space_\(spaceId)",
                    outcome: "deferred"
                )
            )
            deferCreatedWindow(windowId)
            return
        }
        processCreatedWindow(windowId: windowId)
    }

    func shouldDeferCreateForInactiveNativeSpace(_ spaceId: UInt64) -> Bool {
        guard spaceId != 0, let controller else { return false }
        let topology = controller.workspaceManager.spaceTopology
        return topology.isKnownSpace(spaceId) && !topology.isCurrentSpace(spaceId)
    }

    func processCreatedWindow(
        windowId: UInt32,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        retryTrigger: AdmissionRetryTrigger = .create
    ) {
        guard let controller else { return }
        if controller.isDiscoveryInProgress {
            deferCreateDuringDiscovery(windowId)
            return
        }
        if controller.isOwnedWindow(windowNumber: Int(windowId)) {
            rejectOwnedCreate(windowId)
            return
        }

        let windowInfo = resolveWindowInfo(windowId)
        if let windowInfo, isOwnProcessPid(pid_t(windowInfo.pid)) {
            rejectOwnedCreate(windowId)
            return
        }
        let createPlacementContext = pendingCreatePlacementContext(for: Int(windowId))
        let effectivePlacementOrigin = Self.effectivePlacementOrigin(
            placementOrigin,
            createPlacementContext: createPlacementContext
        )
        let outcome = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: fallbackToken,
            fallbackAXRef: fallbackAXRef,
            allowsTrackedIdentityReplacement: retryTrigger.allowsTrackedIdentityReplacement,
            placementOrigin: effectivePlacementOrigin,
            createPlacementContext: createPlacementContext
        )
        guard let candidate = preparedCreateCandidate(
            from: outcome,
            windowId: windowId,
            trigger: retryTrigger
        ) else {
            return
        }

        if completeLiveStructuralReplacementCreate(candidate) {
            return
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(candidate)
            return
        }

        trackPreparedCreate(candidate)
    }

    private func deferCreateDuringDiscovery(_ windowId: UInt32) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionPending,
                windowId: Int(windowId),
                reason: "discovery_in_progress",
                outcome: "deferred"
            )
        )
        deferCreatedWindow(windowId)
    }

    private func rejectOwnedCreate(_ windowId: UInt32) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionIgnored,
                windowId: Int(windowId),
                reason: WindowAdmissionRejectionReason.ownedWindow.rawValue
            )
        )
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        rejectDeferredReplacement(windowId: windowId)
    }

    private func handleCGSSpaceWindowDestroyed(windowId: UInt32) {
        if resolveWindowInfo(windowId) != nil { return }
        if let controller, let entry = controller.workspaceManager.entry(forWindowId: Int(windowId)),
           controller.workspaceManager.hiddenState(for: entry.token) != nil { return }
        handleCGSWindowDestroyed(windowId: windowId, evidence: .transientLifecycle)
    }

    func subscribeToManagedWindows() {
        refreshWindowSubscriptions()
    }

    func liveCreateSpace(
        for windowId: UInt32,
        spaceIdsForWindow: (UInt32) -> [UInt64] = { SkyLight.shared.spacesForWindow($0) }
    ) -> UInt64 {
        guard let controller else { return 0 }
        return controller.workspaceManager.spaceTopology
            .selectWindowSpace(from: spaceIdsForWindow(windowId)) ?? 0
    }

    private func handleCGSWindowDestroyed(
        windowId: UInt32,
        evidence: WindowDestroyEvidence
    ) {
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        let retryRetainCount = cancelCreatedWindowRetry(windowId: windowId)
        if retryRetainCount == 0 {
            releasePreparedWindowSubscription(windowId)
        }
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        rejectDeferredReplacement(windowId: windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: nil, evidence: evidence)
    }

    func processDeferredCreatedWindow(
        _ windowId: UInt32, controller: WMController, spaceIdsForWindow: (UInt32) -> [UInt64]
    ) {
        let retryState = admissionRetryStateByWindowId[windowId]
        let retryTrigger = retryState?.trigger ?? .create
        if case .identityRebind = retryTrigger {
            return
        }
        if controller.isOwnedWindow(windowNumber: Int(windowId)) {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            rejectDeferredReplacement(windowId: windowId)
            return
        }
        let windowInfo = resolveWindowInfo(windowId)
        guard let windowInfo else {
            _ = scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: retryState?.expectedToken,
                axRef: retryState?.axRef,
                reason: .windowInfoMissing,
                trigger: retryTrigger
            )
            return
        }
        if isOwnProcessPid(pid_t(windowInfo.pid)) {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            rejectDeferredReplacement(windowId: windowId)
            return
        }
        if shouldDeferCreateForInactiveNativeSpace(
            liveCreateSpace(for: windowId, spaceIdsForWindow: spaceIdsForWindow)
        ) {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    pid: pid_t(windowInfo.pid),
                    windowId: Int(windowId),
                    reason: "inactive_native_space",
                    outcome: "deferred"
                )
            )
            deferCreatedWindow(windowId)
            return
        }
        admitDeferredCreatedWindow(windowId, windowInfo: windowInfo, retryState: retryState, trigger: retryTrigger)
    }

    private func admitDeferredCreatedWindow(
        _ windowId: UInt32, windowInfo: WindowServerInfo?, retryState: AdmissionRetryState?,
        trigger retryTrigger: AdmissionRetryTrigger
    ) {
        let createPlacementContext = pendingCreatePlacementContext(for: Int(windowId))
        let placementOrigin = Self.effectivePlacementOrigin(
            retryTrigger.placementOrigin,
            createPlacementContext: createPlacementContext
        )
        let outcome = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: retryState?.expectedToken,
            fallbackAXRef: retryState?.axRef,
            allowsTrackedIdentityReplacement: retryTrigger.allowsTrackedIdentityReplacement,
            placementOrigin: placementOrigin,
            createPlacementContext: createPlacementContext
        )
        guard let candidate = preparedCreateCandidate(
            from: outcome,
            windowId: windowId,
            trigger: retryTrigger
        ) else {
            return
        }
        if completeLiveStructuralReplacementCreate(candidate) {
            return
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(candidate)
        } else {
            trackPreparedCreate(candidate)
        }
    }
}
