// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Foundation
import Testing

private func makeWorkspaceNavigationUUID(high: UInt64, low: UInt64) -> omniwm_uuid {
    omniwm_uuid(high: high, low: low)
}

private func makeWorkspaceNavigationToken(
    pid: Int32,
    windowId: Int64
) -> omniwm_window_token {
    omniwm_window_token(pid: pid, window_id: windowId)
}

private func makeWorkspaceNavigationInput(
    operation: UInt32,
    direction: UInt32 = UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
    currentWorkspace: omniwm_uuid? = nil,
    sourceWorkspace: omniwm_uuid? = nil,
    targetWorkspace: omniwm_uuid? = nil,
    adjacentFallbackWorkspaceNumber: UInt32? = nil,
    currentMonitorId: UInt32? = nil,
    previousMonitorId: UInt32? = nil,
    subject: omniwm_window_token? = nil,
    focused: omniwm_window_token? = nil,
    pendingManagedTiled: (token: omniwm_window_token, workspace: omniwm_uuid)? = nil,
    confirmedTiled: (token: omniwm_window_token, workspace: omniwm_uuid)? = nil,
    confirmedFloating: (token: omniwm_window_token, workspace: omniwm_uuid)? = nil,
    activeColumnSubject: omniwm_window_token? = nil,
    selectedColumnSubject: omniwm_window_token? = nil,
    isNonManagedFocusActive: Bool = false,
    isAppFullscreenActive: Bool = false,
    wrapAround: Bool = false,
    followFocus: Bool = false
) -> omniwm_workspace_navigation_input {
    omniwm_workspace_navigation_input(
        operation: operation,
        direction: direction,
        current_workspace_id: currentWorkspace ?? omniwm_uuid(),
        source_workspace_id: sourceWorkspace ?? omniwm_uuid(),
        target_workspace_id: targetWorkspace ?? omniwm_uuid(),
        adjacent_fallback_workspace_number: adjacentFallbackWorkspaceNumber ?? 0,
        current_monitor_id: currentMonitorId ?? 0,
        previous_monitor_id: previousMonitorId ?? 0,
        subject_token: subject ?? omniwm_window_token(),
        focused_token: focused ?? omniwm_window_token(),
        pending_managed_tiled_focus_token: pendingManagedTiled?.token ?? omniwm_window_token(),
        pending_managed_tiled_focus_workspace_id: pendingManagedTiled?.workspace ?? omniwm_uuid(),
        confirmed_tiled_focus_token: confirmedTiled?.token ?? omniwm_window_token(),
        confirmed_tiled_focus_workspace_id: confirmedTiled?.workspace ?? omniwm_uuid(),
        confirmed_floating_focus_token: confirmedFloating?.token ?? omniwm_window_token(),
        confirmed_floating_focus_workspace_id: confirmedFloating?.workspace ?? omniwm_uuid(),
        active_column_subject_token: activeColumnSubject ?? omniwm_window_token(),
        selected_column_subject_token: selectedColumnSubject ?? omniwm_window_token(),
        has_current_workspace_id: currentWorkspace == nil ? 0 : 1,
        has_source_workspace_id: sourceWorkspace == nil ? 0 : 1,
        has_target_workspace_id: targetWorkspace == nil ? 0 : 1,
        has_adjacent_fallback_workspace_number: adjacentFallbackWorkspaceNumber == nil ? 0 : 1,
        has_current_monitor_id: currentMonitorId == nil ? 0 : 1,
        has_previous_monitor_id: previousMonitorId == nil ? 0 : 1,
        has_subject_token: subject == nil ? 0 : 1,
        has_focused_token: focused == nil ? 0 : 1,
        has_pending_managed_tiled_focus_token: pendingManagedTiled == nil ? 0 : 1,
        has_pending_managed_tiled_focus_workspace_id: pendingManagedTiled == nil ? 0 : 1,
        has_confirmed_tiled_focus_token: confirmedTiled == nil ? 0 : 1,
        has_confirmed_tiled_focus_workspace_id: confirmedTiled == nil ? 0 : 1,
        has_confirmed_floating_focus_token: confirmedFloating == nil ? 0 : 1,
        has_confirmed_floating_focus_workspace_id: confirmedFloating == nil ? 0 : 1,
        has_active_column_subject_token: activeColumnSubject == nil ? 0 : 1,
        has_selected_column_subject_token: selectedColumnSubject == nil ? 0 : 1,
        is_non_managed_focus_active: isNonManagedFocusActive ? 1 : 0,
        is_app_fullscreen_active: isAppFullscreenActive ? 1 : 0,
        wrap_around: wrapAround ? 1 : 0,
        follow_focus: followFocus ? 1 : 0
    )
}

