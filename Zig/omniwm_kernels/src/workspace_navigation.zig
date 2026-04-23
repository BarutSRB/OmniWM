// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const status_ok: i32 = 0;
const status_invalid_argument: i32 = 1;
const status_buffer_too_small: i32 = 3;

const op_focus_monitor_cyclic: u32 = 0;
const op_focus_monitor_last: u32 = 1;
const op_swap_workspace_with_monitor: u32 = 2;
const op_switch_workspace_explicit: u32 = 3;
const op_switch_workspace_relative: u32 = 4;
const op_focus_workspace_anywhere: u32 = 5;
const op_workspace_back_and_forth: u32 = 6;
const op_move_window_adjacent: u32 = 7;
const op_move_window_explicit: u32 = 8;
const op_move_column_adjacent: u32 = 9;
const op_move_column_explicit: u32 = 10;
const op_move_window_to_workspace_on_monitor: u32 = 11;
const op_move_window_handle: u32 = 12;

const outcome_noop: u32 = 0;
const outcome_execute: u32 = 1;
const outcome_invalid_target: u32 = 2;
const outcome_blocked: u32 = 3;

const layout_default: u32 = 0;
const layout_niri: u32 = 1;
const layout_dwindle: u32 = 2;

const subject_none: u32 = 0;
const subject_window: u32 = 1;
const subject_column: u32 = 2;

const focus_none: u32 = 0;
const focus_workspace_handoff: u32 = 1;
const focus_resolve_target_if_present: u32 = 2;
const focus_subject: u32 = 3;
const focus_recover_source: u32 = 4;
const focus_clear_managed_focus: u32 = 5;

const direction_left: u32 = 0;
const direction_right: u32 = 1;
const direction_up: u32 = 2;
const direction_down: u32 = 3;

const UUID = extern struct {
    high: u64,
    low: u64,
};

const WindowToken = extern struct {
    pid: i32,
    window_id: i64,
};

const Input = extern struct {
    operation: u32,
    direction: u32,
    current_workspace_id: UUID,
    source_workspace_id: UUID,
    target_workspace_id: UUID,
    adjacent_fallback_workspace_number: u32,
    current_monitor_id: u32,
    previous_monitor_id: u32,
    subject_token: WindowToken,
    focused_token: WindowToken,
    pending_managed_tiled_focus_token: WindowToken,
    pending_managed_tiled_focus_workspace_id: UUID,
    confirmed_tiled_focus_token: WindowToken,
    confirmed_tiled_focus_workspace_id: UUID,
    confirmed_floating_focus_token: WindowToken,
    confirmed_floating_focus_workspace_id: UUID,
    active_column_subject_token: WindowToken,
    selected_column_subject_token: WindowToken,
    has_current_workspace_id: u8,
    has_source_workspace_id: u8,
    has_target_workspace_id: u8,
    has_adjacent_fallback_workspace_number: u8,
    has_current_monitor_id: u8,
    has_previous_monitor_id: u8,
    has_subject_token: u8,
    has_focused_token: u8,
    has_pending_managed_tiled_focus_token: u8,
    has_pending_managed_tiled_focus_workspace_id: u8,
    has_confirmed_tiled_focus_token: u8,
    has_confirmed_tiled_focus_workspace_id: u8,
    has_confirmed_floating_focus_token: u8,
    has_confirmed_floating_focus_workspace_id: u8,
    has_active_column_subject_token: u8,
    has_selected_column_subject_token: u8,
    is_non_managed_focus_active: u8,
    is_app_fullscreen_active: u8,
    wrap_around: u8,
    follow_focus: u8,
};

const MonitorSnapshot = extern struct {
    monitor_id: u32,
    frame_min_x: f64,
    frame_max_y: f64,
    center_x: f64,
    center_y: f64,
    active_workspace_id: UUID,
    previous_workspace_id: UUID,
    has_active_workspace_id: u8,
    has_previous_workspace_id: u8,
};

const WorkspaceSnapshot = extern struct {
    workspace_id: UUID,
    monitor_id: u32,
    layout_kind: u32,
    remembered_tiled_focus_token: WindowToken,
    first_tiled_focus_token: WindowToken,
    remembered_floating_focus_token: WindowToken,
    first_floating_focus_token: WindowToken,
    has_monitor_id: u8,
    has_remembered_tiled_focus_token: u8,
    has_first_tiled_focus_token: u8,
    has_remembered_floating_focus_token: u8,
    has_first_floating_focus_token: u8,
};

const Output = extern struct {
    outcome: u32,
    subject_kind: u32,
    focus_action: u32,
    source_workspace_id: UUID,
    target_workspace_id: UUID,
    target_workspace_materialization_number: u32,
    source_monitor_id: u32,
    target_monitor_id: u32,
    subject_token: WindowToken,
    resolved_focus_token: WindowToken,
    save_workspace_ids: ?[*]UUID,
    save_workspace_capacity: usize,
    save_workspace_count: usize,
    affected_workspace_ids: ?[*]UUID,
    affected_workspace_capacity: usize,
    affected_workspace_count: usize,
    affected_monitor_ids: ?[*]u32,
    affected_monitor_capacity: usize,
    affected_monitor_count: usize,
    has_source_workspace_id: u8,
    has_target_workspace_id: u8,
    has_source_monitor_id: u8,
    has_target_monitor_id: u8,
    has_subject_token: u8,
    has_resolved_focus_token: u8,
    should_materialize_target_workspace: u8,
    should_activate_target_workspace: u8,
    should_set_interaction_monitor: u8,
    should_sync_monitors_to_niri: u8,
    should_hide_focus_border: u8,
    should_commit_workspace_transition: u8,
};

const max_planned_workspace_ids: usize = 8;
const max_planned_monitor_ids: usize = 8;

const UUIDSet = struct {
    values: [max_planned_workspace_ids]UUID = std.mem.zeroes([max_planned_workspace_ids]UUID),
    count: usize = 0,

    fn append(self: *UUIDSet, value: UUID) void {
        if (uuidEq(value, zeroUUID())) return;
        for (self.values[0..self.count]) |existing| {
            if (uuidEq(existing, value)) return;
        }
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = value;
        self.count += 1;
    }
};

const MonitorIdSet = struct {
    values: [max_planned_monitor_ids]u32 = std.mem.zeroes([max_planned_monitor_ids]u32),
    count: usize = 0,

    fn append(self: *MonitorIdSet, value: u32) void {
        if (value == 0) return;
        for (self.values[0..self.count]) |existing| {
            if (existing == value) return;
        }
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = value;
        self.count += 1;
    }
};

const PlannedSets = struct {
    save_workspaces: UUIDSet = .{},
    affected_workspaces: UUIDSet = .{},
    affected_monitors: MonitorIdSet = .{},
};

const MonitorSelectionMode = enum {
    directional,
    wrapped,
};

const MonitorSelectionRank = struct {
    primary: f64,
    secondary: f64,
    distance: ?f64,
};

