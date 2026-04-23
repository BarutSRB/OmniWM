// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;
const kernel_buffer_too_small: i32 = 3;

const op_project: u32 = 0;
const op_reconcile_visible: u32 = 1;
const op_activate_workspace: u32 = 2;
const op_set_interaction_monitor: u32 = 3;
const op_resolve_preferred_focus: u32 = 4;
const op_resolve_workspace_focus: u32 = 5;
const op_apply_session_patch: u32 = 6;
const op_reconcile_topology: u32 = 7;

const outcome_noop: u32 = 0;
const outcome_apply: u32 = 1;
const outcome_invalid_target: u32 = 2;
const outcome_invalid_patch: u32 = 3;

const assignment_unconfigured: u32 = 0;
const assignment_main: u32 = 1;
const assignment_secondary: u32 = 2;
const assignment_specific_display: u32 = 3;

const viewport_none: u32 = 0;
const viewport_static: u32 = 1;
const viewport_gesture: u32 = 2;
const viewport_spring: u32 = 3;

const patch_viewport_none: u32 = 0;
const patch_viewport_apply: u32 = 1;
const patch_viewport_preserve_current: u32 = 2;

const focus_clear_none: u32 = 0;
const focus_clear_pending: u32 = 1;
const focus_clear_pending_and_confirmed: u32 = 2;

const window_mode_tiling: u32 = 0;
const window_mode_floating: u32 = 1;

const restore_cache_source_existing: u32 = 0;
const restore_cache_source_removed_monitor: u32 = 1;

const UUID = extern struct {
    high: u64,
    low: u64,
};

const WindowToken = extern struct {
    pid: i32,
    window_id: i64,
};

const Point = extern struct {
    x: f64,
    y: f64,
};

const Rect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const StringRef = extern struct {
    offset: usize,
    length: usize,
};

const Input = extern struct {
    operation: u32,
    workspace_id: UUID,
    monitor_id: u32,
    focused_workspace_id: UUID,
    pending_tiled_workspace_id: UUID,
    confirmed_tiled_workspace_id: UUID,
    confirmed_floating_workspace_id: UUID,
    pending_tiled_focus_token: WindowToken,
    confirmed_tiled_focus_token: WindowToken,
    confirmed_floating_focus_token: WindowToken,
    remembered_focus_token: WindowToken,
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    current_viewport_kind: u32,
    current_viewport_active_column_index: i32,
    patch_viewport_kind: u32,
    patch_viewport_active_column_index: i32,
    has_workspace_id: u8,
    has_monitor_id: u8,
    has_focused_workspace_id: u8,
    has_pending_tiled_workspace_id: u8,
    has_confirmed_tiled_workspace_id: u8,
    has_confirmed_floating_workspace_id: u8,
    has_pending_tiled_focus_token: u8,
    has_confirmed_tiled_focus_token: u8,
    has_confirmed_floating_focus_token: u8,
    has_remembered_focus_token: u8,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
    has_current_viewport_state: u8,
    has_patch_viewport_state: u8,
    should_update_interaction_monitor: u8,
    preserve_previous_interaction_monitor: u8,
};

const MonitorInput = extern struct {
    monitor_id: u32,
    frame_min_x: f64,
    frame_max_y: f64,
    frame_width: f64,
    frame_height: f64,
    anchor_x: f64,
    anchor_y: f64,
    visible_workspace_id: UUID,
    previous_visible_workspace_id: UUID,
    name: StringRef,
    is_main: u8,
    has_visible_workspace_id: u8,
    has_previous_visible_workspace_id: u8,
    has_name: u8,
};

const PreviousMonitorInput = extern struct {
    monitor_id: u32,
    frame_min_x: f64,
    frame_max_y: f64,
    frame_width: f64,
    frame_height: f64,
    anchor_x: f64,
    anchor_y: f64,
    visible_workspace_id: UUID,
    previous_visible_workspace_id: UUID,
    name: StringRef,
    has_visible_workspace_id: u8,
    has_previous_visible_workspace_id: u8,
    has_name: u8,
};

const DisconnectedCacheInput = extern struct {
    workspace_id: UUID,
    display_id: u32,
    anchor_x: f64,
    anchor_y: f64,
    frame_width: f64,
    frame_height: f64,
    name: StringRef,
    has_name: u8,
};

const WorkspaceInput = extern struct {
    workspace_id: UUID,
    assigned_anchor_point: Point,
    assignment_kind: u32,
    specific_display_id: u32,
    specific_display_name: StringRef,
    remembered_tiled_focus_token: WindowToken,
    remembered_floating_focus_token: WindowToken,
    has_assigned_anchor_point: u8,
    has_specific_display_id: u8,
    has_specific_display_name: u8,
    has_remembered_tiled_focus_token: u8,
    has_remembered_floating_focus_token: u8,
};

const WindowCandidateInput = extern struct {
    workspace_id: UUID,
    token: WindowToken,
    mode: u32,
    order_index: u32,
    has_hidden_proportional_position: u8,
    hidden_reason_is_workspace_inactive: u8,
};

const MonitorResult = extern struct {
    monitor_id: u32,
    visible_workspace_id: UUID,
    previous_visible_workspace_id: UUID,
    resolved_active_workspace_id: UUID,
    has_visible_workspace_id: u8,
    has_previous_visible_workspace_id: u8,
    has_resolved_active_workspace_id: u8,
};

const WorkspaceProjection = extern struct {
    workspace_id: UUID,
    projected_monitor_id: u32,
    home_monitor_id: u32,
    effective_monitor_id: u32,
    has_projected_monitor_id: u8,
    has_home_monitor_id: u8,
    has_effective_monitor_id: u8,
};

const DisconnectedCacheResult = extern struct {
    source_kind: u32,
    source_index: u32,
    workspace_id: UUID,
};

const Output = extern struct {
    outcome: u32,
    patch_viewport_action: u32,
    focus_clear_action: u32,
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    resolved_focus_token: WindowToken,
    monitor_results: [*c]MonitorResult,
    monitor_result_capacity: usize,
    monitor_result_count: usize,
    workspace_projections: [*c]WorkspaceProjection,
    workspace_projection_capacity: usize,
    workspace_projection_count: usize,
    disconnected_cache_results: [*c]DisconnectedCacheResult,
    disconnected_cache_result_capacity: usize,
    disconnected_cache_result_count: usize,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
    has_resolved_focus_token: u8,
    should_remember_focus: u8,
    refresh_restore_intents: u8,
};

const RestoreMonitorKey = extern struct {
    display_id: u32,
    anchor_x: f64,
    anchor_y: f64,
    frame_width: f64,
    frame_height: f64,
    name: StringRef,
    has_name: u8,
};

const RestoreMonitorContext = extern struct {
    frame_min_x: f64,
    frame_max_y: f64,
    visible_frame: Rect,
    key: RestoreMonitorKey,
};

const RestoreVisibleWorkspaceSnapshot = extern struct {
    workspace_id: UUID,
    monitor_key: RestoreMonitorKey,
};

const RestoreDisconnectedCacheEntry = extern struct {
    workspace_id: UUID,
    monitor_key: RestoreMonitorKey,
};

const RestoreWorkspaceMonitorFact = extern struct {
    workspace_id: UUID,
    home_monitor_id: u32,
    effective_monitor_id: u32,
    workspace_exists: u8,
    has_home_monitor_id: u8,
    has_effective_monitor_id: u8,
};

const RestoreTopologyInput = extern struct {
    previous_monitors: [*c]const RestoreMonitorContext,
    previous_monitor_count: usize,
    new_monitors: [*c]const RestoreMonitorContext,
    new_monitor_count: usize,
    visible_workspaces: [*c]const RestoreVisibleWorkspaceSnapshot,
    visible_workspace_count: usize,
    visible_workspace_name_penalties: [*c]const u8,
    visible_workspace_name_penalty_count: usize,
    disconnected_cache_entries: [*c]const RestoreDisconnectedCacheEntry,
    disconnected_cache_entry_count: usize,
    workspace_facts: [*c]const RestoreWorkspaceMonitorFact,
    workspace_fact_count: usize,
    string_bytes: [*c]const u8,
    string_byte_count: usize,
    focused_workspace_id: UUID,
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    has_focused_workspace_id: u8,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
};

const RestoreVisibleAssignment = extern struct {
    monitor_id: u32,
    workspace_id: UUID,
};

const RestoreDisconnectedCacheOutputEntry = extern struct {
    source_kind: u32,
    source_index: u32,
    workspace_id: UUID,
};

const RestoreTopologyOutput = extern struct {
    visible_assignments: [*c]RestoreVisibleAssignment,
    visible_assignment_capacity: usize,
    visible_assignment_count: usize,
    disconnected_cache_entries: [*c]RestoreDisconnectedCacheOutputEntry,
    disconnected_cache_capacity: usize,
    disconnected_cache_count: usize,
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    refresh_restore_intents: u8,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
};

extern fn omniwm_restore_plan_topology(
    input_ptr: ?*const RestoreTopologyInput,
    output_ptr: ?*RestoreTopologyOutput,
) i32;

const KernelError = error{
    InvalidArgument,
    BufferTooSmall,
};

const MonitorState = struct {
    input: MonitorInput,
    visible_workspace_id: ?UUID,
    previous_visible_workspace_id: ?UUID,
};

const WorkspaceState = struct {
    input: WorkspaceInput,
    assigned_anchor_point: ?Point,
};

const ProjectionRecord = struct {
    workspace_id: UUID,
    projected_monitor_id: ?u32,
    home_monitor_id: ?u32,
    effective_monitor_id: ?u32,
};

fn statusFromError(err: KernelError) i32 {
    return switch (err) {
        error.InvalidArgument => kernel_invalid_argument,
        error.BufferTooSmall => kernel_buffer_too_small,
    };
}

fn sliceFromOptionalPtr(comptime T: type, ptr: [*c]const T, count: usize) KernelError![]const T {
    if (count == 0) {
        return &[_]T{};
    }
    if (ptr == null) {
        return error.InvalidArgument;
    }
    return @as([*]const T, @ptrCast(ptr))[0..count];
}

fn sliceFromOptionalMutablePtr(comptime T: type, ptr: [*c]T, count: usize) KernelError![]T {
    if (count == 0) {
        return &[_]T{};
    }
    if (ptr == null) {
        return error.InvalidArgument;
    }
    return @as([*]T, @ptrCast(ptr))[0..count];
}

fn bytesSlice(ptr: [*c]const u8, count: usize) KernelError![]const u8 {
    if (count == 0) {
        return &[_]u8{};
    }
    if (ptr == null) {
        return error.InvalidArgument;
    }
    return @as([*]const u8, @ptrCast(ptr))[0..count];
}

fn validateOutputBuffer(comptime T: type, ptr: [*c]T, capacity: usize) KernelError!void {
    if (capacity > 0 and ptr == null) {
        return error.InvalidArgument;
    }
}

fn uuidEq(lhs: UUID, rhs: UUID) bool {
    return lhs.high == rhs.high and lhs.low == rhs.low;
}

fn zeroUUID() UUID {
    return .{ .high = 0, .low = 0 };
}