private func makeWorkspaceNavigationMonitor(
    id: UInt32,
    minX: Double,
    maxY: Double,
    centerX: Double,
    centerY: Double,
    activeWorkspace: omniwm_uuid? = nil,
    previousWorkspace: omniwm_uuid? = nil
) -> omniwm_workspace_navigation_monitor {
    omniwm_workspace_navigation_monitor(
        monitor_id: id,
        frame_min_x: minX,
        frame_max_y: maxY,
        center_x: centerX,
        center_y: centerY,
        active_workspace_id: activeWorkspace ?? omniwm_uuid(),
        previous_workspace_id: previousWorkspace ?? omniwm_uuid(),
        has_active_workspace_id: activeWorkspace == nil ? 0 : 1,
        has_previous_workspace_id: previousWorkspace == nil ? 0 : 1
    )
}

private func makeWorkspaceNavigationWorkspace(
    id: omniwm_uuid,
    monitorId: UInt32,
    layoutKind: UInt32 = UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_NIRI),
    hasMonitor: Bool = true,
    rememberedTiled: omniwm_window_token? = nil,
    firstTiled: omniwm_window_token? = nil,
    rememberedFloating: omniwm_window_token? = nil,
    firstFloating: omniwm_window_token? = nil
) -> omniwm_workspace_navigation_workspace {
    omniwm_workspace_navigation_workspace(
        workspace_id: id,
        monitor_id: monitorId,
        layout_kind: layoutKind,
        remembered_tiled_focus_token: rememberedTiled ?? omniwm_window_token(),
        first_tiled_focus_token: firstTiled ?? omniwm_window_token(),
        remembered_floating_focus_token: rememberedFloating ?? omniwm_window_token(),
        first_floating_focus_token: firstFloating ?? omniwm_window_token(),
        has_monitor_id: hasMonitor ? 1 : 0,
        has_remembered_tiled_focus_token: rememberedTiled == nil ? 0 : 1,
        has_first_tiled_focus_token: firstTiled == nil ? 0 : 1,
        has_remembered_floating_focus_token: rememberedFloating == nil ? 0 : 1,
        has_first_floating_focus_token: firstFloating == nil ? 0 : 1
    )
}