fn zeroUUID() UUID {
    return .{ .high = 0, .low = 0 };
}

fn zeroToken() WindowToken {
    return .{ .pid = 0, .window_id = 0 };
}

fn uuidEq(lhs: UUID, rhs: UUID) bool {
    return lhs.high == rhs.high and lhs.low == rhs.low;
}

fn tokenEq(lhs: WindowToken, rhs: WindowToken) bool {
    return lhs.pid == rhs.pid and lhs.window_id == rhs.window_id;
}

fn directionOffset(direction: u32) i32 {
    return switch (direction) {
        direction_right, direction_down => 1,
        direction_left, direction_up => -1,
        else => 0,
    };
}

fn movementOffset(direction: u32) i32 {
    return if (direction == direction_down) 1 else -1;
}

fn resetOutput(output: *Output) void {
    const save_workspace_ids = output.save_workspace_ids;
    const save_workspace_capacity = output.save_workspace_capacity;
    const affected_workspace_ids = output.affected_workspace_ids;
    const affected_workspace_capacity = output.affected_workspace_capacity;
    const affected_monitor_ids = output.affected_monitor_ids;
    const affected_monitor_capacity = output.affected_monitor_capacity;
    output.* = std.mem.zeroes(Output);
    output.save_workspace_ids = save_workspace_ids;
    output.save_workspace_capacity = save_workspace_capacity;
    output.affected_workspace_ids = affected_workspace_ids;
    output.affected_workspace_capacity = affected_workspace_capacity;
    output.affected_monitor_ids = affected_monitor_ids;
    output.affected_monitor_capacity = affected_monitor_capacity;
    output.outcome = outcome_noop;
    output.subject_kind = subject_none;
    output.focus_action = focus_none;
    output.source_workspace_id = zeroUUID();
    output.target_workspace_id = zeroUUID();
    output.target_workspace_materialization_number = 0;
    output.subject_token = zeroToken();
    output.resolved_focus_token = zeroToken();
}

fn saveWorkspace(sets: *PlannedSets, workspace_id: UUID) void {
    sets.save_workspaces.append(workspace_id);
}

fn affectWorkspace(sets: *PlannedSets, workspace_id: UUID) void {
    sets.affected_workspaces.append(workspace_id);
}

fn affectMonitor(sets: *PlannedSets, monitor_id: u32) void {
    sets.affected_monitors.append(monitor_id);
}

fn setSubject(output: *Output, kind: u32, token: WindowToken) void {
    output.subject_kind = kind;
    output.subject_token = token;
    output.has_subject_token = if (kind == subject_none) 0 else 1;
}

fn setResolvedFocus(output: *Output, token: ?WindowToken) void {
    if (token) |resolved| {
        output.resolved_focus_token = resolved;
        output.has_resolved_focus_token = 1;
    } else {
        output.resolved_focus_token = zeroToken();
        output.has_resolved_focus_token = 0;
    }
}

fn setSourceWorkspace(output: *Output, workspace: *const WorkspaceSnapshot) void {
    output.source_workspace_id = workspace.workspace_id;
    output.has_source_workspace_id = 1;
    if (workspace.has_monitor_id != 0) {
        output.source_monitor_id = workspace.monitor_id;
        output.has_source_monitor_id = 1;
    }
}

fn setTargetWorkspace(output: *Output, workspace: *const WorkspaceSnapshot) void {
    output.target_workspace_id = workspace.workspace_id;
    output.has_target_workspace_id = 1;
    if (workspace.has_monitor_id != 0) {
        output.target_monitor_id = workspace.monitor_id;
        output.has_target_monitor_id = 1;
    }
}

fn workspaceToken(has_token: u8, token: WindowToken) ?WindowToken {
    return if (has_token != 0) token else null;
}

fn inputToken(has_token: u8, token: WindowToken) ?WindowToken {
    return if (has_token != 0) token else null;
}

fn resolveWorkspaceFocusToken(
    input: Input,
    workspace: *const WorkspaceSnapshot,
) ?WindowToken {
    if (workspaceToken(workspace.has_remembered_tiled_focus_token, workspace.remembered_tiled_focus_token)) |token| {
        return token;
    }
    if (input.has_pending_managed_tiled_focus_token != 0 and
        input.has_pending_managed_tiled_focus_workspace_id != 0 and
        uuidEq(input.pending_managed_tiled_focus_workspace_id, workspace.workspace_id))
    {
        return input.pending_managed_tiled_focus_token;
    }
    if (input.has_confirmed_tiled_focus_token != 0 and
        input.has_confirmed_tiled_focus_workspace_id != 0 and
        uuidEq(input.confirmed_tiled_focus_workspace_id, workspace.workspace_id))
    {
        return input.confirmed_tiled_focus_token;
    }
    if (workspaceToken(workspace.has_first_tiled_focus_token, workspace.first_tiled_focus_token)) |token| {
        return token;
    }
    if (workspaceToken(workspace.has_remembered_floating_focus_token, workspace.remembered_floating_focus_token)) |token| {
        return token;
    }
    if (input.has_confirmed_floating_focus_token != 0 and
        input.has_confirmed_floating_focus_workspace_id != 0 and
        uuidEq(input.confirmed_floating_focus_workspace_id, workspace.workspace_id))
    {
        return input.confirmed_floating_focus_token;
    }
    if (workspaceToken(workspace.has_first_floating_focus_token, workspace.first_floating_focus_token)) |token| {
        return token;
    }
    return null;
}

fn setWorkspaceTransitionFocus(
    input: Input,
    output: *Output,
    workspace: *const WorkspaceSnapshot,
    execute_action: u32,
) void {
    const resolved_focus = resolveWorkspaceFocusToken(input, workspace);
    output.focus_action = if (resolved_focus == null) focus_clear_managed_focus else execute_action;
    setResolvedFocus(output, resolved_focus);
}

fn copyUUIDs(buffer: [*]UUID, values: []const UUID) void {
    for (values, 0..) |value, index| {
        buffer[index] = value;
    }
}

fn copyMonitorIds(buffer: [*]u32, values: []const u32) void {
    for (values, 0..) |value, index| {
        buffer[index] = value;
    }
}

fn finalizeSets(output: *Output, sets: PlannedSets) i32 {
    output.save_workspace_count = sets.save_workspaces.count;
    output.affected_workspace_count = sets.affected_workspaces.count;
    output.affected_monitor_count = sets.affected_monitors.count;

    if (sets.save_workspaces.count > output.save_workspace_capacity or
        sets.affected_workspaces.count > output.affected_workspace_capacity or
        sets.affected_monitors.count > output.affected_monitor_capacity)
    {
        return status_buffer_too_small;
    }

    if (sets.save_workspaces.count > 0) {
        copyUUIDs(output.save_workspace_ids.?, sets.save_workspaces.values[0..sets.save_workspaces.count]);
    }
    if (sets.affected_workspaces.count > 0) {
        copyUUIDs(output.affected_workspace_ids.?, sets.affected_workspaces.values[0..sets.affected_workspaces.count]);
    }
    if (sets.affected_monitors.count > 0) {
        copyMonitorIds(output.affected_monitor_ids.?, sets.affected_monitors.values[0..sets.affected_monitors.count]);
    }

    return status_ok;
}

