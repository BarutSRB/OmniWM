// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import CoreGraphics
import Foundation

private extension TrackedWindowMode {
    var reconcileRawValue: UInt32 {
        switch self {
        case .tiling:
            UInt32(OMNIWM_RECONCILE_WINDOW_MODE_TILING)
        case .floating:
            UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING)
        }
    }

    init(reconcileRawValue: UInt32) {
        switch reconcileRawValue {
        case UInt32(OMNIWM_RECONCILE_WINDOW_MODE_TILING):
            self = .tiling
        case UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING):
            self = .floating
        default:
            preconditionFailure("Unknown reconcile window mode \(reconcileRawValue)")
        }
    }
}

private extension WindowLifecyclePhase {
    init(reconcileRawValue: UInt32) {
        switch reconcileRawValue {
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_DISCOVERED):
            self = .discovered
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_ADMITTED):
            self = .admitted
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_TILED):
            self = .tiled
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_FLOATING):
            self = .floating
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_HIDDEN):
            self = .hidden
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_OFFSCREEN):
            self = .offscreen
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_RESTORING):
            self = .restoring
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_REPLACING):
            self = .replacing
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_NATIVE_FULLSCREEN):
            self = .nativeFullscreen
        case UInt32(OMNIWM_RECONCILE_LIFECYCLE_DESTROYED):
            self = .destroyed
        default:
            preconditionFailure("Unknown reconcile lifecycle \(reconcileRawValue)")
        }
    }
}

private extension ReplacementCorrelation.Reason {
    var reconcileRawValue: UInt32 {
        switch self {
        case .managedReplacement:
            UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_MANAGED_REPLACEMENT)
        case .nativeFullscreen:
            UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_NATIVE_FULLSCREEN)
        case .manualRekey:
            UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_MANUAL_REKEY)
        }
    }

    init(reconcileRawValue: UInt32) {
        switch reconcileRawValue {
        case UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_MANAGED_REPLACEMENT):
            self = .managedReplacement
        case UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_NATIVE_FULLSCREEN):
            self = .nativeFullscreen
        case UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_MANUAL_REKEY):
            self = .manualRekey
        default:
            preconditionFailure("Unknown replacement reason \(reconcileRawValue)")
        }
    }
}

