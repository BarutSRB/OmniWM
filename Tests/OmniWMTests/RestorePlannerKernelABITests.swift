// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Foundation
import Testing

private func makeRestoreKernelUUID(high: UInt64, low: UInt64) -> omniwm_uuid {
    omniwm_uuid(high: high, low: low)
}

private func restoreKernelUUIDEqual(_ lhs: omniwm_uuid, _ rhs: omniwm_uuid) -> Bool {
    lhs.high == rhs.high && lhs.low == rhs.low
}

private func makeRestoreKernelRect(
    x: Double = 0,
    y: Double = 0,
    width: Double = 0,
    height: Double = 0
) -> omniwm_rect {
    omniwm_rect(x: x, y: y, width: width, height: height)
}

private func makeRestoreKernelPoint(x: Double = 0, y: Double = 0) -> omniwm_point {
    omniwm_point(x: x, y: y)
}

private struct RestorePlannerKernelStringTable {
    var bytes: [UInt8] = []

    mutating func append(_ string: String?) -> (ref: omniwm_restore_string_ref, hasValue: UInt8) {
        guard let string, !string.isEmpty else {
            return (omniwm_restore_string_ref(offset: 0, length: 0), 0)
        }

        let utf8 = Array(string.utf8)
        let offset = bytes.count
        bytes.append(contentsOf: utf8)
        return (omniwm_restore_string_ref(offset: offset, length: utf8.count), 1)
    }
}

private func makeRestoreKernelMonitorKey(
    displayId: UInt32,
    name: String,
    anchorX: Double,
    anchorY: Double,
    width: Double,
    height: Double,
    strings: inout RestorePlannerKernelStringTable
) -> omniwm_restore_monitor_key {
    let nameRef = strings.append(name)
    return omniwm_restore_monitor_key(
        display_id: displayId,
        anchor_x: anchorX,
        anchor_y: anchorY,
        frame_width: width,
        frame_height: height,
        name: nameRef.ref,
        has_name: nameRef.hasValue
    )
}

private func makeRestoreKernelMonitorContext(
    displayId: UInt32,
    name: String,
    frameMinX: Double,
    frameMaxY: Double,
    visibleFrame: omniwm_rect,
    anchorX: Double,
    anchorY: Double,
    width: Double,
    height: Double,
    strings: inout RestorePlannerKernelStringTable
) -> omniwm_restore_monitor_context {
    omniwm_restore_monitor_context(
        frame_min_x: frameMinX,
        frame_max_y: frameMaxY,
        visible_frame: visibleFrame,
        key: makeRestoreKernelMonitorKey(
            displayId: displayId,
            name: name,
            anchorX: anchorX,
            anchorY: anchorY,
            width: width,
            height: height,
            strings: &strings
        )
    )
}

private func makeRestoreKernelPersistedKey(
    bundleId: String,
    role: String? = nil,
    subrole: String? = nil,
    title: String? = nil,
    windowLevel: Int32? = nil,
    parentWindowId: UInt32? = nil,
    strings: inout RestorePlannerKernelStringTable
) -> omniwm_restore_persisted_key {
    let bundleIdRef = strings.append(bundleId)
    let roleRef = strings.append(role)
    let subroleRef = strings.append(subrole)
    let titleRef = strings.append(title)
    return omniwm_restore_persisted_key(
        bundle_id: bundleIdRef.ref,
        role: roleRef.ref,
        subrole: subroleRef.ref,
        title: titleRef.ref,
        window_level: windowLevel ?? 0,
        parent_window_id: parentWindowId ?? 0,
        has_bundle_id: bundleIdRef.hasValue,
        has_role: roleRef.hasValue,
        has_subrole: subroleRef.hasValue,
        has_title: titleRef.hasValue,
        has_window_level: windowLevel == nil ? 0 : 1,
        has_parent_window_id: parentWindowId == nil ? 0 : 1
    )
}

@Suite struct RestorePlannerKernelABITests {
    @Test func nullPointersReturnInvalidArgument() {
        var eventOutput = omniwm_restore_event_output()
        var topologyOutput = omniwm_restore_topology_output()
        var hydrationOutput = omniwm_restore_persisted_hydration_output()
        var rescueOutput = omniwm_restore_floating_rescue_output()

        #expect(
            omniwm_restore_plan_event(nil, &eventOutput) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_restore_plan_topology(nil, &topologyOutput) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_restore_plan_persisted_hydration(nil, &hydrationOutput) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_restore_plan_floating_rescue(nil, 1, &rescueOutput) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
    }