private func withWorkspaceNavigationOutput<Result>(
    saveCapacity: Int = 4,
    affectedWorkspaceCapacity: Int = 4,
    affectedMonitorCapacity: Int = 4,
    _ body: (
        inout omniwm_workspace_navigation_output,
        UnsafeMutableBufferPointer<omniwm_uuid>,
        UnsafeMutableBufferPointer<omniwm_uuid>,
        UnsafeMutableBufferPointer<UInt32>
    ) -> Result
) -> Result {
    var saveWorkspaceIds = Array(repeating: omniwm_uuid(), count: saveCapacity)
    var affectedWorkspaceIds = Array(repeating: omniwm_uuid(), count: affectedWorkspaceCapacity)
    var affectedMonitorIds = Array(repeating: UInt32.zero, count: affectedMonitorCapacity)

    return saveWorkspaceIds.withUnsafeMutableBufferPointer { saveBuffer in
        affectedWorkspaceIds.withUnsafeMutableBufferPointer { affectedWorkspaceBuffer in
            affectedMonitorIds.withUnsafeMutableBufferPointer { affectedMonitorBuffer in
                var output = omniwm_workspace_navigation_output(
                    outcome: 0,
                    subject_kind: 0,
                    focus_action: 0,
                    source_workspace_id: omniwm_uuid(),
                    target_workspace_id: omniwm_uuid(),
                    target_workspace_materialization_number: 0,
                    source_monitor_id: 0,
                    target_monitor_id: 0,
                    subject_token: omniwm_window_token(),
                    resolved_focus_token: omniwm_window_token(),
                    save_workspace_ids: saveBuffer.baseAddress,
                    save_workspace_capacity: saveBuffer.count,
                    save_workspace_count: 0,
                    affected_workspace_ids: affectedWorkspaceBuffer.baseAddress,
                    affected_workspace_capacity: affectedWorkspaceBuffer.count,
                    affected_workspace_count: 0,
                    affected_monitor_ids: affectedMonitorBuffer.baseAddress,
                    affected_monitor_capacity: affectedMonitorBuffer.count,
                    affected_monitor_count: 0,
                    has_source_workspace_id: 0,
                    has_target_workspace_id: 0,
                    has_source_monitor_id: 0,
                    has_target_monitor_id: 0,
                    has_subject_token: 0,
                    has_resolved_focus_token: 0,
                    should_materialize_target_workspace: 0,
                    should_activate_target_workspace: 0,
                    should_set_interaction_monitor: 0,
                    should_sync_monitors_to_niri: 0,
                    should_hide_focus_border: 0,
                    should_commit_workspace_transition: 0
                )
                return body(
                    &output,
                    saveBuffer,
                    affectedWorkspaceBuffer,
                    affectedMonitorBuffer
                )
            }
        }
    }
}

@Suite struct WorkspaceNavigationKernelABITests {
    @Test func nullPointersReturnInvalidArgument() {
        var input = omniwm_workspace_navigation_input()
        var output = omniwm_workspace_navigation_output()

        #expect(
            omniwm_workspace_navigation_plan(nil, nil, 0, nil, 0, &output)
                == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_workspace_navigation_plan(&input, nil, 0, nil, 0, nil)
                == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
    }