fn zeroToken() WindowToken {
    return .{ .pid = 0, .window_id = 0 };
}

fn pointDistanceSquared(lhs: Point, rhs: Point) f64 {
    const dx = lhs.x - rhs.x;
    const dy = lhs.y - rhs.y;
    return (dx * dx) + (dy * dy);
}

fn monitorLessThan(lhs: MonitorInput, rhs: MonitorInput) bool {
    if (lhs.frame_min_x != rhs.frame_min_x) {
        return lhs.frame_min_x < rhs.frame_min_x;
    }
    if (lhs.frame_max_y != rhs.frame_max_y) {
        return lhs.frame_max_y > rhs.frame_max_y;
    }
    return lhs.monitor_id < rhs.monitor_id;
}

fn insertionSortMonitorIndices(indices: []usize, monitors: []const MonitorInput) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const value = indices[i];
        var j = i;
        while (j > 0 and monitorLessThan(monitors[value], monitors[indices[j - 1]])) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = value;
    }
}

fn optionalString(bytes: []const u8, ref: StringRef, has_value: bool) KernelError!?[]const u8 {
    if (!has_value) {
        return null;
    }
    if (ref.offset > bytes.len or ref.length > bytes.len - ref.offset) {
        return error.InvalidArgument;
    }
    return bytes[ref.offset .. ref.offset + ref.length];
}

fn namesEqualIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lhs, rhs);
}

fn monitorIndexById(monitors: []const MonitorState, monitor_id: u32) ?usize {
    for (monitors, 0..) |monitor, index| {
        if (monitor.input.monitor_id == monitor_id) {
            return index;
        }
    }
    return null;
}

fn currentVisibleMonitorIdForWorkspace(workspace_id: UUID, monitors: []const MonitorState) ?u32 {
    for (monitors) |monitor| {
        if (monitor.visible_workspace_id) |visible| {
            if (uuidEq(visible, workspace_id)) {
                return monitor.input.monitor_id;
            }
        }
    }
    return null;
}

fn workspaceIndexById(workspaces: []const WorkspaceState, workspace_id: UUID) ?usize {
    for (workspaces, 0..) |workspace, index| {
        if (uuidEq(workspace.input.workspace_id, workspace_id)) {
            return index;
        }
    }
    return null;
}

fn tokenEq(lhs: WindowToken, rhs: WindowToken) bool {
    return lhs.pid == rhs.pid and lhs.window_id == rhs.window_id;
}

fn workspaceToken(has_token: u8, token: WindowToken) ?WindowToken {
    return if (has_token != 0) token else null;
}

fn workspaceHasConfiguredAssignment(workspace: WorkspaceState) bool {
    return workspace.input.assignment_kind != assignment_unconfigured;
}

fn firstSortedMonitorId(monitors: []const MonitorState, sorted_monitor_indices: []const usize) ?u32 {
    if (sorted_monitor_indices.len == 0) {
        return null;
    }
    return monitors[sorted_monitor_indices[0]].input.monitor_id;
}

fn mainMonitorId(monitors: []const MonitorState, sorted_monitor_indices: []const usize) ?u32 {
    for (sorted_monitor_indices) |index| {
        if (monitors[index].input.is_main != 0) {
            return monitors[index].input.monitor_id;
        }
    }
    return firstSortedMonitorId(monitors, sorted_monitor_indices);
}

fn secondaryMonitorId(monitors: []const MonitorState, sorted_monitor_indices: []const usize) ?u32 {
    if (sorted_monitor_indices.len < 2) {
        return null;
    }
    if (mainMonitorId(monitors, sorted_monitor_indices)) |main_id| {
        for (sorted_monitor_indices) |index| {
            if (monitors[index].input.monitor_id != main_id) {
                return monitors[index].input.monitor_id;
            }
        }
    }
    return monitors[sorted_monitor_indices[1]].input.monitor_id;
}

fn specificDisplayMonitorId(
    workspace: WorkspaceState,
    monitors: []const MonitorState,
    sorted_monitor_indices: []const usize,
    string_bytes: []const u8,
) KernelError!?u32 {
    _ = sorted_monitor_indices;
    _ = string_bytes;
    if (workspace.input.has_specific_display_id != 0) {
        for (monitors) |monitor| {
            if (monitor.input.monitor_id == workspace.input.specific_display_id) {
                return monitor.input.monitor_id;
            }
        }
    }
    return null;
}

fn homeMonitorIdForWorkspace(
    workspace: WorkspaceState,
    monitors: []const MonitorState,
    sorted_monitor_indices: []const usize,
    string_bytes: []const u8,
) KernelError!?u32 {
    return switch (workspace.input.assignment_kind) {
        assignment_unconfigured => null,
        assignment_main => mainMonitorId(monitors, sorted_monitor_indices),
        assignment_secondary => secondaryMonitorId(monitors, sorted_monitor_indices),
        assignment_specific_display => try specificDisplayMonitorId(
            workspace,
            monitors,
            sorted_monitor_indices,
            string_bytes,
        ),
        else => error.InvalidArgument,
    };
}

fn effectiveMonitorIdForWorkspace(
    workspace: WorkspaceState,
    monitors: []const MonitorState,
    sorted_monitor_indices: []const usize,
    string_bytes: []const u8,
) KernelError!?u32 {
    if (!workspaceHasConfiguredAssignment(workspace)) {
        return null;
    }

    if (try homeMonitorIdForWorkspace(workspace, monitors, sorted_monitor_indices, string_bytes)) |home_monitor_id| {
        return home_monitor_id;
    }

    const fallback_monitor_id = firstSortedMonitorId(monitors, sorted_monitor_indices) orelse return null;
    const anchor = workspace.assigned_anchor_point orelse return fallback_monitor_id;

    var best_monitor_id = fallback_monitor_id;
    var best_distance = std.math.inf(f64);
    var best_sort_index: usize = 0;
    for (sorted_monitor_indices, 0..) |monitor_index, sort_index| {
        const monitor = monitors[monitor_index];
        const distance = pointDistanceSquared(
            .{ .x = monitor.input.anchor_x, .y = monitor.input.anchor_y },
            anchor,
        );
        if (distance < best_distance) {
            best_distance = distance;
            best_monitor_id = monitor.input.monitor_id;
            best_sort_index = sort_index;
            continue;
        }
        if (distance == best_distance and sort_index < best_sort_index) {
            best_monitor_id = monitor.input.monitor_id;
            best_sort_index = sort_index;
        }
    }
    return best_monitor_id;
}

fn projectedMonitorIdForWorkspace(
    workspace: WorkspaceState,
    effective_monitor_id: ?u32,
    visible_monitor_id: ?u32,
) ?u32 {
    if (!workspaceHasConfiguredAssignment(workspace)) {
        return visible_monitor_id;
    }
    return effective_monitor_id;
}

fn populateProjectionRecords(
    projections: []ProjectionRecord,
    monitors: []const MonitorState,
    workspaces: []const WorkspaceState,
    sorted_monitor_indices: []const usize,
    string_bytes: []const u8,
) KernelError!void {
    if (projections.len != workspaces.len) {
        return error.InvalidArgument;
    }
    for (workspaces, 0..) |workspace, index| {
        const home_monitor_id = try homeMonitorIdForWorkspace(
            workspace,
            monitors,
            sorted_monitor_indices,
            string_bytes,
        );
        const effective_monitor_id = try effectiveMonitorIdForWorkspace(
            workspace,
            monitors,
            sorted_monitor_indices,
            string_bytes,
        );
        const visible_monitor_id = currentVisibleMonitorIdForWorkspace(workspace.input.workspace_id, monitors);

        projections[index] = .{
            .workspace_id = workspace.input.workspace_id,
            .projected_monitor_id = projectedMonitorIdForWorkspace(
                workspace,
                effective_monitor_id,
                visible_monitor_id,
            ),
            .home_monitor_id = home_monitor_id,
            .effective_monitor_id = effective_monitor_id,
        };
    }
}

fn projectedMonitorIdFromRecords(records: []const ProjectionRecord, workspace_id: UUID) ?u32 {
    for (records) |record| {
        if (uuidEq(record.workspace_id, workspace_id)) {
            return record.projected_monitor_id;
        }
    }
    return null;
}

fn restoreVisibleFrame(
    frame_min_x: f64,
    frame_max_y: f64,
    frame_width: f64,
    frame_height: f64,
) Rect {
    return .{
        .x = frame_min_x,
        .y = frame_max_y - frame_height,
        .width = frame_width,
        .height = frame_height,
    };
}

fn restoreMonitorKeyFromMonitorInput(monitor: MonitorInput) RestoreMonitorKey {
    return .{
        .display_id = monitor.monitor_id,
        .anchor_x = monitor.anchor_x,
        .anchor_y = monitor.anchor_y,
        .frame_width = monitor.frame_width,
        .frame_height = monitor.frame_height,
        .name = monitor.name,
        .has_name = monitor.has_name,
    };
}

fn restoreMonitorKeyFromPreviousMonitorInput(monitor: PreviousMonitorInput) RestoreMonitorKey {
    return .{
        .display_id = monitor.monitor_id,
        .anchor_x = monitor.anchor_x,
        .anchor_y = monitor.anchor_y,
        .frame_width = monitor.frame_width,
        .frame_height = monitor.frame_height,
        .name = monitor.name,
        .has_name = monitor.has_name,
    };
}

fn restoreMonitorKeyFromDisconnectedCacheInput(entry: DisconnectedCacheInput) RestoreMonitorKey {
    return .{
        .display_id = entry.display_id,
        .anchor_x = entry.anchor_x,
        .anchor_y = entry.anchor_y,
        .frame_width = entry.frame_width,
        .frame_height = entry.frame_height,
        .name = entry.name,
        .has_name = entry.has_name,
    };
}

fn restoreMonitorContextFromMonitorInput(monitor: MonitorInput) RestoreMonitorContext {
    return .{
        .frame_min_x = monitor.frame_min_x,
        .frame_max_y = monitor.frame_max_y,
        .visible_frame = restoreVisibleFrame(
            monitor.frame_min_x,
            monitor.frame_max_y,
            monitor.frame_width,
            monitor.frame_height,
        ),
        .key = restoreMonitorKeyFromMonitorInput(monitor),
    };
}

fn restoreMonitorContextFromPreviousMonitorInput(monitor: PreviousMonitorInput) RestoreMonitorContext {
    return .{
        .frame_min_x = monitor.frame_min_x,
        .frame_max_y = monitor.frame_max_y,
        .visible_frame = restoreVisibleFrame(
            monitor.frame_min_x,
            monitor.frame_max_y,
            monitor.frame_width,
            monitor.frame_height,
        ),
        .key = restoreMonitorKeyFromPreviousMonitorInput(monitor),
    };
}

fn monitorNamesEqual(
    string_bytes: []const u8,
    lhs_ref: StringRef,
    lhs_has_name: u8,
    rhs_ref: StringRef,
    rhs_has_name: u8,
) KernelError!bool {
    if (lhs_has_name == 0 and rhs_has_name == 0) {
        return true;
    }
    if (lhs_has_name == 0 or rhs_has_name == 0) {
        return false;
    }
    const lhs = (try optionalString(string_bytes, lhs_ref, lhs_has_name != 0)) orelse return false;
    const rhs = (try optionalString(string_bytes, rhs_ref, rhs_has_name != 0)) orelse return false;
    return namesEqualIgnoreCase(lhs, rhs);
}

