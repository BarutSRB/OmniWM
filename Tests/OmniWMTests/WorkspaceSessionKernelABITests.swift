// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Testing

private func makeWorkspaceSessionUUID(high: UInt64, low: UInt64) -> omniwm_uuid {
    omniwm_uuid(high: high, low: low)
}

private func workspaceSessionUUIDEqual(_ lhs: omniwm_uuid, _ rhs: omniwm_uuid) -> Bool {
    lhs.high == rhs.high && lhs.low == rhs.low
}

private func makeWorkspaceSessionToken(
    pid: Int32,
    windowId: Int64
) -> omniwm_window_token {
    omniwm_window_token(pid: pid, window_id: windowId)
}

private struct WorkspaceSessionKernelStringTable {
    var bytes: [UInt8] = []

    mutating func append(_ string: String?) -> (ref: omniwm_restore_string_ref, hasValue: UInt8) {
        guard let string else {
            return (omniwm_restore_string_ref(offset: 0, length: 0), 0)
        }

        let utf8 = Array(string.utf8)
        let offset = bytes.count
        bytes.append(contentsOf: utf8)
        return (omniwm_restore_string_ref(offset: offset, length: utf8.count), 1)
    }
}

private func makeWorkspaceSessionInput(
    operation: UInt32,
    workspaceId: omniwm_uuid? = nil,
    monitorId: UInt32? = nil,
    focusedWorkspaceId: omniwm_uuid? = nil,
    confirmedTiledWorkspaceId: omniwm_uuid? = nil,
    interactionMonitorId: UInt32? = nil,
    previousInteractionMonitorId: UInt32? = nil,
    currentViewportKind: UInt32 = UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_NONE),
    patchViewportKind: UInt32 = UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_NONE),
    hasCurrentViewportState: Bool = false,
    hasPatchViewportState: Bool = false
) -> omniwm_workspace_session_input {
    omniwm_workspace_session_input(
        operation: operation,
        workspace_id: workspaceId ?? omniwm_uuid(),
        monitor_id: monitorId ?? 0,
        focused_workspace_id: focusedWorkspaceId ?? omniwm_uuid(),
        pending_tiled_workspace_id: omniwm_uuid(),
        confirmed_tiled_workspace_id: confirmedTiledWorkspaceId ?? omniwm_uuid(),
        confirmed_floating_workspace_id: omniwm_uuid(),
        pending_tiled_focus_token: omniwm_window_token(),
        confirmed_tiled_focus_token: omniwm_window_token(),
        confirmed_floating_focus_token: omniwm_window_token(),
        remembered_focus_token: omniwm_window_token(),
        interaction_monitor_id: interactionMonitorId ?? 0,
        previous_interaction_monitor_id: previousInteractionMonitorId ?? 0,
        current_viewport_kind: currentViewportKind,
        current_viewport_active_column_index: 0,
        patch_viewport_kind: patchViewportKind,
        patch_viewport_active_column_index: 0,
        has_workspace_id: workspaceId == nil ? 0 : 1,
        has_monitor_id: monitorId == nil ? 0 : 1,
        has_focused_workspace_id: focusedWorkspaceId == nil ? 0 : 1,
        has_pending_tiled_workspace_id: 0,
        has_confirmed_tiled_workspace_id: confirmedTiledWorkspaceId == nil ? 0 : 1,
        has_confirmed_floating_workspace_id: 0,
        has_pending_tiled_focus_token: 0,
        has_confirmed_tiled_focus_token: 0,
        has_confirmed_floating_focus_token: 0,
        has_remembered_focus_token: 0,
        has_interaction_monitor_id: interactionMonitorId == nil ? 0 : 1,
        has_previous_interaction_monitor_id: previousInteractionMonitorId == nil ? 0 : 1,
        has_current_viewport_state: hasCurrentViewportState ? 1 : 0,
        has_patch_viewport_state: hasPatchViewportState ? 1 : 0,
        should_update_interaction_monitor: 0,
        preserve_previous_interaction_monitor: 0
    )
}

private func makeWorkspaceSessionMonitor(
    id: UInt32,
    minX: Double,
    maxY: Double,
    width: Double = 1920,
    height: Double = 1080,
    anchorX: Double,
    anchorY: Double,
    isMain: Bool = false,
    visibleWorkspaceId: omniwm_uuid? = nil,
    previousVisibleWorkspaceId: omniwm_uuid? = nil,
    name: String? = nil,
    strings: inout WorkspaceSessionKernelStringTable
) -> omniwm_workspace_session_monitor {
    let nameRef = strings.append(name)
    return omniwm_workspace_session_monitor(
        monitor_id: id,
        frame_min_x: minX,
        frame_max_y: maxY,
        frame_width: width,
        frame_height: height,
        anchor_x: anchorX,
        anchor_y: anchorY,
        visible_workspace_id: visibleWorkspaceId ?? omniwm_uuid(),
        previous_visible_workspace_id: previousVisibleWorkspaceId ?? omniwm_uuid(),
        name: nameRef.ref,
        is_main: isMain ? 1 : 0,
        has_visible_workspace_id: visibleWorkspaceId == nil ? 0 : 1,
        has_previous_visible_workspace_id: previousVisibleWorkspaceId == nil ? 0 : 1,
        has_name: nameRef.hasValue
    )
}