enum StateReducer {
    static func reduce(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor],
        persistedHydration: PersistedHydrationMutation? = nil
    ) -> ActionPlan {
        var rawEvent = encode(event: event)
        let rawFocusSession = encode(focusSession: currentSnapshot.focusSession)
        let rawEntry = existingEntry.map(encode(entry:))
        let rawHydration = persistedHydration.map(encode(hydration:))
        var rawOutput = omniwm_reconcile_plan_output()

        let status = withOptionalPointer(rawEntry) { entryPointer in
            withOptionalPointer(rawHydration) { hydrationPointer in
                withMonitorBuffer(monitors: monitors) { monitorBuffer in
                    withUnsafePointer(to: rawFocusSession) { focusPointer in
                        omniwm_reconcile_plan(
                            &rawEvent,
                            entryPointer,
                            focusPointer,
                            monitorBuffer.baseAddress,
                            monitorBuffer.count,
                            hydrationPointer,
                            &rawOutput
                        )
                    }
                }
            }
        }

        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_reconcile_plan returned \(status)"
        )

        return decodePlan(
            output: rawOutput,
            event: event,
            currentFocusSession: currentSnapshot.focusSession,
            monitors: monitors
        )
    }

    static func restoreIntent(
        for entry: WindowModel.Entry,
        monitors: [Monitor]
    ) -> RestoreIntent {
        let rawEntry = encode(entry: entry)
        var rawOutput = omniwm_reconcile_restore_intent_output()

        let status = withMonitorBuffer(monitors: monitors) { monitorBuffer in
            withUnsafePointer(to: rawEntry) { entryPointer in
                omniwm_reconcile_restore_intent(
                    entryPointer,
                    monitorBuffer.baseAddress,
                    monitorBuffer.count,
                    &rawOutput
                )
            }
        }

        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_reconcile_restore_intent returned \(status)"
        )

        return decodeRestoreIntent(output: rawOutput, monitors: monitors)
    }

    private static func encode(event: WMEvent) -> omniwm_reconcile_event {
        switch event {
        case let .windowAdmitted(token, workspaceId, monitorId, mode, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_WINDOW_ADMITTED),
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )

        case let .windowRekeyed(from, to, workspaceId, monitorId, reason, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_WINDOW_REKEYED),
                token: to,
                secondaryToken: from,
                workspaceId: workspaceId,
                monitorId: monitorId,
                replacementReason: reason
            )

        case let .windowRemoved(token, workspaceId, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_WINDOW_REMOVED),
                token: token,
                workspaceId: workspaceId
            )

        case let .workspaceAssigned(token, from, to, monitorId, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_WORKSPACE_ASSIGNED),
                token: token,
                workspaceId: to,
                secondaryWorkspaceId: from,
                monitorId: monitorId
            )

        case let .windowModeChanged(token, workspaceId, monitorId, mode, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_WINDOW_MODE_CHANGED),
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )

        case let .floatingGeometryUpdated(token, workspaceId, referenceMonitorId, frame, restoreToFloating, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_FLOATING_GEOMETRY_UPDATED),
                token: token,
                workspaceId: workspaceId,
                monitorId: referenceMonitorId,
                frame: frame,
                restoreToFloating: restoreToFloating
            )

        case let .hiddenStateChanged(token, workspaceId, monitorId, hiddenState, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_HIDDEN_STATE_CHANGED),
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                hiddenState: hiddenState
            )

        case let .nativeFullscreenTransition(token, workspaceId, monitorId, isActive, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_NATIVE_FULLSCREEN_TRANSITION),
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                isActive: isActive
            )

        case let .managedReplacementMetadataChanged(token, workspaceId, monitorId, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_MANAGED_REPLACEMENT_METADATA_CHANGED),
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId
            )

        case .topologyChanged:
            return makeEvent(kind: UInt32(OMNIWM_RECONCILE_EVENT_TOPOLOGY_CHANGED))

        case .activeSpaceChanged:
            return makeEvent(kind: UInt32(OMNIWM_RECONCILE_EVENT_ACTIVE_SPACE_CHANGED))

        case let .focusLeaseChanged(lease, _):
            var raw = makeEvent(kind: UInt32(OMNIWM_RECONCILE_EVENT_FOCUS_LEASE_CHANGED))
            raw.has_focus_lease = lease == nil ? 0 : 1
            return raw

        case let .managedFocusRequested(token, workspaceId, monitorId, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_REQUESTED),
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId
            )

        case let .managedFocusConfirmed(token, workspaceId, monitorId, appFullscreen, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_CONFIRMED),
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                appFullscreen: appFullscreen
            )

        case let .managedFocusCancelled(token, workspaceId, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_CANCELLED),
                secondaryToken: token,
                workspaceId: workspaceId
            )

        case let .nonManagedFocusChanged(active, appFullscreen, preserveFocusedToken, _):
            return makeEvent(
                kind: UInt32(OMNIWM_RECONCILE_EVENT_NON_MANAGED_FOCUS_CHANGED),
                isActive: active,
                appFullscreen: appFullscreen,
                preserveFocusedToken: preserveFocusedToken
            )

        case .systemSleep:
            return makeEvent(kind: UInt32(OMNIWM_RECONCILE_EVENT_SYSTEM_SLEEP))

        case .systemWake:
            return makeEvent(kind: UInt32(OMNIWM_RECONCILE_EVENT_SYSTEM_WAKE))
        }
    }

    private static func encode(hiddenState: WindowModel.HiddenState?) -> UInt32 {
        guard let hiddenState else {
            return UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE)
        }
        if let offscreenSide = hiddenState.offscreenSide {
            switch offscreenSide {
            case .left:
                return UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_LEFT)
            case .right:
                return UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_RIGHT)
            }
        }
        return UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_HIDDEN)
    }

    private static func encode(entry: WindowModel.Entry) -> omniwm_reconcile_entry {
        omniwm_reconcile_entry(
            workspace_id: encode(uuid: entry.workspaceId),
            mode: entry.mode.reconcileRawValue,
            observed_state: encode(observedState: entry.observedState),
            desired_state: encode(desiredState: entry.desiredState),
            floating_state: encode(floatingState: entry.floatingState),
            has_floating_state: entry.floatingState == nil ? 0 : 1
        )
    }

    private static func encode(observedState: ObservedWindowState) -> omniwm_reconcile_observed_state {
        omniwm_reconcile_observed_state(
            frame: observedState.frame.map(encode(rect:)) ?? zeroRect(),
            workspace_id: observedState.workspaceId.map(encode(uuid:)) ?? zeroUUID(),
            monitor_id: observedState.monitorId?.displayId ?? 0,
            has_frame: observedState.frame == nil ? 0 : 1,
            has_workspace_id: observedState.workspaceId == nil ? 0 : 1,
            has_monitor_id: observedState.monitorId == nil ? 0 : 1,
            is_visible: observedState.isVisible ? 1 : 0,
            is_focused: observedState.isFocused ? 1 : 0,
            has_ax_reference: observedState.hasAXReference ? 1 : 0,
            is_native_fullscreen: observedState.isNativeFullscreen ? 1 : 0
        )
    }

    private static func encode(desiredState: DesiredWindowState) -> omniwm_reconcile_desired_state {
        omniwm_reconcile_desired_state(
            workspace_id: desiredState.workspaceId.map(encode(uuid:)) ?? zeroUUID(),
            monitor_id: desiredState.monitorId?.displayId ?? 0,
            disposition: desiredState.disposition?.reconcileRawValue ?? 0,
            floating_frame: desiredState.floatingFrame.map(encode(rect:)) ?? zeroRect(),
            has_workspace_id: desiredState.workspaceId == nil ? 0 : 1,
            has_monitor_id: desiredState.monitorId == nil ? 0 : 1,
            has_disposition: desiredState.disposition == nil ? 0 : 1,
            has_floating_frame: desiredState.floatingFrame == nil ? 0 : 1,
            rescue_eligible: desiredState.rescueEligible ? 1 : 0
        )
    }

    private static func encode(floatingState: WindowModel.FloatingState?) -> omniwm_reconcile_floating_state {
        guard let floatingState else {
            return omniwm_reconcile_floating_state(
                last_frame: zeroRect(),
                normalized_origin: zeroPoint(),
                reference_monitor_id: 0,
                has_normalized_origin: 0,
                has_reference_monitor_id: 0,
                restore_to_floating: 0
            )
        }

        return omniwm_reconcile_floating_state(
            last_frame: encode(rect: floatingState.lastFrame),
            normalized_origin: floatingState.normalizedOrigin.map(encode(point:)) ?? zeroPoint(),
            reference_monitor_id: floatingState.referenceMonitorId?.displayId ?? 0,
            has_normalized_origin: floatingState.normalizedOrigin == nil ? 0 : 1,
            has_reference_monitor_id: floatingState.referenceMonitorId == nil ? 0 : 1,
            restore_to_floating: floatingState.restoreToFloating ? 1 : 0
        )
    }

    private static func encode(focusSession: FocusSessionSnapshot) -> omniwm_reconcile_focus_session {
        omniwm_reconcile_focus_session(
            focused_token: focusSession.focusedToken.map(encode(token:)) ?? zeroToken(),
            pending_managed_focus: encode(pendingManagedFocus: focusSession.pendingManagedFocus),
            has_focused_token: focusSession.focusedToken == nil ? 0 : 1,
            is_non_managed_focus_active: focusSession.isNonManagedFocusActive ? 1 : 0,
            is_app_fullscreen_active: focusSession.isAppFullscreenActive ? 1 : 0
        )
    }

    private static func encode(pendingManagedFocus: PendingManagedFocusSnapshot) -> omniwm_reconcile_pending_focus {
        omniwm_reconcile_pending_focus(
            token: pendingManagedFocus.token.map(encode(token:)) ?? zeroToken(),
            workspace_id: pendingManagedFocus.workspaceId.map(encode(uuid:)) ?? zeroUUID(),
            monitor_id: pendingManagedFocus.monitorId?.displayId ?? 0,
            has_token: pendingManagedFocus.token == nil ? 0 : 1,
            has_workspace_id: pendingManagedFocus.workspaceId == nil ? 0 : 1,
            has_monitor_id: pendingManagedFocus.monitorId == nil ? 0 : 1
        )
    }

    private static func encode(hydration: PersistedHydrationMutation) -> omniwm_reconcile_persisted_hydration {
        omniwm_reconcile_persisted_hydration(
            workspace_id: encode(uuid: hydration.workspaceId),
            monitor_id: hydration.monitorId?.displayId ?? 0,
            target_mode: hydration.targetMode.reconcileRawValue,
            floating_frame: hydration.floatingFrame.map(encode(rect:)) ?? zeroRect(),
            has_monitor_id: hydration.monitorId == nil ? 0 : 1,
            has_floating_frame: hydration.floatingFrame == nil ? 0 : 1
        )
    }

    private static func decodePlan(
        output: omniwm_reconcile_plan_output,
        event: WMEvent,
        currentFocusSession: FocusSessionSnapshot,
        monitors: [Monitor]
    ) -> ActionPlan {
        var plan = ActionPlan()

        if output.has_lifecycle_phase != 0 {
            plan.lifecyclePhase = WindowLifecyclePhase(reconcileRawValue: output.lifecycle_phase)
        }
        if output.has_observed_state != 0 {
            plan.observedState = decode(observedState: output.observed_state)
        }
        if output.has_desired_state != 0 {
            plan.desiredState = decode(desiredState: output.desired_state)
        }
        if output.has_restore_intent != 0 {
            plan.restoreIntent = decodeRestoreIntent(output: output.restore_intent, monitors: monitors)
        }
        if output.has_replacement_correlation != 0 {
            plan.replacementCorrelation = ReplacementCorrelation(
                previousToken: decode(token: output.replacement_correlation.previous_token),
                nextToken: decode(token: output.replacement_correlation.next_token),
                reason: ReplacementCorrelation.Reason(reconcileRawValue: output.replacement_correlation.reason),
                recordedAt: Date()
            )
        }
        if output.has_focus_session != 0 {
            plan.focusSession = decodeFocusSession(
                output: output.focus_session,
                event: event,
                currentFocusSession: currentFocusSession
            )
        }
        plan.notes = decodeNotes(code: output.note_code, event: event)

        return plan
    }

    private static func decode(observedState: omniwm_reconcile_observed_state) -> ObservedWindowState {
        ObservedWindowState(
            frame: observedState.has_frame != 0 ? decode(rect: observedState.frame) : nil,
            workspaceId: observedState.has_workspace_id != 0 ? decode(uuid: observedState.workspace_id) : nil,
            monitorId: observedState.has_monitor_id != 0 ? Monitor.ID(displayId: observedState.monitor_id) : nil,
            isVisible: observedState.is_visible != 0,
            isFocused: observedState.is_focused != 0,
            hasAXReference: observedState.has_ax_reference != 0,
            isNativeFullscreen: observedState.is_native_fullscreen != 0
        )
    }

    private static func decode(desiredState: omniwm_reconcile_desired_state) -> DesiredWindowState {
        DesiredWindowState(
            workspaceId: desiredState.has_workspace_id != 0 ? decode(uuid: desiredState.workspace_id) : nil,
            monitorId: desiredState.has_monitor_id != 0 ? Monitor.ID(displayId: desiredState.monitor_id) : nil,
            disposition: desiredState.has_disposition != 0 ? TrackedWindowMode(reconcileRawValue: desiredState.disposition) : nil,
            floatingFrame: desiredState.has_floating_frame != 0 ? decode(rect: desiredState.floating_frame) : nil,
            rescueEligible: desiredState.rescue_eligible != 0
        )
    }

    private static func decodeRestoreIntent(
        output: omniwm_reconcile_restore_intent_output,
        monitors: [Monitor]
    ) -> RestoreIntent {
        let preferredMonitor: DisplayFingerprint?
        if output.preferred_monitor_index >= 0,
           Int(output.preferred_monitor_index) < monitors.count
        {
            preferredMonitor = DisplayFingerprint(monitor: monitors[Int(output.preferred_monitor_index)])
        } else {
            preferredMonitor = nil
        }

        return RestoreIntent(
            topologyProfile: TopologyProfile(monitors: monitors),
            workspaceId: decode(uuid: output.workspace_id),
            preferredMonitor: preferredMonitor,
            floatingFrame: output.has_floating_frame != 0 ? decode(rect: output.floating_frame) : nil,
            normalizedFloatingOrigin: output.has_normalized_floating_origin != 0 ? decode(point: output.normalized_floating_origin) : nil,
            restoreToFloating: output.restore_to_floating != 0,
            rescueEligible: output.rescue_eligible != 0
        )
    }

    private static func decodeFocusSession(
        output: omniwm_reconcile_focus_session_output,
        event: WMEvent,
        currentFocusSession: FocusSessionSnapshot
    ) -> FocusSessionSnapshot {
        var focusSession = currentFocusSession
        focusSession.focusedToken = output.has_focused_token != 0 ? decode(token: output.focused_token) : nil
        focusSession.pendingManagedFocus = decode(pendingManagedFocus: output.pending_managed_focus)
        focusSession.isNonManagedFocusActive = output.is_non_managed_focus_active != 0
        focusSession.isAppFullscreenActive = output.is_app_fullscreen_active != 0

        switch output.focus_lease_action {
        case UInt32(OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_KEEP_EXISTING):
            break
        case UInt32(OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_CLEAR):
            focusSession.focusLease = nil
        case UInt32(OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_SET_FROM_EVENT):
            guard case let .focusLeaseChanged(lease, _) = event else {
                preconditionFailure("Expected focus lease event for focus lease action")
            }
            focusSession.focusLease = lease
        default:
            preconditionFailure("Unknown focus lease action \(output.focus_lease_action)")
        }

        return focusSession
    }

    private static func decode(pendingManagedFocus: omniwm_reconcile_pending_focus) -> PendingManagedFocusSnapshot {
        PendingManagedFocusSnapshot(
            token: pendingManagedFocus.has_token != 0 ? decode(token: pendingManagedFocus.token) : nil,
            workspaceId: pendingManagedFocus.has_workspace_id != 0 ? decode(uuid: pendingManagedFocus.workspace_id) : nil,
            monitorId: pendingManagedFocus.has_monitor_id != 0 ? Monitor.ID(displayId: pendingManagedFocus.monitor_id) : nil
        )
    }

    private static func decodeNotes(code: UInt32, event: WMEvent) -> [String] {
        switch code {
        case UInt32(OMNIWM_RECONCILE_NOTE_NONE):
            return []
        case UInt32(OMNIWM_RECONCILE_NOTE_MANAGED_REPLACEMENT_METADATA_CHANGED):
            return ["managed_replacement_metadata_changed"]
        case UInt32(OMNIWM_RECONCILE_NOTE_TOPOLOGY_CHANGED):
            guard case let .topologyChanged(displays, _) = event else {
                preconditionFailure("Expected topology changed event for topology note")
            }
            return ["topology=\(displays.count)"]
        case UInt32(OMNIWM_RECONCILE_NOTE_ACTIVE_SPACE_CHANGED):
            return ["active_space_changed"]
        case UInt32(OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_SET):
            guard case let .focusLeaseChanged(lease, _) = event, let lease else {
                preconditionFailure("Expected focus lease event for focus lease note")
            }
            return ["focus_lease=\(lease.owner.rawValue)", lease.reason].filter { !$0.isEmpty }
        case UInt32(OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_CLEARED):
            return ["focus_lease=cleared"]
        case UInt32(OMNIWM_RECONCILE_NOTE_SYSTEM_SLEEP):
            return ["system_sleep"]
        case UInt32(OMNIWM_RECONCILE_NOTE_SYSTEM_WAKE):
            return ["system_wake"]
        default:
            preconditionFailure("Unknown reconcile note code \(code)")
        }
    }

    private static func encode(uuid: UUID) -> omniwm_uuid {
        let bytes = Array(withUnsafeBytes(of: uuid.uuid) { $0 })
        let high = bytes[0..<8].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        let low = bytes[8..<16].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return omniwm_uuid(high: high, low: low)
    }

    private static func decode(uuid: omniwm_uuid) -> UUID {
        let b0 = UInt8((uuid.high >> 56) & 0xff)
        let b1 = UInt8((uuid.high >> 48) & 0xff)
        let b2 = UInt8((uuid.high >> 40) & 0xff)
        let b3 = UInt8((uuid.high >> 32) & 0xff)
        let b4 = UInt8((uuid.high >> 24) & 0xff)
        let b5 = UInt8((uuid.high >> 16) & 0xff)
        let b6 = UInt8((uuid.high >> 8) & 0xff)
        let b7 = UInt8(uuid.high & 0xff)
        let b8 = UInt8((uuid.low >> 56) & 0xff)
        let b9 = UInt8((uuid.low >> 48) & 0xff)
        let b10 = UInt8((uuid.low >> 40) & 0xff)
        let b11 = UInt8((uuid.low >> 32) & 0xff)
        let b12 = UInt8((uuid.low >> 24) & 0xff)
        let b13 = UInt8((uuid.low >> 16) & 0xff)
        let b14 = UInt8((uuid.low >> 8) & 0xff)
        let b15 = UInt8(uuid.low & 0xff)
        return UUID(uuid: (b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15))
    }

    private static func encode(token: WindowToken) -> omniwm_window_token {
        omniwm_window_token(pid: token.pid, window_id: Int64(token.windowId))
    }

    private static func decode(token: omniwm_window_token) -> WindowToken {
        WindowToken(pid: token.pid, windowId: Int(token.window_id))
    }

    private static func encode(rect: CGRect) -> omniwm_rect {
        omniwm_rect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private static func decode(rect: omniwm_rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func encode(point: CGPoint) -> omniwm_point {
        omniwm_point(x: point.x, y: point.y)
    }

    private static func decode(point: omniwm_point) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    private static func zeroUUID() -> omniwm_uuid {
        omniwm_uuid(high: 0, low: 0)
    }

    private static func zeroToken() -> omniwm_window_token {
        omniwm_window_token(pid: 0, window_id: 0)
    }

    private static func zeroPoint() -> omniwm_point {
        omniwm_point(x: 0, y: 0)
    }

    private static func zeroRect() -> omniwm_rect {
        omniwm_rect(x: 0, y: 0, width: 0, height: 0)
    }

    private static func makeEvent(
        kind: UInt32,
        token: WindowToken? = nil,
        secondaryToken: WindowToken? = nil,
        workspaceId: UUID? = nil,
        secondaryWorkspaceId: UUID? = nil,
        monitorId: Monitor.ID? = nil,
        mode: TrackedWindowMode? = nil,
        frame: CGRect? = nil,
        hiddenState: WindowModel.HiddenState? = nil,
        replacementReason: ReplacementCorrelation.Reason? = nil,
        restoreToFloating: Bool = false,
        isActive: Bool = false,
        appFullscreen: Bool = false,
        preserveFocusedToken: Bool = false
    ) -> omniwm_reconcile_event {
        omniwm_reconcile_event(
            kind: kind,
            token: token.map(encode(token:)) ?? zeroToken(),
            secondary_token: secondaryToken.map(encode(token:)) ?? zeroToken(),
            workspace_id: workspaceId.map(encode(uuid:)) ?? zeroUUID(),
            secondary_workspace_id: secondaryWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            monitor_id: monitorId?.displayId ?? 0,
            mode: mode?.reconcileRawValue ?? 0,
            frame: frame.map(encode(rect:)) ?? zeroRect(),
            hidden_state: encode(hiddenState: hiddenState),
            replacement_reason: replacementReason?.reconcileRawValue ?? 0,
            has_secondary_token: secondaryToken == nil ? 0 : 1,
            has_workspace_id: workspaceId == nil ? 0 : 1,
            has_secondary_workspace_id: secondaryWorkspaceId == nil ? 0 : 1,
            has_monitor_id: monitorId == nil ? 0 : 1,
            has_mode: mode == nil ? 0 : 1,
            has_frame: frame == nil ? 0 : 1,
            restore_to_floating: restoreToFloating ? 1 : 0,
            is_active: isActive ? 1 : 0,
            app_fullscreen: appFullscreen ? 1 : 0,
            preserve_focused_token: preserveFocusedToken ? 1 : 0,
            has_focus_lease: 0
        )
    }

    private static func encode(monitor: Monitor) -> omniwm_reconcile_monitor {
        omniwm_reconcile_monitor(
            display_id: monitor.displayId,
            visible_frame: encode(rect: monitor.visibleFrame)
        )
    }

    private static func withMonitorBuffer<Result>(
        monitors: [Monitor],
        _ body: (UnsafeBufferPointer<omniwm_reconcile_monitor>) -> Result
    ) -> Result {
        let rawMonitors = ContiguousArray(monitors.map(encode(monitor:)))
        return rawMonitors.withUnsafeBufferPointer(body)
    }

    private static func withOptionalPointer<Value, Result>(
        _ value: Value?,
        _ body: (UnsafePointer<Value>?) -> Result
    ) -> Result {
        guard var value else {
            return body(nil)
        }
        return withUnsafePointer(to: &value, body)
    }
}