fn topologyEquivalent(
    previous_monitors: []const PreviousMonitorInput,
    current_monitors: []const MonitorState,
    string_bytes: []const u8,
) KernelError!bool {
    if (previous_monitors.len != current_monitors.len) {
        return false;
    }

    for (previous_monitors) |previous| {
        const current_index = monitorIndexById(current_monitors, previous.monitor_id) orelse return false;
        const current = current_monitors[current_index].input;
        if (previous.frame_min_x != current.frame_min_x or
            previous.frame_max_y != current.frame_max_y or
            previous.frame_width != current.frame_width or
            previous.frame_height != current.frame_height or
            previous.anchor_x != current.anchor_x or
            previous.anchor_y != current.anchor_y)
        {
            return false;
        }
        if (!(try monitorNamesEqual(
            string_bytes,
            previous.name,
            previous.has_name,
            current.name,
            current.has_name,
        ))) {
            return false;
        }
    }

    return true;
}

fn clearMonitorSession(monitor: *MonitorState) bool {
    const changed = monitor.visible_workspace_id != null or monitor.previous_visible_workspace_id != null;
    monitor.visible_workspace_id = null;
    monitor.previous_visible_workspace_id = null;
    return changed;
}

fn updateInteractionMonitorState(
    input: Input,
    monitors: []const MonitorState,
    sorted_monitor_indices: []const usize,
    projections: []const ProjectionRecord,
    output: *Output,
) bool {
    const requested_interaction = if (input.has_interaction_monitor_id != 0 and
        monitorIndexById(monitors, input.interaction_monitor_id) != null)
        input.interaction_monitor_id
    else
        null;

    const focused_workspace_monitor_id = if (input.has_focused_workspace_id != 0)
        projectedMonitorIdFromRecords(projections, input.focused_workspace_id)
    else
        null;

    const resolved_interaction = requested_interaction orelse focused_workspace_monitor_id orelse firstSortedMonitorId(monitors, sorted_monitor_indices);
    const resolved_previous = if (input.has_previous_interaction_monitor_id != 0 and
        monitorIndexById(monitors, input.previous_interaction_monitor_id) != null)
        input.previous_interaction_monitor_id
    else
        null;

    output.has_interaction_monitor_id = @intFromBool(resolved_interaction != null);
    output.interaction_monitor_id = resolved_interaction orelse 0;
    output.has_previous_interaction_monitor_id = @intFromBool(resolved_previous != null);
    output.previous_interaction_monitor_id = resolved_previous orelse 0;

    return (input.has_interaction_monitor_id != output.has_interaction_monitor_id) or (resolved_interaction != if (input.has_interaction_monitor_id != 0) input.interaction_monitor_id else null) or (input.has_previous_interaction_monitor_id != output.has_previous_interaction_monitor_id) or (resolved_previous != if (input.has_previous_interaction_monitor_id != 0)
        input.previous_interaction_monitor_id
    else
        null);
}

fn setInteractionMonitorState(
    input: Input,
    monitors: []const MonitorState,
    output: *Output,
) bool {
    const resolved_interaction = if (input.has_monitor_id != 0 and monitorIndexById(monitors, input.monitor_id) != null)
        input.monitor_id
    else
        null;

    var resolved_previous: ?u32 = null;
    if (input.preserve_previous_interaction_monitor != 0 and
        input.has_interaction_monitor_id != 0 and
        (resolved_interaction == null or input.interaction_monitor_id != resolved_interaction.?))
    {
        if (monitorIndexById(monitors, input.interaction_monitor_id) != null) {
            resolved_previous = input.interaction_monitor_id;
        }
    } else if (input.has_previous_interaction_monitor_id != 0 and
        monitorIndexById(monitors, input.previous_interaction_monitor_id) != null)
    {
        resolved_previous = input.previous_interaction_monitor_id;
    }

    output.has_interaction_monitor_id = @intFromBool(resolved_interaction != null);
    output.interaction_monitor_id = resolved_interaction orelse 0;
    output.has_previous_interaction_monitor_id = @intFromBool(resolved_previous != null);
    output.previous_interaction_monitor_id = resolved_previous orelse 0;

    return (input.has_interaction_monitor_id != output.has_interaction_monitor_id) or (resolved_interaction != if (input.has_interaction_monitor_id != 0) input.interaction_monitor_id else null) or (input.has_previous_interaction_monitor_id != output.has_previous_interaction_monitor_id) or (resolved_previous != if (input.has_previous_interaction_monitor_id != 0)
        input.previous_interaction_monitor_id
    else
        null);
}

fn activateWorkspaceOnMonitor(
    input: Input,
    monitors: []MonitorState,
    workspaces: []WorkspaceState,
    sorted_monitor_indices: []const usize,
    string_bytes: []const u8,
    workspace_id: UUID,
    monitor_id: u32,
    output: *Output,
) KernelError!u32 {
    const workspace_index = workspaceIndexById(workspaces, workspace_id) orelse return outcome_invalid_target;
    const target_monitor_index = monitorIndexById(monitors, monitor_id) orelse return outcome_invalid_target;
    const effective_monitor_id = try effectiveMonitorIdForWorkspace(
        workspaces[workspace_index],
        monitors,
        sorted_monitor_indices,
        string_bytes,
    );
    if (effective_monitor_id == null or effective_monitor_id.? != monitor_id) {
        return outcome_invalid_target;
    }

    var changed = false;

    if (currentVisibleMonitorIdForWorkspace(workspace_id, monitors)) |current_monitor_id| {
        if (current_monitor_id != monitor_id) {
            if (monitorIndexById(monitors, current_monitor_id)) |current_monitor_index| {
                monitors[current_monitor_index].previous_visible_workspace_id = workspace_id;
                monitors[current_monitor_index].visible_workspace_id = null;
                changed = true;
            }
        }
    }

    if (monitors[target_monitor_index].visible_workspace_id) |current_visible_workspace_id| {
        if (!uuidEq(current_visible_workspace_id, workspace_id)) {
            monitors[target_monitor_index].previous_visible_workspace_id = current_visible_workspace_id;
            monitors[target_monitor_index].visible_workspace_id = workspace_id;
            changed = true;
        }
    } else {
        monitors[target_monitor_index].visible_workspace_id = workspace_id;
        changed = true;
    }

    workspaces[workspace_index].assigned_anchor_point = .{
        .x = monitors[target_monitor_index].input.anchor_x,
        .y = monitors[target_monitor_index].input.anchor_y,
    };

    if (input.should_update_interaction_monitor != 0) {
        const interaction_changed = setInteractionMonitorState(
            .{
                .operation = op_set_interaction_monitor,
                .workspace_id = zeroUUID(),
                .monitor_id = monitor_id,
                .focused_workspace_id = zeroUUID(),
                .pending_tiled_workspace_id = zeroUUID(),
                .confirmed_tiled_workspace_id = zeroUUID(),
                .confirmed_floating_workspace_id = zeroUUID(),
                .pending_tiled_focus_token = zeroToken(),
                .confirmed_tiled_focus_token = zeroToken(),
                .confirmed_floating_focus_token = zeroToken(),
                .remembered_focus_token = zeroToken(),
                .interaction_monitor_id = input.interaction_monitor_id,
                .previous_interaction_monitor_id = input.previous_interaction_monitor_id,
                .current_viewport_kind = viewport_none,
                .current_viewport_active_column_index = 0,
                .patch_viewport_kind = viewport_none,
                .patch_viewport_active_column_index = 0,
                .has_workspace_id = 0,
                .has_monitor_id = 1,
                .has_focused_workspace_id = 0,
                .has_pending_tiled_workspace_id = 0,
                .has_confirmed_tiled_workspace_id = 0,
                .has_confirmed_floating_workspace_id = 0,
                .has_pending_tiled_focus_token = 0,
                .has_confirmed_tiled_focus_token = 0,
                .has_confirmed_floating_focus_token = 0,
                .has_remembered_focus_token = 0,
                .has_interaction_monitor_id = input.has_interaction_monitor_id,
                .has_previous_interaction_monitor_id = input.has_previous_interaction_monitor_id,
                .has_current_viewport_state = 0,
                .has_patch_viewport_state = 0,
                .should_update_interaction_monitor = 0,
                .preserve_previous_interaction_monitor = 1,
            },
            monitors,
            output,
        );
        changed = interaction_changed or changed;
    }

    return if (changed) outcome_apply else outcome_noop;
}

fn writeMonitorResults(
    monitors: []const MonitorState,
    projections: []const ProjectionRecord,
    output: *Output,
    required_count: usize,
) KernelError!void {
    output.monitor_result_count = required_count;
    if (required_count == 0) {
        return;
    }
    try validateOutputBuffer(MonitorResult, output.monitor_results, output.monitor_result_capacity);
    if (output.monitor_result_capacity < required_count) {
        return error.BufferTooSmall;
    }
    const results = try sliceFromOptionalMutablePtr(
        MonitorResult,
        output.monitor_results,
        output.monitor_result_capacity,
    );

    for (monitors, 0..) |monitor, index| {
        const projected_state = projectedWorkspaceStateForMonitor(
            projections,
            monitor.input.monitor_id,
            monitor.visible_workspace_id,
        );
        const resolved_active_workspace_id = if (projected_state.current_visible_assigned)
            monitor.visible_workspace_id
        else
            projected_state.first_workspace_id;
        results[index] = .{
            .monitor_id = monitor.input.monitor_id,
            .visible_workspace_id = monitor.visible_workspace_id orelse zeroUUID(),
            .previous_visible_workspace_id = monitor.previous_visible_workspace_id orelse zeroUUID(),
            .resolved_active_workspace_id = resolved_active_workspace_id orelse zeroUUID(),
            .has_visible_workspace_id = @intFromBool(monitor.visible_workspace_id != null),
            .has_previous_visible_workspace_id = @intFromBool(monitor.previous_visible_workspace_id != null),
            .has_resolved_active_workspace_id = @intFromBool(resolved_active_workspace_id != null),
        };
    }
}

fn writeWorkspaceProjections(
    projections: []const ProjectionRecord,
    output: *Output,
    required_count: usize,
) KernelError!void {
    output.workspace_projection_count = required_count;
    if (required_count == 0) {
        return;
    }
    try validateOutputBuffer(
        WorkspaceProjection,
        output.workspace_projections,
        output.workspace_projection_capacity,
    );
    if (output.workspace_projection_capacity < required_count) {
        return error.BufferTooSmall;
    }
    const results = try sliceFromOptionalMutablePtr(
        WorkspaceProjection,
        output.workspace_projections,
        output.workspace_projection_capacity,
    );
    for (projections, 0..) |projection, index| {
        results[index] = .{
            .workspace_id = projection.workspace_id,
            .projected_monitor_id = projection.projected_monitor_id orelse 0,
            .home_monitor_id = projection.home_monitor_id orelse 0,
            .effective_monitor_id = projection.effective_monitor_id orelse 0,
            .has_projected_monitor_id = @intFromBool(projection.projected_monitor_id != null),
            .has_home_monitor_id = @intFromBool(projection.home_monitor_id != null),
            .has_effective_monitor_id = @intFromBool(projection.effective_monitor_id != null),
        };
    }
}

