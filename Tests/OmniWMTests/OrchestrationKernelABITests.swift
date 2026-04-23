// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Foundation
import Testing

private func makeOrchestrationKernelUUID(high: UInt64, low: UInt64) -> omniwm_uuid {
    omniwm_uuid(high: high, low: low)
}

private func makeOrchestrationKernelToken(
    pid: Int32,
    windowId: Int64
) -> omniwm_window_token {
    omniwm_window_token(pid: pid, window_id: windowId)
}

private func makeOrchestrationKernelRefresh(
    cycleId: UInt64,
    kind: UInt32,
    reason: UInt32
) -> omniwm_orchestration_refresh {
    omniwm_orchestration_refresh(
        cycle_id: cycleId,
        kind: kind,
        reason: reason,
        affected_workspace_offset: 0,
        affected_workspace_count: 0,
        post_layout_attachment_offset: 0,
        post_layout_attachment_count: 0,
        window_removal_payload_offset: 0,
        window_removal_payload_count: 0,
        follow_up_refresh: omniwm_orchestration_follow_up_refresh(
            kind: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT),
            reason: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP),
            affected_workspace_offset: 0,
            affected_workspace_count: 0
        ),
        visibility_reason: 0,
        has_follow_up_refresh: 0,
        needs_visibility_reconciliation: 0,
        has_visibility_reason: 0,
        reserved0: 0
    )
}

private func makeOrchestrationKernelRequest(
    requestId: UInt64,
    token: omniwm_window_token,
    workspaceId: omniwm_uuid
) -> omniwm_orchestration_managed_request {
    omniwm_orchestration_managed_request(
        request_id: requestId,
        token: token,
        workspace_id: workspaceId,
        retry_count: 0,
        last_activation_source: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_FOCUSED_WINDOW_CHANGED),
        has_last_activation_source: 0,
        reserved0: 0,
        reserved1: 0,
        reserved2: 0
    )
}

private func withOrchestrationKernelOutput<Result>(
    actionCapacity: Int = 8,
    snapshotWorkspaceCapacity: Int = 8,
    snapshotAttachmentCapacity: Int = 8,
    snapshotPayloadCapacity: Int = 4,
    snapshotOldFrameCapacity: Int = 4,
    actionAttachmentCapacity: Int = 8,
    _ body: (
        inout omniwm_orchestration_step_output,
        UnsafeMutableBufferPointer<omniwm_orchestration_action>,
        UnsafeMutableBufferPointer<omniwm_uuid>,
        UnsafeMutableBufferPointer<UInt64>,
        UnsafeMutableBufferPointer<omniwm_orchestration_window_removal_payload>,
        UnsafeMutableBufferPointer<omniwm_orchestration_old_frame_record>,
        UnsafeMutableBufferPointer<UInt64>
    ) -> Result
) -> Result {
    var actions = Array(repeating: omniwm_orchestration_action(), count: actionCapacity)
    var snapshotWorkspaceIds = Array(repeating: omniwm_uuid(), count: snapshotWorkspaceCapacity)
    var snapshotAttachmentIds = Array(repeating: UInt64.zero, count: snapshotAttachmentCapacity)
    var snapshotPayloads = Array(
        repeating: omniwm_orchestration_window_removal_payload(),
        count: snapshotPayloadCapacity
    )
    var snapshotOldFrames = Array(
        repeating: omniwm_orchestration_old_frame_record(),
        count: snapshotOldFrameCapacity
    )
    var actionAttachmentIds = Array(repeating: UInt64.zero, count: actionAttachmentCapacity)

    return actions.withUnsafeMutableBufferPointer { actionBuffer in
        snapshotWorkspaceIds.withUnsafeMutableBufferPointer { workspaceBuffer in
            snapshotAttachmentIds.withUnsafeMutableBufferPointer { snapshotAttachmentBuffer in
                snapshotPayloads.withUnsafeMutableBufferPointer { payloadBuffer in
                    snapshotOldFrames.withUnsafeMutableBufferPointer { oldFrameBuffer in
                        actionAttachmentIds.withUnsafeMutableBufferPointer { actionAttachmentBuffer in
                            var output = omniwm_orchestration_step_output(
                                snapshot: .init(),
                                decision: .init(),
                                actions: actionBuffer.baseAddress,
                                action_capacity: actionBuffer.count,
                                action_count: 0,
                                snapshot_workspace_ids: workspaceBuffer.baseAddress,
                                snapshot_workspace_id_capacity: workspaceBuffer.count,
                                snapshot_workspace_id_count: 0,
                                snapshot_attachment_ids: snapshotAttachmentBuffer.baseAddress,
                                snapshot_attachment_id_capacity: snapshotAttachmentBuffer.count,
                                snapshot_attachment_id_count: 0,
                                snapshot_window_removal_payloads: payloadBuffer.baseAddress,
                                snapshot_window_removal_payload_capacity: payloadBuffer.count,
                                snapshot_window_removal_payload_count: 0,
                                snapshot_old_frame_records: oldFrameBuffer.baseAddress,
                                snapshot_old_frame_record_capacity: oldFrameBuffer.count,
                                snapshot_old_frame_record_count: 0,
                                action_attachment_ids: actionAttachmentBuffer.baseAddress,
                                action_attachment_id_capacity: actionAttachmentBuffer.count,
                                action_attachment_id_count: 0
                            )
                            return body(
                                &output,
                                actionBuffer,
                                workspaceBuffer,
                                snapshotAttachmentBuffer,
                                payloadBuffer,
                                oldFrameBuffer,
                                actionAttachmentBuffer
                            )
                        }
                    }
                }
            }
        }
    }
}