private func makeWorkspaceSessionPreviousMonitor(
    id: UInt32,
    minX: Double,
    maxY: Double,
    width: Double = 1920,
    height: Double = 1080,
    anchorX: Double,
    anchorY: Double,
    visibleWorkspaceId: omniwm_uuid? = nil,
    previousVisibleWorkspaceId: omniwm_uuid? = nil,
    name: String? = nil,
    strings: inout WorkspaceSessionKernelStringTable
) -> omniwm_workspace_session_previous_monitor {
    let nameRef = strings.append(name)
    return omniwm_workspace_session_previous_monitor(
        monitor_id: id,
        frame_min_x: minX,
        frame_max_y: maxY,
        frame_width: width,
        frame_height: height,
        anchor_x: anchorX,
        anchor_y: anchorY,
        visible_workspace_id: visibleWorkspaceId ?? omniwm_uuid(),
        previous_visible_workspace_id: previousVisibleWorkspaceId ?? omniwm_uuid(),
        name: nameRef.ref,
        has_visible_workspace_id: visibleWorkspaceId == nil ? 0 : 1,
        has_previous_visible_workspace_id: previousVisibleWorkspaceId == nil ? 0 : 1,
        has_name: nameRef.hasValue
    )
}

private func makeWorkspaceSessionDisconnectedCacheEntry(
    workspaceId: omniwm_uuid,
    displayId: UInt32,
    anchorX: Double,
    anchorY: Double,
    frameWidth: Double = 1920,
    frameHeight: Double = 1080,
    name: String? = nil,
    strings: inout WorkspaceSessionKernelStringTable
) -> omniwm_workspace_session_disconnected_cache_entry {
    let nameRef = strings.append(name)
    return omniwm_workspace_session_disconnected_cache_entry(
        workspace_id: workspaceId,
        display_id: displayId,
        anchor_x: anchorX,
        anchor_y: anchorY,
        frame_width: frameWidth,
        frame_height: frameHeight,
        name: nameRef.ref,
        has_name: nameRef.hasValue
    )
}

private func makeWorkspaceSessionWorkspace(
    id: omniwm_uuid,
    assignmentKind: UInt32,
    assignedAnchor: omniwm_point? = nil,
    specificDisplayId: UInt32? = nil,
    specificDisplayName: String? = nil,
    rememberedTiled: omniwm_window_token? = nil,
    rememberedFloating: omniwm_window_token? = nil,
    strings: inout WorkspaceSessionKernelStringTable
) -> omniwm_workspace_session_workspace {
    let specificNameRef = strings.append(specificDisplayName)
    return omniwm_workspace_session_workspace(
        workspace_id: id,
        assigned_anchor_point: assignedAnchor ?? omniwm_point(),
        assignment_kind: assignmentKind,
        specific_display_id: specificDisplayId ?? 0,
        specific_display_name: specificNameRef.ref,
        remembered_tiled_focus_token: rememberedTiled ?? omniwm_window_token(),
        remembered_floating_focus_token: rememberedFloating ?? omniwm_window_token(),
        has_assigned_anchor_point: assignedAnchor == nil ? 0 : 1,
        has_specific_display_id: specificDisplayId == nil ? 0 : 1,
        has_specific_display_name: specificNameRef.hasValue,
        has_remembered_tiled_focus_token: rememberedTiled == nil ? 0 : 1,
        has_remembered_floating_focus_token: rememberedFloating == nil ? 0 : 1
    )
}

private func makeWorkspaceSessionCandidate(
    workspaceId: omniwm_uuid,
    token: omniwm_window_token,
    mode: UInt32,
    orderIndex: UInt32,
    hasHiddenProportionalPosition: Bool = false,
    hiddenReasonIsWorkspaceInactive: Bool = false
) -> omniwm_workspace_session_window_candidate {
    omniwm_workspace_session_window_candidate(
        workspace_id: workspaceId,
        token: token,
        mode: mode,
        order_index: orderIndex,
        has_hidden_proportional_position: hasHiddenProportionalPosition ? 1 : 0,
        hidden_reason_is_workspace_inactive: hiddenReasonIsWorkspaceInactive ? 1 : 0
    )
}

