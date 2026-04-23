// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import CoreGraphics
import Foundation

enum OrchestrationKernel {
    private struct EncodedInput {
        var raw = omniwm_orchestration_step_input()
        var workspaceIds: ContiguousArray<omniwm_uuid> = []
        var attachmentIds: ContiguousArray<UInt64> = []
        var windowRemovalPayloads: ContiguousArray<omniwm_orchestration_window_removal_payload> = []
        var oldFrameRecords: ContiguousArray<omniwm_orchestration_old_frame_record> = []
    }

    static func step(
        snapshot: OrchestrationSnapshot,
        event: OrchestrationEvent
    ) -> OrchestrationResult {
        var encoded = encode(snapshot: snapshot, event: event)

        var actions = ContiguousArray(repeating: omniwm_orchestration_action(), count: 16)
        var snapshotWorkspaceIds = ContiguousArray(repeating: zeroUUID(), count: max(encoded.workspaceIds.count + 4, 4))
        var snapshotAttachmentIds = ContiguousArray(repeating: UInt64.zero, count: max(encoded.attachmentIds.count + 4, 4))
        var snapshotPayloads = ContiguousArray(
            repeating: omniwm_orchestration_window_removal_payload(),
            count: max(encoded.windowRemovalPayloads.count + 2, 2)
        )
        var snapshotOldFrames = ContiguousArray(
            repeating: omniwm_orchestration_old_frame_record(),
            count: max(encoded.oldFrameRecords.count + 4, 4)
        )
        var actionAttachmentIds = ContiguousArray(repeating: UInt64.zero, count: max(encoded.attachmentIds.count + 4, 4))

        while true {
            let callResult = callKernel(
                encoded: &encoded,
                actions: &actions,
                snapshotWorkspaceIds: &snapshotWorkspaceIds,
                snapshotAttachmentIds: &snapshotAttachmentIds,
                snapshotPayloads: &snapshotPayloads,
                snapshotOldFrames: &snapshotOldFrames,
                actionAttachmentIds: &actionAttachmentIds
            )

            if callResult.status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL {
                growIfNeeded(&actions, requiredCount: callResult.output.action_count)
                growIfNeeded(&snapshotWorkspaceIds, requiredCount: callResult.output.snapshot_workspace_id_count)
                growIfNeeded(&snapshotAttachmentIds, requiredCount: callResult.output.snapshot_attachment_id_count)
                growIfNeeded(&snapshotPayloads, requiredCount: callResult.output.snapshot_window_removal_payload_count)
                growIfNeeded(&snapshotOldFrames, requiredCount: callResult.output.snapshot_old_frame_record_count)
                growIfNeeded(&actionAttachmentIds, requiredCount: callResult.output.action_attachment_id_count)
                continue
            }

            precondition(
                callResult.status == OMNIWM_KERNELS_STATUS_OK,
                "omniwm_orchestration_step returned \(callResult.status)"
            )

            let workspaceOutput = Array(snapshotWorkspaceIds.prefix(callResult.output.snapshot_workspace_id_count))
            let attachmentOutput = Array(snapshotAttachmentIds.prefix(callResult.output.snapshot_attachment_id_count))
            let payloadOutput = Array(snapshotPayloads.prefix(callResult.output.snapshot_window_removal_payload_count))
            let oldFrameOutput = Array(snapshotOldFrames.prefix(callResult.output.snapshot_old_frame_record_count))
            let actionAttachmentOutput = Array(actionAttachmentIds.prefix(callResult.output.action_attachment_id_count))
            let decodedSnapshot = decode(
                snapshot: callResult.output.snapshot,
                workspaceIds: workspaceOutput,
                attachmentIds: attachmentOutput,
                payloads: payloadOutput,
                oldFrames: oldFrameOutput
            )
            return OrchestrationResult(
                snapshot: decodedSnapshot,
                decision: decode(decision: callResult.output.decision),
                plan: .init(
                    actions: Array(actions.prefix(callResult.output.action_count)).map {
                        decode(action: $0, snapshot: decodedSnapshot, attachmentIds: actionAttachmentOutput)
                    }
                )
            )
        }
    }