fn writeDisconnectedCacheResults(
    results_to_write: []const DisconnectedCacheResult,
    output: *Output,
    required_count: usize,
) KernelError!void {
    output.disconnected_cache_result_count = required_count;
    if (required_count == 0) {
        return;
    }
    try validateOutputBuffer(
        DisconnectedCacheResult,
        output.disconnected_cache_results,
        output.disconnected_cache_result_capacity,
    );
    if (output.disconnected_cache_result_capacity < required_count) {
        return error.BufferTooSmall;
    }
    const results = try sliceFromOptionalMutablePtr(
        DisconnectedCacheResult,
        output.disconnected_cache_results,
        output.disconnected_cache_result_capacity,
    );
    for (results_to_write, 0..) |entry, index| {
        results[index] = entry;
    }
}

const ProjectedWorkspaceState = struct {
    current_visible_assigned: bool,
    first_workspace_id: ?UUID,
};

fn projectedWorkspaceStateForMonitor(
    projections: []const ProjectionRecord,
    monitor_id: u32,
    visible_workspace_id: ?UUID,
) ProjectedWorkspaceState {
    var current_visible_assigned = false;
    var first_workspace_id: ?UUID = null;

    for (projections) |projection| {
        if (projection.projected_monitor_id) |projected_monitor_id| {
            if (projected_monitor_id == monitor_id) {
                if (first_workspace_id == null) {
                    first_workspace_id = projection.workspace_id;
                }
                if (visible_workspace_id) |visible| {
                    if (uuidEq(projection.workspace_id, visible)) {
                        current_visible_assigned = true;
                    }
                }
            }
        }
    }

    return .{
        .current_visible_assigned = current_visible_assigned,
        .first_workspace_id = first_workspace_id,
    };
}

fn candidateIsEligible(
    candidate: WindowCandidateInput,
    workspace_id: UUID,
    mode: u32,
) bool {
    if (!uuidEq(candidate.workspace_id, workspace_id) or candidate.mode != mode) {
        return false;
    }
    if (candidate.has_hidden_proportional_position == 0) {
        return true;
    }
    return candidate.hidden_reason_is_workspace_inactive != 0;
}

fn tokenIsEligibleForWorkspace(
    window_candidates: []const WindowCandidateInput,
    workspace_id: UUID,
    mode: u32,
    token: WindowToken,
) bool {
    for (window_candidates) |candidate| {
        if (tokenEq(candidate.token, token) and candidateIsEligible(candidate, workspace_id, mode)) {
            return true;
        }
    }
    return false;
}

fn firstEligibleTokenForWorkspace(
    window_candidates: []const WindowCandidateInput,
    workspace_id: UUID,
    mode: u32,
) ?WindowToken {
    var best_order_index: u32 = std.math.maxInt(u32);
    var best_token: ?WindowToken = null;

    for (window_candidates) |candidate| {
        if (!candidateIsEligible(candidate, workspace_id, mode)) {
            continue;
        }
        if (best_token == null or candidate.order_index < best_order_index) {
            best_order_index = candidate.order_index;
            best_token = candidate.token;
        }
    }

    return best_token;
}

fn reconcileVisiblePlan(
    allocator: std.mem.Allocator,
    input: Input,
    monitors: []MonitorState,
    workspaces: []WorkspaceState,
    sorted_monitor_indices: []const usize,
    string_bytes: []const u8,
    output: *Output,
) KernelError!u32 {
    const projections = allocator.alloc(ProjectionRecord, workspaces.len) catch return error.InvalidArgument;
    defer allocator.free(projections);

    var changed = false;
    for (sorted_monitor_indices) |monitor_index| {
        const monitor_id = monitors[monitor_index].input.monitor_id;
        try populateProjectionRecords(
            projections,
            monitors,
            workspaces,
            sorted_monitor_indices,
            string_bytes,
        );
        const projected_state = projectedWorkspaceStateForMonitor(
            projections,
            monitor_id,
            monitors[monitor_index].visible_workspace_id,
        );

        if (projected_state.first_workspace_id == null) {
            changed = clearMonitorSession(&monitors[monitor_index]) or changed;
            continue;
        }

        if (projected_state.current_visible_assigned) {
            continue;
        }

        const result = try activateWorkspaceOnMonitor(
            input,
            monitors,
            workspaces,
            sorted_monitor_indices,
            string_bytes,
            projected_state.first_workspace_id.?,
            monitor_id,
            output,
        );
        if (result == outcome_invalid_target) {
            return outcome_invalid_target;
        }
        changed = result == outcome_apply or changed;
    }

    try populateProjectionRecords(
        projections,
        monitors,
        workspaces,
        sorted_monitor_indices,
        string_bytes,
    );

    changed = updateInteractionMonitorState(
        input,
        monitors,
        sorted_monitor_indices,
        projections,
        output,
    ) or changed;

    try writeMonitorResults(monitors, projections, output, monitors.len);
    try writeWorkspaceProjections(projections, output, projections.len);
    return if (changed) outcome_apply else outcome_noop;
}

fn preferredFocusToken(
    input: Input,
    workspace: WorkspaceState,
    window_candidates: []const WindowCandidateInput,
) ?WindowToken {
    if (input.has_pending_tiled_focus_token != 0 and
        input.has_pending_tiled_workspace_id != 0 and
        uuidEq(input.pending_tiled_workspace_id, workspace.input.workspace_id) and
        tokenIsEligibleForWorkspace(
            window_candidates,
            workspace.input.workspace_id,
            window_mode_tiling,
            input.pending_tiled_focus_token,
        ))
    {
        return input.pending_tiled_focus_token;
    }
    if (workspaceToken(
        workspace.input.has_remembered_tiled_focus_token,
        workspace.input.remembered_tiled_focus_token,
    )) |token| {
        if (tokenIsEligibleForWorkspace(
            window_candidates,
            workspace.input.workspace_id,
            window_mode_tiling,
            token,
        )) {
            return token;
        }
    }
    if (input.has_confirmed_tiled_focus_token != 0 and
        input.has_confirmed_tiled_workspace_id != 0 and
        uuidEq(input.confirmed_tiled_workspace_id, workspace.input.workspace_id) and
        tokenIsEligibleForWorkspace(
            window_candidates,
            workspace.input.workspace_id,
            window_mode_tiling,
            input.confirmed_tiled_focus_token,
        ))
    {
        return input.confirmed_tiled_focus_token;
    }
    if (firstEligibleTokenForWorkspace(
        window_candidates,
        workspace.input.workspace_id,
        window_mode_tiling,
    )) |token| {
        return token;
    }
    return null;
}

fn resolveWorkspaceFocusToken(
    input: Input,
    workspace: WorkspaceState,
    window_candidates: []const WindowCandidateInput,
) ?WindowToken {
    if (workspaceToken(
        workspace.input.has_remembered_tiled_focus_token,
        workspace.input.remembered_tiled_focus_token,
    )) |token| {
        if (tokenIsEligibleForWorkspace(
            window_candidates,
            workspace.input.workspace_id,
            window_mode_tiling,
            token,
        )) {
            return token;
        }
    }
    if (preferredFocusToken(input, workspace, window_candidates)) |token| {
        return token;
    }
    if (workspaceToken(
        workspace.input.has_remembered_floating_focus_token,
        workspace.input.remembered_floating_focus_token,
    )) |token| {
        if (tokenIsEligibleForWorkspace(
            window_candidates,
            workspace.input.workspace_id,
            window_mode_floating,
            token,
        )) {
            return token;
        }
    }
    if (input.has_confirmed_floating_focus_token != 0 and
        input.has_confirmed_floating_workspace_id != 0 and
        uuidEq(input.confirmed_floating_workspace_id, workspace.input.workspace_id) and
        tokenIsEligibleForWorkspace(
            window_candidates,
            workspace.input.workspace_id,
            window_mode_floating,
            input.confirmed_floating_focus_token,
        ))
    {
        return input.confirmed_floating_focus_token;
    }
    if (firstEligibleTokenForWorkspace(
        window_candidates,
        workspace.input.workspace_id,
        window_mode_floating,
    )) |token| {
        return token;
    }
    return null;
}