    @Test func eventPlannerKeepsSleepNoteWithoutRefreshAndFallsBackToFirstSortedMonitor() {
        let monitorIds: [UInt32] = [10, 20]
        var input = omniwm_restore_event_input(
            event_kind: UInt32(OMNIWM_RESTORE_EVENT_KIND_SYSTEM_SLEEP),
            sorted_monitor_ids: nil,
            sorted_monitor_count: monitorIds.count,
            interaction_monitor_id: 999,
            previous_interaction_monitor_id: 20,
            has_interaction_monitor_id: 1,
            has_previous_interaction_monitor_id: 1
        )
        var output = omniwm_restore_event_output()

        let status = monitorIds.withUnsafeBufferPointer { monitorBuffer in
            input.sorted_monitor_ids = monitorBuffer.baseAddress
            return omniwm_restore_plan_event(&input, &output)
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.refresh_restore_intents == 0)
        #expect(output.note_code == UInt32(OMNIWM_RESTORE_NOTE_SYSTEM_SLEEP))
        #expect(output.has_interaction_monitor_id == 1)
        #expect(output.interaction_monitor_id == 10)
        #expect(output.has_previous_interaction_monitor_id == 1)
        #expect(output.previous_interaction_monitor_id == 20)
    }

    @Test func topologyPlannerRestoresCachedWorkspaceToHomeMonitorAndReconcilesInteractionMonitor() {
        let workspaceLeft = makeRestoreKernelUUID(high: 1, low: 1)
        let workspaceRight = makeRestoreKernelUUID(high: 2, low: 2)
        var strings = RestorePlannerKernelStringTable()

        let previousMonitors = [
            makeRestoreKernelMonitorContext(
                displayId: 10,
                name: "Left",
                frameMinX: 0,
                frameMaxY: 1080,
                visibleFrame: makeRestoreKernelRect(x: 0, y: 0, width: 1920, height: 1080),
                anchorX: 0,
                anchorY: 1080,
                width: 1920,
                height: 1080,
                strings: &strings
            ),
            makeRestoreKernelMonitorContext(
                displayId: 30,
                name: "Detached",
                frameMinX: 1920,
                frameMaxY: 900,
                visibleFrame: makeRestoreKernelRect(x: 1920, y: 0, width: 1440, height: 900),
                anchorX: 1920,
                anchorY: 900,
                width: 1440,
                height: 900,
                strings: &strings
            ),
        ]
        let newMonitors = [
            makeRestoreKernelMonitorContext(
                displayId: 10,
                name: "Left",
                frameMinX: 0,
                frameMaxY: 1080,
                visibleFrame: makeRestoreKernelRect(x: 0, y: 0, width: 1920, height: 1080),
                anchorX: 0,
                anchorY: 1080,
                width: 1920,
                height: 1080,
                strings: &strings
            ),
            makeRestoreKernelMonitorContext(
                displayId: 20,
                name: "Right",
                frameMinX: 1920,
                frameMaxY: 1080,
                visibleFrame: makeRestoreKernelRect(x: 1920, y: 0, width: 1920, height: 1080),
                anchorX: 1920,
                anchorY: 1080,
                width: 1920,
                height: 1080,
                strings: &strings
            ),
        ]
        let visibleWorkspaces = [
            omniwm_restore_visible_workspace_snapshot(
                workspace_id: workspaceLeft,
                monitor_key: previousMonitors[0].key
            ),
            omniwm_restore_visible_workspace_snapshot(
                workspace_id: workspaceRight,
                monitor_key: previousMonitors[1].key
            ),
        ]
        let workspaceFacts = [
            omniwm_restore_workspace_monitor_fact(
                workspace_id: workspaceLeft,
                home_monitor_id: 10,
                effective_monitor_id: 10,
                workspace_exists: 1,
                has_home_monitor_id: 1,
                has_effective_monitor_id: 1
            ),
            omniwm_restore_workspace_monitor_fact(
                workspace_id: workspaceRight,
                home_monitor_id: 20,
                effective_monitor_id: 20,
                workspace_exists: 1,
                has_home_monitor_id: 1,
                has_effective_monitor_id: 1
            ),
        ]
        let visibleNamePenalties: [UInt8] = [
            0, 1,
            1, 1,
        ]
        var visibleAssignments = Array(
            repeating: omniwm_restore_visible_assignment(monitor_id: 0, workspace_id: omniwm_uuid()),
            count: 2
        )
        var cacheEntries = Array(
            repeating: omniwm_restore_disconnected_cache_output_entry(
                source_kind: 0,
                source_index: 0,
                workspace_id: omniwm_uuid()
            ),
            count: 4
        )
        var output = omniwm_restore_topology_output(
            visible_assignments: nil,
            visible_assignment_capacity: visibleAssignments.count,
            visible_assignment_count: 0,
            disconnected_cache_entries: nil,
            disconnected_cache_capacity: cacheEntries.count,
            disconnected_cache_count: 0,
            interaction_monitor_id: 0,
            previous_interaction_monitor_id: 0,
            refresh_restore_intents: 0,
            has_interaction_monitor_id: 0,
            has_previous_interaction_monitor_id: 0
        )

        let status = strings.bytes.withUnsafeBufferPointer { stringBuffer in
            previousMonitors.withUnsafeBufferPointer { previousBuffer in
                newMonitors.withUnsafeBufferPointer { newBuffer in
                    visibleWorkspaces.withUnsafeBufferPointer { visibleBuffer in
                        visibleNamePenalties.withUnsafeBufferPointer { penaltyBuffer in
                            workspaceFacts.withUnsafeBufferPointer { factBuffer in
                                visibleAssignments.withUnsafeMutableBufferPointer { assignmentBuffer in
                                    cacheEntries.withUnsafeMutableBufferPointer { cacheBuffer in
                                        output.visible_assignments = assignmentBuffer.baseAddress
                                        output.disconnected_cache_entries = cacheBuffer.baseAddress

                                        var input = omniwm_restore_topology_input(
                                            previous_monitors: previousBuffer.baseAddress,
                                            previous_monitor_count: previousBuffer.count,
                                            new_monitors: newBuffer.baseAddress,
                                            new_monitor_count: newBuffer.count,
                                            visible_workspaces: visibleBuffer.baseAddress,
                                            visible_workspace_count: visibleBuffer.count,
                                            visible_workspace_name_penalties: penaltyBuffer.baseAddress,
                                            visible_workspace_name_penalty_count: penaltyBuffer.count,
                                            disconnected_cache_entries: nil,
                                            disconnected_cache_entry_count: 0,
                                            workspace_facts: factBuffer.baseAddress,
                                            workspace_fact_count: factBuffer.count,
                                            string_bytes: stringBuffer.baseAddress,
                                            string_byte_count: stringBuffer.count,
                                            focused_workspace_id: workspaceRight,
                                            interaction_monitor_id: 999,
                                            previous_interaction_monitor_id: 998,
                                            has_focused_workspace_id: 1,
                                            has_interaction_monitor_id: 1,
                                            has_previous_interaction_monitor_id: 1
                                        )

                                        return omniwm_restore_plan_topology(&input, &output)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.refresh_restore_intents == 1)
        #expect(output.visible_assignment_count == 2)
        #expect(output.disconnected_cache_count == 0)
        #expect(output.has_interaction_monitor_id == 1)
        #expect(output.interaction_monitor_id == 20)
        #expect(output.has_previous_interaction_monitor_id == 0)
        #expect(visibleAssignments[0].monitor_id == 10)
        #expect(restoreKernelUUIDEqual(visibleAssignments[0].workspace_id, workspaceLeft))
        #expect(visibleAssignments[1].monitor_id == 20)
        #expect(restoreKernelUUIDEqual(visibleAssignments[1].workspace_id, workspaceRight))
    }

    @Test func persistedHydrationPlannerAppliesDisplayIdFallbackAndNormalizedOrigin() {
        let workspaceId = makeRestoreKernelUUID(high: 9, low: 9)
        var strings = RestorePlannerKernelStringTable()
        let monitors = [
            makeRestoreKernelMonitorContext(
                displayId: 80,
                name: "Studio Display",
                frameMinX: 0,
                frameMaxY: 900,
                visibleFrame: makeRestoreKernelRect(x: 0, y: 0, width: 1440, height: 900),
                anchorX: 0,
                anchorY: 900,
                width: 1440,
                height: 900,
                strings: &strings
            ),
        ]
        let metadataKey = makeRestoreKernelPersistedKey(
            bundleId: "com.example.editor",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Doc",
            windowLevel: 0,
            strings: &strings
        )
        let entries = [
            omniwm_restore_persisted_entry_snapshot(
                key: metadataKey,
                workspace_id: workspaceId,
                preferred_monitor: makeRestoreKernelMonitorKey(
                    displayId: 80,
                    name: "Old Display",
                    anchorX: 2000,
                    anchorY: 900,
                    width: 1200,
                    height: 800,
                    strings: &strings
                ),
                floating_frame: makeRestoreKernelRect(x: 200, y: 200, width: 300, height: 200),
                normalized_floating_origin: makeRestoreKernelPoint(x: 1, y: 1),
                preferred_monitor_name_penalty_offset: 0,
                restore_to_floating: 1,
                consumed: 0,
                has_workspace_id: 1,
                has_preferred_monitor: 1,
                has_floating_frame: 1,
                has_normalized_floating_origin: 1
            ),
        ]
        let namePenalties: [UInt8] = [1]
        var output = omniwm_restore_persisted_hydration_output()

        let status = strings.bytes.withUnsafeBufferPointer { stringBuffer in
            monitors.withUnsafeBufferPointer { monitorBuffer in
                entries.withUnsafeBufferPointer { entryBuffer in
                    namePenalties.withUnsafeBufferPointer { penaltyBuffer in
                        var input = omniwm_restore_persisted_hydration_input(
                            metadata_key: metadataKey,
                            metadata_mode: UInt32(OMNIWM_RECONCILE_WINDOW_MODE_TILING),
                            monitors: monitorBuffer.baseAddress,
                            monitor_count: monitorBuffer.count,
                            entries: entryBuffer.baseAddress,
                            entry_count: entryBuffer.count,
                            preferred_monitor_name_penalties: penaltyBuffer.baseAddress,
                            preferred_monitor_name_penalty_count: penaltyBuffer.count,
                            string_bytes: stringBuffer.baseAddress,
                            string_byte_count: stringBuffer.count
                        )

                        return omniwm_restore_plan_persisted_hydration(&input, &output)
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.outcome == UInt32(OMNIWM_RESTORE_HYDRATION_OUTCOME_MATCHED))
        #expect(output.has_entry_index == 1)
        #expect(output.entry_index == 0)
        #expect(restoreKernelUUIDEqual(output.workspace_id, workspaceId))
        #expect(output.has_preferred_monitor_id == 1)
        #expect(output.preferred_monitor_id == 80)
        #expect(output.target_mode == UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING))
        #expect(output.has_floating_frame == 1)
        #expect(output.floating_frame.x == 1140)
        #expect(output.floating_frame.y == 700)
    }

    @Test func floatingRescuePlannerSkipsHiddenAndApproximateFrames() {
        let candidates = [
            omniwm_restore_floating_rescue_candidate(
                token: omniwm_window_token(pid: 1, window_id: 1),
                workspace_id: makeRestoreKernelUUID(high: 1, low: 1),
                target_monitor_id: 10,
                target_monitor_visible_frame: makeRestoreKernelRect(x: 0, y: 0, width: 1600, height: 900),
                current_frame: makeRestoreKernelRect(),
                floating_frame: makeRestoreKernelRect(x: 100, y: 120, width: 300, height: 200),
                normalized_origin: makeRestoreKernelPoint(),
                reference_monitor_id: 0,
                has_current_frame: 0,
                has_normalized_origin: 0,
                has_reference_monitor_id: 0,
                is_scratchpad_hidden: 0,
                is_workspace_inactive_hidden: 0
            ),
            omniwm_restore_floating_rescue_candidate(
                token: omniwm_window_token(pid: 2, window_id: 2),
                workspace_id: makeRestoreKernelUUID(high: 2, low: 2),
                target_monitor_id: 10,
                target_monitor_visible_frame: makeRestoreKernelRect(x: 0, y: 0, width: 1600, height: 900),
                current_frame: makeRestoreKernelRect(x: 100.4, y: 120.4, width: 300.3, height: 199.5),
                floating_frame: makeRestoreKernelRect(x: 100, y: 120, width: 300, height: 200),
                normalized_origin: makeRestoreKernelPoint(),
                reference_monitor_id: 0,
                has_current_frame: 1,
                has_normalized_origin: 0,
                has_reference_monitor_id: 0,
                is_scratchpad_hidden: 0,
                is_workspace_inactive_hidden: 0
            ),
            omniwm_restore_floating_rescue_candidate(
                token: omniwm_window_token(pid: 3, window_id: 3),
                workspace_id: makeRestoreKernelUUID(high: 3, low: 3),
                target_monitor_id: 10,
                target_monitor_visible_frame: makeRestoreKernelRect(x: 0, y: 0, width: 1600, height: 900),
                current_frame: makeRestoreKernelRect(),
                floating_frame: makeRestoreKernelRect(x: 500, y: 300, width: 300, height: 200),
                normalized_origin: makeRestoreKernelPoint(),
                reference_monitor_id: 0,
                has_current_frame: 0,
                has_normalized_origin: 0,
                has_reference_monitor_id: 0,
                is_scratchpad_hidden: 1,
                is_workspace_inactive_hidden: 0
            ),
        ]
        var operations = Array(
            repeating: omniwm_restore_floating_rescue_operation(
                candidate_index: 0,
                target_frame: makeRestoreKernelRect()
            ),
            count: candidates.count
        )
        var output = omniwm_restore_floating_rescue_output(
            operations: nil,
            operation_capacity: operations.count,
            operation_count: 0
        )

        let status = candidates.withUnsafeBufferPointer { candidateBuffer in
            operations.withUnsafeMutableBufferPointer { operationBuffer in
                output.operations = operationBuffer.baseAddress
                return omniwm_restore_plan_floating_rescue(
                    candidateBuffer.baseAddress,
                    candidateBuffer.count,
                    &output
                )
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.operation_count == 1)
        #expect(operations[0].candidate_index == 0)
        #expect(operations[0].target_frame.x == 100)
        #expect(operations[0].target_frame.y == 120)
    }

    @Test func floatingRescuePlannerOrdersOperationsByStableIdentity() {
        let candidates = [
            omniwm_restore_floating_rescue_candidate(
                token: omniwm_window_token(pid: 4, window_id: 400),
                workspace_id: makeRestoreKernelUUID(high: 2, low: 0),
                target_monitor_id: 10,
                target_monitor_visible_frame: makeRestoreKernelRect(x: 0, y: 0, width: 1600, height: 900),
                current_frame: makeRestoreKernelRect(x: 0, y: 0, width: 300, height: 200),
                floating_frame: makeRestoreKernelRect(x: 500, y: 300, width: 300, height: 200),
                normalized_origin: makeRestoreKernelPoint(),
                reference_monitor_id: 0,
                has_current_frame: 1,
                has_normalized_origin: 0,
                has_reference_monitor_id: 0,
                is_scratchpad_hidden: 0,
                is_workspace_inactive_hidden: 0
            ),
            omniwm_restore_floating_rescue_candidate(
                token: omniwm_window_token(pid: 1, window_id: 100),
                workspace_id: makeRestoreKernelUUID(high: 1, low: 0),
                target_monitor_id: 10,
                target_monitor_visible_frame: makeRestoreKernelRect(x: 0, y: 0, width: 1600, height: 900),
                current_frame: makeRestoreKernelRect(x: 0, y: 0, width: 300, height: 200),
                floating_frame: makeRestoreKernelRect(x: 450, y: 260, width: 300, height: 200),
                normalized_origin: makeRestoreKernelPoint(),
                reference_monitor_id: 0,
                has_current_frame: 1,
                has_normalized_origin: 0,
                has_reference_monitor_id: 0,
                is_scratchpad_hidden: 0,
                is_workspace_inactive_hidden: 0
            ),
        ]
        var operations = Array(
            repeating: omniwm_restore_floating_rescue_operation(
                candidate_index: 0,
                target_frame: makeRestoreKernelRect()
            ),
            count: candidates.count
        )
        var output = omniwm_restore_floating_rescue_output(
            operations: nil,
            operation_capacity: operations.count,
            operation_count: 0
        )

        let status = candidates.withUnsafeBufferPointer { candidateBuffer in
            operations.withUnsafeMutableBufferPointer { operationBuffer in
                output.operations = operationBuffer.baseAddress
                return omniwm_restore_plan_floating_rescue(
                    candidateBuffer.baseAddress,
                    candidateBuffer.count,
                    &output
                )
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.operation_count == 2)
        #expect(operations[0].candidate_index == 1)
        #expect(operations[1].candidate_index == 0)
    }
}
