// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;
const kernel_buffer_too_small: i32 = 3;

const max_segments: usize = 32;
const max_abi_records: usize = 1 << 20;
const activation_retry_limit: u32 = 5;

const layout_default: u32 = 0;
const layout_niri: u32 = 1;
const layout_dwindle: u32 = 2;

const refresh_relayout: u32 = 0;
const refresh_immediate_relayout: u32 = 1;
const refresh_visibility: u32 = 2;
const refresh_window_removal: u32 = 3;
const refresh_full_rescan: u32 = 4;

const refresh_reason_overview_mutation: u32 = 22;

const event_refresh_requested: u32 = 0;
const event_refresh_completed: u32 = 1;
const event_focus_requested: u32 = 2;
const event_activation_observed: u32 = 3;

const activation_source_focused_window_changed: u32 = 0;
const activation_source_workspace_did_activate_application: u32 = 1;
const activation_source_cgs_front_app_changed: u32 = 2;

const activation_origin_external: u32 = 0;
const activation_origin_probe: u32 = 1;
const activation_origin_retry: u32 = 2;

const retry_missing_focused_window: u32 = 0;
const retry_pending_focus_mismatch: u32 = 1;
const retry_pending_focus_unmanaged_token: u32 = 2;
const retry_retry_exhausted: u32 = 3;

const disposition_matches_active: u32 = 0;
const disposition_conflicts_with_pending: u32 = 1;
const disposition_unrelated: u32 = 2;

const match_missing_focused_window: u32 = 0;
const match_managed: u32 = 1;
const match_unmanaged: u32 = 2;
const match_owned_application: u32 = 3;

const decision_refresh_dropped: u32 = 0;
const decision_refresh_queued: u32 = 1;
const decision_refresh_merged: u32 = 2;
const decision_refresh_superseded: u32 = 3;
const decision_refresh_completed: u32 = 4;
const decision_focus_request_accepted: u32 = 5;
const decision_focus_request_superseded: u32 = 6;
const decision_focus_request_continued: u32 = 7;
const decision_focus_request_cancelled: u32 = 8;
const decision_focus_request_ignored: u32 = 9;
const decision_managed_activation_confirmed: u32 = 10;
const decision_managed_activation_deferred: u32 = 11;
const decision_managed_activation_fallback: u32 = 12;

const action_cancel_active_refresh: u32 = 0;
const action_start_refresh: u32 = 1;
const action_run_post_layout_attachments: u32 = 2;
const action_discard_post_layout_attachments: u32 = 3;
const action_perform_visibility_side_effects: u32 = 4;
const action_request_workspace_bar_refresh: u32 = 5;
const action_begin_managed_focus_request: u32 = 6;
const action_front_managed_window: u32 = 7;
const action_clear_managed_focus_state: u32 = 8;
const action_continue_managed_focus_request: u32 = 9;
const action_confirm_managed_activation: u32 = 10;
const action_begin_native_fullscreen_restore_activation: u32 = 11;
const action_enter_non_managed_fallback: u32 = 12;
const action_cancel_activation_retry: u32 = 13;
const action_enter_owned_application_fallback: u32 = 14;

const UUID = extern struct {
    high: u64,
    low: u64,
};

const WindowToken = extern struct {
    pid: i32,
    window_id: i64,
};

const Rect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const OldFrameRecord = extern struct {
    token: WindowToken,
    frame: Rect,
};

const WindowRemovalPayload = extern struct {
    workspace_id: UUID,
    removed_node_id: UUID,
    layout_kind: u32,
    has_removed_node_id: u8,
    should_recover_focus: u8,
    reserved0: u8,
    reserved1: u8,
    old_frame_offset: usize,
    old_frame_count: usize,
};

const FollowUpRefresh = extern struct {
    kind: u32,
    reason: u32,
    affected_workspace_offset: usize,
    affected_workspace_count: usize,
};

const Refresh = extern struct {
    cycle_id: u64,
    kind: u32,
    reason: u32,
    affected_workspace_offset: usize,
    affected_workspace_count: usize,
    post_layout_attachment_offset: usize,
    post_layout_attachment_count: usize,
    window_removal_payload_offset: usize,
    window_removal_payload_count: usize,
    follow_up_refresh: FollowUpRefresh,
    visibility_reason: u32,
    has_follow_up_refresh: u8,
    needs_visibility_reconciliation: u8,
    has_visibility_reason: u8,
    reserved0: u8,
};

const ManagedRequest = extern struct {
    request_id: u64,
    token: WindowToken,
    workspace_id: UUID,
    retry_count: u32,
    last_activation_source: u32,
    has_last_activation_source: u8,
    reserved0: u8,
    reserved1: u8,
    reserved2: u8,
};

const RefreshSnapshot = extern struct {
    active_refresh: Refresh,
    pending_refresh: Refresh,
    has_active_refresh: u8,
    has_pending_refresh: u8,
    reserved0: u8,
    reserved1: u8,
};

const FocusSnapshot = extern struct {
    next_managed_request_id: u64,
    active_managed_request: ManagedRequest,
    pending_focused_token: WindowToken,
    pending_focused_workspace_id: UUID,
    has_active_managed_request: u8,
    has_pending_focused_token: u8,
    has_pending_focused_workspace_id: u8,
    is_non_managed_focus_active: u8,
    is_app_fullscreen_active: u8,
    reserved0: u8,
    reserved1: u8,
    reserved2: u8,
};

const Snapshot = extern struct {
    refresh: RefreshSnapshot,
    focus: FocusSnapshot,
};

const RefreshRequestEvent = extern struct {
    refresh: Refresh,
    should_drop_while_busy: u8,
    is_incremental_refresh_in_progress: u8,
    is_immediate_layout_in_progress: u8,
    has_active_animation_refreshes: u8,
};

const RefreshCompletionEvent = extern struct {
    refresh: Refresh,
    did_complete: u8,
    did_execute_plan: u8,
    reserved0: u8,
    reserved1: u8,
};

const FocusRequestEvent = extern struct {
    token: WindowToken,
    workspace_id: UUID,
};

const ActivationObservation = extern struct {
    source: u32,
    origin: u32,
    match_kind: u32,
    pid: i32,
    token: WindowToken,
    workspace_id: UUID,
    monitor_id: u32,
    has_token: u8,
    has_workspace_id: u8,
    has_monitor_id: u8,
    is_workspace_active: u8,
    app_fullscreen: u8,
    fallback_fullscreen: u8,
    requires_native_fullscreen_restore_relayout: u8,
    reserved0: u8,
    reserved1: u8,
};

const Event = extern struct {
    kind: u32,
    refresh_request: RefreshRequestEvent,
    refresh_completion: RefreshCompletionEvent,
    focus_request: FocusRequestEvent,
    activation_observation: ActivationObservation,
};

const Decision = extern struct {
    kind: u32,
    refresh_kind: u32,
    refresh_reason: u32,
    retry_reason: u32,
    cycle_id: u64,
    secondary_cycle_id: u64,
    request_id: u64,
    secondary_request_id: u64,
    pid: i32,
    token: WindowToken,
    has_token: u8,
    did_complete: u8,
    reserved0: u8,
    reserved1: u8,
};

const Action = extern struct {
    kind: u32,
    retry_reason: u32,
    activation_source: u32,
    activation_origin: u32,
    cycle_id: u64,
    request_id: u64,
    pid: i32,
    token: WindowToken,
    workspace_id: UUID,
    monitor_id: u32,
    attachment_offset: usize,
    attachment_count: usize,
    has_token: u8,
    has_workspace_id: u8,
    has_monitor_id: u8,
    is_workspace_active: u8,
    app_fullscreen: u8,
    reserved0: u8,
    reserved1: u8,
    reserved2: u8,
};

const StepInput = extern struct {
    snapshot: Snapshot,
    event: Event,
    workspace_ids: ?[*]const UUID,
    workspace_id_count: usize,
    attachment_ids: ?[*]const u64,
    attachment_id_count: usize,
    window_removal_payloads: ?[*]const WindowRemovalPayload,
    window_removal_payload_count: usize,
    old_frame_records: ?[*]const OldFrameRecord,
    old_frame_record_count: usize,
};

const StepOutput = extern struct {
    snapshot: Snapshot,
    decision: Decision,
    actions: ?[*]Action,
    action_capacity: usize,
    action_count: usize,
    snapshot_workspace_ids: ?[*]UUID,
    snapshot_workspace_id_capacity: usize,
    snapshot_workspace_id_count: usize,
    snapshot_attachment_ids: ?[*]u64,
    snapshot_attachment_id_capacity: usize,
    snapshot_attachment_id_count: usize,
    snapshot_window_removal_payloads: ?[*]WindowRemovalPayload,
    snapshot_window_removal_payload_capacity: usize,
    snapshot_window_removal_payload_count: usize,
    snapshot_old_frame_records: ?[*]OldFrameRecord,
    snapshot_old_frame_record_capacity: usize,
    snapshot_old_frame_record_count: usize,
    action_attachment_ids: ?[*]u64,
    action_attachment_id_capacity: usize,
    action_attachment_id_count: usize,
};

const AbiLayoutInfo = extern struct {
    step_input_size: usize,
    step_input_alignment: usize,
    step_input_snapshot_offset: usize,
    step_input_event_offset: usize,
    step_input_workspace_ids_offset: usize,
    step_input_window_removal_payloads_offset: usize,
    step_output_size: usize,
    step_output_alignment: usize,
    step_output_snapshot_offset: usize,
    step_output_decision_offset: usize,
    step_output_actions_offset: usize,
    step_output_action_count_offset: usize,
    snapshot_size: usize,
    snapshot_alignment: usize,
    event_size: usize,
    event_alignment: usize,
    refresh_size: usize,
    refresh_alignment: usize,
    managed_request_size: usize,
    managed_request_alignment: usize,
    action_size: usize,
    action_alignment: usize,
};

export fn omniwm_orchestration_get_abi_layout(out_layout: ?*AbiLayoutInfo) callconv(.c) i32 {
    const layout = out_layout orelse return kernel_invalid_argument;
    layout.* = .{
        .step_input_size = @sizeOf(StepInput),
        .step_input_alignment = @alignOf(StepInput),
        .step_input_snapshot_offset = @offsetOf(StepInput, "snapshot"),
        .step_input_event_offset = @offsetOf(StepInput, "event"),
        .step_input_workspace_ids_offset = @offsetOf(StepInput, "workspace_ids"),
        .step_input_window_removal_payloads_offset = @offsetOf(StepInput, "window_removal_payloads"),
        .step_output_size = @sizeOf(StepOutput),
        .step_output_alignment = @alignOf(StepOutput),
        .step_output_snapshot_offset = @offsetOf(StepOutput, "snapshot"),
        .step_output_decision_offset = @offsetOf(StepOutput, "decision"),
        .step_output_actions_offset = @offsetOf(StepOutput, "actions"),
        .step_output_action_count_offset = @offsetOf(StepOutput, "action_count"),
        .snapshot_size = @sizeOf(Snapshot),
        .snapshot_alignment = @alignOf(Snapshot),
        .event_size = @sizeOf(Event),
        .event_alignment = @alignOf(Event),
        .refresh_size = @sizeOf(Refresh),
        .refresh_alignment = @alignOf(Refresh),
        .managed_request_size = @sizeOf(ManagedRequest),
        .managed_request_alignment = @alignOf(ManagedRequest),
        .action_size = @sizeOf(Action),
        .action_alignment = @alignOf(Action),
    };
    return kernel_ok;
}

fn zeroUUID() UUID {
    return .{ .high = 0, .low = 0 };
}

fn zeroToken() WindowToken {
    return .{ .pid = 0, .window_id = 0 };
}

fn uuidEqual(lhs: UUID, rhs: UUID) bool {
    return lhs.high == rhs.high and lhs.low == rhs.low;
}

fn tokenEqual(lhs: WindowToken, rhs: WindowToken) bool {
    return lhs.pid == rhs.pid and lhs.window_id == rhs.window_id;
}

fn isFlag(value: u8) bool {
    return value == 0 or value == 1;
}

fn isRefreshKind(value: u32) bool {
    return value == refresh_relayout or
        value == refresh_immediate_relayout or
        value == refresh_visibility or
        value == refresh_window_removal or
        value == refresh_full_rescan;
}

fn isRefreshReason(value: u32) bool {
    return value <= refresh_reason_overview_mutation;
}

fn isLayoutKind(value: u32) bool {
    return value == layout_default or
        value == layout_niri or
        value == layout_dwindle;
}

fn isEventKind(value: u32) bool {
    return value == event_refresh_requested or
        value == event_refresh_completed or
        value == event_focus_requested or
        value == event_activation_observed;
}