fn reconcileTopologyPlan(
    allocator: std.mem.Allocator,
    input: Input,
    monitors: []MonitorState,
    previous_monitors: []const PreviousMonitorInput,
    disconnected_cache_inputs: []const DisconnectedCacheInput,
    workspaces: []WorkspaceState,
    sorted_monitor_indices: []const usize,
    string_bytes: []const u8,
    output: *Output,
) KernelError!u32 {
    var cache_results = std.ArrayListUnmanaged(DisconnectedCacheResult).empty;
    defer cache_results.deinit(allocator);

    const topology_changed = !(try topologyEquivalent(previous_monitors, monitors, string_bytes));
    if (!topology_changed) {
        cache_results.ensureTotalCapacity(allocator, disconnected_cache_inputs.len) catch {
            return error.InvalidArgument;
        };
        for (disconnected_cache_inputs, 0..) |entry, index| {
            cache_results.appendAssumeCapacity(.{
                .source_kind = restore_cache_source_existing,
                .source_index = @intCast(index),
                .workspace_id = entry.workspace_id,
            });
        }

        const reconcile_outcome = try reconcileVisiblePlan(
            allocator,
            input,
            monitors,
            workspaces,
            sorted_monitor_indices,
            string_bytes,
            output,
        );
        try writeDisconnectedCacheResults(cache_results.items, output, cache_results.items.len);
        return reconcile_outcome;
    }

    var previous_contexts = allocator.alloc(RestoreMonitorContext, previous_monitors.len) catch return error.InvalidArgument;
    defer allocator.free(previous_contexts);
    for (previous_monitors, 0..) |monitor, index| {
        previous_contexts[index] = restoreMonitorContextFromPreviousMonitorInput(monitor);
    }

    var new_contexts = allocator.alloc(RestoreMonitorContext, monitors.len) catch return error.InvalidArgument;
    defer allocator.free(new_contexts);
    for (monitors, 0..) |monitor, index| {
        new_contexts[index] = restoreMonitorContextFromMonitorInput(monitor.input);
    }

    var visible_snapshots = std.ArrayListUnmanaged(RestoreVisibleWorkspaceSnapshot).empty;
    defer visible_snapshots.deinit(allocator);
    var visible_penalties = std.ArrayListUnmanaged(u8).empty;
    defer visible_penalties.deinit(allocator);
    for (previous_monitors) |monitor| {
        if (monitor.has_visible_workspace_id == 0) {
            continue;
        }
        visible_snapshots.append(allocator, .{
            .workspace_id = monitor.visible_workspace_id,
            .monitor_key = restoreMonitorKeyFromPreviousMonitorInput(monitor),
        }) catch return error.InvalidArgument;
        for (monitors) |current| {
            const penalty: u8 = if (try monitorNamesEqual(
                string_bytes,
                monitor.name,
                monitor.has_name,
                current.input.name,
                current.input.has_name,
            ))
                0
            else
                1;
            visible_penalties.append(allocator, penalty) catch return error.InvalidArgument;
        }
    }

    var restore_cache_entries = allocator.alloc(RestoreDisconnectedCacheEntry, disconnected_cache_inputs.len) catch {
        return error.InvalidArgument;
    };
    defer allocator.free(restore_cache_entries);
    for (disconnected_cache_inputs, 0..) |entry, index| {
        restore_cache_entries[index] = .{
            .workspace_id = entry.workspace_id,
            .monitor_key = restoreMonitorKeyFromDisconnectedCacheInput(entry),
        };
    }

    var workspace_facts = allocator.alloc(RestoreWorkspaceMonitorFact, workspaces.len) catch return error.InvalidArgument;
    defer allocator.free(workspace_facts);
    for (workspaces, 0..) |workspace, index| {
        const home_monitor_id = try homeMonitorIdForWorkspace(
            workspace,
            monitors,
            sorted_monitor_indices,
            string_bytes,
        );
        const effective_monitor_id = try effectiveMonitorIdForWorkspace(
            workspace,
            monitors,
            sorted_monitor_indices,
            string_bytes,
        );
        workspace_facts[index] = .{
            .workspace_id = workspace.input.workspace_id,
            .home_monitor_id = home_monitor_id orelse 0,
            .effective_monitor_id = effective_monitor_id orelse 0,
            .workspace_exists = 1,
            .has_home_monitor_id = @intFromBool(home_monitor_id != null),
            .has_effective_monitor_id = @intFromBool(effective_monitor_id != null),
        };
    }

    var restore_visible_assignments = allocator.alloc(RestoreVisibleAssignment, monitors.len) catch {
        return error.InvalidArgument;
    };
    defer allocator.free(restore_visible_assignments);
    var restore_disconnected_cache_outputs = allocator.alloc(
        RestoreDisconnectedCacheOutputEntry,
        disconnected_cache_inputs.len + previous_monitors.len,
    ) catch return error.InvalidArgument;
    defer allocator.free(restore_disconnected_cache_outputs);
    var restore_output = RestoreTopologyOutput{
        .visible_assignments = if (restore_visible_assignments.len == 0) null else restore_visible_assignments.ptr,
        .visible_assignment_capacity = restore_visible_assignments.len,
        .visible_assignment_count = 0,
        .disconnected_cache_entries = if (restore_disconnected_cache_outputs.len == 0)
            null
        else
            restore_disconnected_cache_outputs.ptr,
        .disconnected_cache_capacity = restore_disconnected_cache_outputs.len,
        .disconnected_cache_count = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .refresh_restore_intents = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
    };

    var restore_input = RestoreTopologyInput{
        .previous_monitors = if (previous_contexts.len == 0) null else previous_contexts.ptr,
        .previous_monitor_count = previous_contexts.len,
        .new_monitors = if (new_contexts.len == 0) null else new_contexts.ptr,
        .new_monitor_count = new_contexts.len,
        .visible_workspaces = if (visible_snapshots.items.len == 0) null else visible_snapshots.items.ptr,
        .visible_workspace_count = visible_snapshots.items.len,
        .visible_workspace_name_penalties = if (visible_penalties.items.len == 0) null else visible_penalties.items.ptr,
        .visible_workspace_name_penalty_count = visible_penalties.items.len,
        .disconnected_cache_entries = if (restore_cache_entries.len == 0) null else restore_cache_entries.ptr,
        .disconnected_cache_entry_count = restore_cache_entries.len,
        .workspace_facts = if (workspace_facts.len == 0) null else workspace_facts.ptr,
        .workspace_fact_count = workspace_facts.len,
        .string_bytes = if (string_bytes.len == 0) null else string_bytes.ptr,
        .string_byte_count = string_bytes.len,
        .focused_workspace_id = input.focused_workspace_id,
        .interaction_monitor_id = input.interaction_monitor_id,
        .previous_interaction_monitor_id = input.previous_interaction_monitor_id,
        .has_focused_workspace_id = input.has_focused_workspace_id,
        .has_interaction_monitor_id = input.has_interaction_monitor_id,
        .has_previous_interaction_monitor_id = input.has_previous_interaction_monitor_id,
    };

    const restore_status = omniwm_restore_plan_topology(&restore_input, &restore_output);
    switch (restore_status) {
        kernel_ok => {},
        kernel_invalid_argument => return error.InvalidArgument,
        kernel_buffer_too_small => return error.BufferTooSmall,
        else => return error.InvalidArgument,
    }

    var adjusted_input = input;
    adjusted_input.interaction_monitor_id = restore_output.interaction_monitor_id;
    adjusted_input.previous_interaction_monitor_id = restore_output.previous_interaction_monitor_id;
    adjusted_input.has_interaction_monitor_id = restore_output.has_interaction_monitor_id;
    adjusted_input.has_previous_interaction_monitor_id = restore_output.has_previous_interaction_monitor_id;

    for (restore_visible_assignments[0..restore_output.visible_assignment_count]) |assignment| {
        const activation_outcome = try activateWorkspaceOnMonitor(
            adjusted_input,
            monitors,
            workspaces,
            sorted_monitor_indices,
            string_bytes,
            assignment.workspace_id,
            assignment.monitor_id,
            output,
        );
        if (activation_outcome == outcome_invalid_target) {
            return outcome_invalid_target;
        }
    }

    cache_results.ensureTotalCapacity(allocator, restore_output.disconnected_cache_count) catch {
        return error.InvalidArgument;
    };
    for (restore_disconnected_cache_outputs[0..restore_output.disconnected_cache_count]) |entry| {
        cache_results.appendAssumeCapacity(.{
            .source_kind = entry.source_kind,
            .source_index = entry.source_index,
            .workspace_id = entry.workspace_id,
        });
    }

    const reconcile_outcome = try reconcileVisiblePlan(
        allocator,
        adjusted_input,
        monitors,
        workspaces,
        sorted_monitor_indices,
        string_bytes,
        output,
    );
    if (reconcile_outcome == outcome_invalid_target) {
        return outcome_invalid_target;
    }

    try writeDisconnectedCacheResults(cache_results.items, output, cache_results.items.len);
    output.refresh_restore_intents = 1;
    return outcome_apply;
}

fn resetOutputPreservingBuffers(output: *Output) void {
    output.* = .{
        .outcome = outcome_noop,
        .patch_viewport_action = patch_viewport_none,
        .focus_clear_action = focus_clear_none,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = output.monitor_results,
        .monitor_result_capacity = output.monitor_result_capacity,
        .monitor_result_count = 0,
        .workspace_projections = output.workspace_projections,
        .workspace_projection_capacity = output.workspace_projection_capacity,
        .workspace_projection_count = 0,
        .disconnected_cache_results = output.disconnected_cache_results,
        .disconnected_cache_result_capacity = output.disconnected_cache_result_capacity,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };
}

pub export fn omniwm_workspace_session_plan(
    input_ptr: ?*const Input,
    monitors_ptr: [*c]const MonitorInput,
    monitor_count: usize,
    previous_monitors_ptr: [*c]const PreviousMonitorInput,
    previous_monitor_count: usize,
    workspaces_ptr: [*c]const WorkspaceInput,
    workspace_count: usize,
    window_candidates_ptr: [*c]const WindowCandidateInput,
    window_candidate_count: usize,
    disconnected_cache_entries_ptr: [*c]const DisconnectedCacheInput,
    disconnected_cache_entry_count: usize,
    string_bytes_ptr: [*c]const u8,
    string_byte_count: usize,
    output_ptr: ?*Output,
) i32 {
    const input = input_ptr orelse return kernel_invalid_argument;
    const output = output_ptr orelse return kernel_invalid_argument;
    resetOutputPreservingBuffers(output);

    return planInternal(
        input,
        monitors_ptr,
        monitor_count,
        previous_monitors_ptr,
        previous_monitor_count,
        workspaces_ptr,
        workspace_count,
        window_candidates_ptr,
        window_candidate_count,
        disconnected_cache_entries_ptr,
        disconnected_cache_entry_count,
        string_bytes_ptr,
        string_byte_count,
        output,
    ) catch |err| statusFromError(err);
}