fn monitorSortLess(
    monitors: []const MonitorSnapshot,
    lhs_index: usize,
    rhs_index: usize,
) bool {
    const lhs = monitors[lhs_index];
    const rhs = monitors[rhs_index];
    if (lhs.frame_min_x != rhs.frame_min_x) {
        return lhs.frame_min_x < rhs.frame_min_x;
    }
    if (lhs.frame_max_y != rhs.frame_max_y) {
        return lhs.frame_max_y > rhs.frame_max_y;
    }
    return lhs.monitor_id < rhs.monitor_id;
}

fn monitorSortKeyLess(lhs: MonitorSnapshot, rhs: MonitorSnapshot) bool {
    if (lhs.frame_min_x != rhs.frame_min_x) {
        return lhs.frame_min_x < rhs.frame_min_x;
    }
    if (lhs.frame_max_y != rhs.frame_max_y) {
        return lhs.frame_max_y > rhs.frame_max_y;
    }
    return lhs.monitor_id < rhs.monitor_id;
}

fn findMonitorIndexById(monitors: []const MonitorSnapshot, monitor_id: u32) ?usize {
    for (monitors, 0..) |monitor, index| {
        if (monitor.monitor_id == monitor_id) {
            return index;
        }
    }
    return null;
}

fn findWorkspaceIndexById(workspaces: []const WorkspaceSnapshot, workspace_id: UUID) ?usize {
    for (workspaces, 0..) |workspace, index| {
        if (uuidEq(workspace.workspace_id, workspace_id)) {
            return index;
        }
    }
    return null;
}

fn firstWorkspaceOnMonitor(workspaces: []const WorkspaceSnapshot, monitor_id: u32) ?usize {
    for (workspaces, 0..) |workspace, index| {
        if (workspace.has_monitor_id != 0 and workspace.monitor_id == monitor_id) {
            return index;
        }
    }
    return null;
}

fn workspaceIndexOnMonitor(
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
    workspace_id: UUID,
) ?usize {
    var filtered_index: usize = 0;
    for (workspaces) |workspace| {
        if (workspace.has_monitor_id == 0 or workspace.monitor_id != monitor_id) continue;
        if (uuidEq(workspace.workspace_id, workspace_id)) {
            return filtered_index;
        }
        filtered_index += 1;
    }
    return null;
}

fn workspaceAtMonitorIndex(
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
    desired_index: usize,
) ?usize {
    var filtered_index: usize = 0;
    for (workspaces, 0..) |workspace, index| {
        if (workspace.has_monitor_id == 0 or workspace.monitor_id != monitor_id) continue;
        if (filtered_index == desired_index) {
            return index;
        }
        filtered_index += 1;
    }
    return null;
}

fn workspaceCountOnMonitor(workspaces: []const WorkspaceSnapshot, monitor_id: u32) usize {
    var count: usize = 0;
    for (workspaces) |workspace| {
        if (workspace.has_monitor_id != 0 and workspace.monitor_id == monitor_id) {
            count += 1;
        }
    }
    return count;
}

fn activeOrFirstWorkspaceOnMonitor(
    monitors: []const MonitorSnapshot,
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
) ?usize {
    if (findMonitorIndexById(monitors, monitor_id)) |monitor_index| {
        const monitor = monitors[monitor_index];
        if (monitor.has_active_workspace_id != 0) {
            if (findWorkspaceIndexById(workspaces, monitor.active_workspace_id)) |workspace_index| {
                return workspace_index;
            }
        }
    }
    return firstWorkspaceOnMonitor(workspaces, monitor_id);
}

fn relativeWorkspaceOnMonitor(
    workspaces: []const WorkspaceSnapshot,
    monitor_id: u32,
    current_workspace_id: UUID,
    offset: i32,
    wrap_around: bool,
) ?usize {
    const count = workspaceCountOnMonitor(workspaces, monitor_id);
    if (count <= 1) return null;

    const current_index = workspaceIndexOnMonitor(workspaces, monitor_id, current_workspace_id) orelse return null;
    const desired = @as(i32, @intCast(current_index)) + offset;
    if (wrap_around) {
        const wrapped = @mod(desired, @as(i32, @intCast(count)));
        return workspaceAtMonitorIndex(workspaces, monitor_id, @intCast(wrapped));
    }
    if (desired < 0 or desired >= @as(i32, @intCast(count))) {
        return null;
    }
    return workspaceAtMonitorIndex(workspaces, monitor_id, @intCast(desired));
}

fn monitorSelectionRank(
    candidate: MonitorSnapshot,
    current: MonitorSnapshot,
    direction: u32,
    mode: MonitorSelectionMode,
) MonitorSelectionRank {
    const dx = candidate.center_x - current.center_x;
    const dy = candidate.center_y - current.center_y;

    return switch (mode) {
        .directional => switch (direction) {
            direction_left, direction_right => .{
                .primary = @abs(dx),
                .secondary = @abs(dy),
                .distance = dx * dx + dy * dy,
            },
            direction_up, direction_down => .{
                .primary = @abs(dy),
                .secondary = @abs(dx),
                .distance = dx * dx + dy * dy,
            },
            else => .{ .primary = 0, .secondary = 0, .distance = 0 },
        },
        .wrapped => switch (direction) {
            direction_right => .{ .primary = candidate.center_x, .secondary = @abs(dy), .distance = null },
            direction_left => .{ .primary = -candidate.center_x, .secondary = @abs(dy), .distance = null },
            direction_up => .{ .primary = candidate.center_y, .secondary = @abs(dx), .distance = null },
            direction_down => .{ .primary = -candidate.center_y, .secondary = @abs(dx), .distance = null },
            else => .{ .primary = 0, .secondary = 0, .distance = null },
        },
    };
}

fn betterMonitorCandidate(
    lhs: MonitorSnapshot,
    rhs: MonitorSnapshot,
    current: MonitorSnapshot,
    direction: u32,
    mode: MonitorSelectionMode,
) bool {
    const lhs_rank = monitorSelectionRank(lhs, current, direction, mode);
    const rhs_rank = monitorSelectionRank(rhs, current, direction, mode);

    if (lhs_rank.primary != rhs_rank.primary) {
        return lhs_rank.primary < rhs_rank.primary;
    }
    if (lhs_rank.secondary != rhs_rank.secondary) {
        return lhs_rank.secondary < rhs_rank.secondary;
    }
    if (lhs_rank.distance != null and rhs_rank.distance != null and lhs_rank.distance.? != rhs_rank.distance.?) {
        return lhs_rank.distance.? < rhs_rank.distance.?;
    }
    return monitorSortKeyLess(lhs, rhs);
}