fn isActivationSource(value: u32) bool {
    return value == activation_source_focused_window_changed or
        value == activation_source_workspace_did_activate_application or
        value == activation_source_cgs_front_app_changed;
}

fn isActivationOrigin(value: u32) bool {
    return value == activation_origin_external or
        value == activation_origin_probe or
        value == activation_origin_retry;
}

fn isActivationMatchKind(value: u32) bool {
    return value == match_missing_focused_window or
        value == match_managed or
        value == match_unmanaged or
        value == match_owned_application;
}

fn validateCountPointer(comptime T: type, ptr: ?[*]const T, count: usize) bool {
    return count <= max_abi_records and (count == 0 or ptr != null);
}

fn validateMutableCountPointer(comptime T: type, ptr: ?[*]T, count: usize) bool {
    return count <= max_abi_records and (count == 0 or ptr != null);
}

fn resolveRange(offset: usize, count: usize, total: usize) !struct { start: usize, end: usize } {
    const end = std.math.add(usize, offset, count) catch return error.InvalidArgument;
    if (end > total) {
        return error.InvalidArgument;
    }
    return .{ .start = offset, .end = end };
}

fn resolveOptionalSlice(comptime T: type, ptr: ?[*]const T, count: usize) []const T {
    if (count == 0) {
        return &[_]T{};
    }
    return ptr.?[0..count];
}

fn resolveOptionalMutableSlice(comptime T: type, ptr: ?[*]T, count: usize) []T {
    if (count == 0) {
        return &[_]T{};
    }
    return ptr.?[0..count];
}

fn SegmentList(comptime T: type) type {
    return struct {
        const Self = @This();

        segments: [max_segments][]const T = undefined,
        len: usize = 0,

        fn append(self: *Self, slice: []const T) !void {
            if (slice.len == 0) {
                return;
            }
            if (self.len > 0) {
                const previous = self.segments[self.len - 1];
                const previous_bytes = std.math.mul(usize, previous.len, @sizeOf(T)) catch return error.InvalidArgument;
                const previous_end = std.math.add(usize, @intFromPtr(previous.ptr), previous_bytes) catch return error.InvalidArgument;
                if (previous_end == @intFromPtr(slice.ptr)) {
                    const combined_len = std.math.add(usize, previous.len, slice.len) catch return error.InvalidArgument;
                    self.segments[self.len - 1] = previous.ptr[0..combined_len];
                    return;
                }
            }
            if (self.len >= max_segments) {
                return error.InvalidArgument;
            }
            self.segments[self.len] = slice;
            self.len += 1;
        }

        fn appendAll(self: *Self, other: *const Self) !void {
            var index: usize = 0;
            while (index < other.len) : (index += 1) {
                try self.append(other.segments[index]);
            }
        }

        fn prependAll(self: *Self, other: *const Self) !void {
            if (other.len == 0) {
                return;
            }
            if (self.len + other.len > max_segments) {
                return error.InvalidArgument;
            }
            var index = self.len;
            while (index > 0) : (index -= 1) {
                self.segments[index + other.len - 1] = self.segments[index - 1];
            }
            index = 0;
            while (index < other.len) : (index += 1) {
                self.segments[index] = other.segments[index];
            }
            self.len += other.len;
        }
    };
}

const UUIDSegments = SegmentList(UUID);
const AttachmentSegments = SegmentList(u64);
const PayloadSegments = SegmentList(WindowRemovalPayload);

const FollowUpValue = struct {
    kind: u32 = refresh_relayout,
    reason: u32 = 0,
    workspace_segments: UUIDSegments = .{},
};

const RefreshValue = struct {
    cycle_id: u64 = 0,
    kind: u32 = refresh_relayout,
    reason: u32 = 0,
    workspace_segments: UUIDSegments = .{},
    attachment_segments: AttachmentSegments = .{},
    payload_segments: PayloadSegments = .{},
    follow_up: FollowUpValue = .{},
    has_follow_up: bool = false,
    needs_visibility_reconciliation: bool = false,
    visibility_reason: u32 = 0,
    has_visibility_reason: bool = false,
};

const ManagedRequestValue = struct {
    request_id: u64 = 0,
    token: WindowToken = zeroToken(),
    workspace_id: UUID = zeroUUID(),
    retry_count: u32 = 0,
    last_activation_source: u32 = activation_source_focused_window_changed,
    has_last_activation_source: bool = false,
};

const FocusValue = struct {
    next_managed_request_id: u64 = 1,
    active_managed_request: ManagedRequestValue = .{},
    has_active_managed_request: bool = false,
    pending_focused_token: WindowToken = zeroToken(),
    has_pending_focused_token: bool = false,
    pending_focused_workspace_id: UUID = zeroUUID(),
    has_pending_focused_workspace_id: bool = false,
    is_non_managed_focus_active: bool = false,
    is_app_fullscreen_active: bool = false,
};

const SnapshotValue = struct {
    active_refresh: RefreshValue = .{},
    has_active_refresh: bool = false,
    pending_refresh: RefreshValue = .{},
    has_pending_refresh: bool = false,
    focus: FocusValue = .{},
};

const RefreshRequestValue = struct {
    refresh: RefreshValue,
    should_drop_while_busy: bool,
    is_incremental_refresh_in_progress: bool,
    is_immediate_layout_in_progress: bool,
    has_active_animation_refreshes: bool,
};

const RefreshCompletionValue = struct {
    refresh: RefreshValue,
    did_complete: bool,
    did_execute_plan: bool,
};

const FocusRequestValue = struct {
    token: WindowToken,
    workspace_id: UUID,
};

const ActivationObservationValue = struct {
    source: u32,
    origin: u32,
    match_kind: u32,
    pid: i32,
    token: WindowToken,
    has_token: bool,
    workspace_id: UUID,
    has_workspace_id: bool,
    monitor_id: u32,
    has_monitor_id: bool,
    is_workspace_active: bool,
    app_fullscreen: bool,
    fallback_fullscreen: bool,
    requires_native_fullscreen_restore_relayout: bool,
};

const DecisionValue = struct {
    kind: u32,
    refresh_kind: u32 = refresh_relayout,
    refresh_reason: u32 = 0,
    retry_reason: u32 = retry_missing_focused_window,
    cycle_id: u64 = 0,
    secondary_cycle_id: u64 = 0,
    request_id: u64 = 0,
    secondary_request_id: u64 = 0,
    pid: i32 = 0,
    token: WindowToken = zeroToken(),
    has_token: bool = false,
    did_complete: bool = false,
};

const ActionValue = struct {
    kind: u32,
    retry_reason: u32 = retry_missing_focused_window,
    activation_source: u32 = activation_source_focused_window_changed,
    activation_origin: u32 = activation_origin_external,
    cycle_id: u64 = 0,
    request_id: u64 = 0,
    pid: i32 = 0,
    token: WindowToken = zeroToken(),
    workspace_id: UUID = zeroUUID(),
    monitor_id: u32 = 0,
    attachment_segments: AttachmentSegments = .{},
    has_token: bool = false,
    has_workspace_id: bool = false,
    has_monitor_id: bool = false,
    is_workspace_active: bool = false,
    app_fullscreen: bool = false,
};

const InputContext = struct {
    workspace_ids: []const UUID,
    attachment_ids: []const u64,
    payloads: []const WindowRemovalPayload,
    old_frames: []const OldFrameRecord,

    fn init(raw: *const StepInput) !InputContext {
        if (!validateCountPointer(UUID, raw.workspace_ids, raw.workspace_id_count) or
            !validateCountPointer(u64, raw.attachment_ids, raw.attachment_id_count) or
            !validateCountPointer(WindowRemovalPayload, raw.window_removal_payloads, raw.window_removal_payload_count) or
            !validateCountPointer(OldFrameRecord, raw.old_frame_records, raw.old_frame_record_count))
        {
            return error.InvalidArgument;
        }

        return .{
            .workspace_ids = resolveOptionalSlice(UUID, raw.workspace_ids, raw.workspace_id_count),
            .attachment_ids = resolveOptionalSlice(u64, raw.attachment_ids, raw.attachment_id_count),
            .payloads = resolveOptionalSlice(WindowRemovalPayload, raw.window_removal_payloads, raw.window_removal_payload_count),
            .old_frames = resolveOptionalSlice(OldFrameRecord, raw.old_frame_records, raw.old_frame_record_count),
        };
    }

    fn workspaceSlice(self: *const InputContext, offset: usize, count: usize) ![]const UUID {
        const range = try resolveRange(offset, count, self.workspace_ids.len);
        return self.workspace_ids[range.start..range.end];
    }

    fn attachmentSlice(self: *const InputContext, offset: usize, count: usize) ![]const u64 {
        const range = try resolveRange(offset, count, self.attachment_ids.len);
        return self.attachment_ids[range.start..range.end];
    }

    fn payloadSlice(self: *const InputContext, offset: usize, count: usize) ![]const WindowRemovalPayload {
        const range = try resolveRange(offset, count, self.payloads.len);
        return self.payloads[range.start..range.end];
    }

    fn oldFrameSlice(self: *const InputContext, offset: usize, count: usize) ![]const OldFrameRecord {
        const range = try resolveRange(offset, count, self.old_frames.len);
        return self.old_frames[range.start..range.end];
    }
};