fn planInternal(
    input: *const Input,
    monitors_ptr: [*c]const MonitorInput,
    monitor_count: usize,
    previous_monitors_ptr: [*c]const PreviousMonitorInput,
    previous_monitor_count: usize,
    workspaces_ptr: [*c]const WorkspaceInput,
    workspace_count: usize,
    window_candidates_ptr: [*c]const WindowCandidateInput,
    window_candidate_count: usize,
    disconnected_cache_entries_ptr: [*c]const DisconnectedCacheInput,
    disconnected_cache_entry_count: usize,
    string_bytes_ptr: [*c]const u8,
    string_byte_count: usize,
    output: *Output,
) KernelError!i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const monitor_inputs = try sliceFromOptionalPtr(MonitorInput, monitors_ptr, monitor_count);
    const previous_monitor_inputs = try sliceFromOptionalPtr(
        PreviousMonitorInput,
        previous_monitors_ptr,
        previous_monitor_count,
    );
    const workspace_inputs = try sliceFromOptionalPtr(WorkspaceInput, workspaces_ptr, workspace_count);
    const window_candidates = try sliceFromOptionalPtr(
        WindowCandidateInput,
        window_candidates_ptr,
        window_candidate_count,
    );
    const disconnected_cache_inputs = try sliceFromOptionalPtr(
        DisconnectedCacheInput,
        disconnected_cache_entries_ptr,
        disconnected_cache_entry_count,
    );
    const string_bytes = try bytesSlice(string_bytes_ptr, string_byte_count);

    for (window_candidates) |candidate| {
        switch (candidate.mode) {
            window_mode_tiling, window_mode_floating => {},
            else => return error.InvalidArgument,
        }
    }

    switch (input.operation) {
        op_project,
        op_reconcile_visible,
        op_activate_workspace,
        op_set_interaction_monitor,
        op_resolve_preferred_focus,
        op_resolve_workspace_focus,
        op_apply_session_patch,
        op_reconcile_topology,
        => {},
        else => return error.InvalidArgument,
    }

    const sorted_monitor_indices = allocator.alloc(usize, monitor_inputs.len) catch return error.InvalidArgument;
    defer allocator.free(sorted_monitor_indices);
    for (sorted_monitor_indices, 0..) |*slot, index| {
        slot.* = index;
    }
    insertionSortMonitorIndices(sorted_monitor_indices, monitor_inputs);

    var monitors = allocator.alloc(MonitorState, monitor_inputs.len) catch return error.InvalidArgument;
    defer allocator.free(monitors);
    for (monitor_inputs, 0..) |monitor, index| {
        monitors[index] = .{
            .input = monitor,
            .visible_workspace_id = if (monitor.has_visible_workspace_id != 0) monitor.visible_workspace_id else null,
            .previous_visible_workspace_id = if (monitor.has_previous_visible_workspace_id != 0)
                monitor.previous_visible_workspace_id
            else
                null,
        };
    }

    var workspaces = allocator.alloc(WorkspaceState, workspace_inputs.len) catch return error.InvalidArgument;
    defer allocator.free(workspaces);
    for (workspace_inputs, 0..) |workspace, index| {
        var assigned_anchor_point: ?Point = if (workspace.has_assigned_anchor_point != 0)
            workspace.assigned_anchor_point
        else
            null;
        if (assigned_anchor_point == null) {
            if (currentVisibleMonitorIdForWorkspace(workspace.workspace_id, monitors)) |visible_monitor_id| {
                if (monitorIndexById(monitors, visible_monitor_id)) |visible_monitor_index| {
                    assigned_anchor_point = .{
                        .x = monitors[visible_monitor_index].input.anchor_x,
                        .y = monitors[visible_monitor_index].input.anchor_y,
                    };
                }
            }
        }
        workspaces[index] = .{
            .input = workspace,
            .assigned_anchor_point = assigned_anchor_point,
        };
    }

    switch (input.operation) {
        op_project => {
            const projections = allocator.alloc(ProjectionRecord, workspaces.len) catch return error.InvalidArgument;
            defer allocator.free(projections);
            try populateProjectionRecords(
                projections,
                monitors,
                workspaces,
                sorted_monitor_indices,
                string_bytes,
            );
            try writeMonitorResults(monitors, projections, output, monitors.len);
            try writeWorkspaceProjections(projections, output, projections.len);
            _ = updateInteractionMonitorState(
                input.*,
                monitors,
                sorted_monitor_indices,
                projections,
                output,
            );
            output.outcome = outcome_apply;
        },
        op_reconcile_visible => {
            const result = try reconcileVisiblePlan(
                allocator,
                input.*,
                monitors,
                workspaces,
                sorted_monitor_indices,
                string_bytes,
                output,
            );
            if (result == outcome_invalid_target) {
                output.outcome = outcome_invalid_target;
                return kernel_ok;
            }
            output.outcome = result;
        },
        op_activate_workspace => {
            if (input.has_workspace_id == 0 or input.has_monitor_id == 0) {
                return error.InvalidArgument;
            }
            const result = try activateWorkspaceOnMonitor(
                input.*,
                monitors,
                workspaces,
                sorted_monitor_indices,
                string_bytes,
                input.workspace_id,
                input.monitor_id,
                output,
            );
            if (result == outcome_invalid_target) {
                output.outcome = outcome_invalid_target;
                return kernel_ok;
            }

            const projections = allocator.alloc(ProjectionRecord, workspaces.len) catch return error.InvalidArgument;
            defer allocator.free(projections);
            try populateProjectionRecords(
                projections,
                monitors,
                workspaces,
                sorted_monitor_indices,
                string_bytes,
            );
            if (input.should_update_interaction_monitor == 0) {
                _ = updateInteractionMonitorState(
                    input.*,
                    monitors,
                    sorted_monitor_indices,
                    projections,
                    output,
                );
            }
            try writeMonitorResults(monitors, projections, output, monitors.len);
            try writeWorkspaceProjections(projections, output, projections.len);
            output.outcome = result;
        },
        op_set_interaction_monitor => {
            const changed = setInteractionMonitorState(input.*, monitors, output);
            output.outcome = if (changed) outcome_apply else outcome_noop;
        },
        op_resolve_preferred_focus => {
            if (input.has_workspace_id == 0) {
                return error.InvalidArgument;
            }
            const workspace_index = workspaceIndexById(workspaces, input.workspace_id) orelse {
                output.outcome = outcome_noop;
                return kernel_ok;
            };
            if (preferredFocusToken(input.*, workspaces[workspace_index], window_candidates)) |token| {
                output.resolved_focus_token = token;
                output.has_resolved_focus_token = 1;
                output.outcome = outcome_apply;
            } else {
                output.outcome = outcome_noop;
            }
        },
        op_resolve_workspace_focus => {
            if (input.has_workspace_id == 0) {
                return error.InvalidArgument;
            }
            const workspace_index = workspaceIndexById(workspaces, input.workspace_id) orelse {
                output.outcome = outcome_noop;
                return kernel_ok;
            };
            if (resolveWorkspaceFocusToken(input.*, workspaces[workspace_index], window_candidates)) |token| {
                output.resolved_focus_token = token;
                output.has_resolved_focus_token = 1;
                output.outcome = outcome_apply;
            } else {
                const should_clear_confirmed = (input.has_focused_workspace_id != 0 and
                    uuidEq(input.focused_workspace_id, input.workspace_id)) or
                    (input.has_confirmed_tiled_workspace_id != 0 and
                        uuidEq(input.confirmed_tiled_workspace_id, input.workspace_id)) or
                    (input.has_confirmed_floating_workspace_id != 0 and
                        uuidEq(input.confirmed_floating_workspace_id, input.workspace_id));
                output.focus_clear_action = if (should_clear_confirmed)
                    focus_clear_pending_and_confirmed
                else
                    focus_clear_pending;
                output.outcome = outcome_apply;
            }
        },
        op_apply_session_patch => {
            const has_viewport_patch = input.has_patch_viewport_state != 0;
            const has_remembered_focus = input.has_remembered_focus_token != 0;

            if (!has_viewport_patch and !has_remembered_focus) {
                output.outcome = outcome_noop;
                return kernel_ok;
            }

            if (has_viewport_patch) {
                switch (input.patch_viewport_kind) {
                    viewport_static, viewport_gesture, viewport_spring => {},
                    else => {
                        output.outcome = outcome_invalid_patch;
                        return kernel_ok;
                    },
                }

                if (input.patch_viewport_kind == viewport_gesture and
                    input.has_current_viewport_state != 0 and
                    input.current_viewport_kind == viewport_spring)
                {
                    output.patch_viewport_action = patch_viewport_preserve_current;
                } else {
                    output.patch_viewport_action = patch_viewport_apply;
                }
            }

            output.should_remember_focus = @intFromBool(has_remembered_focus);
            output.outcome = outcome_apply;
        },
        op_reconcile_topology => {
            const result = try reconcileTopologyPlan(
                allocator,
                input.*,
                monitors,
                previous_monitor_inputs,
                disconnected_cache_inputs,
                workspaces,
                sorted_monitor_indices,
                string_bytes,
                output,
            );
            if (result == outcome_invalid_target) {
                output.outcome = outcome_invalid_target;
                return kernel_ok;
            }
            output.outcome = result;
        },
        else => return error.InvalidArgument,
    }

    return kernel_ok;
}

fn testOutput(
    monitor_results: ?[]MonitorResult,
    workspace_projections: ?[]WorkspaceProjection,
    disconnected_cache_results: ?[]DisconnectedCacheResult,
) Output {
    return .{
        .outcome = 0,
        .patch_viewport_action = 0,
        .focus_clear_action = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = if (monitor_results) |buffer| buffer.ptr else null,
        .monitor_result_capacity = if (monitor_results) |buffer| buffer.len else 0,
        .monitor_result_count = 0,
        .workspace_projections = if (workspace_projections) |buffer| buffer.ptr else null,
        .workspace_projection_capacity = if (workspace_projections) |buffer| buffer.len else 0,
        .workspace_projection_count = 0,
        .disconnected_cache_results = if (disconnected_cache_results) |buffer| buffer.ptr else null,
        .disconnected_cache_result_capacity = if (disconnected_cache_results) |buffer| buffer.len else 0,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };
}

