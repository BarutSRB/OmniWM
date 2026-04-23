// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Foundation
import Testing

private func makeReconcileKernelUUID(high: UInt64, low: UInt64) -> omniwm_uuid {
    omniwm_uuid(high: high, low: low)
}

private func makeReconcileKernelToken(pid: Int32, windowId: Int64) -> omniwm_window_token {
    omniwm_window_token(pid: pid, window_id: windowId)
}

private func makeReconcileKernelRect(
    x: Double = 0,
    y: Double = 0,
    width: Double = 0,
    height: Double = 0
) -> omniwm_rect {
    omniwm_rect(x: x, y: y, width: width, height: height)
}

private func makeReconcileKernelObservedState(
    workspace: omniwm_uuid,
    monitorId: UInt32
) -> omniwm_reconcile_observed_state {
    omniwm_reconcile_observed_state(
        frame: makeReconcileKernelRect(),
        workspace_id: workspace,
        monitor_id: monitorId,
        has_frame: 0,
        has_workspace_id: 1,
        has_monitor_id: 1,
        is_visible: 1,
        is_focused: 0,
        has_ax_reference: 1,
        is_native_fullscreen: 0
    )
}

private func makeReconcileKernelDesiredState(
    workspace: omniwm_uuid,
    monitorId: UInt32,
    mode: UInt32
) -> omniwm_reconcile_desired_state {
    omniwm_reconcile_desired_state(
        workspace_id: workspace,
        monitor_id: monitorId,
        disposition: mode,
        floating_frame: makeReconcileKernelRect(),
        has_workspace_id: 1,
        has_monitor_id: 1,
        has_disposition: 1,
        has_floating_frame: 0,
        rescue_eligible: 0
    )
}

private func makeReconcileKernelEntry(
    workspace: omniwm_uuid,
    mode: UInt32,
    observedMonitorId: UInt32,
    desiredMonitorId: UInt32
) -> omniwm_reconcile_entry {
    omniwm_reconcile_entry(
        workspace_id: workspace,
        mode: mode,
        observed_state: makeReconcileKernelObservedState(
            workspace: workspace,
            monitorId: observedMonitorId
        ),
        desired_state: makeReconcileKernelDesiredState(
            workspace: workspace,
            monitorId: desiredMonitorId,
            mode: mode
        ),
        floating_state: omniwm_reconcile_floating_state(
            last_frame: makeReconcileKernelRect(x: 20, y: 30, width: 320, height: 200),
            normalized_origin: omniwm_point(x: 0.2, y: 0.3),
            reference_monitor_id: desiredMonitorId,
            has_normalized_origin: 1,
            has_reference_monitor_id: 1,
            restore_to_floating: 1
        ),
        has_floating_state: mode == UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING) ? 1 : 0
    )
}

private func makeReconcileKernelFocusSession(
    focused: omniwm_window_token? = nil,
    pending: omniwm_window_token? = nil,
    workspace: omniwm_uuid? = nil,
    monitorId: UInt32? = nil
) -> omniwm_reconcile_focus_session {
    omniwm_reconcile_focus_session(
        focused_token: focused ?? makeReconcileKernelToken(pid: 0, windowId: 0),
        pending_managed_focus: omniwm_reconcile_pending_focus(
            token: pending ?? makeReconcileKernelToken(pid: 0, windowId: 0),
            workspace_id: workspace ?? makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: monitorId ?? 0,
            has_token: pending == nil ? 0 : 1,
            has_workspace_id: workspace == nil ? 0 : 1,
            has_monitor_id: monitorId == nil ? 0 : 1
        ),
        has_focused_token: focused == nil ? 0 : 1,
        is_non_managed_focus_active: 0,
        is_app_fullscreen_active: 0
    )
}

private func makeReconcileKernelMonitor(
    displayId: UInt32,
    visibleX: Double = 0
) -> omniwm_reconcile_monitor {
    omniwm_reconcile_monitor(
        display_id: displayId,
        visible_frame: makeReconcileKernelRect(x: visibleX, y: 0, width: 1440, height: 900)
    )
}