const OutputWriter = struct {
    raw: *StepOutput,
    snapshot_workspace_ids: []UUID,
    snapshot_attachment_ids: []u64,
    snapshot_payloads: []WindowRemovalPayload,
    snapshot_old_frames: []OldFrameRecord,
    actions: []Action,
    action_attachment_ids: []u64,

    fn init(raw: *StepOutput) !OutputWriter {
        if (!validateMutableCountPointer(Action, raw.actions, raw.action_capacity) or
            !validateMutableCountPointer(UUID, raw.snapshot_workspace_ids, raw.snapshot_workspace_id_capacity) or
            !validateMutableCountPointer(u64, raw.snapshot_attachment_ids, raw.snapshot_attachment_id_capacity) or
            !validateMutableCountPointer(WindowRemovalPayload, raw.snapshot_window_removal_payloads, raw.snapshot_window_removal_payload_capacity) or
            !validateMutableCountPointer(OldFrameRecord, raw.snapshot_old_frame_records, raw.snapshot_old_frame_record_capacity) or
            !validateMutableCountPointer(u64, raw.action_attachment_ids, raw.action_attachment_id_capacity))
        {
            return error.InvalidArgument;
        }

        raw.action_count = 0;
        raw.snapshot_workspace_id_count = 0;
        raw.snapshot_attachment_id_count = 0;
        raw.snapshot_window_removal_payload_count = 0;
        raw.snapshot_old_frame_record_count = 0;
        raw.action_attachment_id_count = 0;
        raw.snapshot = std.mem.zeroes(Snapshot);
        raw.decision = std.mem.zeroes(Decision);

        return .{
            .raw = raw,
            .snapshot_workspace_ids = resolveOptionalMutableSlice(UUID, raw.snapshot_workspace_ids, raw.snapshot_workspace_id_capacity),
            .snapshot_attachment_ids = resolveOptionalMutableSlice(u64, raw.snapshot_attachment_ids, raw.snapshot_attachment_id_capacity),
            .snapshot_payloads = resolveOptionalMutableSlice(WindowRemovalPayload, raw.snapshot_window_removal_payloads, raw.snapshot_window_removal_payload_capacity),
            .snapshot_old_frames = resolveOptionalMutableSlice(OldFrameRecord, raw.snapshot_old_frame_records, raw.snapshot_old_frame_record_capacity),
            .actions = resolveOptionalMutableSlice(Action, raw.actions, raw.action_capacity),
            .action_attachment_ids = resolveOptionalMutableSlice(u64, raw.action_attachment_ids, raw.action_attachment_id_capacity),
        };
    }

    fn appendSnapshotWorkspace(self: *OutputWriter, value: UUID) !void {
        if (self.raw.snapshot_workspace_id_count >= self.snapshot_workspace_ids.len) {
            return error.BufferTooSmall;
        }
        self.snapshot_workspace_ids[self.raw.snapshot_workspace_id_count] = value;
        self.raw.snapshot_workspace_id_count += 1;
    }

    fn appendSnapshotAttachment(self: *OutputWriter, value: u64) !void {
        if (self.raw.snapshot_attachment_id_count >= self.snapshot_attachment_ids.len) {
            return error.BufferTooSmall;
        }
        self.snapshot_attachment_ids[self.raw.snapshot_attachment_id_count] = value;
        self.raw.snapshot_attachment_id_count += 1;
    }

    fn appendSnapshotPayload(self: *OutputWriter, value: WindowRemovalPayload) !void {
        if (self.raw.snapshot_window_removal_payload_count >= self.snapshot_payloads.len) {
            return error.BufferTooSmall;
        }
        self.snapshot_payloads[self.raw.snapshot_window_removal_payload_count] = value;
        self.raw.snapshot_window_removal_payload_count += 1;
    }

    fn appendSnapshotOldFrame(self: *OutputWriter, value: OldFrameRecord) !void {
        if (self.raw.snapshot_old_frame_record_count >= self.snapshot_old_frames.len) {
            return error.BufferTooSmall;
        }
        self.snapshot_old_frames[self.raw.snapshot_old_frame_record_count] = value;
        self.raw.snapshot_old_frame_record_count += 1;
    }

    fn appendActionRecord(self: *OutputWriter, value: Action) !void {
        if (self.raw.action_count >= self.actions.len) {
            return error.BufferTooSmall;
        }
        self.actions[self.raw.action_count] = value;
        self.raw.action_count += 1;
    }

    fn appendActionAttachment(self: *OutputWriter, value: u64) !void {
        if (self.raw.action_attachment_id_count >= self.action_attachment_ids.len) {
            return error.BufferTooSmall;
        }
        self.action_attachment_ids[self.raw.action_attachment_id_count] = value;
        self.raw.action_attachment_id_count += 1;
    }

    fn serializeUniqueWorkspaces(self: *OutputWriter, segments: *const UUIDSegments) !struct { offset: usize, count: usize } {
        const start = self.raw.snapshot_workspace_id_count;
        var segment_index: usize = 0;
        while (segment_index < segments.len) : (segment_index += 1) {
            for (segments.segments[segment_index]) |workspace_id| {
                var exists = false;
                var existing_index = start;
                while (existing_index < self.raw.snapshot_workspace_id_count) : (existing_index += 1) {
                    if (uuidEqual(self.snapshot_workspace_ids[existing_index], workspace_id)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    try self.appendSnapshotWorkspace(workspace_id);
                }
            }
        }
        return .{
            .offset = start,
            .count = self.raw.snapshot_workspace_id_count - start,
        };
    }

    fn serializeAttachments(self: *OutputWriter, segments: *const AttachmentSegments) !struct { offset: usize, count: usize } {
        const start = self.raw.snapshot_attachment_id_count;
        var segment_index: usize = 0;
        while (segment_index < segments.len) : (segment_index += 1) {
            for (segments.segments[segment_index]) |attachment_id| {
                try self.appendSnapshotAttachment(attachment_id);
            }
        }
        return .{
            .offset = start,
            .count = self.raw.snapshot_attachment_id_count - start,
        };
    }

    fn serializeActionAttachments(self: *OutputWriter, segments: *const AttachmentSegments) !struct { offset: usize, count: usize } {
        const start = self.raw.action_attachment_id_count;
        var segment_index: usize = 0;
        while (segment_index < segments.len) : (segment_index += 1) {
            for (segments.segments[segment_index]) |attachment_id| {
                try self.appendActionAttachment(attachment_id);
            }
        }
        return .{
            .offset = start,
            .count = self.raw.action_attachment_id_count - start,
        };
    }

    fn serializePayloads(
        self: *OutputWriter,
        input_ctx: *const InputContext,
        segments: *const PayloadSegments,
    ) !struct { offset: usize, count: usize } {
        const start = self.raw.snapshot_window_removal_payload_count;
        var segment_index: usize = 0;
        while (segment_index < segments.len) : (segment_index += 1) {
            for (segments.segments[segment_index]) |payload| {
                const old_frames = try input_ctx.oldFrameSlice(payload.old_frame_offset, payload.old_frame_count);
                const old_frame_start = self.raw.snapshot_old_frame_record_count;
                for (old_frames) |old_frame| {
                    try self.appendSnapshotOldFrame(old_frame);
                }
                var copied = payload;
                copied.old_frame_offset = old_frame_start;
                copied.old_frame_count = self.raw.snapshot_old_frame_record_count - old_frame_start;
                try self.appendSnapshotPayload(copied);
            }
        }
        return .{
            .offset = start,
            .count = self.raw.snapshot_window_removal_payload_count - start,
        };
    }

    fn serializeFollowUp(self: *OutputWriter, follow_up: *const FollowUpValue) !FollowUpRefresh {
        const workspaces = try self.serializeUniqueWorkspaces(&follow_up.workspace_segments);
        return .{
            .kind = follow_up.kind,
            .reason = follow_up.reason,
            .affected_workspace_offset = workspaces.offset,
            .affected_workspace_count = workspaces.count,
        };
    }

    fn serializeRefresh(
        self: *OutputWriter,
        input_ctx: *const InputContext,
        refresh: *const RefreshValue,
    ) !Refresh {
        const workspaces = try self.serializeUniqueWorkspaces(&refresh.workspace_segments);
        const attachments = try self.serializeAttachments(&refresh.attachment_segments);
        const payloads = try self.serializePayloads(input_ctx, &refresh.payload_segments);
        var raw_follow_up = std.mem.zeroes(FollowUpRefresh);
        if (refresh.has_follow_up) {
            raw_follow_up = try self.serializeFollowUp(&refresh.follow_up);
        }

        return .{
            .cycle_id = refresh.cycle_id,
            .kind = refresh.kind,
            .reason = refresh.reason,
            .affected_workspace_offset = workspaces.offset,
            .affected_workspace_count = workspaces.count,
            .post_layout_attachment_offset = attachments.offset,
            .post_layout_attachment_count = attachments.count,
            .window_removal_payload_offset = payloads.offset,
            .window_removal_payload_count = payloads.count,
            .follow_up_refresh = raw_follow_up,
            .visibility_reason = refresh.visibility_reason,
            .has_follow_up_refresh = @intFromBool(refresh.has_follow_up),
            .needs_visibility_reconciliation = @intFromBool(refresh.needs_visibility_reconciliation),
            .has_visibility_reason = @intFromBool(refresh.has_visibility_reason),
            .reserved0 = 0,
        };
    }

    fn serializeSnapshot(
        self: *OutputWriter,
        input_ctx: *const InputContext,
        snapshot: *const SnapshotValue,
    ) !Snapshot {
        var raw = std.mem.zeroes(Snapshot);
        raw.focus.next_managed_request_id = snapshot.focus.next_managed_request_id;
        raw.focus.active_managed_request = encodeManagedRequest(snapshot.focus.active_managed_request);
        raw.focus.pending_focused_token = snapshot.focus.pending_focused_token;
        raw.focus.pending_focused_workspace_id = snapshot.focus.pending_focused_workspace_id;
        raw.focus.has_active_managed_request = @intFromBool(snapshot.focus.has_active_managed_request);
        raw.focus.has_pending_focused_token = @intFromBool(snapshot.focus.has_pending_focused_token);
        raw.focus.has_pending_focused_workspace_id = @intFromBool(snapshot.focus.has_pending_focused_workspace_id);
        raw.focus.is_non_managed_focus_active = @intFromBool(snapshot.focus.is_non_managed_focus_active);
        raw.focus.is_app_fullscreen_active = @intFromBool(snapshot.focus.is_app_fullscreen_active);

        if (snapshot.has_active_refresh) {
            raw.refresh.active_refresh = try self.serializeRefresh(input_ctx, &snapshot.active_refresh);
        }
        if (snapshot.has_pending_refresh) {
            raw.refresh.pending_refresh = try self.serializeRefresh(input_ctx, &snapshot.pending_refresh);
        }
        raw.refresh.has_active_refresh = @intFromBool(snapshot.has_active_refresh);
        raw.refresh.has_pending_refresh = @intFromBool(snapshot.has_pending_refresh);
        return raw;
    }

    fn serializeDecision(self: *OutputWriter, decision: DecisionValue) void {
        self.raw.decision.kind = decision.kind;
        self.raw.decision.refresh_kind = decision.refresh_kind;
        self.raw.decision.refresh_reason = decision.refresh_reason;
        self.raw.decision.retry_reason = decision.retry_reason;
        self.raw.decision.cycle_id = decision.cycle_id;
        self.raw.decision.secondary_cycle_id = decision.secondary_cycle_id;
        self.raw.decision.request_id = decision.request_id;
        self.raw.decision.secondary_request_id = decision.secondary_request_id;
        self.raw.decision.pid = decision.pid;
        self.raw.decision.token = decision.token;
        self.raw.decision.has_token = @intFromBool(decision.has_token);
        self.raw.decision.did_complete = @intFromBool(decision.did_complete);
        self.raw.decision.reserved0 = 0;
        self.raw.decision.reserved1 = 0;
    }
};

const ActionWriter = struct {
    writer: *OutputWriter,

    fn append(self: *ActionWriter, source: ActionValue) !void {
        var attachment_offset: usize = 0;
        var attachment_count: usize = 0;
        if (source.kind == action_run_post_layout_attachments or source.kind == action_discard_post_layout_attachments) {
            const serialized = try self.writer.serializeActionAttachments(&source.attachment_segments);
            attachment_offset = serialized.offset;
            attachment_count = serialized.count;
        }

        try self.writer.appendActionRecord(.{
            .kind = source.kind,
            .retry_reason = source.retry_reason,
            .activation_source = source.activation_source,
            .activation_origin = source.activation_origin,
            .cycle_id = source.cycle_id,
            .request_id = source.request_id,
            .pid = source.pid,
            .token = source.token,
            .workspace_id = source.workspace_id,
            .monitor_id = source.monitor_id,
            .attachment_offset = attachment_offset,
            .attachment_count = attachment_count,
            .has_token = @intFromBool(source.has_token),
            .has_workspace_id = @intFromBool(source.has_workspace_id),
            .has_monitor_id = @intFromBool(source.has_monitor_id),
            .is_workspace_active = @intFromBool(source.is_workspace_active),
            .app_fullscreen = @intFromBool(source.app_fullscreen),
            .reserved0 = 0,
            .reserved1 = 0,
            .reserved2 = 0,
        });
    }
};

fn encodeManagedRequest(value: ManagedRequestValue) ManagedRequest {
    return .{
        .request_id = value.request_id,
        .token = value.token,
        .workspace_id = value.workspace_id,
        .retry_count = value.retry_count,
        .last_activation_source = value.last_activation_source,
        .has_last_activation_source = @intFromBool(value.has_last_activation_source),
        .reserved0 = 0,
        .reserved1 = 0,
        .reserved2 = 0,
    };
}

fn validateWindowRemovalPayload(raw: WindowRemovalPayload, input_ctx: *const InputContext) !void {
    if (!isLayoutKind(raw.layout_kind) or
        !isFlag(raw.has_removed_node_id) or
        !isFlag(raw.should_recover_focus))
    {
        return error.InvalidArgument;
    }
    _ = try input_ctx.oldFrameSlice(raw.old_frame_offset, raw.old_frame_count);
}

fn decodeManagedRequest(raw: ManagedRequest) !ManagedRequestValue {
    if (!isFlag(raw.has_last_activation_source) or raw.retry_count > activation_retry_limit) {
        return error.InvalidArgument;
    }
    if (raw.has_last_activation_source != 0 and !isActivationSource(raw.last_activation_source)) {
        return error.InvalidArgument;
    }

    return .{
        .request_id = raw.request_id,
        .token = raw.token,
        .workspace_id = raw.workspace_id,
        .retry_count = raw.retry_count,
        .last_activation_source = raw.last_activation_source,
        .has_last_activation_source = raw.has_last_activation_source != 0,
    };
}

fn decodeRefresh(raw: Refresh, input_ctx: *const InputContext) !RefreshValue {
    if (!isRefreshKind(raw.kind) or
        !isRefreshReason(raw.reason) or
        !isFlag(raw.has_follow_up_refresh) or
        !isFlag(raw.needs_visibility_reconciliation) or
        !isFlag(raw.has_visibility_reason))
    {
        return error.InvalidArgument;
    }
    if (raw.has_visibility_reason != 0 and !isRefreshReason(raw.visibility_reason)) {
        return error.InvalidArgument;
    }

    var value = RefreshValue{
        .cycle_id = raw.cycle_id,
        .kind = raw.kind,
        .reason = raw.reason,
        .needs_visibility_reconciliation = raw.needs_visibility_reconciliation != 0,
        .visibility_reason = raw.visibility_reason,
        .has_visibility_reason = raw.has_visibility_reason != 0,
    };
    try value.workspace_segments.append(try input_ctx.workspaceSlice(raw.affected_workspace_offset, raw.affected_workspace_count));
    try value.attachment_segments.append(try input_ctx.attachmentSlice(raw.post_layout_attachment_offset, raw.post_layout_attachment_count));
    const payloads = try input_ctx.payloadSlice(raw.window_removal_payload_offset, raw.window_removal_payload_count);
    for (payloads) |payload| {
        try validateWindowRemovalPayload(payload, input_ctx);
    }
    try value.payload_segments.append(payloads);
    if (raw.has_follow_up_refresh != 0) {
        if (!isRefreshKind(raw.follow_up_refresh.kind) or !isRefreshReason(raw.follow_up_refresh.reason)) {
            return error.InvalidArgument;
        }
        value.has_follow_up = true;
        value.follow_up.kind = raw.follow_up_refresh.kind;
        value.follow_up.reason = raw.follow_up_refresh.reason;
        try value.follow_up.workspace_segments.append(
            try input_ctx.workspaceSlice(
                raw.follow_up_refresh.affected_workspace_offset,
                raw.follow_up_refresh.affected_workspace_count,
            ),
        );
    }
    return value;
}

fn decodeSnapshot(raw: Snapshot, input_ctx: *const InputContext) !SnapshotValue {
    if (!isFlag(raw.refresh.has_active_refresh) or
        !isFlag(raw.refresh.has_pending_refresh) or
        !isFlag(raw.focus.has_active_managed_request) or
        !isFlag(raw.focus.has_pending_focused_token) or
        !isFlag(raw.focus.has_pending_focused_workspace_id) or
        !isFlag(raw.focus.is_non_managed_focus_active) or
        !isFlag(raw.focus.is_app_fullscreen_active))
    {
        return error.InvalidArgument;
    }
    if ((raw.focus.has_pending_focused_token != 0) != (raw.focus.has_pending_focused_workspace_id != 0)) {
        return error.InvalidArgument;
    }

    var snapshot = SnapshotValue{
        .focus = .{
            .next_managed_request_id = raw.focus.next_managed_request_id,
            .active_managed_request = try decodeManagedRequest(raw.focus.active_managed_request),
            .has_active_managed_request = raw.focus.has_active_managed_request != 0,
            .pending_focused_token = raw.focus.pending_focused_token,
            .has_pending_focused_token = raw.focus.has_pending_focused_token != 0,
            .pending_focused_workspace_id = raw.focus.pending_focused_workspace_id,
            .has_pending_focused_workspace_id = raw.focus.has_pending_focused_workspace_id != 0,
            .is_non_managed_focus_active = raw.focus.is_non_managed_focus_active != 0,
            .is_app_fullscreen_active = raw.focus.is_app_fullscreen_active != 0,
        },
        .has_active_refresh = raw.refresh.has_active_refresh != 0,
        .has_pending_refresh = raw.refresh.has_pending_refresh != 0,
    };

    if (snapshot.has_active_refresh) {
        snapshot.active_refresh = try decodeRefresh(raw.refresh.active_refresh, input_ctx);
    }
    if (snapshot.has_pending_refresh) {
        snapshot.pending_refresh = try decodeRefresh(raw.refresh.pending_refresh, input_ctx);
    }
    return snapshot;
}

fn makeDecision(kind: u32) DecisionValue {
    return .{ .kind = kind };
}

fn makeAction(kind: u32) ActionValue {
    return .{ .kind = kind };
}

fn copyManagedRequestWithTokenWorkspace(request_id: u64, token: WindowToken, workspace_id: UUID) ManagedRequestValue {
    return .{
        .request_id = request_id,
        .token = token,
        .workspace_id = workspace_id,
        .retry_count = 0,
        .last_activation_source = activation_source_focused_window_changed,
        .has_last_activation_source = false,
    };
}

fn clearActiveManagedRequest(focus: *FocusValue) void {
    focus.active_managed_request = .{};
    focus.has_active_managed_request = false;
}

fn clearPendingFocus(focus: *FocusValue) void {
    focus.pending_focused_token = zeroToken();
    focus.pending_focused_workspace_id = zeroUUID();
    focus.has_pending_focused_token = false;
    focus.has_pending_focused_workspace_id = false;
}

fn activationDisposition(focus: *const FocusValue, observation: ActivationObservationValue) u32 {
    if (!focus.has_active_managed_request) {
        return disposition_unrelated;
    }

    const request = focus.active_managed_request;
    if (request.token.pid != observation.pid) {
        return disposition_conflicts_with_pending;
    }
    if (!observation.has_token) {
        return disposition_matches_active;
    }
    return if (tokenEqual(request.token, observation.token))
        disposition_matches_active
    else
        disposition_conflicts_with_pending;
}

fn shouldHonorObservedFocusOverPendingRequest(observation: ActivationObservationValue) bool {
    return observation.source == activation_source_focused_window_changed and
        observation.origin == activation_origin_external;
}

fn shouldHandleManagedActivationWithoutPendingRequest(observation: ActivationObservationValue) bool {
    if (observation.is_workspace_active) {
        return true;
    }

    return switch (observation.source) {
        activation_source_focused_window_changed => true,
        activation_source_workspace_did_activate_application, activation_source_cgs_front_app_changed => observation.origin == activation_origin_external,
        else => false,
    };
}

fn nextRetryCount(request: ManagedRequestValue, source: u32, retry_limit: u32) u32 {
    if (request.has_last_activation_source and request.last_activation_source == source) {
        if (request.retry_count >= retry_limit) {
            return retry_limit + 1;
        }
        return request.retry_count + 1;
    }
    return 1;
}

fn deferManagedActivation(
    snapshot: *SnapshotValue,
    retry_reason: u32,
    source: u32,
    origin: u32,
    retry_limit: u32,
    actions: *ActionWriter,
    decision_out: *DecisionValue,
) !void {
    const request = snapshot.focus.active_managed_request;
    const request_id = request.request_id;
    const request_token = request.token;
    const request_workspace_id = request.workspace_id;
    const next_attempt = nextRetryCount(request, source, retry_limit);
    if (next_attempt > retry_limit) {
        if (origin == activation_origin_probe) {
            try appendContinueManagedFocusRequest(
                actions,
                request_id,
                retry_reason,
                source,
                origin,
            );
            var decision = makeDecision(decision_managed_activation_deferred);
            decision.request_id = request_id;
            decision.retry_reason = retry_reason;
            decision_out.* = decision;
            return;
        }

        try appendClearManagedFocusState(
            actions,
            .{
                .request_id = request_id,
                .token = request_token,
                .workspace_id = request_workspace_id,
                .retry_count = request.retry_count,
                .last_activation_source = request.last_activation_source,
                .has_last_activation_source = request.has_last_activation_source,
            },
        );
        clearActiveManagedRequest(&snapshot.focus);
        clearPendingFocus(&snapshot.focus);
        var decision = makeDecision(decision_focus_request_cancelled);
        decision.request_id = request_id;
        decision.retry_reason = retry_retry_exhausted;
        decision.token = request_token;
        decision.has_token = true;
        decision_out.* = decision;
        return;
    }

    var updated_request = request;
    updated_request.retry_count = next_attempt;
    updated_request.last_activation_source = source;
    updated_request.has_last_activation_source = true;
    snapshot.focus.active_managed_request = updated_request;
    snapshot.focus.has_active_managed_request = true;
    try appendContinueManagedFocusRequest(
        actions,
        updated_request.request_id,
        retry_reason,
        source,
        origin,
    );
    var decision = makeDecision(decision_managed_activation_deferred);
    decision.request_id = updated_request.request_id;
    decision.retry_reason = retry_reason;
    decision_out.* = decision;
}

fn appendClearManagedFocusState(actions: *ActionWriter, request: ManagedRequestValue) !void {
    var action = makeAction(action_clear_managed_focus_state);
    action.request_id = request.request_id;
    action.token = request.token;
    action.workspace_id = request.workspace_id;
    action.has_token = true;
    action.has_workspace_id = true;
    try actions.append(action);
}

fn appendBeginManagedFocusRequest(actions: *ActionWriter, request_id: u64, token: WindowToken, workspace_id: UUID) !void {
    var action = makeAction(action_begin_managed_focus_request);
    action.request_id = request_id;
    action.token = token;
    action.workspace_id = workspace_id;
    action.has_token = true;
    action.has_workspace_id = true;
    try actions.append(action);
}

fn appendFrontManagedWindow(actions: *ActionWriter, token: WindowToken, workspace_id: UUID) !void {
    var action = makeAction(action_front_managed_window);
    action.token = token;
    action.workspace_id = workspace_id;
    action.has_token = true;
    action.has_workspace_id = true;
    try actions.append(action);
}

fn appendContinueManagedFocusRequest(
    actions: *ActionWriter,
    request_id: u64,
    reason: u32,
    source: u32,
    origin: u32,
) !void {
    var action = makeAction(action_continue_managed_focus_request);
    action.request_id = request_id;
    action.retry_reason = reason;
    action.activation_source = source;
    action.activation_origin = origin;
    try actions.append(action);
}

fn appendConfirmManagedActivation(
    actions: *ActionWriter,
    token: WindowToken,
    workspace_id: UUID,
    monitor_id: u32,
    has_monitor_id: bool,
    is_workspace_active: bool,
    app_fullscreen: bool,
    source: u32,
) !void {
    var action = makeAction(action_confirm_managed_activation);
    action.token = token;
    action.workspace_id = workspace_id;
    action.monitor_id = monitor_id;
    action.activation_source = source;
    action.has_token = true;
    action.has_workspace_id = true;
    action.has_monitor_id = has_monitor_id;
    action.is_workspace_active = is_workspace_active;
    action.app_fullscreen = app_fullscreen;
    try actions.append(action);
}

fn appendBeginNativeFullscreenRestoreActivation(
    actions: *ActionWriter,
    token: WindowToken,
    workspace_id: UUID,
    monitor_id: u32,
    has_monitor_id: bool,
    is_workspace_active: bool,
    source: u32,
) !void {
    var action = makeAction(action_begin_native_fullscreen_restore_activation);
    action.token = token;
    action.workspace_id = workspace_id;
    action.monitor_id = monitor_id;
    action.activation_source = source;
    action.has_token = true;
    action.has_workspace_id = true;
    action.has_monitor_id = has_monitor_id;
    action.is_workspace_active = is_workspace_active;
    try actions.append(action);
}

fn appendEnterNonManagedFallback(
    actions: *ActionWriter,
    pid: i32,
    token: ?WindowToken,
    app_fullscreen: bool,
    source: u32,
) !void {
    var action = makeAction(action_enter_non_managed_fallback);
    action.pid = pid;
    action.activation_source = source;
    action.app_fullscreen = app_fullscreen;
    if (token) |resolved| {
        action.token = resolved;
        action.has_token = true;
    }
    try actions.append(action);
}

fn appendCancelActivationRetry(actions: *ActionWriter, request_id: ?u64) !void {
    var action = makeAction(action_cancel_activation_retry);
    if (request_id) |resolved| {
        action.request_id = resolved;
    }
    try actions.append(action);
}

fn appendEnterOwnedApplicationFallback(actions: *ActionWriter, pid: i32, source: u32) !void {
    var action = makeAction(action_enter_owned_application_fallback);
    action.pid = pid;
    action.activation_source = source;
    try actions.append(action);
}

fn appendCancelActiveRefresh(actions: *ActionWriter, cycle_id: u64) !void {
    var action = makeAction(action_cancel_active_refresh);
    action.cycle_id = cycle_id;
    try actions.append(action);
}

fn appendStartRefresh(actions: *ActionWriter, cycle_id: u64) !void {
    var action = makeAction(action_start_refresh);
    action.cycle_id = cycle_id;
    try actions.append(action);
}

fn appendAttachmentAction(actions: *ActionWriter, kind: u32, segments: *const AttachmentSegments) !void {
    var action = makeAction(kind);
    action.attachment_segments = segments.*;
    try actions.append(action);
}

fn appendSimpleAction(actions: *ActionWriter, kind: u32) !void {
    try actions.append(makeAction(kind));
}

fn mergeAbsorbedVisibility(into: *RefreshValue, incoming: *const RefreshValue) void {
    if (incoming.kind == refresh_visibility) {
        into.needs_visibility_reconciliation = true;
        into.visibility_reason = incoming.reason;
        into.has_visibility_reason = true;
        return;
    }
    if (incoming.needs_visibility_reconciliation) {
        into.needs_visibility_reconciliation = true;
        if (incoming.has_visibility_reason) {
            into.visibility_reason = incoming.visibility_reason;
            into.has_visibility_reason = true;
        }
    }
}

fn mergeFollowUpRefresh(existing: ?FollowUpValue, incoming: ?FollowUpValue) !?FollowUpValue {
    if (existing == null and incoming == null) {
        return null;
    }
    if (existing == null) {
        return incoming.?;
    }
    if (incoming == null) {
        return existing.?;
    }

    const existing_value = existing.?;
    const incoming_value = incoming.?;
    var merged = incoming_value;
    try merged.workspace_segments.appendAll(&existing_value.workspace_segments);

    if (existing_value.kind == refresh_immediate_relayout or incoming_value.kind == refresh_immediate_relayout) {
        if (incoming_value.kind == refresh_immediate_relayout) {
            return merged;
        }
        var kept = existing_value;
        try kept.workspace_segments.appendAll(&incoming_value.workspace_segments);
        return kept;
    }

    return merged;
}

fn mergeFollowUp(into: *RefreshValue, kind: u32, reason: u32, affected: *const UUIDSegments) !void {
    const incoming = FollowUpValue{
        .kind = kind,
        .reason = reason,
        .workspace_segments = affected.*,
    };
    const merged = try mergeFollowUpRefresh(if (into.has_follow_up) into.follow_up else null, incoming);
    if (merged) |resolved| {
        into.follow_up = resolved;
        into.has_follow_up = true;
    } else {
        into.has_follow_up = false;
    }
}

fn absorbIntoActiveFullRescan(active_refresh: *const RefreshValue, refresh: *const RefreshValue) !RefreshValue {
    var updated = active_refresh.*;
    try updated.attachment_segments.appendAll(&refresh.attachment_segments);
    mergeAbsorbedVisibility(&updated, refresh);
    return updated;
}

fn mergePendingRefresh(pending_refresh: ?RefreshValue, incoming: *const RefreshValue) !RefreshValue {
    if (pending_refresh == null) {
        return incoming.*;
    }

    var pending = pending_refresh.?;
    const existing_workspace_segments = pending.workspace_segments;
    switch (pending.kind) {
        refresh_full_rescan => switch (incoming.kind) {
            refresh_full_rescan => {
                pending.reason = incoming.reason;
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            else => {
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
        },
        refresh_visibility => switch (incoming.kind) {
            refresh_full_rescan, refresh_window_removal, refresh_immediate_relayout, refresh_relayout => {
                var upgraded = incoming.*;
                upgraded.cycle_id = pending.cycle_id;
                try upgraded.attachment_segments.appendAll(&pending.attachment_segments);
                mergeAbsorbedVisibility(&upgraded, &pending);
                mergeAbsorbedVisibility(&upgraded, incoming);
                pending = upgraded;
            },
            refresh_visibility => {
                pending.reason = incoming.reason;
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
            },
            else => {},
        },
        refresh_window_removal => switch (incoming.kind) {
            refresh_full_rescan => {
                var upgraded = incoming.*;
                upgraded.cycle_id = pending.cycle_id;
                try upgraded.attachment_segments.appendAll(&pending.attachment_segments);
                mergeAbsorbedVisibility(&upgraded, &pending);
                mergeAbsorbedVisibility(&upgraded, incoming);
                pending = upgraded;
            },
            refresh_window_removal => {
                pending.reason = incoming.reason;
                try pending.payload_segments.appendAll(&incoming.payload_segments);
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            refresh_immediate_relayout => {
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                try mergeFollowUp(&pending, refresh_immediate_relayout, incoming.reason, &incoming.workspace_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            refresh_relayout => {
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                try mergeFollowUp(&pending, refresh_relayout, incoming.reason, &incoming.workspace_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            refresh_visibility => {
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            else => {},
        },
        refresh_immediate_relayout => switch (incoming.kind) {
            refresh_full_rescan => {
                var upgraded = incoming.*;
                upgraded.cycle_id = pending.cycle_id;
                try upgraded.attachment_segments.appendAll(&pending.attachment_segments);
                mergeAbsorbedVisibility(&upgraded, &pending);
                mergeAbsorbedVisibility(&upgraded, incoming);
                pending = upgraded;
            },
            refresh_window_removal => {
                var upgraded = incoming.*;
                upgraded.cycle_id = pending.cycle_id;
                try upgraded.attachment_segments.appendAll(&pending.attachment_segments);
                if (pending.has_follow_up) {
                    upgraded.follow_up = pending.follow_up;
                    upgraded.has_follow_up = true;
                }
                try mergeFollowUp(&upgraded, refresh_immediate_relayout, pending.reason, &pending.workspace_segments);
                mergeAbsorbedVisibility(&upgraded, &pending);
                mergeAbsorbedVisibility(&upgraded, incoming);
                pending = upgraded;
            },
            refresh_visibility => {
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            refresh_immediate_relayout => {
                pending.reason = incoming.reason;
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                const merged_follow_up = try mergeFollowUpRefresh(
                    if (pending.has_follow_up) pending.follow_up else null,
                    if (incoming.has_follow_up) incoming.follow_up else null,
                );
                if (merged_follow_up) |resolved| {
                    pending.follow_up = resolved;
                    pending.has_follow_up = true;
                } else {
                    pending.has_follow_up = false;
                }
                mergeAbsorbedVisibility(&pending, incoming);
            },
            refresh_relayout => {
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                try mergeFollowUp(&pending, refresh_relayout, incoming.reason, &incoming.workspace_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            else => {},
        },
        refresh_relayout => switch (incoming.kind) {
            refresh_full_rescan => {
                var upgraded = incoming.*;
                upgraded.cycle_id = pending.cycle_id;
                try upgraded.attachment_segments.appendAll(&pending.attachment_segments);
                mergeAbsorbedVisibility(&upgraded, &pending);
                mergeAbsorbedVisibility(&upgraded, incoming);
                pending = upgraded;
            },
            refresh_window_removal => {
                var upgraded = incoming.*;
                upgraded.cycle_id = pending.cycle_id;
                try upgraded.attachment_segments.appendAll(&pending.attachment_segments);
                try mergeFollowUp(&upgraded, refresh_relayout, pending.reason, &pending.workspace_segments);
                mergeAbsorbedVisibility(&upgraded, &pending);
                mergeAbsorbedVisibility(&upgraded, incoming);
                pending = upgraded;
            },
            refresh_visibility => {
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                mergeAbsorbedVisibility(&pending, incoming);
            },
            refresh_relayout => {
                pending.reason = incoming.reason;
                try pending.attachment_segments.appendAll(&incoming.attachment_segments);
                const merged_follow_up = try mergeFollowUpRefresh(
                    if (pending.has_follow_up) pending.follow_up else null,
                    if (incoming.has_follow_up) incoming.follow_up else null,
                );
                if (merged_follow_up) |resolved| {
                    pending.follow_up = resolved;
                    pending.has_follow_up = true;
                } else {
                    pending.has_follow_up = false;
                }
                mergeAbsorbedVisibility(&pending, incoming);
            },
            refresh_immediate_relayout => {
                var upgraded = incoming.*;
                upgraded.cycle_id = pending.cycle_id;
                try upgraded.attachment_segments.appendAll(&pending.attachment_segments);
                const merged_follow_up = try mergeFollowUpRefresh(
                    if (pending.has_follow_up) pending.follow_up else null,
                    if (incoming.has_follow_up) incoming.follow_up else null,
                );
                if (merged_follow_up) |resolved| {
                    upgraded.follow_up = resolved;
                    upgraded.has_follow_up = true;
                }
                try mergeFollowUp(&upgraded, refresh_relayout, pending.reason, &pending.workspace_segments);
                mergeAbsorbedVisibility(&upgraded, &pending);
                mergeAbsorbedVisibility(&upgraded, incoming);
                pending = upgraded;
            },
            else => {},
        },
        else => {},
    }

    var merged_workspace_segments = UUIDSegments{};
    try merged_workspace_segments.appendAll(&existing_workspace_segments);
    try merged_workspace_segments.appendAll(&incoming.workspace_segments);
    pending.workspace_segments = merged_workspace_segments;
    return pending;
}

fn preserveCancelledRefreshState(cancelled_refresh: *const RefreshValue, pending_refresh: ?RefreshValue) !RefreshValue {
    if (pending_refresh == null) {
        return cancelled_refresh.*;
    }

    var pending = pending_refresh.?;
    if (cancelled_refresh.attachment_segments.len != 0) {
        try pending.attachment_segments.prependAll(&cancelled_refresh.attachment_segments);
    }

    try pending.workspace_segments.appendAll(&cancelled_refresh.workspace_segments);

    if (cancelled_refresh.kind == refresh_window_removal and cancelled_refresh.payload_segments.len != 0) {
        try pending.payload_segments.prependAll(&cancelled_refresh.payload_segments);
        if (pending.kind != refresh_full_rescan and pending.kind != refresh_window_removal) {
            pending.kind = refresh_window_removal;
            pending.reason = cancelled_refresh.reason;
        }
    }

    mergeAbsorbedVisibility(&pending, cancelled_refresh);
    const merged_follow_up = try mergeFollowUpRefresh(
        if (cancelled_refresh.has_follow_up) cancelled_refresh.follow_up else null,
        if (pending.has_follow_up) pending.follow_up else null,
    );
    if (merged_follow_up) |resolved| {
        pending.follow_up = resolved;
        pending.has_follow_up = true;
    } else {
        pending.has_follow_up = false;
    }

    return pending;
}

fn handleRefresh(
    refresh: *const RefreshValue,
    active_refresh: *const RefreshValue,
    pending_refresh: ?RefreshValue,
    actions: *ActionWriter,
) !struct { active_refresh: RefreshValue, pending_refresh: ?RefreshValue, decision: DecisionValue } {
    var updated_active = active_refresh.*;
    var updated_pending = pending_refresh;

    switch (active_refresh.kind) {
        refresh_full_rescan => switch (refresh.kind) {
            refresh_visibility => {
                updated_active = try absorbIntoActiveFullRescan(active_refresh, refresh);
                return .{
                    .active_refresh = updated_active,
                    .pending_refresh = updated_pending,
                    .decision = .{
                        .kind = decision_refresh_merged,
                        .cycle_id = updated_active.cycle_id,
                        .refresh_kind = updated_active.kind,
                    },
                };
            },
            else => {
                updated_pending = try mergePendingRefresh(updated_pending, refresh);
            },
        },
        refresh_visibility => switch (refresh.kind) {
            refresh_visibility, refresh_full_rescan, refresh_window_removal, refresh_immediate_relayout, refresh_relayout => {
                updated_pending = try mergePendingRefresh(updated_pending, refresh);
            },
            else => {},
        },
        refresh_window_removal => switch (refresh.kind) {
            refresh_full_rescan, refresh_window_removal, refresh_immediate_relayout, refresh_relayout, refresh_visibility => {
                updated_pending = try mergePendingRefresh(updated_pending, refresh);
            },
            else => {},
        },
        refresh_immediate_relayout => switch (refresh.kind) {
            refresh_full_rescan, refresh_immediate_relayout, refresh_window_removal => {
                updated_pending = try mergePendingRefresh(updated_pending, refresh);
                try appendCancelActiveRefresh(actions, active_refresh.cycle_id);
                return .{
                    .active_refresh = updated_active,
                    .pending_refresh = updated_pending,
                    .decision = .{
                        .kind = decision_refresh_superseded,
                        .cycle_id = active_refresh.cycle_id,
                        .secondary_cycle_id = if (updated_pending) |resolved| resolved.cycle_id else refresh.cycle_id,
                    },
                };
            },
            refresh_relayout, refresh_visibility => {
                updated_pending = try mergePendingRefresh(updated_pending, refresh);
            },
            else => {},
        },
        refresh_relayout => switch (refresh.kind) {
            refresh_full_rescan, refresh_immediate_relayout, refresh_relayout, refresh_window_removal => {
                updated_pending = try mergePendingRefresh(updated_pending, refresh);
                try appendCancelActiveRefresh(actions, active_refresh.cycle_id);
                return .{
                    .active_refresh = updated_active,
                    .pending_refresh = updated_pending,
                    .decision = .{
                        .kind = decision_refresh_superseded,
                        .cycle_id = active_refresh.cycle_id,
                        .secondary_cycle_id = if (updated_pending) |resolved| resolved.cycle_id else refresh.cycle_id,
                    },
                };
            },
            refresh_visibility => {
                updated_pending = try mergePendingRefresh(updated_pending, refresh);
            },
            else => {},
        },
        else => {},
    }

    return .{
        .active_refresh = updated_active,
        .pending_refresh = updated_pending,
        .decision = .{
            .kind = decision_refresh_merged,
            .cycle_id = if (updated_pending) |resolved| resolved.cycle_id else updated_active.cycle_id,
            .refresh_kind = if (updated_pending) |resolved| resolved.kind else updated_active.kind,
        },
    };
}

fn reduceRefreshRequest(
    snapshot: *SnapshotValue,
    request: RefreshRequestValue,
    actions: *ActionWriter,
) !DecisionValue {
    if (request.should_drop_while_busy and
        (request.is_incremental_refresh_in_progress or request.is_immediate_layout_in_progress or request.has_active_animation_refreshes))
    {
        return .{
            .kind = decision_refresh_dropped,
            .refresh_reason = request.refresh.reason,
        };
    }

    if (snapshot.has_active_refresh) {
        const handled = try handleRefresh(&request.refresh, &snapshot.active_refresh, if (snapshot.has_pending_refresh) snapshot.pending_refresh else null, actions);
        snapshot.active_refresh = handled.active_refresh;
        snapshot.has_active_refresh = true;
        if (handled.pending_refresh) |pending| {
            snapshot.pending_refresh = pending;
            snapshot.has_pending_refresh = true;
        } else {
            snapshot.has_pending_refresh = false;
        }
        return handled.decision;
    }

    const had_pending = snapshot.has_pending_refresh;
    const merged = try mergePendingRefresh(if (snapshot.has_pending_refresh) snapshot.pending_refresh else null, &request.refresh);
    snapshot.pending_refresh = .{};
    snapshot.has_pending_refresh = false;
    snapshot.active_refresh = merged;
    snapshot.has_active_refresh = true;
    try appendStartRefresh(actions, merged.cycle_id);

    return .{
        .kind = if (had_pending) decision_refresh_merged else decision_refresh_queued,
        .cycle_id = merged.cycle_id,
        .refresh_kind = merged.kind,
    };
}

fn reduceRefreshCompletion(
    snapshot: *SnapshotValue,
    completion: RefreshCompletionValue,
    actions: *ActionWriter,
) !DecisionValue {
    var completed: RefreshValue = if (snapshot.has_active_refresh) snapshot.active_refresh else completion.refresh;
    snapshot.has_active_refresh = false;

    if (completion.did_complete) {
        if (completion.did_execute_plan) {
            if (completed.attachment_segments.len != 0) {
                try appendAttachmentAction(actions, action_discard_post_layout_attachments, &completed.attachment_segments);
            }
        } else {
            if (completed.kind != refresh_visibility and completed.needs_visibility_reconciliation) {
                try appendSimpleAction(actions, action_perform_visibility_side_effects);
                try appendSimpleAction(actions, action_request_workspace_bar_refresh);
            }
            if (completed.attachment_segments.len != 0) {
                try appendAttachmentAction(actions, action_run_post_layout_attachments, &completed.attachment_segments);
            }
        }

        if (completed.has_follow_up) {
            var follow_up_refresh = RefreshValue{
                .cycle_id = completed.cycle_id +% 1,
                .kind = completed.follow_up.kind,
                .reason = completed.follow_up.reason,
                .workspace_segments = completed.follow_up.workspace_segments,
            };
            if (snapshot.has_pending_refresh) {
                snapshot.pending_refresh = try mergePendingRefresh(snapshot.pending_refresh, &follow_up_refresh);
            } else {
                snapshot.pending_refresh = follow_up_refresh;
            }
            snapshot.has_pending_refresh = true;
        }
    } else {
        snapshot.pending_refresh = try preserveCancelledRefreshState(&completed, if (snapshot.has_pending_refresh) snapshot.pending_refresh else null);
        snapshot.has_pending_refresh = true;
    }

    if (snapshot.has_pending_refresh) {
        snapshot.active_refresh = snapshot.pending_refresh;
        snapshot.has_active_refresh = true;
        snapshot.has_pending_refresh = false;
        try appendStartRefresh(actions, snapshot.active_refresh.cycle_id);
    }

    return .{
        .kind = decision_refresh_completed,
        .cycle_id = completed.cycle_id,
        .did_complete = completion.did_complete,
    };
}

fn reduceFocusRequest(
    snapshot: *SnapshotValue,
    request: FocusRequestValue,
    actions: *ActionWriter,
) !DecisionValue {
    const request_id = snapshot.focus.next_managed_request_id;
    const next_request = copyManagedRequestWithTokenWorkspace(request_id, request.token, request.workspace_id);

    if (snapshot.focus.has_active_managed_request) {
        const active_request = snapshot.focus.active_managed_request;
        if (tokenEqual(active_request.token, request.token) and uuidEqual(active_request.workspace_id, request.workspace_id)) {
            try appendBeginManagedFocusRequest(actions, active_request.request_id, request.token, request.workspace_id);
            try appendFrontManagedWindow(actions, request.token, request.workspace_id);
            return .{
                .kind = decision_focus_request_ignored,
                .token = request.token,
                .has_token = true,
            };
        }

        try appendClearManagedFocusState(actions, active_request);
        try appendBeginManagedFocusRequest(actions, request_id, request.token, request.workspace_id);
        try appendFrontManagedWindow(actions, request.token, request.workspace_id);
        snapshot.focus.active_managed_request = next_request;
        snapshot.focus.has_active_managed_request = true;
        snapshot.focus.pending_focused_token = request.token;
        snapshot.focus.pending_focused_workspace_id = request.workspace_id;
        snapshot.focus.has_pending_focused_token = true;
        snapshot.focus.has_pending_focused_workspace_id = true;
        snapshot.focus.next_managed_request_id = request_id +% 1;
        return .{
            .kind = decision_focus_request_superseded,
            .request_id = request_id,
            .secondary_request_id = active_request.request_id,
            .token = request.token,
            .has_token = true,
        };
    }

    try appendBeginManagedFocusRequest(actions, request_id, request.token, request.workspace_id);
    try appendFrontManagedWindow(actions, request.token, request.workspace_id);
    snapshot.focus.active_managed_request = next_request;
    snapshot.focus.has_active_managed_request = true;
    snapshot.focus.pending_focused_token = request.token;
    snapshot.focus.pending_focused_workspace_id = request.workspace_id;
    snapshot.focus.has_pending_focused_token = true;
    snapshot.focus.has_pending_focused_workspace_id = true;
    snapshot.focus.next_managed_request_id = request_id +% 1;
    return .{
        .kind = decision_focus_request_accepted,
        .request_id = request_id,
        .token = request.token,
        .has_token = true,
    };
}

fn reduceActivation(
    snapshot: *SnapshotValue,
    observation: ActivationObservationValue,
    retry_limit: u32,
    actions: *ActionWriter,
) !DecisionValue {
    const disposition = activationDisposition(&snapshot.focus, observation);

    switch (observation.match_kind) {
        match_missing_focused_window => {
            switch (disposition) {
                disposition_matches_active, disposition_conflicts_with_pending => {
                    if (shouldHonorObservedFocusOverPendingRequest(observation)) {
                        try appendClearManagedFocusState(actions, snapshot.focus.active_managed_request);
                        clearActiveManagedRequest(&snapshot.focus);
                        clearPendingFocus(&snapshot.focus);
                    } else {
                        var decision = makeDecision(decision_managed_activation_deferred);
                        try deferManagedActivation(
                            snapshot,
                            retry_missing_focused_window,
                            observation.source,
                            observation.origin,
                            retry_limit,
                            actions,
                            &decision,
                        );
                        return decision;
                    }
                },
                else => {},
            }

            clearActiveManagedRequest(&snapshot.focus);
            snapshot.focus.is_non_managed_focus_active = true;
            snapshot.focus.is_app_fullscreen_active = observation.fallback_fullscreen;
            clearPendingFocus(&snapshot.focus);
            try appendEnterNonManagedFallback(actions, observation.pid, null, observation.fallback_fullscreen, observation.source);
            return .{
                .kind = decision_managed_activation_fallback,
                .pid = observation.pid,
            };
        },
        match_managed => {
            switch (disposition) {
                disposition_matches_active => {},
                disposition_conflicts_with_pending => {
                    if (shouldHonorObservedFocusOverPendingRequest(observation)) {
                        try appendClearManagedFocusState(actions, snapshot.focus.active_managed_request);
                        clearActiveManagedRequest(&snapshot.focus);
                        clearPendingFocus(&snapshot.focus);
                    } else {
                        var decision = makeDecision(decision_managed_activation_deferred);
                        try deferManagedActivation(
                            snapshot,
                            retry_pending_focus_mismatch,
                            observation.source,
                            observation.origin,
                            retry_limit,
                            actions,
                            &decision,
                        );
                        return decision;
                    }
                },
                disposition_unrelated => {
                    if (!shouldHandleManagedActivationWithoutPendingRequest(observation)) {
                        return .{
                            .kind = decision_focus_request_ignored,
                            .token = observation.token,
                            .has_token = true,
                        };
                    }
                },
                else => {},
            }

            if (observation.requires_native_fullscreen_restore_relayout) {
                try appendBeginNativeFullscreenRestoreActivation(
                    actions,
                    observation.token,
                    observation.workspace_id,
                    observation.monitor_id,
                    observation.has_monitor_id,
                    observation.is_workspace_active,
                    observation.source,
                );
                clearActiveManagedRequest(&snapshot.focus);
                snapshot.focus.pending_focused_token = observation.token;
                snapshot.focus.pending_focused_workspace_id = observation.workspace_id;
                snapshot.focus.has_pending_focused_token = true;
                snapshot.focus.has_pending_focused_workspace_id = true;
            } else {
                try appendConfirmManagedActivation(
                    actions,
                    observation.token,
                    observation.workspace_id,
                    observation.monitor_id,
                    observation.has_monitor_id,
                    observation.is_workspace_active,
                    observation.app_fullscreen,
                    observation.source,
                );
                clearActiveManagedRequest(&snapshot.focus);
                clearPendingFocus(&snapshot.focus);
                snapshot.focus.is_non_managed_focus_active = false;
                snapshot.focus.is_app_fullscreen_active = observation.app_fullscreen;
            }

            return .{
                .kind = decision_managed_activation_confirmed,
                .token = observation.token,
                .has_token = true,
            };
        },
        match_unmanaged => {
            switch (disposition) {
                disposition_matches_active, disposition_conflicts_with_pending => {
                    if (shouldHonorObservedFocusOverPendingRequest(observation)) {
                        try appendClearManagedFocusState(actions, snapshot.focus.active_managed_request);
                        clearActiveManagedRequest(&snapshot.focus);
                        clearPendingFocus(&snapshot.focus);
                    } else {
                        var decision = makeDecision(decision_managed_activation_deferred);
                        try deferManagedActivation(
                            snapshot,
                            retry_pending_focus_unmanaged_token,
                            observation.source,
                            observation.origin,
                            retry_limit,
                            actions,
                            &decision,
                        );
                        return decision;
                    }
                },
                else => {},
            }

            clearActiveManagedRequest(&snapshot.focus);
            clearPendingFocus(&snapshot.focus);
            snapshot.focus.is_non_managed_focus_active = true;
            snapshot.focus.is_app_fullscreen_active = observation.fallback_fullscreen;
            try appendEnterNonManagedFallback(actions, observation.pid, if (observation.has_token) observation.token else null, observation.fallback_fullscreen, observation.source);
            return .{
                .kind = decision_managed_activation_fallback,
                .pid = observation.pid,
            };
        },
        match_owned_application => {
            if (snapshot.focus.has_active_managed_request) {
                const request = snapshot.focus.active_managed_request;
                if (request.token.pid == observation.pid) {
                    try appendClearManagedFocusState(actions, request);
                    clearActiveManagedRequest(&snapshot.focus);
                    clearPendingFocus(&snapshot.focus);
                }
            } else {
                clearPendingFocus(&snapshot.focus);
                try appendCancelActivationRetry(actions, null);
            }

            snapshot.focus.is_non_managed_focus_active = true;
            snapshot.focus.is_app_fullscreen_active = false;
            try appendEnterOwnedApplicationFallback(actions, observation.pid, observation.source);
            return .{
                .kind = decision_managed_activation_fallback,
                .pid = observation.pid,
            };
        },
        else => return error.InvalidArgument,
    }
}

fn decodeRefreshRequestEvent(raw: RefreshRequestEvent, input_ctx: *const InputContext) !RefreshRequestValue {
    if (!isFlag(raw.should_drop_while_busy) or
        !isFlag(raw.is_incremental_refresh_in_progress) or
        !isFlag(raw.is_immediate_layout_in_progress) or
        !isFlag(raw.has_active_animation_refreshes))
    {
        return error.InvalidArgument;
    }

    return .{
        .refresh = try decodeRefresh(raw.refresh, input_ctx),
        .should_drop_while_busy = raw.should_drop_while_busy != 0,
        .is_incremental_refresh_in_progress = raw.is_incremental_refresh_in_progress != 0,
        .is_immediate_layout_in_progress = raw.is_immediate_layout_in_progress != 0,
        .has_active_animation_refreshes = raw.has_active_animation_refreshes != 0,
    };
}

fn decodeRefreshCompletionEvent(raw: RefreshCompletionEvent, input_ctx: *const InputContext) !RefreshCompletionValue {
    if (!isFlag(raw.did_complete) or !isFlag(raw.did_execute_plan)) {
        return error.InvalidArgument;
    }

    return .{
        .refresh = try decodeRefresh(raw.refresh, input_ctx),
        .did_complete = raw.did_complete != 0,
        .did_execute_plan = raw.did_execute_plan != 0,
    };
}

fn decodeActivationObservation(raw: ActivationObservation) !ActivationObservationValue {
    if (!isActivationSource(raw.source) or
        !isActivationOrigin(raw.origin) or
        !isActivationMatchKind(raw.match_kind) or
        !isFlag(raw.has_token) or
        !isFlag(raw.has_workspace_id) or
        !isFlag(raw.has_monitor_id) or
        !isFlag(raw.is_workspace_active) or
        !isFlag(raw.app_fullscreen) or
        !isFlag(raw.fallback_fullscreen) or
        !isFlag(raw.requires_native_fullscreen_restore_relayout))
    {
        return error.InvalidArgument;
    }

    switch (raw.match_kind) {
        match_missing_focused_window => {
            if (raw.has_workspace_id != 0 or raw.has_monitor_id != 0 or raw.app_fullscreen != 0 or
                raw.requires_native_fullscreen_restore_relayout != 0)
            {
                return error.InvalidArgument;
            }
        },
        match_managed => {
            if (raw.has_token == 0 or raw.has_workspace_id == 0 or raw.fallback_fullscreen != 0) {
                return error.InvalidArgument;
            }
        },
        match_unmanaged => {
            if (raw.has_token == 0 or raw.has_workspace_id != 0 or raw.has_monitor_id != 0 or
                raw.is_workspace_active != 0 or raw.requires_native_fullscreen_restore_relayout != 0)
            {
                return error.InvalidArgument;
            }
        },
        match_owned_application => {
            if (raw.has_token != 0 or raw.has_workspace_id != 0 or raw.has_monitor_id != 0 or
                raw.is_workspace_active != 0 or raw.app_fullscreen != 0 or raw.fallback_fullscreen != 0 or
                raw.requires_native_fullscreen_restore_relayout != 0)
            {
                return error.InvalidArgument;
            }
        },
        else => unreachable,
    }

    return .{
        .source = raw.source,
        .origin = raw.origin,
        .match_kind = raw.match_kind,
        .pid = raw.pid,
        .token = raw.token,
        .has_token = raw.has_token != 0,
        .workspace_id = raw.workspace_id,
        .has_workspace_id = raw.has_workspace_id != 0,
        .monitor_id = raw.monitor_id,
        .has_monitor_id = raw.has_monitor_id != 0,
        .is_workspace_active = raw.is_workspace_active != 0,
        .app_fullscreen = raw.app_fullscreen != 0,
        .fallback_fullscreen = raw.fallback_fullscreen != 0,
        .requires_native_fullscreen_restore_relayout = raw.requires_native_fullscreen_restore_relayout != 0,
    };
}

fn runStep(raw_input: *const StepInput, raw_output: *StepOutput) !void {
    const input_ctx = try InputContext.init(raw_input);
    var writer = try OutputWriter.init(raw_output);
    var actions = ActionWriter{ .writer = &writer };
    var snapshot = try decodeSnapshot(raw_input.snapshot, &input_ctx);

    if (!isEventKind(raw_input.event.kind)) {
        return error.InvalidArgument;
    }

    const decision = switch (raw_input.event.kind) {
        event_refresh_requested => try reduceRefreshRequest(&snapshot, try decodeRefreshRequestEvent(raw_input.event.refresh_request, &input_ctx), &actions),
        event_refresh_completed => try reduceRefreshCompletion(&snapshot, try decodeRefreshCompletionEvent(raw_input.event.refresh_completion, &input_ctx), &actions),
        event_focus_requested => try reduceFocusRequest(&snapshot, .{
            .token = raw_input.event.focus_request.token,
            .workspace_id = raw_input.event.focus_request.workspace_id,
        }, &actions),
        event_activation_observed => try reduceActivation(&snapshot, try decodeActivationObservation(raw_input.event.activation_observation), activation_retry_limit, &actions),
        else => unreachable,
    };
    writer.raw.snapshot = try writer.serializeSnapshot(&input_ctx, &snapshot);
    writer.serializeDecision(decision);
}

pub export fn omniwm_orchestration_step(
    input: ?*const StepInput,
    output: ?*StepOutput,
) i32 {
    const resolved_input = input orelse return kernel_invalid_argument;
    const resolved_output = output orelse return kernel_invalid_argument;

    runStep(resolved_input, resolved_output) catch |err| {
        return switch (err) {
            error.InvalidArgument => kernel_invalid_argument,
            error.BufferTooSmall => kernel_buffer_too_small,
        };
    };

    return kernel_ok;
}

fn makeUUID(high: u64, low: u64) UUID {
    return .{ .high = high, .low = low };
}

fn makeToken(pid: i32, window_id: i64) WindowToken {
    return .{ .pid = pid, .window_id = window_id };
}

fn makeRequest(request_id: u64, token: WindowToken, workspace_id: UUID) ManagedRequest {
    return .{
        .request_id = request_id,
        .token = token,
        .workspace_id = workspace_id,
        .retry_count = 0,
        .last_activation_source = activation_source_focused_window_changed,
        .has_last_activation_source = 0,
        .reserved0 = 0,
        .reserved1 = 0,
        .reserved2 = 0,
    };
}

fn makeRefreshRaw(cycle_id: u64, kind: u32, reason: u32) Refresh {
    return .{
        .cycle_id = cycle_id,
        .kind = kind,
        .reason = reason,
        .affected_workspace_offset = 0,
        .affected_workspace_count = 0,
        .post_layout_attachment_offset = 0,
        .post_layout_attachment_count = 0,
        .window_removal_payload_offset = 0,
        .window_removal_payload_count = 0,
        .follow_up_refresh = std.mem.zeroes(FollowUpRefresh),
        .visibility_reason = 0,
        .has_follow_up_refresh = 0,
        .needs_visibility_reconciliation = 0,
        .has_visibility_reason = 0,
        .reserved0 = 0,
    };
}

test "orchestration step supersedes focus request and preserves ordering" {
    const workspace_a = makeUUID(1, 2);
    const workspace_b = makeUUID(3, 4);
    const old_token = makeToken(77, 1);
    const new_token = makeToken(77, 2);

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.next_managed_request_id = 9;
    input.snapshot.focus.active_managed_request = makeRequest(4, old_token, workspace_a);
    input.snapshot.focus.has_active_managed_request = 1;
    input.snapshot.focus.pending_focused_token = old_token;
    input.snapshot.focus.pending_focused_workspace_id = workspace_a;
    input.snapshot.focus.has_pending_focused_token = 1;
    input.snapshot.focus.has_pending_focused_workspace_id = 1;
    input.event.kind = event_focus_requested;
    input.event.focus_request = .{
        .token = new_token,
        .workspace_id = workspace_b,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 8;
    var workspace_storage = [_]UUID{zeroUUID()} ** 8;
    var attachment_storage = [_]u64{0} ** 8;
    var payload_storage = [_]WindowRemovalPayload{std.mem.zeroes(WindowRemovalPayload)} ** 4;
    var old_frame_storage = [_]OldFrameRecord{std.mem.zeroes(OldFrameRecord)} ** 4;
    var action_attachment_storage = [_]u64{0} ** 8;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = &workspace_storage,
        .snapshot_workspace_id_capacity = workspace_storage.len,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = &attachment_storage,
        .snapshot_attachment_id_capacity = attachment_storage.len,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = &payload_storage,
        .snapshot_window_removal_payload_capacity = payload_storage.len,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = &old_frame_storage,
        .snapshot_old_frame_record_capacity = old_frame_storage.len,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = &action_attachment_storage,
        .action_attachment_id_capacity = action_attachment_storage.len,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_orchestration_step(&input, &output));
    try std.testing.expectEqual(decision_focus_request_superseded, output.decision.kind);
    try std.testing.expectEqual(@as(u64, 9), output.decision.request_id);
    try std.testing.expectEqual(@as(u64, 4), output.decision.secondary_request_id);
    try std.testing.expectEqual(@as(usize, 3), output.action_count);
    try std.testing.expectEqual(action_clear_managed_focus_state, output.actions.?[0].kind);
    try std.testing.expectEqual(action_begin_managed_focus_request, output.actions.?[1].kind);
    try std.testing.expectEqual(action_front_managed_window, output.actions.?[2].kind);
    try std.testing.expect(output.snapshot.focus.has_active_managed_request != 0);
    try std.testing.expect(tokenEqual(output.snapshot.focus.active_managed_request.token, new_token));
}

test "orchestration step defers unmanaged activation conflict" {
    const workspace = makeUUID(5, 6);
    const requested_token = makeToken(88, 3);
    const observed_token = makeToken(88, 4);

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.next_managed_request_id = 8;
    input.snapshot.focus.active_managed_request = makeRequest(7, requested_token, workspace);
    input.snapshot.focus.has_active_managed_request = 1;
    input.snapshot.focus.pending_focused_token = requested_token;
    input.snapshot.focus.pending_focused_workspace_id = workspace;
    input.snapshot.focus.has_pending_focused_token = 1;
    input.snapshot.focus.has_pending_focused_workspace_id = 1;
    input.event.kind = event_activation_observed;
    input.event.activation_observation = .{
        .source = activation_source_workspace_did_activate_application,
        .origin = activation_origin_external,
        .match_kind = match_unmanaged,
        .pid = observed_token.pid,
        .token = observed_token,
        .workspace_id = zeroUUID(),
        .monitor_id = 0,
        .has_token = 1,
        .has_workspace_id = 0,
        .has_monitor_id = 0,
        .is_workspace_active = 0,
        .app_fullscreen = 0,
        .fallback_fullscreen = 0,
        .requires_native_fullscreen_restore_relayout = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 4;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_orchestration_step(&input, &output));
    try std.testing.expectEqual(decision_managed_activation_deferred, output.decision.kind);
    try std.testing.expectEqual(retry_pending_focus_unmanaged_token, output.decision.retry_reason);
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
    try std.testing.expectEqual(action_continue_managed_focus_request, output.actions.?[0].kind);
    try std.testing.expectEqual(retry_pending_focus_unmanaged_token, output.actions.?[0].retry_reason);
    try std.testing.expectEqual(@as(u32, 1), output.snapshot.focus.active_managed_request.retry_count);
    try std.testing.expectEqual(activation_source_workspace_did_activate_application, output.snapshot.focus.active_managed_request.last_activation_source);
    try std.testing.expect(output.snapshot.focus.active_managed_request.has_last_activation_source != 0);
}

test "orchestration step keeps unrelated managed request during owned application activation" {
    const workspace = makeUUID(17, 18);
    const requested_token = makeToken(77, 3);
    const owned_pid: i32 = 1234;

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.next_managed_request_id = 8;
    input.snapshot.focus.active_managed_request = makeRequest(7, requested_token, workspace);
    input.snapshot.focus.has_active_managed_request = 1;
    input.snapshot.focus.pending_focused_token = requested_token;
    input.snapshot.focus.pending_focused_workspace_id = workspace;
    input.snapshot.focus.has_pending_focused_token = 1;
    input.snapshot.focus.has_pending_focused_workspace_id = 1;
    input.event.kind = event_activation_observed;
    input.event.activation_observation = .{
        .source = activation_source_cgs_front_app_changed,
        .origin = activation_origin_external,
        .match_kind = match_owned_application,
        .pid = owned_pid,
        .token = zeroToken(),
        .workspace_id = zeroUUID(),
        .monitor_id = 0,
        .has_token = 0,
        .has_workspace_id = 0,
        .has_monitor_id = 0,
        .is_workspace_active = 0,
        .app_fullscreen = 0,
        .fallback_fullscreen = 0,
        .requires_native_fullscreen_restore_relayout = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 2;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_orchestration_step(&input, &output));
    try std.testing.expectEqual(decision_managed_activation_fallback, output.decision.kind);
    try std.testing.expectEqual(owned_pid, output.decision.pid);
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
    try std.testing.expectEqual(action_enter_owned_application_fallback, output.actions.?[0].kind);
    try std.testing.expectEqual(owned_pid, output.actions.?[0].pid);
    try std.testing.expect(output.snapshot.focus.has_active_managed_request != 0);
    try std.testing.expect(tokenEqual(output.snapshot.focus.active_managed_request.token, requested_token));
    try std.testing.expect(output.snapshot.focus.has_pending_focused_token != 0);
    try std.testing.expect(output.snapshot.focus.is_non_managed_focus_active != 0);
}

test "orchestration step routes native fullscreen restore activation separately" {
    const workspace = makeUUID(7, 8);
    const token = makeToken(90, 5);

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.next_managed_request_id = 13;
    input.snapshot.focus.active_managed_request = makeRequest(12, token, workspace);
    input.snapshot.focus.has_active_managed_request = 1;
    input.snapshot.focus.pending_focused_token = token;
    input.snapshot.focus.pending_focused_workspace_id = workspace;
    input.snapshot.focus.has_pending_focused_token = 1;
    input.snapshot.focus.has_pending_focused_workspace_id = 1;
    input.event.kind = event_activation_observed;
    input.event.activation_observation = .{
        .source = activation_source_focused_window_changed,
        .origin = activation_origin_external,
        .match_kind = match_managed,
        .pid = token.pid,
        .token = token,
        .workspace_id = workspace,
        .monitor_id = 0,
        .has_token = 1,
        .has_workspace_id = 1,
        .has_monitor_id = 0,
        .is_workspace_active = 1,
        .app_fullscreen = 0,
        .fallback_fullscreen = 0,
        .requires_native_fullscreen_restore_relayout = 1,
        .reserved0 = 0,
        .reserved1 = 0,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 4;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_orchestration_step(&input, &output));
    try std.testing.expectEqual(decision_managed_activation_confirmed, output.decision.kind);
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
    try std.testing.expectEqual(action_begin_native_fullscreen_restore_activation, output.actions.?[0].kind);
    try std.testing.expectEqual(@as(u8, 0), output.snapshot.focus.has_active_managed_request);
    try std.testing.expect(output.snapshot.focus.has_pending_focused_token != 0);
    try std.testing.expect(tokenEqual(output.snapshot.focus.pending_focused_token, token));
}

test "orchestration step returns cancelled focus decision payload on retry exhaustion" {
    const workspace = makeUUID(11, 12);
    const requested_token = makeToken(66, 12);
    const observed_token = makeToken(66, 13);

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.next_managed_request_id = 10;
    input.snapshot.focus.active_managed_request = makeRequest(9, requested_token, workspace);
    input.snapshot.focus.active_managed_request.retry_count = 5;
    input.snapshot.focus.active_managed_request.last_activation_source = activation_source_workspace_did_activate_application;
    input.snapshot.focus.active_managed_request.has_last_activation_source = 1;
    input.snapshot.focus.has_active_managed_request = 1;
    input.snapshot.focus.pending_focused_token = requested_token;
    input.snapshot.focus.pending_focused_workspace_id = workspace;
    input.snapshot.focus.has_pending_focused_token = 1;
    input.snapshot.focus.has_pending_focused_workspace_id = 1;
    input.event.kind = event_activation_observed;
    input.event.activation_observation = .{
        .source = activation_source_workspace_did_activate_application,
        .origin = activation_origin_external,
        .match_kind = match_unmanaged,
        .pid = observed_token.pid,
        .token = observed_token,
        .workspace_id = zeroUUID(),
        .monitor_id = 0,
        .has_token = 1,
        .has_workspace_id = 0,
        .has_monitor_id = 0,
        .is_workspace_active = 0,
        .app_fullscreen = 0,
        .fallback_fullscreen = 0,
        .requires_native_fullscreen_restore_relayout = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 4;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_orchestration_step(&input, &output));
    try std.testing.expectEqual(decision_focus_request_cancelled, output.decision.kind);
    try std.testing.expectEqual(@as(u64, 9), output.decision.request_id);
    try std.testing.expectEqual(retry_retry_exhausted, output.decision.retry_reason);
    try std.testing.expect(output.decision.has_token != 0);
    try std.testing.expect(tokenEqual(output.decision.token, requested_token));
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
    try std.testing.expectEqual(action_clear_managed_focus_state, output.actions.?[0].kind);
    try std.testing.expect(tokenEqual(output.actions.?[0].token, requested_token));
}

test "orchestration step leaves probe-origin retry exhaustion pending" {
    const workspace = makeUUID(11, 12);
    const requested_token = makeToken(66, 12);
    const observed_token = makeToken(66, 13);

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.next_managed_request_id = 10;
    input.snapshot.focus.active_managed_request = makeRequest(9, requested_token, workspace);
    input.snapshot.focus.active_managed_request.retry_count = 5;
    input.snapshot.focus.active_managed_request.last_activation_source = activation_source_focused_window_changed;
    input.snapshot.focus.active_managed_request.has_last_activation_source = 1;
    input.snapshot.focus.has_active_managed_request = 1;
    input.snapshot.focus.pending_focused_token = requested_token;
    input.snapshot.focus.pending_focused_workspace_id = workspace;
    input.snapshot.focus.has_pending_focused_token = 1;
    input.snapshot.focus.has_pending_focused_workspace_id = 1;
    input.event.kind = event_activation_observed;
    input.event.activation_observation = .{
        .source = activation_source_focused_window_changed,
        .origin = activation_origin_probe,
        .match_kind = match_unmanaged,
        .pid = observed_token.pid,
        .token = observed_token,
        .workspace_id = zeroUUID(),
        .monitor_id = 0,
        .has_token = 1,
        .has_workspace_id = 0,
        .has_monitor_id = 0,
        .is_workspace_active = 0,
        .app_fullscreen = 0,
        .fallback_fullscreen = 0,
        .requires_native_fullscreen_restore_relayout = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 4;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_orchestration_step(&input, &output));
    try std.testing.expectEqual(decision_managed_activation_deferred, output.decision.kind);
    try std.testing.expectEqual(retry_pending_focus_unmanaged_token, output.decision.retry_reason);
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
    try std.testing.expectEqual(action_continue_managed_focus_request, output.actions.?[0].kind);
    try std.testing.expect(output.snapshot.focus.has_active_managed_request != 0);
    try std.testing.expectEqual(@as(u32, 5), output.snapshot.focus.active_managed_request.retry_count);
    try std.testing.expect(output.snapshot.focus.has_pending_focused_token != 0);
}

test "orchestration step preserves cancelled window removal before restart" {
    const workspace = makeUUID(9, 10);
    const payload = WindowRemovalPayload{
        .workspace_id = workspace,
        .removed_node_id = zeroUUID(),
        .layout_kind = layout_niri,
        .has_removed_node_id = 0,
        .should_recover_focus = 1,
        .reserved0 = 0,
        .reserved1 = 0,
        .old_frame_offset = 0,
        .old_frame_count = 0,
    };
    var attachments = [_]u64{5};
    var payloads = [_]WindowRemovalPayload{payload};

    var input = std.mem.zeroes(StepInput);
    input.attachment_ids = &attachments;
    input.attachment_id_count = attachments.len;
    input.window_removal_payloads = &payloads;
    input.window_removal_payload_count = payloads.len;
    input.snapshot.refresh.active_refresh = makeRefreshRaw(21, refresh_window_removal, 19);
    input.snapshot.refresh.active_refresh.post_layout_attachment_offset = 0;
    input.snapshot.refresh.active_refresh.post_layout_attachment_count = 1;
    input.snapshot.refresh.active_refresh.window_removal_payload_offset = 0;
    input.snapshot.refresh.active_refresh.window_removal_payload_count = 1;
    input.snapshot.refresh.has_active_refresh = 1;
    input.snapshot.refresh.pending_refresh = makeRefreshRaw(22, refresh_relayout, 10);
    input.snapshot.refresh.has_pending_refresh = 1;
    input.event.kind = event_refresh_completed;
    input.event.refresh_completion = .{
        .refresh = input.snapshot.refresh.active_refresh,
        .did_complete = 0,
        .did_execute_plan = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 4;
    var workspace_storage = [_]UUID{zeroUUID()} ** 8;
    var snapshot_attachments = [_]u64{0} ** 8;
    var snapshot_payloads = [_]WindowRemovalPayload{std.mem.zeroes(WindowRemovalPayload)} ** 4;
    var snapshot_old_frames = [_]OldFrameRecord{std.mem.zeroes(OldFrameRecord)} ** 4;
    var action_attachment_storage = [_]u64{0} ** 8;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = &workspace_storage,
        .snapshot_workspace_id_capacity = workspace_storage.len,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = &snapshot_attachments,
        .snapshot_attachment_id_capacity = snapshot_attachments.len,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = &snapshot_payloads,
        .snapshot_window_removal_payload_capacity = snapshot_payloads.len,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = &snapshot_old_frames,
        .snapshot_old_frame_record_capacity = snapshot_old_frames.len,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = &action_attachment_storage,
        .action_attachment_id_capacity = action_attachment_storage.len,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_orchestration_step(&input, &output));
    try std.testing.expectEqual(decision_refresh_completed, output.decision.kind);
    try std.testing.expectEqual(@as(u64, 21), output.decision.cycle_id);
    try std.testing.expectEqual(@as(u8, 0), output.decision.did_complete);
    try std.testing.expect(output.snapshot.refresh.has_active_refresh != 0);
    try std.testing.expectEqual(refresh_window_removal, output.snapshot.refresh.active_refresh.kind);
    try std.testing.expectEqual(@as(usize, 1), output.snapshot.refresh.active_refresh.post_layout_attachment_count);
    try std.testing.expectEqual(@as(usize, 1), output.snapshot.refresh.active_refresh.window_removal_payload_count);
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
    try std.testing.expectEqual(action_start_refresh, output.actions.?[0].kind);
}

test "orchestration step returns buffer too small when action storage is insufficient" {
    const workspace = makeUUID(11, 12);
    const old_token = makeToken(1, 1);
    const new_token = makeToken(1, 2);

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.next_managed_request_id = 2;
    input.snapshot.focus.active_managed_request = makeRequest(1, old_token, workspace);
    input.snapshot.focus.has_active_managed_request = 1;
    input.event.kind = event_focus_requested;
    input.event.focus_request = .{
        .token = new_token,
        .workspace_id = workspace,
    };

    var action_storage = [_]Action{std.mem.zeroes(Action)} ** 2;
    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = &action_storage,
        .action_capacity = action_storage.len,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_buffer_too_small, omniwm_orchestration_step(&input, &output));
}

test "orchestration step rejects oversized ABI counts" {
    var workspace = [_]UUID{makeUUID(1, 2)};
    var input = std.mem.zeroes(StepInput);
    input.workspace_ids = &workspace;
    input.workspace_id_count = max_abi_records + 1;

    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = null,
        .action_capacity = 0,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_invalid_argument, omniwm_orchestration_step(&input, &output));
}

test "orchestration step rejects invalid refresh discriminants" {
    var input = std.mem.zeroes(StepInput);
    input.event.kind = event_refresh_requested;
    input.event.refresh_request = .{
        .refresh = makeRefreshRaw(1, 999, 0),
        .should_drop_while_busy = 0,
        .is_incremental_refresh_in_progress = 0,
        .is_immediate_layout_in_progress = 0,
        .has_active_animation_refreshes = 0,
    };

    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = null,
        .action_capacity = 0,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_invalid_argument, omniwm_orchestration_step(&input, &output));
}

test "orchestration step rejects retry counts beyond kernel budget" {
    const workspace = makeUUID(1, 2);
    const token = makeToken(3, 4);

    var input = std.mem.zeroes(StepInput);
    input.snapshot.focus.active_managed_request = makeRequest(1, token, workspace);
    input.snapshot.focus.active_managed_request.retry_count = std.math.maxInt(u32);
    input.snapshot.focus.active_managed_request.last_activation_source = activation_source_focused_window_changed;
    input.snapshot.focus.active_managed_request.has_last_activation_source = 1;
    input.snapshot.focus.has_active_managed_request = 1;
    input.event.kind = event_focus_requested;
    input.event.focus_request = .{
        .token = token,
        .workspace_id = workspace,
    };

    var output = StepOutput{
        .snapshot = std.mem.zeroes(Snapshot),
        .decision = std.mem.zeroes(Decision),
        .actions = null,
        .action_capacity = 0,
        .action_count = 0,
        .snapshot_workspace_ids = null,
        .snapshot_workspace_id_capacity = 0,
        .snapshot_workspace_id_count = 0,
        .snapshot_attachment_ids = null,
        .snapshot_attachment_id_capacity = 0,
        .snapshot_attachment_id_count = 0,
        .snapshot_window_removal_payloads = null,
        .snapshot_window_removal_payload_capacity = 0,
        .snapshot_window_removal_payload_count = 0,
        .snapshot_old_frame_records = null,
        .snapshot_old_frame_record_capacity = 0,
        .snapshot_old_frame_record_count = 0,
        .action_attachment_ids = null,
        .action_attachment_id_capacity = 0,
        .action_attachment_id_count = 0,
    };

    try std.testing.expectEqual(kernel_invalid_argument, omniwm_orchestration_step(&input, &output));
}

test "orchestration segment append rejects overflowing adjacency math" {
    var segments = UUIDSegments{};
    const fake_ptr: [*]const UUID = @ptrFromInt(0x1000);
    const overflowing_len = std.math.maxInt(usize) / @sizeOf(UUID) + 1;

    try segments.append(fake_ptr[0..overflowing_len]);
    try std.testing.expectError(error.InvalidArgument, segments.append(fake_ptr[0..1]));
}