private func callWorkspaceSessionKernel(
    input: inout omniwm_workspace_session_input,
    monitors: [omniwm_workspace_session_monitor] = [],
    previousMonitors: [omniwm_workspace_session_previous_monitor] = [],
    workspaces: [omniwm_workspace_session_workspace] = [],
    windowCandidates: [omniwm_workspace_session_window_candidate] = [],
    disconnectedCacheEntries: [omniwm_workspace_session_disconnected_cache_entry] = [],
    stringBytes: [UInt8] = [],
    output: inout omniwm_workspace_session_output
) -> Int32 {
    monitors.withUnsafeBufferPointer { monitorBuffer in
        previousMonitors.withUnsafeBufferPointer { previousMonitorBuffer in
            workspaces.withUnsafeBufferPointer { workspaceBuffer in
                windowCandidates.withUnsafeBufferPointer { candidateBuffer in
                    disconnectedCacheEntries.withUnsafeBufferPointer { disconnectedCacheBuffer in
                        stringBytes.withUnsafeBufferPointer { stringBuffer in
                            omniwm_workspace_session_plan(
                                &input,
                                monitorBuffer.baseAddress,
                                monitorBuffer.count,
                                previousMonitorBuffer.baseAddress,
                                previousMonitorBuffer.count,
                                workspaceBuffer.baseAddress,
                                workspaceBuffer.count,
                                candidateBuffer.baseAddress,
                                candidateBuffer.count,
                                disconnectedCacheBuffer.baseAddress,
                                disconnectedCacheBuffer.count,
                                stringBuffer.baseAddress,
                                stringBuffer.count,
                                &output
                            )
                        }
                    }
                }
            }
        }
    }
}

private func withWorkspaceSessionOutput<Result>(
    monitorCapacity: Int = 4,
    projectionCapacity: Int = 4,
    disconnectedCacheCapacity: Int = 4,
    _ body: (
        inout omniwm_workspace_session_output,
        UnsafeMutableBufferPointer<omniwm_workspace_session_monitor_result>,
        UnsafeMutableBufferPointer<omniwm_workspace_session_workspace_projection>
    ) -> Result
) -> Result {
    var monitorResults = Array(
        repeating: omniwm_workspace_session_monitor_result(),
        count: monitorCapacity
    )
    var workspaceProjections = Array(
        repeating: omniwm_workspace_session_workspace_projection(),
        count: projectionCapacity
    )
    var disconnectedCacheResults = Array(
        repeating: omniwm_workspace_session_disconnected_cache_result(),
        count: disconnectedCacheCapacity
    )

    return monitorResults.withUnsafeMutableBufferPointer { monitorBuffer in
        workspaceProjections.withUnsafeMutableBufferPointer { projectionBuffer in
            disconnectedCacheResults.withUnsafeMutableBufferPointer { disconnectedCacheBuffer in
                var output = omniwm_workspace_session_output(
                    outcome: 0,
                    patch_viewport_action: 0,
                    focus_clear_action: 0,
                    interaction_monitor_id: 0,
                    previous_interaction_monitor_id: 0,
                    resolved_focus_token: omniwm_window_token(),
                    monitor_results: monitorBuffer.baseAddress,
                    monitor_result_capacity: monitorBuffer.count,
                    monitor_result_count: 0,
                    workspace_projections: projectionBuffer.baseAddress,
                    workspace_projection_capacity: projectionBuffer.count,
                    workspace_projection_count: 0,
                    disconnected_cache_results: disconnectedCacheBuffer.baseAddress,
                    disconnected_cache_result_capacity: disconnectedCacheBuffer.count,
                    disconnected_cache_result_count: 0,
                    has_interaction_monitor_id: 0,
                    has_previous_interaction_monitor_id: 0,
                    has_resolved_focus_token: 0,
                    should_remember_focus: 0,
                    refresh_restore_intents: 0
                )
                return body(&output, monitorBuffer, projectionBuffer)
            }
        }
    }
}