    private static func callKernel(
        encoded: inout EncodedInput,
        actions: inout ContiguousArray<omniwm_orchestration_action>,
        snapshotWorkspaceIds: inout ContiguousArray<omniwm_uuid>,
        snapshotAttachmentIds: inout ContiguousArray<UInt64>,
        snapshotPayloads: inout ContiguousArray<omniwm_orchestration_window_removal_payload>,
        snapshotOldFrames: inout ContiguousArray<omniwm_orchestration_old_frame_record>,
        actionAttachmentIds: inout ContiguousArray<UInt64>
    ) -> (status: Int32, output: omniwm_orchestration_step_output) {
        encoded.workspaceIds.withUnsafeBufferPointer { workspaceInputBuffer in
            encoded.attachmentIds.withUnsafeBufferPointer { attachmentInputBuffer in
                encoded.windowRemovalPayloads.withUnsafeBufferPointer { payloadInputBuffer in
                    encoded.oldFrameRecords.withUnsafeBufferPointer { oldFrameInputBuffer in
                        actions.withUnsafeMutableBufferPointer { actionBuffer in
                            snapshotWorkspaceIds.withUnsafeMutableBufferPointer { snapshotWorkspaceBuffer in
                                snapshotAttachmentIds.withUnsafeMutableBufferPointer { snapshotAttachmentBuffer in
                                    snapshotPayloads.withUnsafeMutableBufferPointer { snapshotPayloadBuffer in
                                        snapshotOldFrames.withUnsafeMutableBufferPointer { snapshotOldFrameBuffer in
                                            actionAttachmentIds.withUnsafeMutableBufferPointer { actionAttachmentBuffer in
                                                encoded.raw.workspace_ids = workspaceInputBuffer.baseAddress
                                                encoded.raw.workspace_id_count = workspaceInputBuffer.count
                                                encoded.raw.attachment_ids = attachmentInputBuffer.baseAddress
                                                encoded.raw.attachment_id_count = attachmentInputBuffer.count
                                                encoded.raw.window_removal_payloads = payloadInputBuffer.baseAddress
                                                encoded.raw.window_removal_payload_count = payloadInputBuffer.count
                                                encoded.raw.old_frame_records = oldFrameInputBuffer.baseAddress
                                                encoded.raw.old_frame_record_count = oldFrameInputBuffer.count

                                                var output = omniwm_orchestration_step_output(
                                                    snapshot: .init(),
                                                    decision: .init(),
                                                    actions: actionBuffer.baseAddress,
                                                    action_capacity: actionBuffer.count,
                                                    action_count: 0,
                                                    snapshot_workspace_ids: snapshotWorkspaceBuffer.baseAddress,
                                                    snapshot_workspace_id_capacity: snapshotWorkspaceBuffer.count,
                                                    snapshot_workspace_id_count: 0,
                                                    snapshot_attachment_ids: snapshotAttachmentBuffer.baseAddress,
                                                    snapshot_attachment_id_capacity: snapshotAttachmentBuffer.count,
                                                    snapshot_attachment_id_count: 0,
                                                    snapshot_window_removal_payloads: snapshotPayloadBuffer.baseAddress,
                                                    snapshot_window_removal_payload_capacity: snapshotPayloadBuffer.count,
                                                    snapshot_window_removal_payload_count: 0,
                                                    snapshot_old_frame_records: snapshotOldFrameBuffer.baseAddress,
                                                    snapshot_old_frame_record_capacity: snapshotOldFrameBuffer.count,
                                                    snapshot_old_frame_record_count: 0,
                                                    action_attachment_ids: actionAttachmentBuffer.baseAddress,
                                                    action_attachment_id_capacity: actionAttachmentBuffer.count,
                                                    action_attachment_id_count: 0
                                                )
                                                let status = withUnsafeMutablePointer(to: &encoded.raw) { inputPointer in
                                                    withUnsafeMutablePointer(to: &output) { outputPointer in
                                                        omniwm_orchestration_step(inputPointer, outputPointer)
                                                    }
                                                }
                                                return (status, output)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func growIfNeeded<T>(
        _ buffer: inout ContiguousArray<T>,
        requiredCount: Int
    ) {
        guard requiredCount > buffer.count else { return }
        let nextCount = max(requiredCount, max(buffer.count, 1) * 2)
        buffer = ContiguousArray(repeating: buffer.first!, count: nextCount)
    }

    private static func encode(
        snapshot: OrchestrationSnapshot,
        event: OrchestrationEvent
    ) -> EncodedInput {
        var encoded = EncodedInput()
        encoded.raw.snapshot = encode(snapshot: snapshot, into: &encoded)
        encoded.raw.event = encode(event: event, into: &encoded)
        return encoded
    }

    private static func encode(
        snapshot: OrchestrationSnapshot,
        into encoded: inout EncodedInput
    ) -> omniwm_orchestration_snapshot {
        omniwm_orchestration_snapshot(
            refresh: .init(
                active_refresh: snapshot.refresh.activeRefresh.map { encode(refresh: $0, into: &encoded) } ?? .init(),
                pending_refresh: snapshot.refresh.pendingRefresh.map { encode(refresh: $0, into: &encoded) } ?? .init(),
                has_active_refresh: snapshot.refresh.activeRefresh == nil ? 0 : 1,
                has_pending_refresh: snapshot.refresh.pendingRefresh == nil ? 0 : 1,
                reserved0: 0,
                reserved1: 0
            ),
            focus: .init(
                next_managed_request_id: snapshot.focus.nextManagedRequestId,
                active_managed_request: snapshot.focus.activeManagedRequest.map(encode(request:)) ?? .init(),
                pending_focused_token: snapshot.focus.pendingFocusedToken.map(encode(token:)) ?? zeroToken(),
                pending_focused_workspace_id: snapshot.focus.pendingFocusedWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                has_active_managed_request: snapshot.focus.activeManagedRequest == nil ? 0 : 1,
                has_pending_focused_token: snapshot.focus.pendingFocusedToken == nil ? 0 : 1,
                has_pending_focused_workspace_id: snapshot.focus.pendingFocusedWorkspaceId == nil ? 0 : 1,
                is_non_managed_focus_active: snapshot.focus.isNonManagedFocusActive ? 1 : 0,
                is_app_fullscreen_active: snapshot.focus.isAppFullscreenActive ? 1 : 0,
                reserved0: 0,
                reserved1: 0,
                reserved2: 0
            )
        )
    }

    private static func encode(
        event: OrchestrationEvent,
        into encoded: inout EncodedInput
    ) -> omniwm_orchestration_event {
        var raw = omniwm_orchestration_event()
        switch event {
        case let .refreshRequested(event):
            raw.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_REFRESH_REQUESTED)
            raw.refresh_request = .init(
                refresh: encode(refresh: event.refresh, into: &encoded),
                should_drop_while_busy: event.shouldDropWhileBusy ? 1 : 0,
                is_incremental_refresh_in_progress: event.isIncrementalRefreshInProgress ? 1 : 0,
                is_immediate_layout_in_progress: event.isImmediateLayoutInProgress ? 1 : 0,
                has_active_animation_refreshes: event.hasActiveAnimationRefreshes ? 1 : 0
            )
        case let .refreshCompleted(event):
            raw.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_REFRESH_COMPLETED)
            raw.refresh_completion = .init(
                refresh: encode(refresh: event.refresh, into: &encoded),
                did_complete: event.didComplete ? 1 : 0,
                did_execute_plan: event.didExecutePlan ? 1 : 0,
                reserved0: 0,
                reserved1: 0
            )
        case let .focusRequested(event):
            raw.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_FOCUS_REQUESTED)
            raw.focus_request = .init(
                token: encode(token: event.token),
                workspace_id: encode(uuid: event.workspaceId)
            )
        case let .activationObserved(observation):
            raw.kind = UInt32(OMNIWM_ORCHESTRATION_EVENT_ACTIVATION_OBSERVED)
            raw.activation_observation = encode(observation: observation)
        }
        return raw
    }

    private static func encode(
        refresh: ScheduledRefresh,
        into encoded: inout EncodedInput
    ) -> omniwm_orchestration_refresh {
        let workspaceRange = append(refresh.affectedWorkspaceIds.sorted { $0.uuidString < $1.uuidString }.map(encode(uuid:)), to: &encoded.workspaceIds)
        let attachmentRange = append(refresh.postLayoutAttachmentIds, to: &encoded.attachmentIds)
        let payloadRange = append(refresh.windowRemovalPayloads.map { encode(payload: $0, into: &encoded) }, to: &encoded.windowRemovalPayloads)
        return omniwm_orchestration_refresh(
            cycle_id: refresh.cycleId,
            kind: rawRefreshKind(refresh.kind),
            reason: rawRefreshReason(refresh.reason),
            affected_workspace_offset: workspaceRange.offset,
            affected_workspace_count: workspaceRange.count,
            post_layout_attachment_offset: attachmentRange.offset,
            post_layout_attachment_count: attachmentRange.count,
            window_removal_payload_offset: payloadRange.offset,
            window_removal_payload_count: payloadRange.count,
            follow_up_refresh: refresh.followUpRefresh.map { encode(followUp: $0, into: &encoded) } ?? .init(),
            visibility_reason: refresh.visibilityReason.map(rawRefreshReason) ?? 0,
            has_follow_up_refresh: refresh.followUpRefresh == nil ? 0 : 1,
            needs_visibility_reconciliation: refresh.needsVisibilityReconciliation ? 1 : 0,
            has_visibility_reason: refresh.visibilityReason == nil ? 0 : 1,
            reserved0: 0
        )
    }

    private static func encode(
        followUp: FollowUpRefresh,
        into encoded: inout EncodedInput
    ) -> omniwm_orchestration_follow_up_refresh {
        let workspaceRange = append(followUp.affectedWorkspaceIds.sorted { $0.uuidString < $1.uuidString }.map(encode(uuid:)), to: &encoded.workspaceIds)
        return .init(
            kind: rawRefreshKind(followUp.kind),
            reason: rawRefreshReason(followUp.reason),
            affected_workspace_offset: workspaceRange.offset,
            affected_workspace_count: workspaceRange.count
        )
    }

    private static func encode(
        payload: WindowRemovalPayload,
        into encoded: inout EncodedInput
    ) -> omniwm_orchestration_window_removal_payload {
        let frames = payload.niriOldFrames
            .sorted {
                if $0.key.pid != $1.key.pid { return $0.key.pid < $1.key.pid }
                return $0.key.windowId < $1.key.windowId
            }
            .map { token, frame in
                omniwm_orchestration_old_frame_record(token: encode(token: token), frame: encode(rect: frame))
            }
        let frameRange = append(frames, to: &encoded.oldFrameRecords)
        return .init(
            workspace_id: encode(uuid: payload.workspaceId),
            removed_node_id: payload.removedNodeId.map { encode(uuid: $0.uuid) } ?? zeroUUID(),
            layout_kind: rawLayoutKind(payload.layoutType),
            has_removed_node_id: payload.removedNodeId == nil ? 0 : 1,
            should_recover_focus: payload.shouldRecoverFocus ? 1 : 0,
            reserved0: 0,
            reserved1: 0,
            old_frame_offset: frameRange.offset,
            old_frame_count: frameRange.count
        )
    }

    private static func encode(request: ManagedFocusRequest) -> omniwm_orchestration_managed_request {
        .init(
            request_id: request.requestId,
            token: encode(token: request.token),
            workspace_id: encode(uuid: request.workspaceId),
            retry_count: UInt32(request.retryCount),
            last_activation_source: request.lastActivationSource.map(rawActivationSource) ?? 0,
            has_last_activation_source: request.lastActivationSource == nil ? 0 : 1,
            reserved0: 0,
            reserved1: 0,
            reserved2: 0
        )
    }

    private static func encode(observation: ManagedActivationObservation) -> omniwm_orchestration_activation_observation {
        var raw = omniwm_orchestration_activation_observation()
        raw.source = rawActivationSource(observation.source)
        raw.origin = rawActivationOrigin(observation.origin)
        switch observation.match {
        case let .missingFocusedWindow(pid, fallbackFullscreen):
            raw.match_kind = UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_MISSING_FOCUSED_WINDOW)
            raw.pid = Int32(pid)
            raw.fallback_fullscreen = fallbackFullscreen ? 1 : 0
        case let .managed(token, workspaceId, monitorId, isWorkspaceActive, appFullscreen, requiresNativeFullscreenRestoreRelayout):
            raw.match_kind = UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_MANAGED)
            raw.pid = Int32(token.pid)
            raw.token = encode(token: token)
            raw.workspace_id = encode(uuid: workspaceId)
            raw.monitor_id = monitorId?.displayId ?? 0
            raw.has_token = 1
            raw.has_workspace_id = 1
            raw.has_monitor_id = monitorId == nil ? 0 : 1
            raw.is_workspace_active = isWorkspaceActive ? 1 : 0
            raw.app_fullscreen = appFullscreen ? 1 : 0
            raw.requires_native_fullscreen_restore_relayout = requiresNativeFullscreenRestoreRelayout ? 1 : 0
        case let .unmanaged(pid, token, appFullscreen, fallbackFullscreen):
            raw.match_kind = UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_UNMANAGED)
            raw.pid = Int32(pid)
            raw.token = encode(token: token)
            raw.has_token = 1
            raw.app_fullscreen = appFullscreen ? 1 : 0
            raw.fallback_fullscreen = fallbackFullscreen ? 1 : 0
        case let .ownedApplication(pid):
            raw.match_kind = UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_OWNED_APPLICATION)
            raw.pid = Int32(pid)
        }
        return raw
    }

    private static func decode(
        snapshot: omniwm_orchestration_snapshot,
        workspaceIds: [omniwm_uuid],
        attachmentIds: [UInt64],
        payloads: [omniwm_orchestration_window_removal_payload],
        oldFrames: [omniwm_orchestration_old_frame_record]
    ) -> OrchestrationSnapshot {
        .init(
            refresh: .init(
                activeRefresh: snapshot.refresh.has_active_refresh == 0
                    ? nil
                    : decode(refresh: snapshot.refresh.active_refresh, workspaceIds: workspaceIds, attachmentIds: attachmentIds, payloads: payloads, oldFrames: oldFrames),
                pendingRefresh: snapshot.refresh.has_pending_refresh == 0
                    ? nil
                    : decode(refresh: snapshot.refresh.pending_refresh, workspaceIds: workspaceIds, attachmentIds: attachmentIds, payloads: payloads, oldFrames: oldFrames)
            ),
            focus: .init(
                nextManagedRequestId: snapshot.focus.next_managed_request_id,
                activeManagedRequest: snapshot.focus.has_active_managed_request == 0
                    ? nil
                    : decode(request: snapshot.focus.active_managed_request),
                pendingFocusedToken: snapshot.focus.has_pending_focused_token == 0
                    ? nil
                    : decode(token: snapshot.focus.pending_focused_token),
                pendingFocusedWorkspaceId: snapshot.focus.has_pending_focused_workspace_id == 0
                    ? nil
                    : decode(uuid: snapshot.focus.pending_focused_workspace_id),
                isNonManagedFocusActive: snapshot.focus.is_non_managed_focus_active != 0,
                isAppFullscreenActive: snapshot.focus.is_app_fullscreen_active != 0
            )
        )
    }

    private static func decode(
        refresh: omniwm_orchestration_refresh,
        workspaceIds: [omniwm_uuid],
        attachmentIds: [UInt64],
        payloads: [omniwm_orchestration_window_removal_payload],
        oldFrames: [omniwm_orchestration_old_frame_record]
    ) -> ScheduledRefresh {
        var decoded = ScheduledRefresh(
            cycleId: refresh.cycle_id,
            kind: refreshKind(rawValue: refresh.kind),
            reason: refreshReason(rawValue: refresh.reason),
            affectedWorkspaceIds: Set(workspaceSlice(workspaceIds, offset: refresh.affected_workspace_offset, count: refresh.affected_workspace_count)),
            postLayoutAttachmentIds: attachmentSlice(attachmentIds, offset: refresh.post_layout_attachment_offset, count: refresh.post_layout_attachment_count)
        )
        decoded.windowRemovalPayloads = payloadSlice(payloads, offset: refresh.window_removal_payload_offset, count: refresh.window_removal_payload_count)
            .map { decode(payload: $0, oldFrames: oldFrames) }
        decoded.followUpRefresh = refresh.has_follow_up_refresh == 0
            ? nil
            : decode(followUp: refresh.follow_up_refresh, workspaceIds: workspaceIds)
        decoded.needsVisibilityReconciliation = refresh.needs_visibility_reconciliation != 0
        decoded.visibilityReason = refresh.has_visibility_reason == 0 ? nil : refreshReason(rawValue: refresh.visibility_reason)
        return decoded
    }

    private static func decode(
        followUp: omniwm_orchestration_follow_up_refresh,
        workspaceIds: [omniwm_uuid]
    ) -> FollowUpRefresh {
        .init(
            kind: refreshKind(rawValue: followUp.kind),
            reason: refreshReason(rawValue: followUp.reason),
            affectedWorkspaceIds: Set(workspaceSlice(workspaceIds, offset: followUp.affected_workspace_offset, count: followUp.affected_workspace_count))
        )
    }

    private static func decode(
        payload: omniwm_orchestration_window_removal_payload,
        oldFrames: [omniwm_orchestration_old_frame_record]
    ) -> WindowRemovalPayload {
        let frameRecords = oldFrameSlice(oldFrames, offset: payload.old_frame_offset, count: payload.old_frame_count)
        return .init(
            workspaceId: decode(uuid: payload.workspace_id),
            layoutType: layoutType(rawValue: payload.layout_kind),
            removedNodeId: payload.has_removed_node_id == 0 ? nil : NodeId(uuid: decode(uuid: payload.removed_node_id)),
            niriOldFrames: Dictionary(uniqueKeysWithValues: frameRecords.map { (decode(token: $0.token), decode(rect: $0.frame)) }),
            shouldRecoverFocus: payload.should_recover_focus != 0
        )
    }

    private static func decode(request: omniwm_orchestration_managed_request) -> ManagedFocusRequest {
        .init(
            requestId: request.request_id,
            token: decode(token: request.token),
            workspaceId: decode(uuid: request.workspace_id),
            retryCount: Int(request.retry_count),
            lastActivationSource: request.has_last_activation_source == 0 ? nil : activationSource(rawValue: request.last_activation_source)
        )
    }

    private static func decode(decision: omniwm_orchestration_decision) -> OrchestrationDecision {
        switch decision.kind {
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_DROPPED):
            return .refreshDropped(reason: refreshReason(rawValue: decision.refresh_reason))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_QUEUED):
            return .refreshQueued(cycleId: decision.cycle_id, kind: refreshKind(rawValue: decision.refresh_kind))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_MERGED):
            return .refreshMerged(cycleId: decision.cycle_id, kind: refreshKind(rawValue: decision.refresh_kind))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_SUPERSEDED):
            return .refreshSuperseded(activeCycleId: decision.cycle_id, pendingCycleId: decision.secondary_cycle_id)
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_REFRESH_COMPLETED):
            return .refreshCompleted(cycleId: decision.cycle_id, didComplete: decision.did_complete != 0)
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_ACCEPTED):
            return .focusRequestAccepted(requestId: decision.request_id, token: decode(token: decision.token))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_SUPERSEDED):
            return .focusRequestSuperseded(
                replacedRequestId: decision.secondary_request_id,
                requestId: decision.request_id,
                token: decode(token: decision.token)
            )
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_CONTINUED):
            return .focusRequestContinued(requestId: decision.request_id, reason: retryReason(rawValue: decision.retry_reason))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_CANCELLED):
            return .focusRequestCancelled(
                requestId: decision.request_id,
                token: decision.has_token == 0 ? nil : decode(token: decision.token)
            )
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_IGNORED):
            return .focusRequestIgnored(token: decode(token: decision.token))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_CONFIRMED):
            return .managedActivationConfirmed(token: decode(token: decision.token))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_DEFERRED):
            return .managedActivationDeferred(requestId: decision.request_id, reason: retryReason(rawValue: decision.retry_reason))
        case UInt32(OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_FALLBACK):
            return .managedActivationFallback(pid: pid_t(decision.pid))
        default:
            preconditionFailure("Unknown orchestration decision \(decision.kind)")
        }
    }

    private static func decode(
        action: omniwm_orchestration_action,
        snapshot: OrchestrationSnapshot,
        attachmentIds: [UInt64]
    ) -> OrchestrationPlan.Action {
        switch action.kind {
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_CANCEL_ACTIVE_REFRESH):
            return .cancelActiveRefresh(cycleId: action.cycle_id)
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_START_REFRESH):
            return .startRefresh(
                KernelContract.require(
                    [snapshot.refresh.activeRefresh, snapshot.refresh.pendingRefresh]
                        .compactMap { $0 }
                        .first { $0.cycleId == action.cycle_id },
                    "Missing refresh for start action cycle \(action.cycle_id)"
                )
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_RUN_POST_LAYOUT_ATTACHMENTS):
            return .runPostLayoutAttachments(attachmentSlice(attachmentIds, offset: action.attachment_offset, count: action.attachment_count))
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_DISCARD_POST_LAYOUT_ATTACHMENTS):
            return .discardPostLayoutAttachments(attachmentSlice(attachmentIds, offset: action.attachment_offset, count: action.attachment_count))
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_PERFORM_VISIBILITY_SIDE_EFFECTS):
            return .performVisibilitySideEffects
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_REQUEST_WORKSPACE_BAR_REFRESH):
            return .requestWorkspaceBarRefresh
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_BEGIN_MANAGED_FOCUS_REQUEST):
            return .beginManagedFocusRequest(
                requestId: action.request_id,
                token: decode(token: action.token),
                workspaceId: decode(uuid: action.workspace_id)
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_FRONT_MANAGED_WINDOW):
            return .frontManagedWindow(
                token: decode(token: action.token),
                workspaceId: decode(uuid: action.workspace_id)
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_CLEAR_MANAGED_FOCUS_STATE):
            return .clearManagedFocusState(
                requestId: action.request_id,
                token: decode(token: action.token),
                workspaceId: action.has_workspace_id == 0 ? nil : decode(uuid: action.workspace_id)
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_CONTINUE_MANAGED_FOCUS_REQUEST):
            return .continueManagedFocusRequest(
                requestId: action.request_id,
                reason: retryReason(rawValue: action.retry_reason),
                source: activationSource(rawValue: action.activation_source),
                origin: activationOrigin(rawValue: action.activation_origin)
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_CONFIRM_MANAGED_ACTIVATION):
            return .confirmManagedActivation(
                token: decode(token: action.token),
                workspaceId: decode(uuid: action.workspace_id),
                monitorId: action.has_monitor_id == 0 ? nil : Monitor.ID(displayId: action.monitor_id),
                isWorkspaceActive: action.is_workspace_active != 0,
                appFullscreen: action.app_fullscreen != 0,
                source: activationSource(rawValue: action.activation_source)
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_BEGIN_NATIVE_FULLSCREEN_RESTORE_ACTIVATION):
            return .beginNativeFullscreenRestoreActivation(
                token: decode(token: action.token),
                workspaceId: decode(uuid: action.workspace_id),
                monitorId: action.has_monitor_id == 0 ? nil : Monitor.ID(displayId: action.monitor_id),
                isWorkspaceActive: action.is_workspace_active != 0,
                source: activationSource(rawValue: action.activation_source)
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_ENTER_NON_MANAGED_FALLBACK):
            return .enterNonManagedFallback(
                pid: pid_t(action.pid),
                token: action.has_token == 0 ? nil : decode(token: action.token),
                appFullscreen: action.app_fullscreen != 0,
                source: activationSource(rawValue: action.activation_source)
            )
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_CANCEL_ACTIVATION_RETRY):
            return .cancelActivationRetry(requestId: action.request_id == 0 ? nil : action.request_id)
        case UInt32(OMNIWM_ORCHESTRATION_ACTION_ENTER_OWNED_APPLICATION_FALLBACK):
            return .enterOwnedApplicationFallback(
                pid: pid_t(action.pid),
                source: activationSource(rawValue: action.activation_source)
            )
        default:
            preconditionFailure("Unknown orchestration action \(action.kind)")
        }
    }

    private static func append<T>(
        _ values: [T],
        to buffer: inout ContiguousArray<T>
    ) -> (offset: Int, count: Int) {
        let offset = buffer.count
        buffer.append(contentsOf: values)
        return (offset, values.count)
    }

    private static func workspaceSlice(
        _ workspaceIds: [omniwm_uuid],
        offset: Int,
        count: Int
    ) -> [WorkspaceDescriptor.ID] {
        Array(workspaceIds[offset ..< offset + count]).map(decode(uuid:))
    }

    private static func attachmentSlice(
        _ attachmentIds: [UInt64],
        offset: Int,
        count: Int
    ) -> [RefreshAttachmentId] {
        Array(attachmentIds[offset ..< offset + count])
    }

    private static func payloadSlice(
        _ payloads: [omniwm_orchestration_window_removal_payload],
        offset: Int,
        count: Int
    ) -> [omniwm_orchestration_window_removal_payload] {
        Array(payloads[offset ..< offset + count])
    }

    private static func oldFrameSlice(
        _ oldFrames: [omniwm_orchestration_old_frame_record],
        offset: Int,
        count: Int
    ) -> [omniwm_orchestration_old_frame_record] {
        Array(oldFrames[offset ..< offset + count])
    }

    private static func rawRefreshKind(_ kind: ScheduledRefreshKind) -> UInt32 {
        switch kind {
        case .relayout: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT)
        case .immediateRelayout: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_IMMEDIATE_RELAYOUT)
        case .visibilityRefresh: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_VISIBILITY_REFRESH)
        case .windowRemoval: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_WINDOW_REMOVAL)
        case .fullRescan: UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_FULL_RESCAN)
        }
    }

    private static func refreshKind(rawValue: UInt32) -> ScheduledRefreshKind {
        switch rawValue {
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT): .relayout
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_IMMEDIATE_RELAYOUT): .immediateRelayout
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_VISIBILITY_REFRESH): .visibilityRefresh
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_WINDOW_REMOVAL): .windowRemoval
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_KIND_FULL_RESCAN): .fullRescan
        default: KernelContract.require(nil as ScheduledRefreshKind?, "Unknown orchestration refresh kind \(rawValue)")
        }
    }

    private static func rawRefreshReason(_ reason: RefreshReason) -> UInt32 {
        switch reason {
        case .startup: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP)
        case .appLaunched: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_LAUNCHED)
        case .unlock: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_UNLOCK)
        case .activeSpaceChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_ACTIVE_SPACE_CHANGED)
        case .monitorConfigurationChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_CONFIGURATION_CHANGED)
        case .appRulesChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_RULES_CHANGED)
        case .workspaceConfigChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_CONFIG_CHANGED)
        case .layoutConfigChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_CONFIG_CHANGED)
        case .monitorSettingsChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_SETTINGS_CHANGED)
        case .gapsChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_GAPS_CHANGED)
        case .workspaceTransition: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_TRANSITION)
        case .appActivationTransition: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_ACTIVATION_TRANSITION)
        case .workspaceLayoutToggled: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_LAYOUT_TOGGLED)
        case .appTerminated: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_TERMINATED)
        case .windowRuleReevaluation: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_RULE_REEVALUATION)
        case .layoutCommand: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_COMMAND)
        case .interactiveGesture: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_INTERACTIVE_GESTURE)
        case .axWindowCreated: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CREATED)
        case .axWindowChanged: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CHANGED)
        case .windowDestroyed: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_DESTROYED)
        case .appHidden: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_HIDDEN)
        case .appUnhidden: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_UNHIDDEN)
        case .overviewMutation: UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_OVERVIEW_MUTATION)
        }
    }

    private static func refreshReason(rawValue: UInt32) -> RefreshReason {
        switch rawValue {
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP): .startup
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_LAUNCHED): .appLaunched
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_UNLOCK): .unlock
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_ACTIVE_SPACE_CHANGED): .activeSpaceChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_CONFIGURATION_CHANGED): .monitorConfigurationChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_RULES_CHANGED): .appRulesChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_CONFIG_CHANGED): .workspaceConfigChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_CONFIG_CHANGED): .layoutConfigChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_SETTINGS_CHANGED): .monitorSettingsChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_GAPS_CHANGED): .gapsChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_TRANSITION): .workspaceTransition
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_ACTIVATION_TRANSITION): .appActivationTransition
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_LAYOUT_TOGGLED): .workspaceLayoutToggled
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_TERMINATED): .appTerminated
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_RULE_REEVALUATION): .windowRuleReevaluation
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_COMMAND): .layoutCommand
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_INTERACTIVE_GESTURE): .interactiveGesture
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CREATED): .axWindowCreated
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CHANGED): .axWindowChanged
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_DESTROYED): .windowDestroyed
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_HIDDEN): .appHidden
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_UNHIDDEN): .appUnhidden
        case UInt32(OMNIWM_ORCHESTRATION_REFRESH_REASON_OVERVIEW_MUTATION): .overviewMutation
        default: KernelContract.require(nil as RefreshReason?, "Unknown orchestration refresh reason \(rawValue)")
        }
    }

    private static func rawLayoutKind(_ layoutType: LayoutType) -> UInt32 {
        switch layoutType {
        case .defaultLayout: UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DEFAULT)
        case .niri: UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_NIRI)
        case .dwindle: UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DWINDLE)
        }
    }

    private static func layoutType(rawValue: UInt32) -> LayoutType {
        switch rawValue {
        case UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DEFAULT): .defaultLayout
        case UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_NIRI): .niri
        case UInt32(OMNIWM_ORCHESTRATION_LAYOUT_KIND_DWINDLE): .dwindle
        default: KernelContract.require(nil as LayoutType?, "Unknown orchestration layout kind \(rawValue)")
        }
    }

    private static func rawActivationSource(_ source: ActivationEventSource) -> UInt32 {
        switch source {
        case .focusedWindowChanged: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_FOCUSED_WINDOW_CHANGED)
        case .workspaceDidActivateApplication: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_WORKSPACE_DID_ACTIVATE_APPLICATION)
        case .cgsFrontAppChanged: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_CGS_FRONT_APP_CHANGED)
        }
    }

    private static func activationSource(rawValue: UInt32) -> ActivationEventSource {
        switch rawValue {
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_FOCUSED_WINDOW_CHANGED): .focusedWindowChanged
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_WORKSPACE_DID_ACTIVATE_APPLICATION): .workspaceDidActivateApplication
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_CGS_FRONT_APP_CHANGED): .cgsFrontAppChanged
        default: KernelContract.require(nil as ActivationEventSource?, "Unknown activation source \(rawValue)")
        }
    }

    private static func rawActivationOrigin(_ origin: ActivationCallOrigin) -> UInt32 {
        switch origin {
        case .external: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_EXTERNAL)
        case .probe: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_PROBE)
        case .retry: UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_RETRY)
        }
    }

    private static func activationOrigin(rawValue: UInt32) -> ActivationCallOrigin {
        switch rawValue {
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_EXTERNAL): .external
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_PROBE): .probe
        case UInt32(OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_RETRY): .retry
        default: KernelContract.require(nil as ActivationCallOrigin?, "Unknown activation origin \(rawValue)")
        }
    }

    private static func retryReason(rawValue: UInt32) -> ActivationRetryReason {
        switch rawValue {
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_MISSING_FOCUSED_WINDOW): .missingFocusedWindow
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_PENDING_FOCUS_MISMATCH): .pendingFocusMismatch
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_PENDING_FOCUS_UNMANAGED_TOKEN): .pendingFocusUnmanagedToken
        case UInt32(OMNIWM_ORCHESTRATION_RETRY_REASON_RETRY_EXHAUSTED): .retryExhausted
        default: KernelContract.require(nil as ActivationRetryReason?, "Unknown retry reason \(rawValue)")
        }
    }

    private static func encode(uuid: UUID) -> omniwm_uuid {
        let bytes = Array(withUnsafeBytes(of: uuid.uuid) { $0 })
        let high = bytes[0 ..< 8].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        let low = bytes[8 ..< 16].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
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

    private static func zeroUUID() -> omniwm_uuid {
        omniwm_uuid(high: 0, low: 0)
    }

    private static func encode(token: WindowToken) -> omniwm_window_token {
        omniwm_window_token(pid: token.pid, window_id: Int64(token.windowId))
    }

    private static func decode(token: omniwm_window_token) -> WindowToken {
        WindowToken(pid: token.pid, windowId: Int(token.window_id))
    }

    private static func zeroToken() -> omniwm_window_token {
        omniwm_window_token(pid: 0, window_id: 0)
    }

    private static func encode(rect: CGRect) -> omniwm_rect {
        omniwm_rect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    private static func decode(rect: omniwm_rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