struct OrchestrationKernelABITests {
    @Test func `zig and swift agree on orchestration abi layout`() {
        var layout = omniwm_orchestration_abi_layout_info()

        #expect(
            omniwm_orchestration_get_abi_layout(&layout) == OMNIWM_KERNELS_STATUS_OK
        )
        #expect(omniwm_orchestration_get_abi_layout(nil) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)

        #expect(layout.step_input_size == MemoryLayout<omniwm_orchestration_step_input>.size)
        #expect(layout.step_input_alignment == MemoryLayout<omniwm_orchestration_step_input>.alignment)
        #expect(
            layout.step_input_snapshot_offset
                == MemoryLayout<omniwm_orchestration_step_input>.offset(of: \.snapshot)!
        )
        #expect(
            layout.step_input_event_offset
                == MemoryLayout<omniwm_orchestration_step_input>.offset(of: \.event)!
        )
        #expect(
            layout.step_input_workspace_ids_offset
                == MemoryLayout<omniwm_orchestration_step_input>.offset(of: \.workspace_ids)!
        )
        #expect(
            layout.step_input_window_removal_payloads_offset
                == MemoryLayout<omniwm_orchestration_step_input>.offset(of: \.window_removal_payloads)!
        )

        #expect(layout.step_output_size == MemoryLayout<omniwm_orchestration_step_output>.size)
        #expect(layout.step_output_alignment == MemoryLayout<omniwm_orchestration_step_output>.alignment)
        #expect(
            layout.step_output_snapshot_offset
                == MemoryLayout<omniwm_orchestration_step_output>.offset(of: \.snapshot)!
        )
        #expect(
            layout.step_output_decision_offset
                == MemoryLayout<omniwm_orchestration_step_output>.offset(of: \.decision)!
        )
        #expect(
            layout.step_output_actions_offset
                == MemoryLayout<omniwm_orchestration_step_output>.offset(of: \.actions)!
        )
        #expect(
            layout.step_output_action_count_offset
                == MemoryLayout<omniwm_orchestration_step_output>.offset(of: \.action_count)!
        )

        #expect(layout.snapshot_size == MemoryLayout<omniwm_orchestration_snapshot>.size)
        #expect(layout.snapshot_alignment == MemoryLayout<omniwm_orchestration_snapshot>.alignment)
        #expect(layout.event_size == MemoryLayout<omniwm_orchestration_event>.size)
        #expect(layout.event_alignment == MemoryLayout<omniwm_orchestration_event>.alignment)
        #expect(layout.refresh_size == MemoryLayout<omniwm_orchestration_refresh>.size)
        #expect(layout.refresh_alignment == MemoryLayout<omniwm_orchestration_refresh>.alignment)
        #expect(layout.managed_request_size == MemoryLayout<omniwm_orchestration_managed_request>.size)
        #expect(layout.managed_request_alignment == MemoryLayout<omniwm_orchestration_managed_request>.alignment)
        #expect(layout.action_size == MemoryLayout<omniwm_orchestration_action>.size)
        #expect(layout.action_alignment == MemoryLayout<omniwm_orchestration_action>.alignment)
    }

    @Test func `null pointers return invalid argument`() {
        var input = omniwm_orchestration_step_input()
        var output = omniwm_orchestration_step_output()

        #expect(
            omniwm_orchestration_step(nil, &output) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_orchestration_step(&input, nil) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
    }

    @Test func `invalid refresh discriminant returns invalid argument`() {
        var input = omniwm_orchestration_step_input()
        input.event.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_REFRESH_REQUESTED)
        input.event.refresh_request = omniwm_orchestration_refresh_request_event(
            refresh: makeOrchestrationKernelRefresh(
                cycleId: 1,
                kind: 999,
                reason: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP)
            ),
            should_drop_while_busy: 0,
            is_incremental_refresh_in_progress: 0,
            is_immediate_layout_in_progress: 0,
            has_active_animation_refreshes: 0
        )

        withOrchestrationKernelOutput(actionCapacity: 0) { output, _, _, _, _, _, _ in
            let status = withUnsafeMutablePointer(to: &output) { outputPointer in
                withUnsafeMutablePointer(to: &input) { inputPointer in
                    omniwm_orchestration_step(inputPointer, outputPointer)
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)
        }
    }

    @Test func `empty snapshot starts requested refresh at abi boundary`() {
        var input = omniwm_orchestration_step_input()
        input.event.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_REFRESH_REQUESTED)
        input.event.refresh_request = omniwm_orchestration_refresh_request_event(
            refresh: makeOrchestrationKernelRefresh(
                cycleId: 1,
                kind: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT),
                reason: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP)
            ),
            should_drop_while_busy: 0,
            is_incremental_refresh_in_progress: 0,
            is_immediate_layout_in_progress: 0,
            has_active_animation_refreshes: 0
        )

        withOrchestrationKernelOutput { output, actions, _, _, _, _, _ in
            let status = withUnsafeMutablePointer(to: &output) { outputPointer in
                withUnsafeMutablePointer(to: &input) { inputPointer in
                    omniwm_orchestration_step(inputPointer, outputPointer)
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(
                output.decision.kind
                    == UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_QUEUED)
            )
            #expect(output.decision.cycle_id == 1)
            #expect(output.snapshot.refresh.has_active_refresh != 0)
            #expect(output.snapshot.refresh.active_refresh.cycle_id == 1)
            #expect(
                output.snapshot.refresh.active_refresh.kind
                    == UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT)
            )
            #expect(output.action_count == 1)
            #expect(
                actions.prefix(Int(output.action_count)).first?.kind
                    == UInt32(OMNIWM_ORCHESTRATION_ACTION_START_REFRESH)
            )
        }
    }

    @Test func `focus request accepts and orders actions at abi boundary`() {
        let workspaceId = makeOrchestrationKernelUUID(high: 10, low: 11)
        let oldToken = makeOrchestrationKernelToken(pid: 77, windowId: 1)
        let newToken = makeOrchestrationKernelToken(pid: 77, windowId: 2)

        var input = omniwm_orchestration_step_input()
        input.snapshot.focus.next_managed_request_id = 9
        input.snapshot.focus.active_managed_request = makeOrchestrationKernelRequest(
            requestId: 4,
            token: oldToken,
            workspaceId: workspaceId
        )
        input.snapshot.focus.has_active_managed_request = 1
        input.snapshot.focus.pending_focused_token = oldToken
        input.snapshot.focus.pending_focused_workspace_id = workspaceId
        input.snapshot.focus.has_pending_focused_token = 1
        input.snapshot.focus.has_pending_focused_workspace_id = 1
        input.event.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_FOCUS_REQUESTED)
        input.event.focus_request = omniwm_orchestration_focus_request_event(
            token: newToken,
            workspace_id: workspaceId
        )

        withOrchestrationKernelOutput { output, actions, _, _, _, _, _ in
            let status = withUnsafeMutablePointer(to: &output) { outputPointer in
                withUnsafeMutablePointer(to: &input) { inputPointer in
                    omniwm_orchestration_step(inputPointer, outputPointer)
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(
                output.decision.kind
                    == UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_SUPERSEDED)
            )
            #expect(output.decision.request_id == 9)
            #expect(output.decision.secondary_request_id == 4)
            #expect(output.action_count == 3)
            #expect(
                actions.prefix(Int(output.action_count)).map(\.kind)
                    == [
                        UInt32(OMNIWM_ORCHESTRATION_ACTION_CLEAR_MANAGED_FOCUS_STATE),
                        UInt32(OMNIWM_ORCHESTRATION_ACTION_BEGIN_MANAGED_FOCUS_REQUEST),
                        UInt32(OMNIWM_ORCHESTRATION_ACTION_FRONT_MANAGED_WINDOW)
                    ]
            )
        }
    }

    @Test func `cancelled window removal restarts with preserved payloads`() {
        let workspaceId = makeOrchestrationKernelUUID(high: 20, low: 21)

        let attachments: [UInt64] = [5]
        let payloads = [
            omniwm_orchestration_window_removal_payload(
                workspace_id: workspaceId,
                removed_node_id: omniwm_uuid(),
                layout_kind: UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_NIRI),
                has_removed_node_id: 0,
                should_recover_focus: 1,
                reserved0: 0,
                reserved1: 0,
                old_frame_offset: 0,
                old_frame_count: 0
            )
        ]

        var input = omniwm_orchestration_step_input()
        input.snapshot.refresh.active_refresh = makeOrchestrationKernelRefresh(
            cycleId: 21,
            kind: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_WINDOW_REMOVAL),
            reason: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_DESTROYED)
        )
        input.snapshot.refresh.active_refresh.post_layout_attachment_offset = 0
        input.snapshot.refresh.active_refresh.post_layout_attachment_count = 1
        input.snapshot.refresh.active_refresh.window_removal_payload_offset = 0
        input.snapshot.refresh.active_refresh.window_removal_payload_count = 1
        input.snapshot.refresh.has_active_refresh = 1
        input.snapshot.refresh.pending_refresh = makeOrchestrationKernelRefresh(
            cycleId: 22,
            kind: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT),
            reason: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_TRANSITION)
        )
        input.snapshot.refresh.has_pending_refresh = 1
        input.event.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_REFRESH_COMPLETED)
        input.event.refresh_completion = omniwm_orchestration_refresh_completion_event(
            refresh: input.snapshot.refresh.active_refresh,
            did_complete: 0,
            did_execute_plan: 0,
            reserved0: 0,
            reserved1: 0
        )

        withOrchestrationKernelOutput { output, actions, _, _, _, _, _ in
            let status = attachments.withUnsafeBufferPointer { attachmentBuffer in
                payloads.withUnsafeBufferPointer { payloadBuffer in
                    input.attachment_ids = attachmentBuffer.baseAddress
                    input.attachment_id_count = attachmentBuffer.count
                    input.window_removal_payloads = payloadBuffer.baseAddress
                    input.window_removal_payload_count = payloadBuffer.count

                    return withUnsafeMutablePointer(to: &output) { outputPointer in
                        withUnsafeMutablePointer(to: &input) { inputPointer in
                            omniwm_orchestration_step(inputPointer, outputPointer)
                        }
                    }
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_OK)
            #expect(
                output.decision.kind
                    == UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_COMPLETED)
            )
            #expect(output.decision.cycle_id == 21)
            #expect(output.decision.did_complete == 0)
            #expect(output.snapshot.refresh.has_active_refresh != 0)
            #expect(
                output.snapshot.refresh.active_refresh.kind
                    == UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_WINDOW_REMOVAL)
            )
            #expect(output.snapshot.refresh.active_refresh.post_layout_attachment_count == 1)
            #expect(output.snapshot.refresh.active_refresh.window_removal_payload_count == 1)
            #expect(output.action_count == 1)
            #expect(
                actions.prefix(Int(output.action_count)).first?.kind
                    == UInt32(OMNIWM_ORCHESTRATION_ACTION_START_REFRESH)
            )
        }
    }

    @Test func `insufficient action capacity returns buffer too small`() {
        let workspaceId = makeOrchestrationKernelUUID(high: 30, low: 31)
        let oldToken = makeOrchestrationKernelToken(pid: 5, windowId: 1)
        let newToken = makeOrchestrationKernelToken(pid: 5, windowId: 2)

        var input = omniwm_orchestration_step_input()
        input.snapshot.focus.next_managed_request_id = 2
        input.snapshot.focus.active_managed_request = makeOrchestrationKernelRequest(
            requestId: 1,
            token: oldToken,
            workspaceId: workspaceId
        )
        input.snapshot.focus.has_active_managed_request = 1
        input.event.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_FOCUS_REQUESTED)
        input.event.focus_request = omniwm_orchestration_focus_request_event(
            token: newToken,
            workspace_id: workspaceId
        )

        withOrchestrationKernelOutput(actionCapacity: 2) { output, _, _, _, _, _, _ in
            let status = withUnsafeMutablePointer(to: &output) { outputPointer in
                withUnsafeMutablePointer(to: &input) { inputPointer in
                    omniwm_orchestration_step(inputPointer, outputPointer)
                }
            }

            #expect(status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL)
        }
    }
}