test "project resolves specific display fallback using updated anchor" {
    const string_bytes = "MainSideDetached";
    const main_name = StringRef{ .offset = 0, .length = 4 };
    const side_name = StringRef{ .offset = 4, .length = 4 };
    const detached_name = StringRef{ .offset = 8, .length = 8 };

    var input = Input{
        .operation = op_project,
        .workspace_id = zeroUUID(),
        .monitor_id = 0,
        .focused_workspace_id = zeroUUID(),
        .pending_tiled_workspace_id = zeroUUID(),
        .confirmed_tiled_workspace_id = zeroUUID(),
        .confirmed_floating_workspace_id = zeroUUID(),
        .pending_tiled_focus_token = zeroToken(),
        .confirmed_tiled_focus_token = zeroToken(),
        .confirmed_floating_focus_token = zeroToken(),
        .remembered_focus_token = zeroToken(),
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .current_viewport_kind = viewport_none,
        .current_viewport_active_column_index = 0,
        .patch_viewport_kind = viewport_none,
        .patch_viewport_active_column_index = 0,
        .has_workspace_id = 0,
        .has_monitor_id = 0,
        .has_focused_workspace_id = 0,
        .has_pending_tiled_workspace_id = 0,
        .has_confirmed_tiled_workspace_id = 0,
        .has_confirmed_floating_workspace_id = 0,
        .has_pending_tiled_focus_token = 0,
        .has_confirmed_tiled_focus_token = 0,
        .has_confirmed_floating_focus_token = 0,
        .has_remembered_focus_token = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_current_viewport_state = 0,
        .has_patch_viewport_state = 0,
        .should_update_interaction_monitor = 0,
        .preserve_previous_interaction_monitor = 0,
    };

    const ws = UUID{ .high = 1, .low = 1 };
    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = main_name,
            .is_main = 1,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
        .{
            .monitor_id = 20,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = side_name,
            .is_main = 0,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
    };
    const workspaces = [_]WorkspaceInput{
        .{
            .workspace_id = ws,
            .assigned_anchor_point = .{ .x = 3840, .y = 1080 },
            .assignment_kind = assignment_specific_display,
            .specific_display_id = 300,
            .specific_display_name = detached_name,
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 1,
            .has_specific_display_name = 1,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };
    var monitor_results = [_]MonitorResult{ undefined, undefined };
    var projections = [_]WorkspaceProjection{undefined};
    var output = testOutput(monitor_results[0..], projections[0..], &[_]DisconnectedCacheResult{});

    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        null,
        0,
        &workspaces,
        workspaces.len,
        null,
        0,
        null,
        0,
        string_bytes.ptr,
        string_bytes.len,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(@as(usize, 1), output.workspace_projection_count);
    try std.testing.expectEqual(@as(u8, 1), projections[0].has_effective_monitor_id);
    try std.testing.expectEqual(@as(u32, 20), projections[0].effective_monitor_id);
}

test "project reports resolved active workspace for monitor without visible session" {
    const string_bytes = "MainSide";
    const main_name = StringRef{ .offset = 0, .length = 4 };
    const side_name = StringRef{ .offset = 4, .length = 4 };

    var input = std.mem.zeroes(Input);
    input.operation = op_project;

    const ws_main = UUID{ .high = 6, .low = 6 };
    const ws_side = UUID{ .high = 7, .low = 7 };
    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = main_name,
            .is_main = 1,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
        .{
            .monitor_id = 20,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .visible_workspace_id = ws_side,
            .previous_visible_workspace_id = zeroUUID(),
            .name = side_name,
            .is_main = 0,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
    };
    const workspaces = [_]WorkspaceInput{
        .{
            .workspace_id = ws_main,
            .assigned_anchor_point = .{ .x = 0, .y = 0 },
            .assignment_kind = assignment_main,
            .specific_display_id = 0,
            .specific_display_name = StringRef{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 0,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
        .{
            .workspace_id = ws_side,
            .assigned_anchor_point = .{ .x = 0, .y = 0 },
            .assignment_kind = assignment_secondary,
            .specific_display_id = 0,
            .specific_display_name = StringRef{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 0,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };
    var monitor_results = [_]MonitorResult{ undefined, undefined };
    var projections = [_]WorkspaceProjection{ undefined, undefined };
    var output = testOutput(monitor_results[0..], projections[0..], &[_]DisconnectedCacheResult{});

    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        null,
        0,
        &workspaces,
        workspaces.len,
        null,
        0,
        null,
        0,
        string_bytes.ptr,
        string_bytes.len,
        &output,
    );

    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(@as(usize, 2), output.monitor_result_count);
    try std.testing.expectEqual(@as(u8, 0), monitor_results[0].has_visible_workspace_id);
    try std.testing.expectEqual(@as(u8, 1), monitor_results[0].has_resolved_active_workspace_id);
    try std.testing.expect(uuidEq(ws_main, monitor_results[0].resolved_active_workspace_id));
    try std.testing.expectEqual(@as(u8, 1), monitor_results[1].has_visible_workspace_id);
    try std.testing.expectEqual(@as(u8, 1), monitor_results[1].has_resolved_active_workspace_id);
    try std.testing.expect(uuidEq(ws_side, monitor_results[1].resolved_active_workspace_id));
}

test "reconcile visible assigns first projected workspace and clears empty monitor" {
    var input = std.mem.zeroes(Input);
    input.operation = op_reconcile_visible;

    const ws_main = UUID{ .high = 1, .low = 1 };
    const ws_side = UUID{ .high = 2, .low = 2 };
    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = .{ .offset = 0, .length = 0 },
            .is_main = 1,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 0,
        },
        .{
            .monitor_id = 20,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = .{ .offset = 0, .length = 0 },
            .is_main = 0,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 0,
        },
    };
    const workspaces = [_]WorkspaceInput{
        .{
            .workspace_id = ws_main,
            .assigned_anchor_point = .{ .x = 0, .y = 1080 },
            .assignment_kind = assignment_main,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
        .{
            .workspace_id = ws_side,
            .assigned_anchor_point = .{ .x = 1920, .y = 1080 },
            .assignment_kind = assignment_secondary,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };
    var monitor_results = [_]MonitorResult{ undefined, undefined };
    var workspace_projections = [_]WorkspaceProjection{ undefined, undefined };
    var output = Output{
        .outcome = 0,
        .patch_viewport_action = 0,
        .focus_clear_action = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = &monitor_results,
        .monitor_result_capacity = monitor_results.len,
        .monitor_result_count = 0,
        .workspace_projections = &workspace_projections,
        .workspace_projection_capacity = workspace_projections.len,
        .workspace_projection_count = 0,
        .disconnected_cache_results = null,
        .disconnected_cache_result_capacity = 0,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };

    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        null,
        0,
        &workspaces,
        workspaces.len,
        null,
        0,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(outcome_apply, output.outcome);
    try std.testing.expectEqual(ws_main.high, monitor_results[0].visible_workspace_id.high);
    try std.testing.expectEqual(ws_side.high, monitor_results[1].visible_workspace_id.high);
}

test "activate workspace updates previous visible and interaction monitor" {
    var input = std.mem.zeroes(Input);
    input.operation = op_activate_workspace;
    input.workspace_id = UUID{ .high = 2, .low = 2 };
    input.monitor_id = 20;
    input.has_workspace_id = 1;
    input.has_monitor_id = 1;
    input.should_update_interaction_monitor = 1;
    input.interaction_monitor_id = 10;
    input.has_interaction_monitor_id = 1;

    const ws_main = UUID{ .high = 1, .low = 1 };
    const ws_side = UUID{ .high = 2, .low = 2 };
    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = ws_main,
            .previous_visible_workspace_id = zeroUUID(),
            .name = .{ .offset = 0, .length = 0 },
            .is_main = 1,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 0,
        },
        .{
            .monitor_id = 20,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = .{ .offset = 0, .length = 0 },
            .is_main = 0,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 0,
        },
    };
    const workspaces = [_]WorkspaceInput{
        .{
            .workspace_id = ws_main,
            .assigned_anchor_point = .{ .x = 0, .y = 1080 },
            .assignment_kind = assignment_main,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
        .{
            .workspace_id = ws_side,
            .assigned_anchor_point = .{ .x = 1920, .y = 1080 },
            .assignment_kind = assignment_secondary,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };
    var monitor_results = [_]MonitorResult{ undefined, undefined };
    var workspace_projections = [_]WorkspaceProjection{ undefined, undefined };
    var output = Output{
        .outcome = 0,
        .patch_viewport_action = 0,
        .focus_clear_action = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = &monitor_results,
        .monitor_result_capacity = monitor_results.len,
        .monitor_result_count = 0,
        .workspace_projections = &workspace_projections,
        .workspace_projection_capacity = workspace_projections.len,
        .workspace_projection_count = 0,
        .disconnected_cache_results = null,
        .disconnected_cache_result_capacity = 0,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };

    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        null,
        0,
        &workspaces,
        workspaces.len,
        null,
        0,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(outcome_apply, output.outcome);
    try std.testing.expectEqual(ws_side.high, monitor_results[1].visible_workspace_id.high);
    try std.testing.expectEqual(@as(u8, 1), output.has_interaction_monitor_id);
    try std.testing.expectEqual(@as(u32, 20), output.interaction_monitor_id);
    try std.testing.expectEqual(@as(u8, 1), output.has_previous_interaction_monitor_id);
    try std.testing.expectEqual(@as(u32, 10), output.previous_interaction_monitor_id);
}

test "resolve workspace focus prefers remembered tiled before floating" {
    var input = std.mem.zeroes(Input);
    input.operation = op_resolve_workspace_focus;
    input.workspace_id = UUID{ .high = 1, .low = 1 };
    input.has_workspace_id = 1;

    const remembered_tiled = WindowToken{ .pid = 42, .window_id = 4201 };
    const remembered_floating = WindowToken{ .pid = 42, .window_id = 4202 };
    const workspace = [_]WorkspaceInput{
        .{
            .workspace_id = input.workspace_id,
            .assigned_anchor_point = .{ .x = 0, .y = 0 },
            .assignment_kind = assignment_main,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = remembered_tiled,
            .remembered_floating_focus_token = remembered_floating,
            .has_assigned_anchor_point = 0,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 1,
            .has_remembered_floating_focus_token = 1,
        },
    };
    const candidates = [_]WindowCandidateInput{
        .{
            .workspace_id = input.workspace_id,
            .token = remembered_tiled,
            .mode = window_mode_tiling,
            .order_index = 1,
            .has_hidden_proportional_position = 1,
            .hidden_reason_is_workspace_inactive = 1,
        },
        .{
            .workspace_id = input.workspace_id,
            .token = remembered_floating,
            .mode = window_mode_floating,
            .order_index = 0,
            .has_hidden_proportional_position = 0,
            .hidden_reason_is_workspace_inactive = 0,
        },
    };
    var output = Output{
        .outcome = 0,
        .patch_viewport_action = 0,
        .focus_clear_action = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = null,
        .monitor_result_capacity = 0,
        .monitor_result_count = 0,
        .workspace_projections = null,
        .workspace_projection_capacity = 0,
        .workspace_projection_count = 0,
        .disconnected_cache_results = null,
        .disconnected_cache_result_capacity = 0,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };

    const status = omniwm_workspace_session_plan(
        &input,
        null,
        0,
        null,
        0,
        &workspace,
        workspace.len,
        &candidates,
        candidates.len,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(@as(u8, 1), output.has_resolved_focus_token);
    try std.testing.expectEqual(remembered_tiled.window_id, output.resolved_focus_token.window_id);
}

test "preferred focus skips hidden pending candidate and uses first eligible tiled window" {
    var input = std.mem.zeroes(Input);
    input.operation = op_resolve_preferred_focus;
    input.workspace_id = UUID{ .high = 9, .low = 9 };
    input.has_workspace_id = 1;
    input.pending_tiled_workspace_id = input.workspace_id;
    input.has_pending_tiled_workspace_id = 1;

    const hidden_pending = WindowToken{ .pid = 50, .window_id = 5001 };
    const first_eligible = WindowToken{ .pid = 50, .window_id = 5002 };
    input.pending_tiled_focus_token = hidden_pending;
    input.has_pending_tiled_focus_token = 1;

    const workspace = [_]WorkspaceInput{
        .{
            .workspace_id = input.workspace_id,
            .assigned_anchor_point = .{ .x = 0, .y = 0 },
            .assignment_kind = assignment_unconfigured,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 0,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };
    const candidates = [_]WindowCandidateInput{
        .{
            .workspace_id = input.workspace_id,
            .token = hidden_pending,
            .mode = window_mode_tiling,
            .order_index = 0,
            .has_hidden_proportional_position = 1,
            .hidden_reason_is_workspace_inactive = 0,
        },
        .{
            .workspace_id = input.workspace_id,
            .token = first_eligible,
            .mode = window_mode_tiling,
            .order_index = 1,
            .has_hidden_proportional_position = 0,
            .hidden_reason_is_workspace_inactive = 0,
        },
    };
    var output = Output{
        .outcome = 0,
        .patch_viewport_action = 0,
        .focus_clear_action = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = null,
        .monitor_result_capacity = 0,
        .monitor_result_count = 0,
        .workspace_projections = null,
        .workspace_projection_capacity = 0,
        .workspace_projection_count = 0,
        .disconnected_cache_results = null,
        .disconnected_cache_result_capacity = 0,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };

    const status = omniwm_workspace_session_plan(
        &input,
        null,
        0,
        null,
        0,
        &workspace,
        workspace.len,
        &candidates,
        candidates.len,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(@as(u8, 1), output.has_resolved_focus_token);
    try std.testing.expectEqual(first_eligible.window_id, output.resolved_focus_token.window_id);
}

test "resolve workspace focus falls back to first eligible floating candidate" {
    var input = std.mem.zeroes(Input);
    input.operation = op_resolve_workspace_focus;
    input.workspace_id = UUID{ .high = 10, .low = 10 };
    input.has_workspace_id = 1;

    const hidden_tiled = WindowToken{ .pid = 60, .window_id = 6001 };
    const first_floating = WindowToken{ .pid = 60, .window_id = 6002 };
    const workspace = [_]WorkspaceInput{
        .{
            .workspace_id = input.workspace_id,
            .assigned_anchor_point = .{ .x = 0, .y = 0 },
            .assignment_kind = assignment_unconfigured,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 0,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };
    const candidates = [_]WindowCandidateInput{
        .{
            .workspace_id = input.workspace_id,
            .token = hidden_tiled,
            .mode = window_mode_tiling,
            .order_index = 0,
            .has_hidden_proportional_position = 1,
            .hidden_reason_is_workspace_inactive = 0,
        },
        .{
            .workspace_id = input.workspace_id,
            .token = first_floating,
            .mode = window_mode_floating,
            .order_index = 0,
            .has_hidden_proportional_position = 0,
            .hidden_reason_is_workspace_inactive = 0,
        },
    };
    var output = Output{
        .outcome = 0,
        .patch_viewport_action = 0,
        .focus_clear_action = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = null,
        .monitor_result_capacity = 0,
        .monitor_result_count = 0,
        .workspace_projections = null,
        .workspace_projection_capacity = 0,
        .workspace_projection_count = 0,
        .disconnected_cache_results = null,
        .disconnected_cache_result_capacity = 0,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };

    const status = omniwm_workspace_session_plan(
        &input,
        null,
        0,
        null,
        0,
        &workspace,
        workspace.len,
        &candidates,
        candidates.len,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(@as(u8, 1), output.has_resolved_focus_token);
    try std.testing.expectEqual(first_floating.window_id, output.resolved_focus_token.window_id);
}

test "session patch preserves current spring against stale gesture patch" {
    var input = std.mem.zeroes(Input);
    input.operation = op_apply_session_patch;
    input.has_patch_viewport_state = 1;
    input.patch_viewport_kind = viewport_gesture;
    input.has_current_viewport_state = 1;
    input.current_viewport_kind = viewport_spring;

    var output = Output{
        .outcome = 0,
        .patch_viewport_action = 0,
        .focus_clear_action = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .resolved_focus_token = zeroToken(),
        .monitor_results = null,
        .monitor_result_capacity = 0,
        .monitor_result_count = 0,
        .workspace_projections = null,
        .workspace_projection_capacity = 0,
        .workspace_projection_count = 0,
        .disconnected_cache_results = null,
        .disconnected_cache_result_capacity = 0,
        .disconnected_cache_result_count = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
        .has_resolved_focus_token = 0,
        .should_remember_focus = 0,
        .refresh_restore_intents = 0,
    };

    const status = omniwm_workspace_session_plan(
        &input,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(patch_viewport_preserve_current, output.patch_viewport_action);
}

test "session patch invalid viewport returns invalid patch" {
    var input = std.mem.zeroes(Input);
    input.operation = op_apply_session_patch;
    input.has_patch_viewport_state = 1;
    input.patch_viewport_kind = 99;

    var output = testOutput(null, null, null);
    const status = omniwm_workspace_session_plan(
        &input,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(outcome_invalid_patch, output.outcome);
}

test "set interaction monitor clears missing target" {
    var input = std.mem.zeroes(Input);
    input.operation = op_set_interaction_monitor;
    input.monitor_id = 99;
    input.has_monitor_id = 1;
    input.interaction_monitor_id = 10;
    input.has_interaction_monitor_id = 1;

    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = .{ .offset = 0, .length = 0 },
            .is_main = 1,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 0,
        },
    };

    var output = testOutput(null, null, null);
    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        null,
        0,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(outcome_apply, output.outcome);
    try std.testing.expectEqual(@as(u8, 0), output.has_interaction_monitor_id);
    try std.testing.expectEqual(@as(u8, 0), output.has_previous_interaction_monitor_id);
}

test "reconcile topology collapses visible workspace onto remaining monitor" {
    const string_bytes = "LeftRight";
    const left_name = StringRef{ .offset = 0, .length = 4 };
    const right_name = StringRef{ .offset = 4, .length = 5 };
    const ws_main = UUID{ .high = 11, .low = 11 };
    const ws_side = UUID{ .high = 22, .low = 22 };

    var input = std.mem.zeroes(Input);
    input.operation = op_reconcile_topology;
    input.interaction_monitor_id = 20;
    input.previous_interaction_monitor_id = 10;
    input.has_interaction_monitor_id = 1;
    input.has_previous_interaction_monitor_id = 1;

    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = ws_main,
            .previous_visible_workspace_id = zeroUUID(),
            .name = left_name,
            .is_main = 1,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
    };
    const previous_monitors = [_]PreviousMonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = ws_main,
            .previous_visible_workspace_id = zeroUUID(),
            .name = left_name,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
        .{
            .monitor_id = 20,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .visible_workspace_id = ws_side,
            .previous_visible_workspace_id = zeroUUID(),
            .name = right_name,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
    };
    const workspaces = [_]WorkspaceInput{
        .{
            .workspace_id = ws_main,
            .assigned_anchor_point = .{ .x = 0, .y = 1080 },
            .assignment_kind = assignment_main,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
        .{
            .workspace_id = ws_side,
            .assigned_anchor_point = .{ .x = 1920, .y = 1080 },
            .assignment_kind = assignment_secondary,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };

    var monitor_results = [_]MonitorResult{undefined};
    var projections = [_]WorkspaceProjection{ undefined, undefined };
    var cache_results = [_]DisconnectedCacheResult{ undefined, undefined };
    var output = testOutput(monitor_results[0..], projections[0..], cache_results[0..]);
    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        &previous_monitors,
        previous_monitors.len,
        &workspaces,
        workspaces.len,
        null,
        0,
        null,
        0,
        string_bytes.ptr,
        string_bytes.len,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(outcome_apply, output.outcome);
    try std.testing.expectEqual(@as(u8, 1), output.refresh_restore_intents);
    try std.testing.expectEqual(ws_side.high, monitor_results[0].visible_workspace_id.high);
    try std.testing.expectEqual(ws_main.high, monitor_results[0].previous_visible_workspace_id.high);
    try std.testing.expectEqual(@as(usize, 1), output.disconnected_cache_result_count);
    try std.testing.expectEqual(restore_cache_source_removed_monitor, cache_results[0].source_kind);
}

test "reconcile topology restores cached workspace to reappearing monitor" {
    const string_bytes = "LeftRightReplacement";
    const left_name = StringRef{ .offset = 0, .length = 4 };
    const right_name = StringRef{ .offset = 4, .length = 5 };
    const replacement_name = StringRef{ .offset = 9, .length = 11 };
    const ws_main = UUID{ .high = 31, .low = 31 };
    const ws_side = UUID{ .high = 32, .low = 32 };

    var input = std.mem.zeroes(Input);
    input.operation = op_reconcile_topology;
    input.interaction_monitor_id = 10;
    input.has_interaction_monitor_id = 1;

    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = ws_side,
            .previous_visible_workspace_id = ws_main,
            .name = left_name,
            .is_main = 1,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 1,
            .has_name = 1,
        },
        .{
            .monitor_id = 30,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .visible_workspace_id = zeroUUID(),
            .previous_visible_workspace_id = zeroUUID(),
            .name = replacement_name,
            .is_main = 0,
            .has_visible_workspace_id = 0,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
    };
    const previous_monitors = [_]PreviousMonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = ws_side,
            .previous_visible_workspace_id = ws_main,
            .name = left_name,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 1,
            .has_name = 1,
        },
    };
    const disconnected_cache_entries = [_]DisconnectedCacheInput{
        .{
            .workspace_id = ws_side,
            .display_id = 20,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .name = right_name,
            .has_name = 1,
        },
    };
    const workspaces = [_]WorkspaceInput{
        .{
            .workspace_id = ws_main,
            .assigned_anchor_point = .{ .x = 0, .y = 1080 },
            .assignment_kind = assignment_main,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
        .{
            .workspace_id = ws_side,
            .assigned_anchor_point = .{ .x = 1920, .y = 1080 },
            .assignment_kind = assignment_secondary,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };

    var monitor_results = [_]MonitorResult{ undefined, undefined };
    var projections = [_]WorkspaceProjection{ undefined, undefined };
    var cache_results = [_]DisconnectedCacheResult{undefined};
    var output = testOutput(monitor_results[0..], projections[0..], cache_results[0..]);
    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        &previous_monitors,
        previous_monitors.len,
        &workspaces,
        workspaces.len,
        null,
        0,
        &disconnected_cache_entries,
        disconnected_cache_entries.len,
        string_bytes.ptr,
        string_bytes.len,
        &output,
    );
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(outcome_apply, output.outcome);
    try std.testing.expectEqual(ws_main.high, monitor_results[0].visible_workspace_id.high);
    try std.testing.expectEqual(ws_side.high, monitor_results[1].visible_workspace_id.high);
    try std.testing.expectEqual(@as(usize, 0), output.disconnected_cache_result_count);
}

test "reconcile topology reports disconnected cache buffer too small" {
    const string_bytes = "LeftRight";
    const left_name = StringRef{ .offset = 0, .length = 4 };
    const right_name = StringRef{ .offset = 4, .length = 5 };
    const ws_main = UUID{ .high = 41, .low = 41 };
    const ws_side = UUID{ .high = 42, .low = 42 };

    var input = std.mem.zeroes(Input);
    input.operation = op_reconcile_topology;

    const monitors = [_]MonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = ws_main,
            .previous_visible_workspace_id = zeroUUID(),
            .name = left_name,
            .is_main = 1,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
    };
    const previous_monitors = [_]PreviousMonitorInput{
        .{
            .monitor_id = 10,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 0,
            .anchor_y = 1080,
            .visible_workspace_id = ws_main,
            .previous_visible_workspace_id = zeroUUID(),
            .name = left_name,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
        .{
            .monitor_id = 20,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .frame_width = 1920,
            .frame_height = 1080,
            .anchor_x = 1920,
            .anchor_y = 1080,
            .visible_workspace_id = ws_side,
            .previous_visible_workspace_id = zeroUUID(),
            .name = right_name,
            .has_visible_workspace_id = 1,
            .has_previous_visible_workspace_id = 0,
            .has_name = 1,
        },
    };
    const workspaces = [_]WorkspaceInput{
        .{
            .workspace_id = ws_main,
            .assigned_anchor_point = .{ .x = 0, .y = 1080 },
            .assignment_kind = assignment_main,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
        .{
            .workspace_id = ws_side,
            .assigned_anchor_point = .{ .x = 1920, .y = 1080 },
            .assignment_kind = assignment_secondary,
            .specific_display_id = 0,
            .specific_display_name = .{ .offset = 0, .length = 0 },
            .remembered_tiled_focus_token = zeroToken(),
            .remembered_floating_focus_token = zeroToken(),
            .has_assigned_anchor_point = 1,
            .has_specific_display_id = 0,
            .has_specific_display_name = 0,
            .has_remembered_tiled_focus_token = 0,
            .has_remembered_floating_focus_token = 0,
        },
    };

    var monitor_results = [_]MonitorResult{undefined};
    var projections = [_]WorkspaceProjection{ undefined, undefined };
    var output = testOutput(monitor_results[0..], projections[0..], &[_]DisconnectedCacheResult{});
    const status = omniwm_workspace_session_plan(
        &input,
        &monitors,
        monitors.len,
        &previous_monitors,
        previous_monitors.len,
        &workspaces,
        workspaces.len,
        null,
        0,
        null,
        0,
        string_bytes.ptr,
        string_bytes.len,
        &output,
    );
    try std.testing.expectEqual(kernel_buffer_too_small, status);
    try std.testing.expectEqual(@as(usize, 1), output.disconnected_cache_result_count);
}