private func withWorkspaceSessionOutputBuffers<Result>(
    monitorCapacity: Int = 4,
    projectionCapacity: Int = 4,
    disconnectedCacheCapacity: Int = 4,
    _ body: (
        inout omniwm_workspace_session_output,
        UnsafeMutableBufferPointer<omniwm_workspace_session_monitor_result>,
        UnsafeMutableBufferPointer<omniwm_workspace_session_workspace_projection>,
        UnsafeMutableBufferPointer<omniwm_workspace_session_disconnected_cache_result>
    ) -> Result
) -> Result {
    var monitorResults = Array(
        repeating: omniwm_workspace_session_monitor_result(),
        count: monitorCapacity
    )
    var workspaceProjections = Array(
        repeating: omniwm_workspace_session_workspace_projection(),
        count: projectionCapacity
    )
    var disconnectedCacheResults = Array(
        repeating: omniwm_workspace_session_disconnected_cache_result(),
        count: disconnectedCacheCapacity
    )

    return monitorResults.withUnsafeMutableBufferPointer { monitorBuffer in
        workspaceProjections.withUnsafeMutableBufferPointer { projectionBuffer in
            disconnectedCacheResults.withUnsafeMutableBufferPointer { disconnectedCacheBuffer in
                var output = omniwm_workspace_session_output(
                    outcome: 0,
                    patch_viewport_action: 0,
                    focus_clear_action: 0,
                    interaction_monitor_id: 0,
                    previous_interaction_monitor_id: 0,
                    resolved_focus_token: omniwm_window_token(),
                    monitor_results: monitorBuffer.baseAddress,
                    monitor_result_capacity: monitorBuffer.count,
                    monitor_result_count: 0,
                    workspace_projections: projectionBuffer.baseAddress,
                    workspace_projection_capacity: projectionBuffer.count,
                    workspace_projection_count: 0,
                    disconnected_cache_results: disconnectedCacheBuffer.baseAddress,
                    disconnected_cache_result_capacity: disconnectedCacheBuffer.count,
                    disconnected_cache_result_count: 0,
                    has_interaction_monitor_id: 0,
                    has_previous_interaction_monitor_id: 0,
                    has_resolved_focus_token: 0,
                    should_remember_focus: 0,
                    refresh_restore_intents: 0
                )
                return body(&output, monitorBuffer, projectionBuffer, disconnectedCacheBuffer)
            }
        }
    }
}

struct WorkspaceSessionKernelABITests {
    @Test func `null pointers return invalid argument`() {
        var input = omniwm_workspace_session_input()
        var output = omniwm_workspace_session_output()

        #expect(
            omniwm_workspace_session_plan(nil, nil, 0, nil, 0, nil, 0, nil, 0, nil, 0, nil, 0, &output)
                == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_workspace_session_plan(&input, nil, 0, nil, 0, nil, 0, nil, 0, nil, 0, nil, 0, nil)
                == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
    }