@Suite struct ReconcileKernelABITests {
    @Test func nullPointersReturnInvalidArgument() {
        #expect(
            omniwm_reconcile_plan(
                nil,
                nil,
                nil,
                nil,
                0,
                nil,
                nil
            ) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_reconcile_restore_intent(
                nil,
                nil,
                0,
                nil
            ) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
    }

    @Test func admittedPlanSeedsStateWithoutExistingEntryOrMonitors() {
        let workspace = makeReconcileKernelUUID(high: 10, low: 11)
        var event = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_WINDOW_ADMITTED),
            token: makeReconcileKernelToken(pid: 7201, windowId: 7201),
            secondary_token: makeReconcileKernelToken(pid: 0, windowId: 0),
            workspace_id: workspace,
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 0,
            mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING),
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE),
            replacement_reason: 0,
            has_secondary_token: 0,
            has_workspace_id: 1,
            has_secondary_workspace_id: 0,
            has_monitor_id: 0,
            has_mode: 1,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 0
        )
        let focus = makeReconcileKernelFocusSession()
        var output = omniwm_reconcile_plan_output()

        let status = withUnsafePointer(to: &event) { eventPointer in
            withUnsafePointer(to: focus) { focusPointer in
                omniwm_reconcile_plan(
                    eventPointer,
                    nil,
                    focusPointer,
                    nil,
                    0,
                    nil,
                    &output
                )
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.has_lifecycle_phase == 1)
        #expect(output.lifecycle_phase == UInt32(OMNIWM_RECONCILE_LIFECYCLE_FLOATING))
        #expect(output.has_observed_state == 1)
        #expect(output.has_desired_state == 1)
        #expect(output.has_restore_intent == 0)
        #expect(output.observed_state.has_workspace_id == 1)
        #expect(output.observed_state.has_monitor_id == 0)
        #expect(output.desired_state.disposition == UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING))
        #expect(output.desired_state.rescue_eligible == 1)
    }

    @Test func hiddenAndFocusLeaseEventsReturnStableLifecycleAndLeaseActions() {
        let workspace = makeReconcileKernelUUID(high: 12, low: 13)
        var hiddenEvent = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_HIDDEN_STATE_CHANGED),
            token: makeReconcileKernelToken(pid: 7202, windowId: 7202),
            secondary_token: makeReconcileKernelToken(pid: 0, windowId: 0),
            workspace_id: workspace,
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 41,
            mode: 0,
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_RIGHT),
            replacement_reason: 0,
            has_secondary_token: 0,
            has_workspace_id: 1,
            has_secondary_workspace_id: 0,
            has_monitor_id: 1,
            has_mode: 0,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 0
        )
        var entry = makeReconcileKernelEntry(
            workspace: workspace,
            mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING),
            observedMonitorId: 41,
            desiredMonitorId: 41
        )
        let focus = makeReconcileKernelFocusSession()
        var hiddenOutput = omniwm_reconcile_plan_output()

        let hiddenStatus = withUnsafePointer(to: &hiddenEvent) { eventPointer in
            withUnsafePointer(to: &entry) { entryPointer in
                withUnsafePointer(to: focus) { focusPointer in
                    omniwm_reconcile_plan(
                        eventPointer,
                        entryPointer,
                        focusPointer,
                        nil,
                        0,
                        nil,
                        &hiddenOutput
                    )
                }
            }
        }

        #expect(hiddenStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(hiddenOutput.lifecycle_phase == UInt32(OMNIWM_RECONCILE_LIFECYCLE_OFFSCREEN))
        #expect(hiddenOutput.observed_state.is_visible == 0)
        #expect(hiddenOutput.note_code == UInt32(OMNIWM_RECONCILE_NOTE_NONE))

        var leaseEvent = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_FOCUS_LEASE_CHANGED),
            token: makeReconcileKernelToken(pid: 0, windowId: 0),
            secondary_token: makeReconcileKernelToken(pid: 0, windowId: 0),
            workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 0,
            mode: 0,
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE),
            replacement_reason: 0,
            has_secondary_token: 0,
            has_workspace_id: 0,
            has_secondary_workspace_id: 0,
            has_monitor_id: 0,
            has_mode: 0,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 0
        )
        var leaseOutput = omniwm_reconcile_plan_output()

        let leaseStatus = withUnsafePointer(to: &leaseEvent) { eventPointer in
            withUnsafePointer(to: focus) { focusPointer in
                omniwm_reconcile_plan(
                    eventPointer,
                    nil,
                    focusPointer,
                    nil,
                    0,
                    nil,
                    &leaseOutput
                )
            }
        }

        #expect(leaseStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(leaseOutput.has_focus_session == 1)
        #expect(
            leaseOutput.focus_session.focus_lease_action
                == UInt32(OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_CLEAR)
        )
        #expect(
            leaseOutput.note_code
                == UInt32(OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_CLEARED)
        )
    }

    @Test func rekeyPlanMigratesFocusedAndPendingTokens() {
        let workspace = makeReconcileKernelUUID(high: 1, low: 2)
        var event = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_WINDOW_REKEYED),
            token: makeReconcileKernelToken(pid: 7001, windowId: 7002),
            secondary_token: makeReconcileKernelToken(pid: 7001, windowId: 7001),
            workspace_id: workspace,
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 11,
            mode: 0,
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE),
            replacement_reason: UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_MANAGED_REPLACEMENT),
            has_secondary_token: 1,
            has_workspace_id: 1,
            has_secondary_workspace_id: 0,
            has_monitor_id: 1,
            has_mode: 0,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 0
        )
        var entry = makeReconcileKernelEntry(
            workspace: workspace,
            mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_TILING),
            observedMonitorId: 11,
            desiredMonitorId: 11
        )
        var focus = makeReconcileKernelFocusSession(
            focused: makeReconcileKernelToken(pid: 7001, windowId: 7001),
            pending: makeReconcileKernelToken(pid: 7001, windowId: 7001),
            workspace: workspace,
            monitorId: 11
        )
        var output = omniwm_reconcile_plan_output()

        let status = withUnsafePointer(to: &event) { eventPointer in
            withUnsafePointer(to: &entry) { entryPointer in
                withUnsafePointer(to: &focus) { focusPointer in
                    omniwm_reconcile_plan(
                        eventPointer,
                        entryPointer,
                        focusPointer,
                        nil,
                        0,
                        nil,
                        &output
                    )
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.has_focus_session == 1)
        #expect(output.focus_session.has_focused_token == 1)
        #expect(output.focus_session.focused_token.window_id == 7002)
        #expect(output.focus_session.pending_managed_focus.token.window_id == 7002)
        #expect(output.has_replacement_correlation == 1)
        #expect(output.replacement_correlation.reason == UInt32(OMNIWM_RECONCILE_REPLACEMENT_REASON_MANAGED_REPLACEMENT))
    }

    @Test func restoreIntentPrefersDesiredThenObservedThenFloatingReferenceMonitor() {
        let workspace = makeReconcileKernelUUID(high: 3, low: 4)
        let monitors = [
            makeReconcileKernelMonitor(displayId: 21),
            makeReconcileKernelMonitor(displayId: 22, visibleX: 1440),
            makeReconcileKernelMonitor(displayId: 23, visibleX: 2880),
        ]
        var entry = makeReconcileKernelEntry(
            workspace: workspace,
            mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING),
            observedMonitorId: 22,
            desiredMonitorId: 21
        )
        entry.floating_state.reference_monitor_id = 23
        var output = omniwm_reconcile_restore_intent_output()

        let desiredStatus = monitors.withUnsafeBufferPointer { monitorBuffer in
            withUnsafePointer(to: &entry) { entryPointer in
                omniwm_reconcile_restore_intent(
                    entryPointer,
                    monitorBuffer.baseAddress,
                    monitorBuffer.count,
                    &output
                )
            }
        }
        #expect(desiredStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.preferred_monitor_index == 0)

        entry.desired_state.has_monitor_id = 0
        let observedStatus = monitors.withUnsafeBufferPointer { monitorBuffer in
            withUnsafePointer(to: &entry) { entryPointer in
                omniwm_reconcile_restore_intent(
                    entryPointer,
                    monitorBuffer.baseAddress,
                    monitorBuffer.count,
                    &output
                )
            }
        }
        #expect(observedStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.preferred_monitor_index == 1)

        entry.observed_state.has_monitor_id = 0
        let floatingStatus = monitors.withUnsafeBufferPointer { monitorBuffer in
            withUnsafePointer(to: &entry) { entryPointer in
                omniwm_reconcile_restore_intent(
                    entryPointer,
                    monitorBuffer.baseAddress,
                    monitorBuffer.count,
                    &output
                )
            }
        }
        #expect(floatingStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.preferred_monitor_index == 2)
        #expect(output.has_normalized_floating_origin == 1)
        #expect(output.restore_to_floating == 1)
        #expect(output.rescue_eligible == 1)
    }

    @Test func hydrationUpdatesDesiredStateAndRestoreIntentInSinglePlanSolve() {
        let workspace = makeReconcileKernelUUID(high: 5, low: 6)
        var event = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_MANAGED_REPLACEMENT_METADATA_CHANGED),
            token: makeReconcileKernelToken(pid: 7101, windowId: 7101),
            secondary_token: makeReconcileKernelToken(pid: 0, windowId: 0),
            workspace_id: workspace,
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 31,
            mode: 0,
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE),
            replacement_reason: 0,
            has_secondary_token: 0,
            has_workspace_id: 1,
            has_secondary_workspace_id: 0,
            has_monitor_id: 1,
            has_mode: 0,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 0
        )
        var entry = makeReconcileKernelEntry(
            workspace: workspace,
            mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_TILING),
            observedMonitorId: 31,
            desiredMonitorId: 31
        )
        var focus = makeReconcileKernelFocusSession()
        var hydration = omniwm_reconcile_persisted_hydration(
            workspace_id: makeReconcileKernelUUID(high: 7, low: 8),
            monitor_id: 31,
            target_mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING),
            floating_frame: makeReconcileKernelRect(x: 140, y: 180, width: 540, height: 320),
            has_monitor_id: 1,
            has_floating_frame: 1
        )
        let monitors = [makeReconcileKernelMonitor(displayId: 31)]
        var output = omniwm_reconcile_plan_output()

        let status = monitors.withUnsafeBufferPointer { monitorBuffer in
            withUnsafePointer(to: &event) { eventPointer in
                withUnsafePointer(to: &entry) { entryPointer in
                    withUnsafePointer(to: &focus) { focusPointer in
                        withUnsafePointer(to: &hydration) { hydrationPointer in
                            omniwm_reconcile_plan(
                                eventPointer,
                                entryPointer,
                                focusPointer,
                                monitorBuffer.baseAddress,
                                monitorBuffer.count,
                                hydrationPointer,
                                &output
                            )
                        }
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.has_lifecycle_phase == 1)
        #expect(output.lifecycle_phase == UInt32(OMNIWM_RECONCILE_LIFECYCLE_FLOATING))
        #expect(output.has_desired_state == 1)
        #expect(output.desired_state.disposition == UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING))
        #expect(output.desired_state.has_floating_frame == 1)
        #expect(output.desired_state.rescue_eligible == 1)
        #expect(output.has_restore_intent == 1)
        #expect(output.restore_intent.preferred_monitor_index == 0)
        #expect(output.restore_intent.has_normalized_floating_origin == 1)
    }

    @Test func hiddenStateChangesMapVisibilityAndLifecycleAtTheABI() {
        let workspace = makeReconcileKernelUUID(high: 9, low: 10)
        var event = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_HIDDEN_STATE_CHANGED),
            token: makeReconcileKernelToken(pid: 7201, windowId: 7201),
            secondary_token: makeReconcileKernelToken(pid: 0, windowId: 0),
            workspace_id: workspace,
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 41,
            mode: 0,
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_HIDDEN),
            replacement_reason: 0,
            has_secondary_token: 0,
            has_workspace_id: 1,
            has_secondary_workspace_id: 0,
            has_monitor_id: 1,
            has_mode: 0,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 0
        )
        var entry = makeReconcileKernelEntry(
            workspace: workspace,
            mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING),
            observedMonitorId: 41,
            desiredMonitorId: 41
        )
        var focus = makeReconcileKernelFocusSession()
        var output = omniwm_reconcile_plan_output()

        func solve() -> Int32 {
            withUnsafePointer(to: &event) { eventPointer in
                withUnsafePointer(to: &entry) { entryPointer in
                    withUnsafePointer(to: &focus) { focusPointer in
                        omniwm_reconcile_plan(
                            eventPointer,
                            entryPointer,
                            focusPointer,
                            nil,
                            0,
                            nil,
                            &output
                        )
                    }
                }
            }
        }

        #expect(solve() == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.has_observed_state == 1)
        #expect(output.observed_state.is_visible == 0)
        #expect(output.lifecycle_phase == UInt32(OMNIWM_RECONCILE_LIFECYCLE_HIDDEN))

        event.hidden_state = UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_LEFT)
        #expect(solve() == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.observed_state.is_visible == 0)
        #expect(output.lifecycle_phase == UInt32(OMNIWM_RECONCILE_LIFECYCLE_OFFSCREEN))

        event.hidden_state = UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE)
        #expect(solve() == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.observed_state.is_visible == 1)
        #expect(output.lifecycle_phase == UInt32(OMNIWM_RECONCILE_LIFECYCLE_FLOATING))
    }

    @Test func focusLeaseAndManagedFocusCancellationExposeStableABIFlags() {
        let workspace = makeReconcileKernelUUID(high: 11, low: 12)
        let pendingToken = makeReconcileKernelToken(pid: 7301, windowId: 7302)
        var focus = makeReconcileKernelFocusSession(
            pending: pendingToken,
            workspace: workspace,
            monitorId: 55
        )
        var output = omniwm_reconcile_plan_output()

        var leaseEvent = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_FOCUS_LEASE_CHANGED),
            token: makeReconcileKernelToken(pid: 0, windowId: 0),
            secondary_token: makeReconcileKernelToken(pid: 0, windowId: 0),
            workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 0,
            mode: 0,
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE),
            replacement_reason: 0,
            has_secondary_token: 0,
            has_workspace_id: 0,
            has_secondary_workspace_id: 0,
            has_monitor_id: 0,
            has_mode: 0,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 1
        )

        let leaseSetStatus = withUnsafePointer(to: &leaseEvent) { eventPointer in
            withUnsafePointer(to: &focus) { focusPointer in
                omniwm_reconcile_plan(
                    eventPointer,
                    nil,
                    focusPointer,
                    nil,
                    0,
                    nil,
                    &output
                )
            }
        }
        #expect(leaseSetStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.has_focus_session == 1)
        #expect(output.focus_session.focus_lease_action == UInt32(OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_SET_FROM_EVENT))
        #expect(output.note_code == UInt32(OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_SET))

        leaseEvent.has_focus_lease = 0
        let leaseClearStatus = withUnsafePointer(to: &leaseEvent) { eventPointer in
            withUnsafePointer(to: &focus) { focusPointer in
                omniwm_reconcile_plan(
                    eventPointer,
                    nil,
                    focusPointer,
                    nil,
                    0,
                    nil,
                    &output
                )
            }
        }
        #expect(leaseClearStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.focus_session.focus_lease_action == UInt32(OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_CLEAR))
        #expect(output.note_code == UInt32(OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_CLEARED))

        var cancelEvent = omniwm_reconcile_event(
            kind: UInt32(OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_CANCELLED),
            token: makeReconcileKernelToken(pid: 0, windowId: 0),
            secondary_token: makeReconcileKernelToken(pid: 7301, windowId: 9999),
            workspace_id: workspace,
            secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
            monitor_id: 0,
            mode: 0,
            frame: makeReconcileKernelRect(),
            hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE),
            replacement_reason: 0,
            has_secondary_token: 1,
            has_workspace_id: 1,
            has_secondary_workspace_id: 0,
            has_monitor_id: 0,
            has_mode: 0,
            has_frame: 0,
            restore_to_floating: 0,
            is_active: 0,
            app_fullscreen: 0,
            preserve_focused_token: 0,
            has_focus_lease: 0
        )

        let mismatchStatus = withUnsafePointer(to: &cancelEvent) { eventPointer in
            withUnsafePointer(to: &focus) { focusPointer in
                omniwm_reconcile_plan(
                    eventPointer,
                    nil,
                    focusPointer,
                    nil,
                    0,
                    nil,
                    &output
                )
            }
        }
        #expect(mismatchStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.focus_session.pending_managed_focus.has_token == 1)

        cancelEvent.secondary_token = pendingToken
        let matchingStatus = withUnsafePointer(to: &cancelEvent) { eventPointer in
            withUnsafePointer(to: &focus) { focusPointer in
                omniwm_reconcile_plan(
                    eventPointer,
                    nil,
                    focusPointer,
                    nil,
                    0,
                    nil,
                    &output
                )
            }
        }
        #expect(matchingStatus == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.focus_session.pending_managed_focus.has_token == 0)
        #expect(output.focus_session.pending_managed_focus.has_workspace_id == 0)
    }

    @Test func noteOnlyKernelEventsReturnStableNoteCodes() {
        let focus = makeReconcileKernelFocusSession()

        func run(kind: UInt32) -> omniwm_reconcile_plan_output {
            var event = omniwm_reconcile_event(
                kind: kind,
                token: makeReconcileKernelToken(pid: 0, windowId: 0),
                secondary_token: makeReconcileKernelToken(pid: 0, windowId: 0),
                workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
                secondary_workspace_id: makeReconcileKernelUUID(high: 0, low: 0),
                monitor_id: 0,
                mode: 0,
                frame: makeReconcileKernelRect(),
                hidden_state: UInt32(OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE),
                replacement_reason: 0,
                has_secondary_token: 0,
                has_workspace_id: 0,
                has_secondary_workspace_id: 0,
                has_monitor_id: 0,
                has_mode: 0,
                has_frame: 0,
                restore_to_floating: 0,
                is_active: 0,
                app_fullscreen: 0,
                preserve_focused_token: 0,
                has_focus_lease: 0
            )
            var output = omniwm_reconcile_plan_output()
            let status = withUnsafePointer(to: &event) { eventPointer in
                withUnsafePointer(to: focus) { focusPointer in
                    omniwm_reconcile_plan(
                        eventPointer,
                        nil,
                        focusPointer,
                        nil,
                        0,
                        nil,
                        &output
                    )
                }
            }
            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            return output
        }

        #expect(
            run(kind: UInt32(OMNIWM_RECONCILE_EVENT_TOPOLOGY_CHANGED)).note_code
                == UInt32(OMNIWM_RECONCILE_NOTE_TOPOLOGY_CHANGED)
        )
        #expect(
            run(kind: UInt32(OMNIWM_RECONCILE_EVENT_ACTIVE_SPACE_CHANGED)).note_code
                == UInt32(OMNIWM_RECONCILE_NOTE_ACTIVE_SPACE_CHANGED)
        )
        #expect(
            run(kind: UInt32(OMNIWM_RECONCILE_EVENT_SYSTEM_SLEEP)).note_code
                == UInt32(OMNIWM_RECONCILE_NOTE_SYSTEM_SLEEP)
        )
        #expect(
            run(kind: UInt32(OMNIWM_RECONCILE_EVENT_SYSTEM_WAKE)).note_code
                == UInt32(OMNIWM_RECONCILE_NOTE_SYSTEM_WAKE)
        )
    }
}