fn adjacentMonitorIndex(
    monitors: []const MonitorSnapshot,
    current_monitor_id: u32,
    direction: u32,
    wrap_around: bool,
) ?usize {
    const current_index = findMonitorIndexById(monitors, current_monitor_id) orelse return null;
    const current = monitors[current_index];

    var best_directional: ?usize = null;
    var best_wrapped: ?usize = null;

    for (monitors, 0..) |candidate, candidate_index| {
        if (candidate.monitor_id == current.monitor_id) continue;

        const dx = candidate.center_x - current.center_x;
        const dy = candidate.center_y - current.center_y;
        const is_directional = switch (direction) {
            direction_left => dx < 0,
            direction_right => dx > 0,
            direction_up => dy > 0,
            direction_down => dy < 0,
            else => false,
        };

        if (is_directional) {
            if (best_directional == null or betterMonitorCandidate(
                candidate,
                monitors[best_directional.?],
                current,
                direction,
                .directional,
            )) {
                best_directional = candidate_index;
            }
        }

        if (wrap_around) {
            if (best_wrapped == null or betterMonitorCandidate(
                candidate,
                monitors[best_wrapped.?],
                current,
                direction,
                .wrapped,
            )) {
                best_wrapped = candidate_index;
            }
        }
    }

    return best_directional orelse best_wrapped;
}

fn cyclicMonitorIndex(monitors: []const MonitorSnapshot, current_monitor_id: u32, previous: bool) ?usize {
    if (monitors.len <= 1) return null;
    const current_index = findMonitorIndexById(monitors, current_monitor_id) orelse return null;

    var rank: usize = 0;
    for (monitors, 0..) |_, index| {
        if (index != current_index and monitorSortLess(monitors, index, current_index)) {
            rank += 1;
        }
    }

    const desired_rank = if (previous)
        if (rank > 0) rank - 1 else monitors.len - 1
    else
        (rank + 1) % monitors.len;

    for (monitors, 0..) |_, index| {
        var candidate_rank: usize = 0;
        for (monitors, 0..) |_, other_index| {
            if (other_index != index and monitorSortLess(monitors, other_index, index)) {
                candidate_rank += 1;
            }
        }
        if (candidate_rank == desired_rank) {
            return index;
        }
    }

    return null;
}

fn sourceWorkspaceIndex(input: Input, workspaces: []const WorkspaceSnapshot) ?usize {
    if (input.has_source_workspace_id == 0) return null;
    return findWorkspaceIndexById(workspaces, input.source_workspace_id);
}

fn explicitTargetWorkspaceIndex(input: Input, workspaces: []const WorkspaceSnapshot) ?usize {
    if (input.has_target_workspace_id == 0) return null;
    return findWorkspaceIndexById(workspaces, input.target_workspace_id);
}

fn commitTransferPlan(
    output: *Output,
    sets: *PlannedSets,
    source_workspace: ?*const WorkspaceSnapshot,
    target_workspace: *const WorkspaceSnapshot,
    subject_kind: u32,
    subject_token: WindowToken,
    follow_focus: bool,
    commit_transition: bool,
    save_source_workspace: bool,
) void {
    output.outcome = outcome_execute;
    output.focus_action = if (follow_focus) focus_subject else focus_recover_source;
    output.should_commit_workspace_transition = @intFromBool(commit_transition);
    output.should_activate_target_workspace = @intFromBool(follow_focus);
    output.should_set_interaction_monitor = @intFromBool(follow_focus);
    setSubject(output, subject_kind, subject_token);
    setTargetWorkspace(output, target_workspace);
    affectWorkspace(sets, target_workspace.workspace_id);
    if (output.has_target_monitor_id != 0) {
        affectMonitor(sets, output.target_monitor_id);
    }

    if (source_workspace) |source| {
        setSourceWorkspace(output, source);
        if (save_source_workspace) {
            saveWorkspace(sets, source.workspace_id);
        }
        affectWorkspace(sets, source.workspace_id);
        if (output.has_source_monitor_id != 0) {
            affectMonitor(sets, output.source_monitor_id);
        }
    }
}

fn commitMaterializedTransferPlan(
    output: *Output,
    sets: *PlannedSets,
    source_workspace: *const WorkspaceSnapshot,
    target_monitor_id: u32,
    target_workspace_number: u32,
    subject_kind: u32,
    subject_token: WindowToken,
) void {
    output.outcome = outcome_execute;
    output.focus_action = focus_recover_source;
    output.should_commit_workspace_transition = 1;
    output.target_workspace_materialization_number = target_workspace_number;
    output.target_monitor_id = target_monitor_id;
    output.has_target_monitor_id = 1;
    output.should_materialize_target_workspace = 1;
    setSubject(output, subject_kind, subject_token);
    setSourceWorkspace(output, source_workspace);
    saveWorkspace(sets, source_workspace.workspace_id);
    affectWorkspace(sets, source_workspace.workspace_id);
    if (output.has_source_monitor_id != 0) {
        affectMonitor(sets, output.source_monitor_id);
    }
    affectMonitor(sets, target_monitor_id);
}