    @Test func `nil nested output buffers with capacity return invalid argument`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 1, low: 1)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                name: "Main",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceId,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            )
        ]
        var output = omniwm_workspace_session_output(
            outcome: 0,
            patch_viewport_action: 0,
            focus_clear_action: 0,
            interaction_monitor_id: 0,
            previous_interaction_monitor_id: 0,
            resolved_focus_token: omniwm_window_token(),
            monitor_results: nil,
            monitor_result_capacity: 1,
            monitor_result_count: 0,
            workspace_projections: nil,
            workspace_projection_capacity: 1,
            workspace_projection_count: 0,
            disconnected_cache_results: nil,
            disconnected_cache_result_capacity: 1,
            disconnected_cache_result_count: 0,
            has_interaction_monitor_id: 0,
            has_previous_interaction_monitor_id: 0,
            has_resolved_focus_token: 0,
            should_remember_focus: 0,
            refresh_restore_intents: 0
        )

        let status = callWorkspaceSessionKernel(
            input: &input,
            monitors: monitors,
            workspaces: workspaces,
            stringBytes: strings.bytes,
            output: &output
        )

        #expect(status == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)
    }

    @Test func `project falls back to nearest monitor for missing specific display`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 2, low: 2)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                name: "Main",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                name: "Side",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceId,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                assignedAnchor: omniwm_point(x: 2100, y: 1000),
                specificDisplayId: 30,
                specificDisplayName: "Detached",
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 2,
            projectionCapacity: 1
        ) { output, _, projectionBuffer in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.workspace_projection_count == 1)
            #expect(projectionBuffer[0].has_home_monitor_id == 0)
            #expect(projectionBuffer[0].has_effective_monitor_id == 1)
            #expect(projectionBuffer[0].effective_monitor_id == 20)
            #expect(projectionBuffer[0].has_projected_monitor_id == 1)
            #expect(projectionBuffer[0].projected_monitor_id == 20)
            #expect(workspaceSessionUUIDEqual(projectionBuffer[0].workspace_id, workspaceId))
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `project does not resolve specific display by name alone`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 22, low: 22)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 40,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                name: "Detached",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 50,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                name: "Side",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceId,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                assignedAnchor: omniwm_point(x: 2100, y: 1000),
                specificDisplayId: 30,
                specificDisplayName: "Detached",
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 2,
            projectionCapacity: 1
        ) { output, _, projectionBuffer in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.workspace_projection_count == 1)
            #expect(projectionBuffer[0].has_home_monitor_id == 0)
            #expect(projectionBuffer[0].has_effective_monitor_id == 1)
            #expect(projectionBuffer[0].effective_monitor_id == 50)
            #expect(projectionBuffer[0].has_projected_monitor_id == 1)
            #expect(projectionBuffer[0].projected_monitor_id == 50)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `project keeps specific display fallback aligned with inserted monitor anchors`() {
        let workspaceCenter = makeWorkspaceSessionUUID(high: 3, low: 3)
        let workspaceRightOne = makeWorkspaceSessionUUID(high: 4, low: 4)
        let workspaceRightTwo = makeWorkspaceSessionUUID(high: 5, low: 5)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 30,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                name: "Left",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 40,
                minX: 1000,
                maxY: 1080,
                anchorX: 1000,
                anchorY: 1080,
                name: "Replacement Center",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 50,
                minX: 3000,
                maxY: 1080,
                anchorX: 3000,
                anchorY: 1080,
                name: "Replacement Right",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceCenter,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                assignedAnchor: omniwm_point(x: 1000, y: 1080),
                specificDisplayId: 10,
                specificDisplayName: "Center",
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceRightOne,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                assignedAnchor: omniwm_point(x: 3000, y: 1080),
                specificDisplayId: 20,
                specificDisplayName: "Right",
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceRightTwo,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                assignedAnchor: omniwm_point(x: 3000, y: 1080),
                specificDisplayId: 20,
                specificDisplayName: "Right",
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 3,
            projectionCapacity: 3
        ) { output, _, projectionBuffer in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )

            #expect(output.workspace_projection_count == 3)
            #expect(projectionBuffer[0].projected_monitor_id == 40)
            #expect(projectionBuffer[1].projected_monitor_id == 50)
            #expect(projectionBuffer[2].projected_monitor_id == 50)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `project returns resolved active workspace for monitor without visible session`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 6, low: 6)
        let workspaceSide = makeWorkspaceSessionUUID(high: 7, low: 7)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                name: "Main",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                visibleWorkspaceId: workspaceSide,
                name: "Side",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSide,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 2,
            projectionCapacity: 2
        ) { output, monitorBuffer, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.monitor_result_count == 2)
            #expect(monitorBuffer[0].monitor_id == 10)
            #expect(monitorBuffer[0].has_visible_workspace_id == 0)
            #expect(monitorBuffer[0].has_resolved_active_workspace_id == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].resolved_active_workspace_id, workspaceMain))
            #expect(monitorBuffer[1].monitor_id == 20)
            #expect(monitorBuffer[1].has_visible_workspace_id == 1)
            #expect(monitorBuffer[1].has_resolved_active_workspace_id == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[1].resolved_active_workspace_id, workspaceSide))
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `reconcile visible repairs assignments and follows focused workspace monitor`() {
        let workspaceOne = makeWorkspaceSessionUUID(high: 10, low: 10)
        let workspaceTwo = makeWorkspaceSessionUUID(high: 20, low: 20)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_VISIBLE),
            focusedWorkspaceId: workspaceTwo,
            interactionMonitorId: 999,
            previousInteractionMonitorId: 30
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceTwo,
                name: "Main",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                name: "Side",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceOne,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceTwo,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 2,
            projectionCapacity: 2
        ) { output, monitorBuffer, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.monitor_result_count == 2)
            #expect(monitorBuffer[0].monitor_id == 10)
            #expect(monitorBuffer[0].has_visible_workspace_id == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].visible_workspace_id, workspaceOne))
            #expect(monitorBuffer[0].has_previous_visible_workspace_id == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].previous_visible_workspace_id, workspaceTwo))
            #expect(monitorBuffer[1].monitor_id == 20)
            #expect(monitorBuffer[1].has_visible_workspace_id == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[1].visible_workspace_id, workspaceTwo))
            #expect(output.has_interaction_monitor_id == 1)
            #expect(output.interaction_monitor_id == 20)
            #expect(output.has_previous_interaction_monitor_id == 0)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `resolve workspace focus returns floating fallback and clear directive`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 30, low: 30)
        let floatingToken = makeWorkspaceSessionToken(pid: 42, windowId: 7)
        let staleTiledToken = makeWorkspaceSessionToken(pid: 99, windowId: 9)
        var strings = WorkspaceSessionKernelStringTable()
        var resolveInput = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_WORKSPACE_FOCUS),
            workspaceId: workspaceId
        )
        let floatingWorkspace = [
            makeWorkspaceSessionWorkspace(
                id: workspaceId,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_UNCONFIGURED),
                rememberedFloating: floatingToken,
                strings: &strings
            )
        ]
        let floatingCandidates = [
            makeWorkspaceSessionCandidate(
                workspaceId: workspaceId,
                token: staleTiledToken,
                mode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_TILING),
                orderIndex: 0,
                hasHiddenProportionalPosition: true,
                hiddenReasonIsWorkspaceInactive: false
            ),
            makeWorkspaceSessionCandidate(
                workspaceId: workspaceId,
                token: floatingToken,
                mode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_FLOATING),
                orderIndex: 0
            )
        ]

        let resolveStatus: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 0,
            projectionCapacity: 0
        ) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &resolveInput,
                workspaces: floatingWorkspace,
                windowCandidates: floatingCandidates,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.has_resolved_focus_token == 1)
            #expect(output.resolved_focus_token.pid == floatingToken.pid)
            #expect(output.resolved_focus_token.window_id == floatingToken.window_id)
            return status
        }

        #expect(resolveStatus == OMNIWM_KERNELS_STATUS_OK)

        var clearInput = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_WORKSPACE_FOCUS),
            workspaceId: workspaceId,
            confirmedTiledWorkspaceId: workspaceId
        )
        let emptyWorkspace = [
            makeWorkspaceSessionWorkspace(
                id: workspaceId,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_UNCONFIGURED),
                strings: &strings
            )
        ]

        let clearStatus: Int32 = withWorkspaceSessionOutput(monitorCapacity: 0, projectionCapacity: 0) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &clearInput,
                workspaces: emptyWorkspace,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.has_resolved_focus_token == 0)
            #expect(
                output.focus_clear_action
                    == UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING_AND_CONFIRMED)
            )
            return status
        }

        #expect(clearStatus == OMNIWM_KERNELS_STATUS_OK)

        var focusedClearInput = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_WORKSPACE_FOCUS),
            workspaceId: workspaceId,
            focusedWorkspaceId: workspaceId
        )

        let focusedClearStatus: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 0,
            projectionCapacity: 0
        ) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &focusedClearInput,
                workspaces: emptyWorkspace,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.has_resolved_focus_token == 0)
            #expect(
                output.focus_clear_action
                    == UInt32(OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING_AND_CONFIRMED)
            )
            return status
        }

        #expect(focusedClearStatus == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `preferred focus rejects stale pending candidate and uses first eligible tiled candidate`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 35, low: 35)
        let hiddenPending = makeWorkspaceSessionToken(pid: 11, windowId: 1101)
        let firstEligible = makeWorkspaceSessionToken(pid: 11, windowId: 1102)
        var strings = WorkspaceSessionKernelStringTable()
        let workspace = [
            makeWorkspaceSessionWorkspace(
                id: workspaceId,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_UNCONFIGURED),
                strings: &strings
            )
        ]
        let candidates = [
            makeWorkspaceSessionCandidate(
                workspaceId: workspaceId,
                token: hiddenPending,
                mode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_TILING),
                orderIndex: 0,
                hasHiddenProportionalPosition: true,
                hiddenReasonIsWorkspaceInactive: false
            ),
            makeWorkspaceSessionCandidate(
                workspaceId: workspaceId,
                token: firstEligible,
                mode: UInt32(OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_TILING),
                orderIndex: 1
            )
        ]
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_PREFERRED_FOCUS),
            workspaceId: workspaceId
        )
        input.pending_tiled_workspace_id = workspaceId
        input.pending_tiled_focus_token = hiddenPending
        input.has_pending_tiled_workspace_id = 1
        input.has_pending_tiled_focus_token = 1

        let status: Int32 = withWorkspaceSessionOutput(monitorCapacity: 0, projectionCapacity: 0) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                workspaces: workspace,
                windowCandidates: candidates,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.has_resolved_focus_token == 1)
            #expect(output.resolved_focus_token.window_id == firstEligible.window_id)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `apply session patch preserves current spring against gesture patch`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 40, low: 40)
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_APPLY_SESSION_PATCH),
            workspaceId: workspaceId,
            currentViewportKind: UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_SPRING),
            patchViewportKind: UInt32(OMNIWM_WORKSPACE_SESSION_VIEWPORT_GESTURE),
            hasCurrentViewportState: true,
            hasPatchViewportState: true
        )

        let status: Int32 = withWorkspaceSessionOutput(monitorCapacity: 0, projectionCapacity: 0) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(
                output.patch_viewport_action
                    == UInt32(OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_PRESERVE_CURRENT)
            )
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `project ignores encoded specific display names when display id is missing`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 50, low: 50)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                name: "",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                name: "Side",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceId,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY),
                assignedAnchor: omniwm_point(x: 1900, y: 1080),
                specificDisplayId: 30,
                specificDisplayName: "",
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 2,
            projectionCapacity: 1
        ) { output, _, projectionBuffer in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.workspace_projection_count == 1)
            #expect(projectionBuffer[0].has_home_monitor_id == 0)
            #expect(projectionBuffer[0].has_effective_monitor_id == 1)
            #expect(projectionBuffer[0].effective_monitor_id == 20)
            #expect(projectionBuffer[0].has_projected_monitor_id == 1)
            #expect(projectionBuffer[0].projected_monitor_id == 20)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `set interaction monitor resolves valid target and preserves previous`() {
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_SET_INTERACTION_MONITOR),
            monitorId: 20,
            interactionMonitorId: 10
        )
        input.preserve_previous_interaction_monitor = 1
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                name: "Main",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                name: "Side",
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(monitorCapacity: 0, projectionCapacity: 0) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.has_interaction_monitor_id == 1)
            #expect(output.interaction_monitor_id == 20)
            #expect(output.has_previous_interaction_monitor_id == 1)
            #expect(output.previous_interaction_monitor_id == 10)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `set interaction monitor clears missing target`() {
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_SET_INTERACTION_MONITOR),
            monitorId: 99,
            interactionMonitorId: 10
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                name: "Main",
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(monitorCapacity: 0, projectionCapacity: 0) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.has_interaction_monitor_id == 0)
            #expect(output.has_previous_interaction_monitor_id == 0)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `apply session patch rejects invalid viewport kind`() {
        let workspaceId = makeWorkspaceSessionUUID(high: 60, low: 60)
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_APPLY_SESSION_PATCH),
            workspaceId: workspaceId
        )
        input.patch_viewport_kind = 99
        input.has_patch_viewport_state = 1

        let status: Int32 = withWorkspaceSessionOutput(monitorCapacity: 0, projectionCapacity: 0) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_INVALID_PATCH))
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `reconcile topology collapses monitors and reports removed cache`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 70, low: 70)
        let workspaceSide = makeWorkspaceSessionUUID(high: 71, low: 71)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY),
            interactionMonitorId: 20,
            previousInteractionMonitorId: 10
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            )
        ]
        let previousMonitors = [
            makeWorkspaceSessionPreviousMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                visibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            ),
            makeWorkspaceSessionPreviousMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                visibleWorkspaceId: workspaceSide,
                name: "Right",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSide,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutputBuffers(
            monitorCapacity: 1,
            projectionCapacity: 2,
            disconnectedCacheCapacity: 2
        ) { output, monitorBuffer, _, disconnectedCacheBuffer in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                previousMonitors: previousMonitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.refresh_restore_intents == 1)
            #expect(output.monitor_result_count == 1)
            #expect(monitorBuffer[0].monitor_id == 10)
            #expect(monitorBuffer[0].has_visible_workspace_id == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].visible_workspace_id, workspaceSide))
            #expect(monitorBuffer[0].has_previous_visible_workspace_id == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].previous_visible_workspace_id, workspaceMain))
            #expect(output.disconnected_cache_result_count == 1)
            #expect(disconnectedCacheBuffer[0].source_kind == UInt32(OMNIWM_RESTORE_CACHE_SOURCE_REMOVED_MONITOR))
            #expect(disconnectedCacheBuffer[0].source_index == 1)
            #expect(workspaceSessionUUIDEqual(disconnectedCacheBuffer[0].workspace_id, workspaceSide))
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `reconcile topology restores disconnected workspace to reappearing monitor`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 80, low: 80)
        let workspaceSide = makeWorkspaceSessionUUID(high: 81, low: 81)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY),
            interactionMonitorId: 10
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceSide,
                previousVisibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 30,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                name: "Replacement",
                strings: &strings
            )
        ]
        let previousMonitors = [
            makeWorkspaceSessionPreviousMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                visibleWorkspaceId: workspaceSide,
                previousVisibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            )
        ]
        let disconnectedCacheEntries = [
            makeWorkspaceSessionDisconnectedCacheEntry(
                workspaceId: workspaceSide,
                displayId: 20,
                anchorX: 1920,
                anchorY: 1080,
                name: "Right",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSide,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutputBuffers(
            monitorCapacity: 2,
            projectionCapacity: 2,
            disconnectedCacheCapacity: 1
        ) { output, monitorBuffer, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                previousMonitors: previousMonitors,
                workspaces: workspaces,
                disconnectedCacheEntries: disconnectedCacheEntries,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(output.refresh_restore_intents == 1)
            #expect(output.monitor_result_count == 2)
            #expect(monitorBuffer[0].monitor_id == 10)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].visible_workspace_id, workspaceMain))
            #expect(monitorBuffer[1].monitor_id == 30)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[1].visible_workspace_id, workspaceSide))
            #expect(output.disconnected_cache_result_count == 0)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `reconcile topology restores previously visible workspace when multiple workspaces share monitor`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 90, low: 90)
        let workspaceSideOne = makeWorkspaceSessionUUID(high: 91, low: 91)
        let workspaceSideTwo = makeWorkspaceSessionUUID(high: 92, low: 92)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY),
            interactionMonitorId: 10
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceSideTwo,
                previousVisibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            ),
            makeWorkspaceSessionMonitor(
                id: 30,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                name: "Replacement",
                strings: &strings
            )
        ]
        let previousMonitors = [
            makeWorkspaceSessionPreviousMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                visibleWorkspaceId: workspaceSideTwo,
                previousVisibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            )
        ]
        let disconnectedCacheEntries = [
            makeWorkspaceSessionDisconnectedCacheEntry(
                workspaceId: workspaceSideTwo,
                displayId: 20,
                anchorX: 1920,
                anchorY: 1080,
                name: "Right",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSideOne,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSideTwo,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutputBuffers(
            monitorCapacity: 2,
            projectionCapacity: 3,
            disconnectedCacheCapacity: 1
        ) { output, monitorBuffer, projectionBuffer, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                previousMonitors: previousMonitors,
                workspaces: workspaces,
                disconnectedCacheEntries: disconnectedCacheEntries,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY))
            #expect(monitorBuffer[0].monitor_id == 10)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].visible_workspace_id, workspaceMain))
            #expect(monitorBuffer[1].monitor_id == 30)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[1].visible_workspace_id, workspaceSideTwo))
            #expect(projectionBuffer[1].projected_monitor_id == 30)
            #expect(projectionBuffer[2].projected_monitor_id == 30)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `reconcile topology returns noop when equivalent and already consistent`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 100, low: 100)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY),
            interactionMonitorId: 10
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceMain,
                name: "Main",
                strings: &strings
            )
        ]
        let previousMonitors = [
            makeWorkspaceSessionPreviousMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                visibleWorkspaceId: workspaceMain,
                name: "Main",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutputBuffers(
            monitorCapacity: 1,
            projectionCapacity: 1,
            disconnectedCacheCapacity: 0
        ) { output, monitorBuffer, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                previousMonitors: previousMonitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.outcome == UInt32(OMNIWM_WORKSPACE_SESSION_OUTCOME_NOOP))
            #expect(output.refresh_restore_intents == 0)
            #expect(output.monitor_result_count == 1)
            #expect(workspaceSessionUUIDEqual(monitorBuffer[0].visible_workspace_id, workspaceMain))
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
    }

    @Test func `reconcile topology reports buffer too small for monitor results`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 110, low: 110)
        let workspaceSide = makeWorkspaceSessionUUID(high: 111, low: 111)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            )
        ]
        let previousMonitors = [
            makeWorkspaceSessionPreviousMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                visibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            ),
            makeWorkspaceSessionPreviousMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                visibleWorkspaceId: workspaceSide,
                name: "Right",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSide,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 0,
            projectionCapacity: 2,
            disconnectedCacheCapacity: 2
        ) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                previousMonitors: previousMonitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.monitor_result_count == 1)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL)
    }

    @Test func `reconcile topology reports buffer too small for workspace projections`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 120, low: 120)
        let workspaceSide = makeWorkspaceSessionUUID(high: 121, low: 121)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceMain,
                name: "Main",
                strings: &strings
            )
        ]
        let previousMonitors = [
            makeWorkspaceSessionPreviousMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                visibleWorkspaceId: workspaceMain,
                name: "Main",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSide,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 1,
            projectionCapacity: 1,
            disconnectedCacheCapacity: 0
        ) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                previousMonitors: previousMonitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.workspace_projection_count == 2)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL)
    }

    @Test func `reconcile topology reports buffer too small for disconnected cache results`() {
        let workspaceMain = makeWorkspaceSessionUUID(high: 130, low: 130)
        let workspaceSide = makeWorkspaceSessionUUID(high: 131, low: 131)
        var strings = WorkspaceSessionKernelStringTable()
        var input = makeWorkspaceSessionInput(
            operation: UInt32(OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY)
        )
        let monitors = [
            makeWorkspaceSessionMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                isMain: true,
                visibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            )
        ]
        let previousMonitors = [
            makeWorkspaceSessionPreviousMonitor(
                id: 10,
                minX: 0,
                maxY: 1080,
                anchorX: 0,
                anchorY: 1080,
                visibleWorkspaceId: workspaceMain,
                name: "Left",
                strings: &strings
            ),
            makeWorkspaceSessionPreviousMonitor(
                id: 20,
                minX: 1920,
                maxY: 1080,
                anchorX: 1920,
                anchorY: 1080,
                visibleWorkspaceId: workspaceSide,
                name: "Right",
                strings: &strings
            )
        ]
        let workspaces = [
            makeWorkspaceSessionWorkspace(
                id: workspaceMain,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN),
                strings: &strings
            ),
            makeWorkspaceSessionWorkspace(
                id: workspaceSide,
                assignmentKind: UInt32(OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY),
                strings: &strings
            )
        ]

        let status: Int32 = withWorkspaceSessionOutput(
            monitorCapacity: 1,
            projectionCapacity: 2,
            disconnectedCacheCapacity: 0
        ) { output, _, _ in
            let status = callWorkspaceSessionKernel(
                input: &input,
                monitors: monitors,
                previousMonitors: previousMonitors,
                workspaces: workspaces,
                stringBytes: strings.bytes,
                output: &output
            )
            #expect(output.disconnected_cache_result_count == 1)
            return status
        }

        #expect(status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL)
    }
}