    @Test func nilNestedOutputBuffersWithCapacityReturnInvalidArgument() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 900, low: 900)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_EXPLICIT),
            currentWorkspace: workspaceOne,
            targetWorkspace: workspaceOne
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 1,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 1)
        ]
        var output = omniwm_workspace_navigation_output(
            outcome: 0,
            subject_kind: 0,
            focus_action: 0,
            source_workspace_id: omniwm_uuid(),
            target_workspace_id: omniwm_uuid(),
            target_workspace_materialization_number: 0,
            source_monitor_id: 0,
            target_monitor_id: 0,
            subject_token: omniwm_window_token(),
            resolved_focus_token: omniwm_window_token(),
            save_workspace_ids: nil,
            save_workspace_capacity: 1,
            save_workspace_count: 0,
            affected_workspace_ids: nil,
            affected_workspace_capacity: 1,
            affected_workspace_count: 0,
            affected_monitor_ids: nil,
            affected_monitor_capacity: 1,
            affected_monitor_count: 0,
            has_source_workspace_id: 0,
            has_target_workspace_id: 0,
            has_source_monitor_id: 0,
            has_target_monitor_id: 0,
            has_subject_token: 0,
            has_resolved_focus_token: 0,
            should_materialize_target_workspace: 0,
            should_activate_target_workspace: 0,
            should_set_interaction_monitor: 0,
            should_sync_monitors_to_niri: 0,
            should_hide_focus_border: 0,
            should_commit_workspace_transition: 0
        )

        let status = monitors.withUnsafeBufferPointer { monitorBuffer in
            workspaces.withUnsafeBufferPointer { workspaceBuffer in
                omniwm_workspace_navigation_plan(
                    &input,
                    monitorBuffer.baseAddress,
                    monitorBuffer.count,
                    workspaceBuffer.baseAddress,
                    workspaceBuffer.count,
                    &output
                )
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)
    }

    @Test func explicitSwitchPlansWorkspaceHandoffAndSaveDirective() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 1, low: 1)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 2, low: 2)
        let targetToken = makeWorkspaceNavigationToken(pid: 42, windowId: 4201)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_EXPLICIT),
            currentWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 100,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 100),
            makeWorkspaceNavigationWorkspace(
                id: workspaceTwo,
                monitorId: 100,
                rememberedTiled: targetToken
            )
        ]

        withWorkspaceNavigationOutput { output, saveBuffer, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_WORKSPACE_HANDOFF))
            #expect(output.should_hide_focus_border == 1)
            #expect(output.should_activate_target_workspace == 1)
            #expect(output.should_commit_workspace_transition == 1)
            #expect(output.save_workspace_count == 1)
            #expect(output.has_resolved_focus_token == 1)
            #expect(output.resolved_focus_token.pid == targetToken.pid)
            #expect(output.resolved_focus_token.window_id == targetToken.window_id)
            #expect(saveBuffer[0].high == workspaceOne.high)
            #expect(saveBuffer[0].low == workspaceOne.low)
            #expect(output.target_workspace_id.high == workspaceTwo.high)
            #expect(output.target_workspace_id.low == workspaceTwo.low)
            #expect(output.target_monitor_id == 100)
        }
    }

    @Test func explicitSwitchToActiveWorkspaceNoopsWithoutHidingBorder() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 905, low: 905)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_EXPLICIT),
            currentWorkspace: workspaceOne,
            targetWorkspace: workspaceOne
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 101,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 101)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_NOOP))
            #expect(output.should_hide_focus_border == 0)
            #expect(output.should_commit_workspace_transition == 0)
        }
    }

    @Test func adjacentWindowMovePlansSourceRecoveryAndAffectedSets() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 11, low: 11)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 22, low: 22)
        let token = makeWorkspaceNavigationToken(pid: 77, windowId: 9901)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_ADJACENT),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN),
            currentWorkspace: workspaceOne,
            sourceWorkspace: workspaceOne,
            currentMonitorId: 500,
            focused: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 500,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 500),
            makeWorkspaceNavigationWorkspace(
                id: workspaceTwo,
                monitorId: 500,
                layoutKind: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_DWINDLE)
            )
        ]

        withWorkspaceNavigationOutput { output, saveBuffer, affectedWorkspaceBuffer, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.subject_kind == UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_WINDOW))
            #expect(output.has_subject_token == 1)
            #expect(output.subject_token.pid == token.pid)
            #expect(output.subject_token.window_id == token.window_id)
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_RECOVER_SOURCE))
            #expect(output.save_workspace_count == 1)
            #expect(output.affected_workspace_count == 2)
            #expect(output.affected_monitor_count == 1)
            #expect(saveBuffer[0].high == workspaceOne.high)
            #expect(affectedWorkspaceBuffer[0].high == workspaceTwo.high || affectedWorkspaceBuffer[1].high == workspaceTwo.high)
            #expect(affectedMonitorBuffer[0] == 500)
        }
    }

    @Test func adjacentWindowMoveCanRequestNumberedWorkspaceMaterialization() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 111, low: 111)
        let token = makeWorkspaceNavigationToken(pid: 177, windowId: 19_901)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_ADJACENT),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN),
            currentWorkspace: workspaceOne,
            sourceWorkspace: workspaceOne,
            adjacentFallbackWorkspaceNumber: 2,
            currentMonitorId: 510,
            focused: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 510,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 510)
        ]

        withWorkspaceNavigationOutput { output, _, affectedWorkspaceBuffer, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.should_materialize_target_workspace == 1)
            #expect(output.target_workspace_materialization_number == 2)
            #expect(output.has_target_workspace_id == 0)
            #expect(output.has_target_monitor_id == 1)
            #expect(output.target_monitor_id == 510)
            #expect(output.affected_workspace_count == 1)
            #expect(affectedWorkspaceBuffer[0].high == workspaceOne.high)
            #expect(output.affected_monitor_count == 1)
            #expect(affectedMonitorBuffer[0] == 510)
        }
    }

    @Test func adjacentColumnMoveCanRequestNumberedWorkspaceMaterialization() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 121, low: 121)
        let token = makeWorkspaceNavigationToken(pid: 188, windowId: 20_901)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_ADJACENT),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN),
            currentWorkspace: workspaceOne,
            sourceWorkspace: workspaceOne,
            adjacentFallbackWorkspaceNumber: 2,
            currentMonitorId: 520,
            activeColumnSubject: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 520,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 520)
        ]

        withWorkspaceNavigationOutput { output, _, _, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.subject_kind == UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_COLUMN))
            #expect(output.should_materialize_target_workspace == 1)
            #expect(output.target_workspace_materialization_number == 2)
            #expect(output.has_target_workspace_id == 0)
            #expect(output.has_target_monitor_id == 1)
            #expect(output.target_monitor_id == 520)
            #expect(output.affected_monitor_count == 1)
            #expect(affectedMonitorBuffer[0] == 520)
        }
    }

    @Test func adjacentWindowMoveWithoutNeighborOrFallbackStaysNoop() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 131, low: 131)
        let token = makeWorkspaceNavigationToken(pid: 199, windowId: 21_901)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_ADJACENT),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN),
            currentWorkspace: workspaceOne,
            sourceWorkspace: workspaceOne,
            currentMonitorId: 530,
            focused: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 530,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 530)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_NOOP))
            #expect(output.should_materialize_target_workspace == 0)
            #expect(output.has_target_workspace_id == 0)
        }
    }

    @Test func relativeWorkspaceBoundaryIsPureNoop() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 41, low: 41)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_RELATIVE),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
            currentWorkspace: workspaceOne,
            currentMonitorId: 900,
            wrapAround: false
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 900,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 900)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_NOOP))
            #expect(output.should_hide_focus_border == 0)
            #expect(output.should_activate_target_workspace == 0)
        }
    }

    @Test func explicitWindowMoveDoesNotSaveSourceWorkspaceState() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 51, low: 51)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 52, low: 52)
        let token = makeWorkspaceNavigationToken(pid: 91, windowId: 5001)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT),
            sourceWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo,
            focused: token,
            followFocus: false
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 910,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 911,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 910),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 911)
        ]

        withWorkspaceNavigationOutput { output, _, affectedWorkspaceBuffer, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.save_workspace_count == 0)
            #expect(output.affected_workspace_count == 2)
            #expect(
                affectedWorkspaceBuffer[0].high == workspaceOne.high
                    || affectedWorkspaceBuffer[1].high == workspaceOne.high
            )
        }
    }

    @Test func swapPlansClosestDirectionalMonitorWorkspace() {
        let workspaceCenter = makeWorkspaceNavigationUUID(high: 61, low: 61)
        let workspaceNear = makeWorkspaceNavigationUUID(high: 62, low: 62)
        let workspaceFar = makeWorkspaceNavigationUUID(high: 63, low: 63)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWAP_WORKSPACE_WITH_MONITOR),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
            currentWorkspace: workspaceCenter,
            currentMonitorId: 920
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 920,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceCenter
            ),
            makeWorkspaceNavigationMonitor(
                id: 921,
                minX: 1100,
                maxY: 1430,
                centerX: 2060,
                centerY: 890,
                activeWorkspace: workspaceNear
            ),
            makeWorkspaceNavigationMonitor(
                id: 922,
                minX: 1800,
                maxY: 1080,
                centerX: 2760,
                centerY: 540,
                activeWorkspace: workspaceFar
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceCenter, monitorId: 920),
            makeWorkspaceNavigationWorkspace(id: workspaceNear, monitorId: 921),
            makeWorkspaceNavigationWorkspace(id: workspaceFar, monitorId: 922)
        ]

        withWorkspaceNavigationOutput { output, _, affectedWorkspaceBuffer, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.target_monitor_id == 921)
            #expect(output.target_workspace_id.high == workspaceNear.high)
            #expect(output.affected_workspace_count == 2)
            #expect(output.affected_monitor_count == 2)
            #expect(
                affectedWorkspaceBuffer[0].high == workspaceNear.high
                    || affectedWorkspaceBuffer[1].high == workspaceNear.high
            )
            #expect(Set(affectedMonitorBuffer.prefix(2)) == Set([920, 921]))
        }
    }

    @Test func focusLastMonitorToEmptyWorkspacePlansClearManagedFocus() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 601, low: 601)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 602, low: 602)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_MONITOR_LAST),
            currentMonitorId: 10,
            previousMonitorId: 20
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 10),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 20)
        ]

        withWorkspaceNavigationOutput { output, _, affectedWorkspaceBuffer, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_CLEAR_MANAGED_FOCUS))
            #expect(output.has_resolved_focus_token == 0)
            #expect(output.target_monitor_id == 20)
            #expect(output.target_workspace_id.high == workspaceTwo.high)
            #expect(output.affected_workspace_count == 1)
            #expect(affectedWorkspaceBuffer[0].high == workspaceTwo.high)
            #expect(output.affected_monitor_count == 1)
            #expect(affectedMonitorBuffer[0] == 20)
        }
    }

    @Test func swapToEmptyTargetPlansClearManagedFocus() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 611, low: 611)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 612, low: 612)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWAP_WORKSPACE_WITH_MONITOR),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
            currentWorkspace: workspaceOne,
            currentMonitorId: 11
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 11,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 12,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 11),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 12)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_CLEAR_MANAGED_FOCUS))
            #expect(output.has_resolved_focus_token == 0)
            #expect(output.target_workspace_id.high == workspaceTwo.high)
        }
    }

    @Test func callerAllocatedOutputBuffersReportWhenTooSmall() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 31, low: 31)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 32, low: 32)
        let token = makeWorkspaceNavigationToken(pid: 88, windowId: 4401)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT),
            sourceWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo,
            focused: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 700,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 701,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 700),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 701)
        ]

        withWorkspaceNavigationOutput(saveCapacity: 1, affectedWorkspaceCapacity: 1, affectedMonitorCapacity: 1) {
            output,
            _,
            _,
            _
            in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL)
            #expect(output.save_workspace_count == 0)
            #expect(output.affected_workspace_count == 2)
            #expect(output.affected_monitor_count == 2)
        }
    }

    @Test func explicitColumnMovePrefersActiveColumnSubjectOverSelectionFallback() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 801, low: 801)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 802, low: 802)
        let activeColumnToken = makeWorkspaceNavigationToken(pid: 300, windowId: 30_001)
        let selectedColumnToken = makeWorkspaceNavigationToken(pid: 301, windowId: 30_002)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_EXPLICIT),
            sourceWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo,
            activeColumnSubject: activeColumnToken,
            selectedColumnSubject: selectedColumnToken
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 130,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 130),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 130)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.subject_kind == UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_COLUMN))
            #expect(output.subject_token.pid == activeColumnToken.pid)
            #expect(output.subject_token.window_id == activeColumnToken.window_id)
        }
    }

    @Test func focusWorkspaceAnywhereSavesCurrentAndVisibleTargetWorkspace() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 71, low: 71)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 72, low: 72)
        let workspaceThree = makeWorkspaceNavigationUUID(high: 73, low: 73)
        let targetToken = makeWorkspaceNavigationToken(pid: 73, windowId: 7301)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_WORKSPACE_ANYWHERE),
            currentWorkspace: workspaceOne,
            targetWorkspace: workspaceThree,
            currentMonitorId: 1000
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 1000,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 1001,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 1000),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 1001),
            makeWorkspaceNavigationWorkspace(
                id: workspaceThree,
                monitorId: 1001,
                rememberedTiled: targetToken
            )
        ]

        withWorkspaceNavigationOutput { output, saveBuffer, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_WORKSPACE_HANDOFF))
            #expect(output.has_resolved_focus_token == 1)
            #expect(output.resolved_focus_token.pid == targetToken.pid)
            #expect(output.resolved_focus_token.window_id == targetToken.window_id)
            #expect(output.should_sync_monitors_to_niri == 1)
            #expect(output.save_workspace_count == 2)
            #expect(
                (saveBuffer[0].high == workspaceOne.high && saveBuffer[1].high == workspaceTwo.high)
                    || (saveBuffer[0].high == workspaceTwo.high && saveBuffer[1].high == workspaceOne.high)
            )
        }
    }

    @Test func explicitWindowMoveFollowFocusRequestsSubjectFocusAndActivation() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 81, low: 81)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 82, low: 82)
        let token = makeWorkspaceNavigationToken(pid: 201, windowId: 8801)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT),
            sourceWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo,
            focused: token,
            followFocus: true
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 1100,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            ),
            makeWorkspaceNavigationMonitor(
                id: 1101,
                minX: 1920,
                maxY: 1080,
                centerX: 2880,
                centerY: 540,
                activeWorkspace: workspaceTwo
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 1100),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 1101)
        ]

        withWorkspaceNavigationOutput { output, _, _, affectedMonitorBuffer in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE))
            #expect(output.subject_kind == UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_WINDOW))
            #expect(output.focus_action == UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_SUBJECT))
            #expect(output.should_activate_target_workspace == 1)
            #expect(output.should_set_interaction_monitor == 1)
            #expect(output.should_commit_workspace_transition == 1)
            #expect(output.affected_monitor_count == 2)
            #expect(Set(affectedMonitorBuffer.prefix(2)) == Set([1100, 1101]))
        }
    }

    @Test func explicitColumnMoveWithoutSelectionIsBlocked() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 91, low: 91)
        let workspaceTwo = makeWorkspaceNavigationUUID(high: 92, low: 92)
        let token = makeWorkspaceNavigationToken(pid: 202, windowId: 9901)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_EXPLICIT),
            sourceWorkspace: workspaceOne,
            targetWorkspace: workspaceTwo,
            focused: token
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 1200,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 1200),
            makeWorkspaceNavigationWorkspace(id: workspaceTwo, monitorId: 1200)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_BLOCKED))
            #expect(output.has_subject_token == 0)
        }
    }

    @Test func workspaceBackAndForthNoopsWhenPreviousMatchesActive() {
        let workspaceOne = makeWorkspaceNavigationUUID(high: 101, low: 101)
        var input = makeWorkspaceNavigationInput(
            operation: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_WORKSPACE_BACK_AND_FORTH),
            currentWorkspace: workspaceOne,
            currentMonitorId: 1300
        )
        let monitors = [
            makeWorkspaceNavigationMonitor(
                id: 1300,
                minX: 0,
                maxY: 1080,
                centerX: 960,
                centerY: 540,
                activeWorkspace: workspaceOne,
                previousWorkspace: workspaceOne
            )
        ]
        let workspaces = [
            makeWorkspaceNavigationWorkspace(id: workspaceOne, monitorId: 1300)
        ]

        withWorkspaceNavigationOutput { output, _, _, _ in
            let status = monitors.withUnsafeBufferPointer { monitorBuffer in
                workspaces.withUnsafeBufferPointer { workspaceBuffer in
                    omniwm_workspace_navigation_plan(
                        &input,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        &output
                    )
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_NOOP))
            #expect(output.should_hide_focus_border == 0)
            #expect(output.save_workspace_count == 0)
        }
    }
}