fn plan(input: Input, monitors: []const MonitorSnapshot, workspaces: []const WorkspaceSnapshot, output: *Output) i32 {
    var sets = PlannedSets{};
    switch (input.operation) {
        op_switch_workspace_explicit => {
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_index];
            if (target.has_monitor_id == 0 or findMonitorIndexById(monitors, target.monitor_id) == null) {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            }
            if (input.has_current_workspace_id != 0 and uuidEq(input.current_workspace_id, target.workspace_id)) {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            }

            output.outcome = outcome_execute;
            output.should_hide_focus_border = 1;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);
            setWorkspaceTransitionFocus(input, output, target, focus_workspace_handoff);
            if (input.has_current_workspace_id != 0) {
                saveWorkspace(&sets, input.current_workspace_id);
            }
            return finalizeSets(output, sets);
        },
        op_switch_workspace_relative => {
            if (input.has_current_monitor_id == 0 or input.has_current_workspace_id == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const target_index = relativeWorkspaceOnMonitor(
                workspaces,
                input.current_monitor_id,
                input.current_workspace_id,
                directionOffset(input.direction),
                input.wrap_around != 0,
            ) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_index];
            output.outcome = outcome_execute;
            output.should_hide_focus_border = 1;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);
            setWorkspaceTransitionFocus(input, output, target, focus_workspace_handoff);
            saveWorkspace(&sets, input.current_workspace_id);
            return finalizeSets(output, sets);
        },
        op_focus_workspace_anywhere => {
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_index];
            if (target.has_monitor_id == 0 or findMonitorIndexById(monitors, target.monitor_id) == null) {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            }

            output.outcome = outcome_execute;
            output.should_hide_focus_border = 1;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_sync_monitors_to_niri = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);
            setWorkspaceTransitionFocus(input, output, target, focus_workspace_handoff);
            if (input.has_current_workspace_id != 0) {
                saveWorkspace(&sets, input.current_workspace_id);
            }
            if (input.has_current_monitor_id != 0 and input.current_monitor_id != target.monitor_id) {
                if (activeOrFirstWorkspaceOnMonitor(monitors, workspaces, target.monitor_id)) |visible_target_index| {
                    const visible_target_workspace = workspaces[visible_target_index];
                    saveWorkspace(&sets, visible_target_workspace.workspace_id);
                }
            }
            return finalizeSets(output, sets);
        },
        op_workspace_back_and_forth => {
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const current_monitor_index = findMonitorIndexById(monitors, input.current_monitor_id) orelse {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            };
            const current_monitor = monitors[current_monitor_index];
            if (current_monitor.has_previous_workspace_id == 0) {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            }
            if (current_monitor.has_active_workspace_id != 0 and uuidEq(
                current_monitor.previous_workspace_id,
                current_monitor.active_workspace_id,
            )) {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            }
            const target_index = findWorkspaceIndexById(workspaces, current_monitor.previous_workspace_id) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_index];
            output.outcome = outcome_execute;
            output.should_hide_focus_border = 1;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target);
            setWorkspaceTransitionFocus(input, output, target, focus_workspace_handoff);
            if (input.has_current_workspace_id != 0) {
                saveWorkspace(&sets, input.current_workspace_id);
            }
            return finalizeSets(output, sets);
        },
        op_focus_monitor_cyclic => {
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const target_monitor_index = cyclicMonitorIndex(
                monitors,
                input.current_monitor_id,
                input.direction == direction_left or input.direction == direction_up,
            ) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target_monitor = monitors[target_monitor_index];
            const target_workspace_index = activeOrFirstWorkspaceOnMonitor(
                monitors,
                workspaces,
                target_monitor.monitor_id,
            ) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target_workspace = &workspaces[target_workspace_index];

            output.outcome = outcome_execute;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target_workspace);
            setWorkspaceTransitionFocus(input, output, target_workspace, focus_resolve_target_if_present);
            affectWorkspace(&sets, target_workspace.workspace_id);
            affectMonitor(&sets, target_monitor.monitor_id);
            return finalizeSets(output, sets);
        },
        op_focus_monitor_last => {
            if (input.has_current_monitor_id == 0 or input.has_previous_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            if (input.current_monitor_id == input.previous_monitor_id) {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            }
            if (findMonitorIndexById(monitors, input.previous_monitor_id) == null) {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            }
            const target_workspace_index = activeOrFirstWorkspaceOnMonitor(
                monitors,
                workspaces,
                input.previous_monitor_id,
            ) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target_workspace = &workspaces[target_workspace_index];

            output.outcome = outcome_execute;
            output.should_activate_target_workspace = 1;
            output.should_set_interaction_monitor = 1;
            output.should_commit_workspace_transition = 1;
            setTargetWorkspace(output, target_workspace);
            setWorkspaceTransitionFocus(input, output, target_workspace, focus_resolve_target_if_present);
            affectWorkspace(&sets, target_workspace.workspace_id);
            affectMonitor(&sets, input.previous_monitor_id);
            return finalizeSets(output, sets);
        },
        op_swap_workspace_with_monitor => {
            if (input.has_current_monitor_id == 0 or input.has_current_workspace_id == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const source_index = findWorkspaceIndexById(workspaces, input.current_workspace_id) orelse {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            };
            const source = &workspaces[source_index];
            const target_monitor_index = adjacentMonitorIndex(
                monitors,
                input.current_monitor_id,
                input.direction,
                false,
            ) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target_monitor = monitors[target_monitor_index];
            const target_workspace_index = activeOrFirstWorkspaceOnMonitor(
                monitors,
                workspaces,
                target_monitor.monitor_id,
            ) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_workspace_index];

            output.outcome = outcome_execute;
            output.should_sync_monitors_to_niri = 1;
            output.should_commit_workspace_transition = 1;
            setSourceWorkspace(output, source);
            setTargetWorkspace(output, target);
            setWorkspaceTransitionFocus(input, output, target, focus_resolve_target_if_present);

            saveWorkspace(&sets, source.workspace_id);
            affectWorkspace(&sets, source.workspace_id);
            affectWorkspace(&sets, target.workspace_id);
            affectMonitor(&sets, input.current_monitor_id);
            affectMonitor(&sets, target_monitor.monitor_id);
            return finalizeSets(output, sets);
        },
        op_move_window_adjacent => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            };
            const source = &workspaces[source_index];
            if (input.has_focused_token == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const maybe_target_index = relativeWorkspaceOnMonitor(
                workspaces,
                input.current_monitor_id,
                source.workspace_id,
                movementOffset(input.direction),
                false,
            );
            if (maybe_target_index) |target_index| {
                commitTransferPlan(
                    output,
                    &sets,
                    source,
                    &workspaces[target_index],
                    subject_window,
                    input.focused_token,
                    false,
                    true,
                    true,
                );
            } else if (input.has_adjacent_fallback_workspace_number != 0) {
                commitMaterializedTransferPlan(
                    output,
                    &sets,
                    source,
                    input.current_monitor_id,
                    input.adjacent_fallback_workspace_number,
                    subject_window,
                    input.focused_token,
                );
            } else {
                output.outcome = outcome_noop;
            }
            return finalizeSets(output, sets);
        },
        op_move_column_adjacent => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            };
            const source = &workspaces[source_index];
            if (source.layout_kind != layout_niri or input.has_active_column_subject_token == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            if (input.has_current_monitor_id == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const maybe_target_index = relativeWorkspaceOnMonitor(
                workspaces,
                input.current_monitor_id,
                source.workspace_id,
                movementOffset(input.direction),
                false,
            );
            if (maybe_target_index) |target_index| {
                commitTransferPlan(
                    output,
                    &sets,
                    source,
                    &workspaces[target_index],
                    subject_column,
                    input.active_column_subject_token,
                    false,
                    true,
                    true,
                );
            } else if (input.has_adjacent_fallback_workspace_number != 0) {
                commitMaterializedTransferPlan(
                    output,
                    &sets,
                    source,
                    input.current_monitor_id,
                    input.adjacent_fallback_workspace_number,
                    subject_column,
                    input.active_column_subject_token,
                );
            } else {
                output.outcome = outcome_noop;
            }
            return finalizeSets(output, sets);
        },
        op_move_column_explicit => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            };
            const source = &workspaces[source_index];
            const subject_token = inputToken(input.has_active_column_subject_token, input.active_column_subject_token) orelse
                inputToken(input.has_selected_column_subject_token, input.selected_column_subject_token) orelse {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            };
            if (source.layout_kind != layout_niri) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_index];
            if (uuidEq(source.workspace_id, target.workspace_id)) {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            }
            commitTransferPlan(
                output,
                &sets,
                source,
                target,
                subject_column,
                subject_token,
                false,
                true,
                true,
            );
            return finalizeSets(output, sets);
        },
        op_move_window_explicit, op_move_window_handle => {
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_index];
            const source_index = sourceWorkspaceIndex(input, workspaces);
            const subject_token = if (input.has_subject_token != 0) input.subject_token else if (input.has_focused_token != 0) input.focused_token else zeroToken();
            if (tokenEq(subject_token, zeroToken())) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            if (source_index) |index| {
                if (uuidEq(workspaces[index].workspace_id, target.workspace_id)) {
                    output.outcome = outcome_noop;
                    return finalizeSets(output, sets);
                }
            }
            commitTransferPlan(
                output,
                &sets,
                if (source_index) |index| &workspaces[index] else null,
                target,
                subject_window,
                subject_token,
                input.follow_focus != 0,
                input.operation != op_move_window_handle,
                false,
            );
            return finalizeSets(output, sets);
        },
        op_move_window_to_workspace_on_monitor => {
            const source_index = sourceWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            };
            if (input.has_current_monitor_id == 0 or input.has_focused_token == 0) {
                output.outcome = outcome_blocked;
                return finalizeSets(output, sets);
            }
            const target_monitor_index = adjacentMonitorIndex(
                monitors,
                input.current_monitor_id,
                input.direction,
                false,
            ) orelse {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            };
            const target_monitor = monitors[target_monitor_index];
            const target_index = explicitTargetWorkspaceIndex(input, workspaces) orelse {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            };
            const target = &workspaces[target_index];
            if (target.has_monitor_id == 0 or target.monitor_id != target_monitor.monitor_id) {
                output.outcome = outcome_invalid_target;
                return finalizeSets(output, sets);
            }
            if (uuidEq(workspaces[source_index].workspace_id, target.workspace_id)) {
                output.outcome = outcome_noop;
                return finalizeSets(output, sets);
            }
            commitTransferPlan(
                output,
                &sets,
                &workspaces[source_index],
                target,
                subject_window,
                input.focused_token,
                input.follow_focus != 0,
                true,
                false,
            );
            return finalizeSets(output, sets);
        },
        else => return status_invalid_argument,
    }
}

