import CoreGraphics
import Foundation

enum StateReducer {
    static func reduce(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor]
    ) -> ActionPlan {
        var plan = ActionPlan()

        switch event {
        case let .windowAdmitted(_, workspaceId, monitorId, mode, _):
            plan.lifecyclePhase = lifecyclePhase(for: mode)
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )

        case let .windowRekeyed(from, to, workspaceId, monitorId, reason, _):
            plan.lifecyclePhase = .replacing
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            plan.replacementCorrelation = ReplacementCorrelation(
                previousToken: from,
                nextToken: to,
                reason: reason,
                recordedAt: Date()
            )
            plan.focusSession = rekeyedFocusSession(
                from: currentSnapshot.focusSession,
                oldToken: from,
                newToken: to
            )

        case let .windowRemoved(token, _, _):
            plan.lifecyclePhase = .destroyed
            plan.focusSession = removingFocusState(
                from: currentSnapshot.focusSession,
                token: token
            )

        case let .workspaceAssigned(_, _, workspaceId, monitorId, _):
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )

        case let .windowModeChanged(_, workspaceId, monitorId, mode, _):
            plan.lifecyclePhase = lifecyclePhase(for: mode)
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )

        case let .floatingGeometryUpdated(_, workspaceId, referenceMonitorId, frame, restoreToFloating, _):
            plan.lifecyclePhase = .floating
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: referenceMonitorId ?? existingEntry?.observedState.monitorId
            )
            observedState.frame = frame
            plan.observedState = observedState

            var desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: referenceMonitorId ?? existingEntry?.desiredState.monitorId,
                mode: .floating
            )
            desiredState.floatingFrame = frame
            desiredState.rescueEligible = restoreToFloating
            plan.desiredState = desiredState

        case let .hiddenStateChanged(_, workspaceId, monitorId, hiddenState, _):
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            observedState.isVisible = hiddenState == nil
            plan.observedState = observedState
            if let hiddenState {
                plan.lifecyclePhase = hiddenState.offscreenSide == nil ? .hidden : .offscreen
            } else {
                plan.lifecyclePhase = lifecyclePhase(for: existingEntry?.mode ?? .tiling)
            }

        case let .nativeFullscreenTransition(_, workspaceId, monitorId, isActive, _):
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            observedState.isNativeFullscreen = isActive
            plan.observedState = observedState
            plan.lifecyclePhase = isActive ? .nativeFullscreen : lifecyclePhase(for: existingEntry?.mode ?? .tiling)

        case let .managedReplacementMetadataChanged(_, workspaceId, monitorId, _):
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            plan.notes = ["managed_replacement_metadata_changed"]

        case let .topologyChanged(displays, _):
            plan.notes = ["topology=\(displays.count)"]

        case .activeSpaceChanged:
            plan.notes = ["active_space_changed"]

        case let .focusLeaseChanged(lease, _):
            plan.focusSession = updatingFocusLease(
                in: currentSnapshot.focusSession,
                lease: lease
            )
            if let lease {
                plan.notes = ["focus_lease=\(lease.owner.rawValue)", lease.reason].filter { !$0.isEmpty }
            } else {
                plan.notes = ["focus_lease=cleared"]
            }

        case let .managedFocusRequested(token, workspaceId, monitorId, _):
            plan.focusSession = managedFocusRequested(
                from: currentSnapshot.focusSession,
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId
            )

        case let .managedFocusConfirmed(token, workspaceId, monitorId, appFullscreen, _):
            plan.focusSession = managedFocusConfirmed(
                from: currentSnapshot.focusSession,
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                appFullscreen: appFullscreen
            )

        case let .managedFocusCancelled(token, workspaceId, _):
            plan.focusSession = managedFocusCancelled(
                from: currentSnapshot.focusSession,
                token: token,
                workspaceId: workspaceId
            )

        case let .nonManagedFocusChanged(
            active,
            appFullscreen,
            preserveFocusedToken,
            preservePendingManagedFocus,
            _
        ):
            plan.focusSession = nonManagedFocusChanged(
                from: currentSnapshot.focusSession,
                active: active,
                appFullscreen: appFullscreen,
                preserveFocusedToken: preserveFocusedToken,
                preservePendingManagedFocus: preservePendingManagedFocus
            )

        case .systemSleep:
            plan.notes = ["system_sleep"]

        case .systemWake:
            plan.notes = ["system_wake"]
        }

        if plan.restoreIntent == nil, let existingEntry {
            plan.restoreIntent = restoreIntent(for: existingEntry, monitors: monitors)
        }

        return plan
    }

    static func restoreIntent(
        for entry: WindowModel.Entry,
        monitors: [Monitor]
    ) -> RestoreIntent {
        let preferredMonitorId = entry.desiredState.monitorId
            ?? entry.observedState.monitorId
            ?? entry.floatingState?.referenceMonitorId
        let preferredMonitor = preferredMonitorId.flatMap { id in
            monitors.first { $0.id == id }
        }
        let floatingState = entry.floatingState
        let niriPlacement = entry.mode == .tiling && entry.restoreIntent?.workspaceId == entry.workspaceId
            ? entry.restoreIntent?.niriPlacement
            : nil
        return RestoreIntent(
            topologyProfile: TopologyProfile(monitors: monitors),
            workspaceId: entry.workspaceId,
            preferredMonitor: preferredMonitor.map(DisplayFingerprint.init),
            floatingFrame: entry.desiredState.floatingFrame ?? floatingState?.lastFrame,
            normalizedFloatingOrigin: floatingState?.normalizedOrigin,
            restoreToFloating: floatingState?.restoreToFloating ?? (entry.mode == .floating),
            rescueEligible: entry.desiredState.rescueEligible || floatingState?.restoreToFloating == true,
            niriPlacement: niriPlacement
        )
    }

    static func replay(_ trace: [ReconcileTraceRecord]) -> [ActionPlan] {
        trace.map(\.plan)
    }

    private static func lifecyclePhase(for mode: TrackedWindowMode) -> WindowLifecyclePhase {
        switch mode {
        case .tiling:
            .tiled
        case .floating:
            .floating
        }
    }

    private static func baseObservedState(
        from entry: WindowModel.Entry?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        var state = entry?.observedState ?? ObservedWindowState.initial(
            workspaceId: workspaceId,
            monitorId: monitorId
        )
        state.workspaceId = workspaceId
        state.monitorId = monitorId ?? state.monitorId
        state.hasAXReference = true
        return state
    }

    private static func baseDesiredState(
        from entry: WindowModel.Entry?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode
    ) -> DesiredWindowState {
        var state = entry?.desiredState ?? DesiredWindowState.initial(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: mode
        )
        state.workspaceId = workspaceId
        state.monitorId = monitorId ?? state.monitorId
        state.disposition = mode
        state.rescueEligible = mode == .floating || state.rescueEligible
        return state
    }

    private static func updatingFocusLease(
        in focusSession: FocusSessionSnapshot,
        lease: FocusPolicyLease?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.focusLease = lease
        return focusSession
    }

    private static func managedFocusRequested(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: token,
            workspaceId: workspaceId,
            monitorId: monitorId
        )
        return focusSession
    }

    private static func managedFocusConfirmed(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId _: WorkspaceDescriptor.ID,
        monitorId _: Monitor.ID?,
        appFullscreen: Bool
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.focusedToken = token
        focusSession.pendingManagedFocus = .empty
        focusSession.isNonManagedFocusActive = false
        focusSession.isAppFullscreenActive = appFullscreen
        return focusSession
    }

    private static func managedFocusCancelled(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        let matchesToken = token.map { focusSession.pendingManagedFocus.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { focusSession.pendingManagedFocus.workspaceId == $0 } ?? true
        if matchesToken, matchesWorkspace {
            focusSession.pendingManagedFocus = .empty
        }
        return focusSession
    }

    private static func nonManagedFocusChanged(
        from focusSession: FocusSessionSnapshot,
        active: Bool,
        appFullscreen: Bool,
        preserveFocusedToken: Bool,
        preservePendingManagedFocus: Bool
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if active, !preserveFocusedToken {
            focusSession.focusedToken = nil
        }
        if !preservePendingManagedFocus {
            focusSession.pendingManagedFocus = .empty
        }
        focusSession.isNonManagedFocusActive = active
        focusSession.isAppFullscreenActive = appFullscreen
        return focusSession
    }

    private static func rekeyedFocusSession(
        from focusSession: FocusSessionSnapshot,
        oldToken: WindowToken,
        newToken: WindowToken
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if focusSession.focusedToken == oldToken {
            focusSession.focusedToken = newToken
        }
        if focusSession.pendingManagedFocus.token == oldToken {
            focusSession.pendingManagedFocus.token = newToken
        }
        return focusSession
    }

    private static func removingFocusState(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if focusSession.focusedToken == token {
            focusSession.focusedToken = nil
            focusSession.isAppFullscreenActive = false
        }
        if focusSession.pendingManagedFocus.token == token {
            focusSession.pendingManagedFocus = .empty
        }
        return focusSession
    }
}