pub export fn omniwm_workspace_navigation_plan(
    input_ptr: ?*const Input,
    monitors_ptr: ?[*]const MonitorSnapshot,
    monitor_count: usize,
    workspaces_ptr: ?[*]const WorkspaceSnapshot,
    workspace_count: usize,
    output_ptr: ?*Output,
) i32 {
    const input = input_ptr orelse return status_invalid_argument;
    const output = output_ptr orelse return status_invalid_argument;
    if (monitor_count > 0 and monitors_ptr == null) return status_invalid_argument;
    if (workspace_count > 0 and workspaces_ptr == null) return status_invalid_argument;
    if (output.save_workspace_capacity > 0 and output.save_workspace_ids == null) return status_invalid_argument;
    if (output.affected_workspace_capacity > 0 and output.affected_workspace_ids == null) return status_invalid_argument;
    if (output.affected_monitor_capacity > 0 and output.affected_monitor_ids == null) return status_invalid_argument;

    resetOutput(output);

    const monitors = if (monitor_count == 0)
        &[_]MonitorSnapshot{}
    else
        monitors_ptr.?[0..monitor_count];
    const workspaces = if (workspace_count == 0)
        &[_]WorkspaceSnapshot{}
    else
        workspaces_ptr.?[0..workspace_count];

    return plan(input.*, monitors, workspaces, output);
}

fn makeWorkspaceSnapshot(workspace_id: UUID, monitor_id: u32, layout_kind: u32) WorkspaceSnapshot {
    return .{
        .workspace_id = workspace_id,
        .monitor_id = monitor_id,
        .layout_kind = layout_kind,
        .remembered_tiled_focus_token = zeroToken(),
        .first_tiled_focus_token = zeroToken(),
        .remembered_floating_focus_token = zeroToken(),
        .first_floating_focus_token = zeroToken(),
        .has_monitor_id = 1,
        .has_remembered_tiled_focus_token = 0,
        .has_first_tiled_focus_token = 0,
        .has_remembered_floating_focus_token = 0,
        .has_first_floating_focus_token = 0,
    };
}

fn makeOutput(save_workspaces: []UUID, affected_workspaces: []UUID, affected_monitors: []u32) Output {
    return .{
        .outcome = 0,
        .subject_kind = 0,
        .focus_action = 0,
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .target_workspace_materialization_number = 0,
        .source_monitor_id = 0,
        .target_monitor_id = 0,
        .subject_token = zeroToken(),
        .resolved_focus_token = zeroToken(),
        .save_workspace_ids = if (save_workspaces.len == 0) null else save_workspaces.ptr,
        .save_workspace_capacity = save_workspaces.len,
        .save_workspace_count = 0,
        .affected_workspace_ids = if (affected_workspaces.len == 0) null else affected_workspaces.ptr,
        .affected_workspace_capacity = affected_workspaces.len,
        .affected_workspace_count = 0,
        .affected_monitor_ids = if (affected_monitors.len == 0) null else affected_monitors.ptr,
        .affected_monitor_capacity = affected_monitors.len,
        .affected_monitor_count = 0,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_source_monitor_id = 0,
        .has_target_monitor_id = 0,
        .has_subject_token = 0,
        .has_resolved_focus_token = 0,
        .should_materialize_target_workspace = 0,
        .should_activate_target_workspace = 0,
        .should_set_interaction_monitor = 0,
        .should_sync_monitors_to_niri = 0,
        .should_hide_focus_border = 0,
        .should_commit_workspace_transition = 0,
    };
}

fn makeInput(operation: u32) Input {
    return .{
        .operation = operation,
        .direction = direction_right,
        .current_workspace_id = zeroUUID(),
        .source_workspace_id = zeroUUID(),
        .target_workspace_id = zeroUUID(),
        .adjacent_fallback_workspace_number = 0,
        .current_monitor_id = 0,
        .previous_monitor_id = 0,
        .subject_token = zeroToken(),
        .focused_token = zeroToken(),
        .pending_managed_tiled_focus_token = zeroToken(),
        .pending_managed_tiled_focus_workspace_id = zeroUUID(),
        .confirmed_tiled_focus_token = zeroToken(),
        .confirmed_tiled_focus_workspace_id = zeroUUID(),
        .confirmed_floating_focus_token = zeroToken(),
        .confirmed_floating_focus_workspace_id = zeroUUID(),
        .active_column_subject_token = zeroToken(),
        .selected_column_subject_token = zeroToken(),
        .has_current_workspace_id = 0,
        .has_source_workspace_id = 0,
        .has_target_workspace_id = 0,
        .has_adjacent_fallback_workspace_number = 0,
        .has_current_monitor_id = 0,
        .has_previous_monitor_id = 0,
        .has_subject_token = 0,
        .has_focused_token = 0,
        .has_pending_managed_tiled_focus_token = 0,
        .has_pending_managed_tiled_focus_workspace_id = 0,
        .has_confirmed_tiled_focus_token = 0,
        .has_confirmed_tiled_focus_workspace_id = 0,
        .has_confirmed_floating_focus_token = 0,
        .has_confirmed_floating_focus_workspace_id = 0,
        .has_active_column_subject_token = 0,
        .has_selected_column_subject_token = 0,
        .is_non_managed_focus_active = 0,
        .is_app_fullscreen_active = 0,
        .wrap_around = 0,
        .follow_focus = 0,
    };
}

test "explicit switch targets workspace handoff and saves current workspace" {
    var save_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const target_token = WindowToken{ .pid = 42, .window_id = 4201 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 11, layout_niri),
        blk: {
            var workspace = makeWorkspaceSnapshot(ws2, 11, layout_niri);
            workspace.remembered_tiled_focus_token = target_token;
            workspace.has_remembered_tiled_focus_token = 1;
            break :blk workspace;
        },
    };
    var input = makeInput(op_switch_workspace_explicit);
    input.current_workspace_id = ws1;
    input.target_workspace_id = ws2;
    input.current_monitor_id = 11;
    input.has_current_workspace_id = 1;
    input.has_target_workspace_id = 1;
    input.has_current_monitor_id = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(focus_workspace_handoff, output.focus_action);
    try std.testing.expectEqual(@as(u8, 1), output.should_hide_focus_border);
    try std.testing.expectEqual(@as(u8, 1), output.should_commit_workspace_transition);
    try std.testing.expectEqual(@as(u8, 1), output.has_resolved_focus_token);
    try std.testing.expect(tokenEq(output.resolved_focus_token, target_token));
    try std.testing.expectEqual(@as(usize, 1), output.save_workspace_count);
    try std.testing.expect(uuidEq(save_workspaces[0], ws1));
    try std.testing.expect(uuidEq(output.target_workspace_id, ws2));
    try std.testing.expectEqual(@as(u32, 11), output.target_monitor_id);
}

test "adjacent window move plans source recovery and both affected workspaces" {
    var save_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const token = WindowToken{ .pid = 7, .window_id = 99 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 11, layout_niri),
        makeWorkspaceSnapshot(ws2, 11, layout_dwindle),
    };
    var input = makeInput(op_move_window_adjacent);
    input.direction = direction_down;
    input.current_workspace_id = ws1;
    input.source_workspace_id = ws1;
    input.current_monitor_id = 11;
    input.focused_token = token;
    input.has_current_workspace_id = 1;
    input.has_source_workspace_id = 1;
    input.has_current_monitor_id = 1;
    input.has_focused_token = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(subject_window, output.subject_kind);
    try std.testing.expect(tokenEq(output.subject_token, token));
    try std.testing.expectEqual(focus_recover_source, output.focus_action);
    try std.testing.expectEqual(@as(usize, 1), output.save_workspace_count);
    try std.testing.expectEqual(@as(usize, 2), output.affected_workspace_count);
    try std.testing.expect(uuidEq(output.source_workspace_id, ws1));
    try std.testing.expect(uuidEq(output.target_workspace_id, ws2));
}

test "adjacent window move can request numbered workspace materialization" {
    var save_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 1, .low = 1 };
    const token = WindowToken{ .pid = 7, .window_id = 99 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 11, layout_niri),
    };
    var input = makeInput(op_move_window_adjacent);
    input.direction = direction_down;
    input.current_workspace_id = ws1;
    input.source_workspace_id = ws1;
    input.current_monitor_id = 11;
    input.focused_token = token;
    input.adjacent_fallback_workspace_number = 2;
    input.has_current_workspace_id = 1;
    input.has_source_workspace_id = 1;
    input.has_current_monitor_id = 1;
    input.has_focused_token = 1;
    input.has_adjacent_fallback_workspace_number = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(@as(u8, 1), output.should_materialize_target_workspace);
    try std.testing.expectEqual(@as(u32, 2), output.target_workspace_materialization_number);
    try std.testing.expectEqual(@as(u8, 0), output.has_target_workspace_id);
    try std.testing.expectEqual(@as(u8, 1), output.has_target_monitor_id);
    try std.testing.expectEqual(@as(u32, 11), output.target_monitor_id);
    try std.testing.expectEqual(@as(usize, 1), output.affected_workspace_count);
    try std.testing.expect(uuidEq(affected_workspaces[0], ws1));
}

test "adjacent column move can request numbered workspace materialization" {
    var save_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 11, .low = 11 };
    const token = WindowToken{ .pid = 17, .window_id = 199 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 21,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 21, layout_niri),
    };
    var input = makeInput(op_move_column_adjacent);
    input.direction = direction_down;
    input.current_workspace_id = ws1;
    input.source_workspace_id = ws1;
    input.current_monitor_id = 21;
    input.active_column_subject_token = token;
    input.adjacent_fallback_workspace_number = 2;
    input.has_current_workspace_id = 1;
    input.has_source_workspace_id = 1;
    input.has_current_monitor_id = 1;
    input.has_active_column_subject_token = 1;
    input.has_adjacent_fallback_workspace_number = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(subject_column, output.subject_kind);
    try std.testing.expectEqual(@as(u8, 1), output.should_materialize_target_workspace);
    try std.testing.expectEqual(@as(u32, 2), output.target_workspace_materialization_number);
    try std.testing.expectEqual(@as(u8, 0), output.has_target_workspace_id);
    try std.testing.expectEqual(@as(u8, 1), output.has_target_monitor_id);
    try std.testing.expectEqual(@as(u32, 21), output.target_monitor_id);
}

test "wrong-monitor move target returns invalid target" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID()};
    var affected_monitors = [_]u32{0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
        .{
            .monitor_id = 22,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .center_x = 2880,
            .center_y = 540,
            .active_workspace_id = zeroUUID(),
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 0,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 11, layout_niri),
        makeWorkspaceSnapshot(ws2, 11, layout_niri),
    };
    var input = makeInput(op_move_window_to_workspace_on_monitor);
    input.direction = direction_right;
    input.current_workspace_id = ws1;
    input.source_workspace_id = ws1;
    input.target_workspace_id = ws2;
    input.current_monitor_id = 11;
    input.focused_token = WindowToken{ .pid = 9, .window_id = 901 };
    input.has_current_workspace_id = 1;
    input.has_source_workspace_id = 1;
    input.has_target_workspace_id = 1;
    input.has_current_monitor_id = 1;
    input.has_focused_token = 1;
    input.follow_focus = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_invalid_target, output.outcome);
}

test "relative workspace boundary stays a pure noop" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID()};
    var affected_monitors = [_]u32{0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 1, .low = 1 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 11, layout_niri),
    };
    var input = makeInput(op_switch_workspace_relative);
    input.direction = direction_right;
    input.current_workspace_id = ws1;
    input.current_monitor_id = 11;
    input.has_current_workspace_id = 1;
    input.has_current_monitor_id = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_noop, output.outcome);
    try std.testing.expectEqual(@as(u8, 0), output.should_hide_focus_border);
}

test "explicit window move does not request source workspace save" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID(), zeroUUID()};
    var affected_monitors = [_]u32{0, 0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 1, .low = 1 };
    const ws2 = UUID{ .high = 2, .low = 2 };
    const token = WindowToken{ .pid = 7, .window_id = 77 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 11,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
        .{
            .monitor_id = 12,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .center_x = 2880,
            .center_y = 540,
            .active_workspace_id = ws2,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 11, layout_niri),
        makeWorkspaceSnapshot(ws2, 12, layout_niri),
    };
    var input = makeInput(op_move_window_explicit);
    input.direction = direction_right;
    input.source_workspace_id = ws1;
    input.target_workspace_id = ws2;
    input.focused_token = token;
    input.has_source_workspace_id = 1;
    input.has_target_workspace_id = 1;
    input.has_focused_token = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(@as(usize, 0), output.save_workspace_count);
    try std.testing.expectEqual(@as(usize, 2), output.affected_workspace_count);
}

test "focus workspace anywhere saves current and visible target workspace" {
    var save_workspaces = [_]UUID{ zeroUUID(), zeroUUID(), zeroUUID() };
    var affected_workspaces = [_]UUID{ zeroUUID(), zeroUUID() };
    var affected_monitors = [_]u32{ 0, 0 };
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 71, .low = 71 };
    const ws2 = UUID{ .high = 72, .low = 72 };
    const ws3 = UUID{ .high = 73, .low = 73 };
    const target_token = WindowToken{ .pid = 73, .window_id = 7301 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 1000,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
        .{
            .monitor_id = 1001,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .center_x = 2880,
            .center_y = 540,
            .active_workspace_id = ws2,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 1000, layout_niri),
        makeWorkspaceSnapshot(ws2, 1001, layout_niri),
        blk: {
            var workspace = makeWorkspaceSnapshot(ws3, 1001, layout_niri);
            workspace.remembered_tiled_focus_token = target_token;
            workspace.has_remembered_tiled_focus_token = 1;
            break :blk workspace;
        },
    };
    var input = makeInput(op_focus_workspace_anywhere);
    input.direction = direction_right;
    input.current_workspace_id = ws1;
    input.target_workspace_id = ws3;
    input.current_monitor_id = 1000;
    input.has_current_workspace_id = 1;
    input.has_target_workspace_id = 1;
    input.has_current_monitor_id = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(focus_workspace_handoff, output.focus_action);
    try std.testing.expectEqual(@as(u8, 1), output.has_resolved_focus_token);
    try std.testing.expect(tokenEq(output.resolved_focus_token, target_token));
    try std.testing.expectEqual(@as(u8, 1), output.should_sync_monitors_to_niri);
    try std.testing.expectEqual(@as(usize, 2), output.save_workspace_count);
    try std.testing.expect(
        (uuidEq(save_workspaces[0], ws1) and uuidEq(save_workspaces[1], ws2)) or
            (uuidEq(save_workspaces[0], ws2) and uuidEq(save_workspaces[1], ws1)),
    );
}

test "follow-focus window move targets subject focus and activation" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{ zeroUUID(), zeroUUID() };
    var affected_monitors = [_]u32{ 0, 0 };
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 81, .low = 81 };
    const ws2 = UUID{ .high = 82, .low = 82 };
    const token = WindowToken{ .pid = 201, .window_id = 8801 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 1100,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
        .{
            .monitor_id = 1101,
            .frame_min_x = 1920,
            .frame_max_y = 1080,
            .center_x = 2880,
            .center_y = 540,
            .active_workspace_id = ws2,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 1100, layout_niri),
        makeWorkspaceSnapshot(ws2, 1101, layout_niri),
    };
    var input = makeInput(op_move_window_explicit);
    input.direction = direction_right;
    input.source_workspace_id = ws1;
    input.target_workspace_id = ws2;
    input.focused_token = token;
    input.has_source_workspace_id = 1;
    input.has_target_workspace_id = 1;
    input.has_focused_token = 1;
    input.follow_focus = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_execute, output.outcome);
    try std.testing.expectEqual(subject_window, output.subject_kind);
    try std.testing.expectEqual(focus_subject, output.focus_action);
    try std.testing.expectEqual(@as(u8, 1), output.should_activate_target_workspace);
    try std.testing.expectEqual(@as(u8, 1), output.should_set_interaction_monitor);
    try std.testing.expectEqual(@as(u8, 1), output.should_commit_workspace_transition);
    try std.testing.expectEqual(@as(usize, 2), output.affected_monitor_count);
}

test "explicit column move without selection is blocked" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID()};
    var affected_monitors = [_]u32{0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 91, .low = 91 };
    const ws2 = UUID{ .high = 92, .low = 92 };
    const token = WindowToken{ .pid = 202, .window_id = 9901 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 1200,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = zeroUUID(),
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 0,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 1200, layout_niri),
        makeWorkspaceSnapshot(ws2, 1200, layout_niri),
    };
    var input = makeInput(op_move_column_explicit);
    input.direction = direction_right;
    input.source_workspace_id = ws1;
    input.target_workspace_id = ws2;
    input.focused_token = token;
    input.has_source_workspace_id = 1;
    input.has_target_workspace_id = 1;
    input.has_focused_token = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_blocked, output.outcome);
    try std.testing.expectEqual(@as(u8, 0), output.has_subject_token);
}

test "workspace back and forth noops when previous matches active" {
    var save_workspaces = [_]UUID{zeroUUID()};
    var affected_workspaces = [_]UUID{zeroUUID()};
    var affected_monitors = [_]u32{0};
    var output = makeOutput(save_workspaces[0..], affected_workspaces[0..], affected_monitors[0..]);
    const ws1 = UUID{ .high = 101, .low = 101 };
    const monitors = [_]MonitorSnapshot{
        .{
            .monitor_id = 1300,
            .frame_min_x = 0,
            .frame_max_y = 1080,
            .center_x = 960,
            .center_y = 540,
            .active_workspace_id = ws1,
            .previous_workspace_id = ws1,
            .has_active_workspace_id = 1,
            .has_previous_workspace_id = 1,
        },
    };
    const workspaces = [_]WorkspaceSnapshot{
        makeWorkspaceSnapshot(ws1, 1300, layout_niri),
    };
    var input = makeInput(op_workspace_back_and_forth);
    input.direction = direction_right;
    input.current_workspace_id = ws1;
    input.current_monitor_id = 1300;
    input.has_current_workspace_id = 1;
    input.has_current_monitor_id = 1;

    const status = omniwm_workspace_navigation_plan(
        &input,
        &monitors,
        monitors.len,
        &workspaces,
        workspaces.len,
        &output,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(outcome_noop, output.outcome);
    try std.testing.expectEqual(@as(u8, 0), output.should_hide_focus_border);
    try std.testing.expectEqual(@as(usize, 0), output.save_workspace_count);
}
