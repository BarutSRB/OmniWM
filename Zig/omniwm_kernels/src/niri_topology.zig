// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");
const viewport_policy = @import("viewport_policy.zig");

const status_ok: i32 = 0;
const status_invalid_argument: i32 = 1;
const status_allocation_failed: i32 = 2;
const status_buffer_too_small: i32 = 3;

const op_add_window: u32 = 0;
const op_remove_window: u32 = 1;
const op_sync_windows: u32 = 2;
const op_focus: u32 = 3;
const op_focus_column: u32 = 4;
const op_focus_window_in_column: u32 = 5;
const op_focus_combined: u32 = 6;
const op_ensure_visible: u32 = 7;
const op_move_column: u32 = 8;
const op_move_window: u32 = 9;
const op_column_removal: u32 = 10;
const op_insert_window_in_new_column: u32 = 11;
const op_swap_windows: u32 = 12;
const op_insert_window_by_move: u32 = 13;

const direction_left: u32 = 0;
const direction_right: u32 = 1;
const direction_up: u32 = 2;
const direction_down: u32 = 3;

const insert_before: u32 = 0;
const insert_after: u32 = 1;

const orientation_horizontal: u32 = 0;
const orientation_vertical: u32 = 1;

const center_never: u32 = 0;
const center_always: u32 = 1;
const center_on_overflow: u32 = 2;

const viewport_none: u32 = 0;
const viewport_delta_only: u32 = 1;
const viewport_set_static: u32 = 2;
const viewport_animate: u32 = 3;

const effect_none: u32 = 0;
const effect_remove_column: u32 = 1;
const effect_add_column: u32 = 2;
const effect_move_column: u32 = 3;
const effect_expel_window: u32 = 4;
const effect_consume_window: u32 = 5;
const effect_reorder_window: u32 = 6;

const null_id: u64 = 0;
const epsilon: f64 = 0.001;

const TopologyColumnInput = extern struct {
    id: u64,
    span: f64,
    window_start_index: u32,
    window_count: u32,
    active_window_index: i32,
    is_tabbed: u8,
};

const TopologyWindowInput = extern struct {
    id: u64,
    sizing_mode: u8,
};

const TopologyInput = extern struct {
    operation: u32,
    direction: u32,
    orientation: u32,
    center_mode: u32,
    subject_window_id: u64,
    target_window_id: u64,
    selected_window_id: u64,
    focused_window_id: u64,
    active_column_index: i32,
    insert_index: i32,
    target_index: i32,
    from_column_index: i32,
    max_windows_per_column: u32,
    gap: f64,
    viewport_span: f64,
    current_view_offset: f64,
    stationary_view_offset: f64,
    scale: f64,
    default_new_column_span: f64,
    previous_active_position: f64,
    activate_prev_column_on_removal: f64,
    infinite_loop: u8,
    always_center_single_column: u8,
    animate: u8,
    has_previous_active_position: u8,
    has_activate_prev_column_on_removal: u8,
    reset_for_single_window: u8,
    is_active_workspace: u8,
    has_completed_initial_refresh: u8,
    viewport_is_gesture_or_animation: u8,
};

const TopologyColumnOutput = extern struct {
    id: u64,
    window_start_index: u32,
    window_count: u32,
    active_window_index: i32,
    is_tabbed: u8,
};

const TopologyWindowOutput = extern struct {
    id: u64,
};

const TopologyResult = extern struct {
    column_count: usize,
    window_count: usize,
    selected_window_id: u64,
    remembered_focus_window_id: u64,
    new_window_id: u64,
    fallback_window_id: u64,
    active_column_index: i32,
    source_column_index: i32,
    target_column_index: i32,
    source_window_index: i32,
    target_window_index: i32,
    viewport_action: u32,
    effect_kind: u32,
    viewport_offset_delta: f64,
    viewport_target_offset: f64,
    restore_previous_view_offset: f64,
    activate_prev_column_on_removal: f64,
    has_restore_previous_view_offset: u8,
    has_activate_prev_column_on_removal: u8,
    should_clear_activate_prev_column_on_removal: u8,
    source_column_became_empty: u8,
    inserted_before_active: u8,
    did_apply: u8,
};

const ColumnState = struct {
    id: u64 = 0,
    span: f64 = 0,
    count: usize = 0,
    active: i32 = 0,
    is_tabbed: bool = false,
};

const WindowLocation = struct {
    column: usize,
    window: usize,
};

const ViewportPlan = struct {
    offset_delta: f64 = 0,
    target_offset: f64 = 0,
    action: u32 = viewport_none,
};

const Topology = struct {
    columns: []ColumnState,
    windows: []u64,
    window_modes: []u8,
    temp_windows: []u64,
    temp_window_modes: []u8,
    column_spans: []f64,
    column_modes: []u8,
    column_count: usize,
    window_capacity: usize,

    fn init(
        allocator: std.mem.Allocator,
        column_capacity: usize,
        window_capacity_per_column: usize,
    ) !Topology {
        const safe_column_capacity = @max(column_capacity, 1);
        const safe_window_capacity = @max(window_capacity_per_column, 1);
        return .{
            .columns = try allocator.alloc(ColumnState, safe_column_capacity),
            .windows = try allocator.alloc(u64, safe_column_capacity * safe_window_capacity),
            .window_modes = try allocator.alloc(u8, safe_column_capacity * safe_window_capacity),
            .temp_windows = try allocator.alloc(u64, safe_window_capacity),
            .temp_window_modes = try allocator.alloc(u8, safe_window_capacity),
            .column_spans = try allocator.alloc(f64, safe_column_capacity),
            .column_modes = try allocator.alloc(u8, safe_column_capacity),
            .column_count = 0,
            .window_capacity = safe_window_capacity,
        };
    }

    fn deinit(self: *Topology, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
        allocator.free(self.windows);
        allocator.free(self.window_modes);
        allocator.free(self.temp_windows);
        allocator.free(self.temp_window_modes);
        allocator.free(self.column_spans);
        allocator.free(self.column_modes);
    }

    fn columnWindowSlice(self: *Topology, index: usize) []u64 {
        const start = index * self.window_capacity;
        return self.windows[start .. start + self.window_capacity];
    }

    fn columnWindowSliceConst(self: *const Topology, index: usize) []const u64 {
        const start = index * self.window_capacity;
        return self.windows[start .. start + self.window_capacity];
    }

    fn columnWindowModeSlice(self: *Topology, index: usize) []u8 {
        const start = index * self.window_capacity;
        return self.window_modes[start .. start + self.window_capacity];
    }

    fn columnWindowModeSliceConst(self: *const Topology, index: usize) []const u8 {
        const start = index * self.window_capacity;
        return self.window_modes[start .. start + self.window_capacity];
    }

    fn totalWindowCount(self: *const Topology) usize {
        var total: usize = 0;
        for (self.columns[0..self.column_count]) |column| {
            total += column.count;
        }
        return total;
    }

    fn copyColumn(self: *Topology, dst: usize, src: usize) void {
        self.columns[dst] = self.columns[src];
        const src_windows = self.columnWindowSliceConst(src);
        const dst_windows = self.columnWindowSlice(dst);
        const src_window_modes = self.columnWindowModeSliceConst(src);
        const dst_window_modes = self.columnWindowModeSlice(dst);
        for (0..self.columns[src].count) |index| {
            dst_windows[index] = src_windows[index];
            dst_window_modes[index] = src_window_modes[index];
        }
    }

    fn swapColumns(self: *Topology, lhs: usize, rhs: usize) void {
        if (lhs == rhs) return;

        const lhs_state = self.columns[lhs];
        const rhs_state = self.columns[rhs];
        const lhs_windows = self.columnWindowSlice(lhs);
        const rhs_windows = self.columnWindowSlice(rhs);
        const lhs_window_modes = self.columnWindowModeSlice(lhs);
        const rhs_window_modes = self.columnWindowModeSlice(rhs);

        for (0..lhs_state.count) |index| {
            self.temp_windows[index] = lhs_windows[index];
            self.temp_window_modes[index] = lhs_window_modes[index];
        }
        for (0..rhs_state.count) |index| {
            lhs_windows[index] = rhs_windows[index];
            lhs_window_modes[index] = rhs_window_modes[index];
        }
        for (0..lhs_state.count) |index| {
            rhs_windows[index] = self.temp_windows[index];
            rhs_window_modes[index] = self.temp_window_modes[index];
        }

        self.columns[lhs] = rhs_state;
        self.columns[rhs] = lhs_state;
    }

    fn insertColumn(self: *Topology, raw_index: usize, id: u64, span: f64, is_tabbed: bool) bool {
        if (self.column_count >= self.columns.len) return false;
        const index = @min(raw_index, self.column_count);

        var cursor = self.column_count;
        while (cursor > index) {
            self.copyColumn(cursor, cursor - 1);
            cursor -= 1;
        }

        self.columns[index] = .{
            .id = id,
            .span = span,
            .count = 0,
            .active = 0,
            .is_tabbed = is_tabbed,
        };
        self.column_count += 1;
        return true;
    }

    fn removeColumn(self: *Topology, index: usize) void {
        if (index >= self.column_count) return;
        var cursor = index;
        while (cursor + 1 < self.column_count) : (cursor += 1) {
            self.copyColumn(cursor, cursor + 1);
        }
        self.column_count -= 1;
    }

    fn insertWindow(self: *Topology, column_index: usize, raw_index: usize, id: u64, sizing_mode: u8) bool {
        if (column_index >= self.column_count) return false;
        var column = &self.columns[column_index];
        if (column.count >= self.window_capacity) return false;

        const index = @min(raw_index, column.count);
        const slice = self.columnWindowSlice(column_index);
        const mode_slice = self.columnWindowModeSlice(column_index);
        var cursor = column.count;
        while (cursor > index) {
            slice[cursor] = slice[cursor - 1];
            mode_slice[cursor] = mode_slice[cursor - 1];
            cursor -= 1;
        }
        slice[index] = id;
        mode_slice[index] = sizing_mode;
        column.count += 1;
        return true;
    }

    fn removeWindowAt(self: *Topology, location: WindowLocation) bool {
        if (location.column >= self.column_count) return false;
        var column = &self.columns[location.column];
        if (location.window >= column.count) return false;

        if (column.is_tabbed) {
            const active: usize = if (column.active < 0) 0 else @intCast(column.active);
            if (active == location.window) {
                if (column.count > 1 and location.window >= column.count - 1) {
                    column.active = @intCast(if (location.window == 0) 0 else location.window - 1);
                }
            } else if (location.window < active) {
                column.active = @intCast(if (active == 0) 0 else active - 1);
            }
        }

        const slice = self.columnWindowSlice(location.column);
        const mode_slice = self.columnWindowModeSlice(location.column);
        var cursor = location.window;
        while (cursor + 1 < column.count) : (cursor += 1) {
            slice[cursor] = slice[cursor + 1];
            mode_slice[cursor] = mode_slice[cursor + 1];
        }
        column.count -= 1;
        clampActive(column);
        return true;
    }

    fn removeWindowAtWithoutActiveAdjustment(self: *Topology, location: WindowLocation) bool {
        if (location.column >= self.column_count) return false;
        var column = &self.columns[location.column];
        if (location.window >= column.count) return false;

        const slice = self.columnWindowSlice(location.column);
        const mode_slice = self.columnWindowModeSlice(location.column);
        var cursor = location.window;
        while (cursor + 1 < column.count) : (cursor += 1) {
            slice[cursor] = slice[cursor + 1];
            mode_slice[cursor] = mode_slice[cursor + 1];
        }
        column.count -= 1;
        clampActive(column);
        return true;
    }

    fn windowModeAt(self: *const Topology, location: WindowLocation) u8 {
        if (location.column >= self.column_count) return viewport_policy.sizing_mode_normal;
        if (location.window >= self.columns[location.column].count) return viewport_policy.sizing_mode_normal;
        return self.columnWindowModeSliceConst(location.column)[location.window];
    }

    fn recomputeViewportMetadata(self: *Topology) void {
        for (self.columns[0..self.column_count], 0..) |column, index| {
            self.column_spans[index] = column.span;
            self.column_modes[index] = viewport_policy.effectiveColumnMode(
                self.columnWindowModeSliceConst(index)[0..column.count]
            );
        }
    }

    fn findWindow(self: *const Topology, id: u64) ?WindowLocation {
        if (id == null_id) return null;
        for (self.columns[0..self.column_count], 0..) |column, column_index| {
            const slice = self.columnWindowSliceConst(column_index);
            for (slice[0..column.count], 0..) |window_id, window_index| {
                if (window_id == id) {
                    return .{ .column = column_index, .window = window_index };
                }
            }
        }
        return null;
    }

    fn firstWindow(self: *const Topology) u64 {
        for (self.columns[0..self.column_count], 0..) |column, column_index| {
            if (column.count > 0) {
                return self.columnWindowSliceConst(column_index)[0];
            }
        }
        return null_id;
    }
};

fn swiftMax(lhs: f64, rhs: f64) f64 {
    return if (rhs > lhs) rhs else lhs;
}

fn swiftMin(lhs: f64, rhs: f64) f64 {
    return if (rhs < lhs) rhs else lhs;
}

fn clampInt(value: i32, min_value: i32, max_value: i32) i32 {
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}

fn clampActive(column: *ColumnState) void {
    if (column.count == 0) {
        column.active = 0;
        return;
    }
    column.active = clampInt(column.active, 0, @as(i32, @intCast(column.count - 1)));
}

fn asOptionalIndex(value: i32) ?usize {
    if (value < 0) return null;
    return @intCast(value);
}

fn directionPrimaryStep(direction: u32, orientation: u32) ?i32 {
    return switch (orientation) {
        orientation_horizontal => switch (direction) {
            direction_right => 1,
            direction_left => -1,
            else => null,
        },
        orientation_vertical => switch (direction) {
            direction_down => 1,
            direction_up => -1,
            else => null,
        },
        else => null,
    };
}

fn directionSecondaryStep(direction: u32, orientation: u32) ?i32 {
    return switch (orientation) {
        orientation_horizontal => switch (direction) {
            direction_up => 1,
            direction_down => -1,
            else => null,
        },
        orientation_vertical => switch (direction) {
            direction_right => 1,
            direction_left => -1,
            else => null,
        },
        else => null,
    };
}

fn wrapIndex(index: i32, total: usize, infinite_loop: bool) ?usize {
    if (total == 0) return null;
    if (infinite_loop) {
        const total_i32: i32 = @intCast(total);
        const wrapped = @mod(index, total_i32);
        return @intCast(wrapped);
    }
    if (index < 0 or index >= @as(i32, @intCast(total))) return null;
    return @intCast(index);
}

fn columnPosition(topology: *const Topology, index: usize, gap: f64) f64 {
    var position: f64 = 0;
    var cursor: usize = 0;
    while (cursor < index and cursor < topology.column_count) : (cursor += 1) {
        position += topology.columns[cursor].span + gap;
    }
    return position;
}

fn totalSpan(topology: *const Topology, gap: f64) f64 {
    return viewport_policy.totalSpan(topology.column_spans[0..topology.column_count], gap);
}

fn centeredOffset(topology: *const Topology, gap: f64, viewport_span: f64, index: usize) f64 {
    return viewport_policy.centeredOffset(
        topology.column_spans[0..topology.column_count],
        topology.column_modes[0..topology.column_count],
        gap,
        viewport_span,
        index,
    );
}

fn visibleOffset(
    topology: *const Topology,
    gap: f64,
    viewport_span: f64,
    index: usize,
    current_view_start: f64,
    center_mode: u32,
    always_center_single_column: bool,
    from_index: ?usize,
    scale: f64,
) f64 {
    return viewport_policy.visibleOffset(
        topology.column_spans[0..topology.column_count],
        topology.column_modes[0..topology.column_count],
        gap,
        viewport_span,
        @intCast(index),
        current_view_start,
        center_mode,
        always_center_single_column,
        from_index,
        scale,
    );
}

fn fallbackSelectionOnRemoval(topology: *const Topology, removing_id: u64) u64 {
    const location = topology.findWindow(removing_id) orelse return null_id;
    const column = topology.columns[location.column];
    const windows = topology.columnWindowSliceConst(location.column);

    if (location.window + 1 < column.count) return windows[location.window + 1];
    if (location.window > 0) return windows[location.window - 1];

    if (location.column > 0) {
        const previous = topology.columns[location.column - 1];
        if (previous.count > 0) return topology.columnWindowSliceConst(location.column - 1)[0];
    }
    if (location.column + 1 < topology.column_count) {
        const next = topology.columns[location.column + 1];
        if (next.count > 0) return topology.columnWindowSliceConst(location.column + 1)[0];
    }

    for (topology.columns[0..topology.column_count], 0..) |candidate, index| {
        if (index == location.column or candidate.count == 0) continue;
        return topology.columnWindowSliceConst(index)[0];
    }
    return null_id;
}

fn fallbackSelectionOnColumnRemoval(topology: *const Topology, removing_column_index: usize) u64 {
    if (removing_column_index >= topology.column_count) return null_id;

    if (removing_column_index > 0) {
        const previous = topology.columns[removing_column_index - 1];
        if (previous.count > 0) return topology.columnWindowSliceConst(removing_column_index - 1)[0];
    }
    if (removing_column_index + 1 < topology.column_count) {
        const next = topology.columns[removing_column_index + 1];
        if (next.count > 0) return topology.columnWindowSliceConst(removing_column_index + 1)[0];
    }

    for (topology.columns[0..topology.column_count], 0..) |candidate, index| {
        if (index == removing_column_index or candidate.count == 0) continue;
        return topology.columnWindowSliceConst(index)[0];
    }
    return null_id;
}

fn firstColumnWithWindow(topology: *const Topology, id: u64) ?usize {
    return if (topology.findWindow(id)) |location| location.column else null;
}

fn containsId(ids: []const u64, id: u64) bool {
    for (ids) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

fn ensureNonEmptyWorkspaceColumn(topology: *Topology, default_span: f64) bool {
    if (topology.totalWindowCount() != 0) return true;

    if (topology.column_count == 0) {
        return topology.insertColumn(0, 0, default_span, false);
    }

    var cursor: usize = 1;
    while (cursor < topology.column_count) {
        if (topology.columns[cursor].count == 0) {
            topology.removeColumn(cursor);
        } else {
            cursor += 1;
        }
    }
    topology.columns[0].span = if (topology.columns[0].span > 0) topology.columns[0].span else default_span;
    topology.columns[0].active = 0;
    topology.columns[0].is_tabbed = false;
    return true;
}

fn addWindow(topology: *Topology, input: TopologyInput, id: u64) bool {
    if (id == null_id or topology.findWindow(id) != null) return false;
    const default_span = if (input.default_new_column_span > 0) input.default_new_column_span else 1;

    if (topology.totalWindowCount() == 0) {
        if (!ensureNonEmptyWorkspaceColumn(topology, default_span)) return false;
        return topology.insertWindow(0, 0, id, viewport_policy.sizing_mode_normal);
    }

    const reference_column = firstColumnWithWindow(topology, input.focused_window_id) orelse firstColumnWithWindow(topology, input.selected_window_id) orelse if (topology.column_count == 0) null else topology.column_count - 1;

    const insert_index = if (reference_column) |column_index| column_index + 1 else topology.column_count;
    if (!topology.insertColumn(insert_index, 0, default_span, false)) return false;
    return topology.insertWindow(insert_index, 0, id, viewport_policy.sizing_mode_normal);
}

fn cleanupEmptyColumns(topology: *Topology, default_span: f64) void {
    var cursor: usize = 0;
    while (cursor < topology.column_count) {
        if (topology.columns[cursor].count == 0) {
            topology.removeColumn(cursor);
        } else {
            cursor += 1;
        }
    }

    if (topology.column_count == 0) {
        _ = topology.insertColumn(0, 0, default_span, false);
    }
}

fn removeWindow(topology: *Topology, id: u64, default_span: f64) bool {
    const location = topology.findWindow(id) orelse return false;
    _ = topology.removeWindowAt(location);
    if (topology.columns[location.column].count == 0) {
        topology.removeColumn(location.column);
    }
    if (topology.totalWindowCount() == 0) {
        cleanupEmptyColumns(topology, default_span);
    }
    return true;
}

fn activeIndex(input: TopologyInput, topology: *const Topology) usize {
    if (topology.column_count == 0) return 0;
    if (input.active_column_index < 0) return 0;
    return @min(@as(usize, @intCast(input.active_column_index)), topology.column_count - 1);
}

fn planEnsureVisible(
    topology: *Topology,
    input: TopologyInput,
    target_column: usize,
    previous_active_position: ?f64,
    from_column: ?usize,
) ViewportPlan {
    if (topology.column_count == 0 or target_column >= topology.column_count) return .{};
    topology.recomputeViewportMetadata();

    const active = activeIndex(input, topology);
    const old_active_pos = previous_active_position orelse columnPosition(topology, active, input.gap);
    const new_active_pos = columnPosition(topology, target_column, input.gap);
    const delta = old_active_pos - new_active_pos;
    const stationary_after_delta = input.stationary_view_offset + delta;
    const stationary_view_start = new_active_pos + stationary_after_delta;

    const target = visibleOffset(
        topology,
        input.gap,
        input.viewport_span,
        target_column,
        stationary_view_start,
        input.center_mode,
        input.always_center_single_column != 0,
        from_column,
        input.scale,
    );

    const pixel = 1.0 / swiftMax(input.scale, 1.0);
    if (@abs(delta) <= pixel and @abs(target - stationary_after_delta) <= pixel) {
        return .{};
    }
    if (@abs(target - stationary_after_delta) <= pixel) {
        return .{
            .offset_delta = delta,
            .target_offset = stationary_after_delta,
            .action = viewport_delta_only,
        };
    }

    return .{
        .offset_delta = delta,
        .target_offset = target,
        .action = if (input.animate != 0) viewport_animate else viewport_set_static,
    };
}

fn planTransitionToColumn(topology: *Topology, input: TopologyInput, target_column: usize) ViewportPlan {
    if (topology.column_count == 0 or target_column >= topology.column_count) return .{};
    topology.recomputeViewportMetadata();
    const previous_active = activeIndex(input, topology);
    const old_active_pos = columnPosition(topology, previous_active, input.gap);
    const new_active_pos = columnPosition(topology, target_column, input.gap);
    const delta = old_active_pos - new_active_pos;
    const current_after_delta = input.current_view_offset + delta;
    const target = visibleOffset(
        topology,
        input.gap,
        input.viewport_span,
        target_column,
        new_active_pos + current_after_delta,
        input.center_mode,
        input.always_center_single_column != 0,
        if (input.from_column_index >= 0) @intCast(input.from_column_index) else previous_active,
        input.scale,
    );
    const pixel = 1.0 / swiftMax(input.scale, 1.0);
    if (@abs(target - current_after_delta) < pixel) {
        return .{
            .offset_delta = delta + (target - current_after_delta),
            .target_offset = target,
            .action = viewport_delta_only,
        };
    }
    return .{
        .offset_delta = delta,
        .target_offset = target,
        .action = if (input.animate != 0) viewport_animate else viewport_set_static,
    };
}

fn applyViewportPlan(result: *TopologyResult, plan: ViewportPlan) void {
    result.viewport_offset_delta += plan.offset_delta;
    result.viewport_target_offset = plan.target_offset;
    result.viewport_action = plan.action;
}

fn focusWindowById(topology: *Topology, input: TopologyInput, id: u64, result: *TopologyResult) bool {
    const target = topology.findWindow(id) orelse return false;
    if (topology.findWindow(input.selected_window_id)) |current| {
        topology.columns[current.column].active = @intCast(current.window);
    }
    topology.columns[target.column].active = @intCast(target.window);
    result.selected_window_id = id;
    result.active_column_index = @intCast(target.column);
    const from_column = asOptionalIndex(input.from_column_index) orelse activeIndex(input, topology);
    const previous_position = if (input.has_previous_active_position != 0) input.previous_active_position else null;
    applyViewportPlan(result, planEnsureVisible(topology, input, target.column, previous_position, from_column));
    return true;
}

fn focusByDirection(topology: *Topology, input: TopologyInput, result: *TopologyResult) bool {
    const current = topology.findWindow(input.selected_window_id) orelse return false;

    if (directionPrimaryStep(input.direction, input.orientation)) |step| {
        const distance: i32 = if (input.insert_index > 0) input.insert_index else 1;
        const target_column_index = wrapIndex(
            @as(i32, @intCast(current.column)) + step * distance,
            topology.column_count,
            input.infinite_loop != 0,
        ) orelse return false;
        const target_column = topology.columns[target_column_index];
        if (target_column.count == 0) return false;
        const active = if (input.target_index >= 0 and input.target_index < @as(i32, @intCast(target_column.count)))
            @as(usize, @intCast(input.target_index))
        else
            @min(if (target_column.active < 0) 0 else @as(usize, @intCast(target_column.active)), target_column.count - 1);
        const target_id = topology.columnWindowSliceConst(target_column_index)[active];
        return focusWindowById(topology, input, target_id, result);
    }

    const step = directionSecondaryStep(input.direction, input.orientation) orelse return false;
    const column = topology.columns[current.column];
    const current_index = if (column.is_tabbed) @as(i32, @intCast(@min(if (column.active < 0) 0 else @as(usize, @intCast(column.active)), column.count - 1))) else @as(i32, @intCast(current.window));
    const target_index_i32 = current_index + step;
    if (target_index_i32 < 0 or target_index_i32 >= @as(i32, @intCast(column.count))) return false;
    const target_index: usize = @intCast(target_index_i32);
    const target_id = topology.columnWindowSliceConst(current.column)[target_index];
    return focusWindowById(topology, input, target_id, result);
}

fn focusCombined(topology: *Topology, input: TopologyInput, result: *TopologyResult) bool {
    const current = topology.findWindow(input.selected_window_id) orelse return false;
    const vertical_direction: u32 = if (input.direction == direction_left) direction_down else direction_up;
    const horizontal_direction: u32 = if (input.direction == direction_left) direction_left else direction_right;

    var vertical_input = input;
    vertical_input.direction = vertical_direction;
    if (directionSecondaryStep(vertical_direction, input.orientation)) |step| {
        const column = topology.columns[current.column];
        const current_index = if (column.is_tabbed) @as(i32, @intCast(@min(if (column.active < 0) 0 else @as(usize, @intCast(column.active)), column.count - 1))) else @as(i32, @intCast(current.window));
        const target_index_i32 = current_index + step;
        if (target_index_i32 >= 0 and target_index_i32 < @as(i32, @intCast(column.count))) {
            const target_index: usize = @intCast(target_index_i32);
            const target_id = topology.columnWindowSliceConst(current.column)[target_index];
            return focusWindowById(topology, vertical_input, target_id, result);
        }
    }

    var horizontal_input = input;
    horizontal_input.direction = horizontal_direction;
    return focusByDirection(topology, horizontal_input, result);
}

fn planColumnRemoval(topology: *const Topology, input: TopologyInput, removed_column_index: usize, result: *TopologyResult) void {
    if (removed_column_index >= topology.column_count) return;

    const active = activeIndex(input, topology);
    const post_removal_count = if (topology.column_count > 0) topology.column_count - 1 else 0;
    const fallback = fallbackSelectionOnColumnRemoval(topology, removed_column_index);

    result.effect_kind = effect_remove_column;
    result.source_column_index = @intCast(removed_column_index);
    result.fallback_window_id = fallback;
    result.selected_window_id = if (fallback != null_id) fallback else input.selected_window_id;
    result.should_clear_activate_prev_column_on_removal = 1;

    if (removed_column_index < active) {
        const offset = columnPosition(topology, removed_column_index + 1, input.gap) - columnPosition(topology, removed_column_index, input.gap);
        result.active_column_index = @intCast(active - 1);
        result.viewport_offset_delta += offset;
    } else if (removed_column_index == active and input.has_activate_prev_column_on_removal != 0) {
        result.active_column_index = @intCast(if (active == 0) 0 else active - 1);
        result.restore_previous_view_offset = input.activate_prev_column_on_removal;
        result.has_restore_previous_view_offset = 1;
    } else if (removed_column_index == active) {
        result.active_column_index = @intCast(@min(active, if (post_removal_count == 0) 0 else post_removal_count - 1));
    } else {
        result.active_column_index = @intCast(active);
    }
}

fn syncWindows(
    topology: *Topology,
    input: TopologyInput,
    desired_ids: []const u64,
    removed_seed_ids: []const u64,
    result: *TopologyResult,
) !bool {
    const default_span = if (input.default_new_column_span > 0) input.default_new_column_span else 1;
    const existing_window_count = topology.totalWindowCount();
    const initial_column_count = topology.column_count;

    var first_removed_full_column: ?usize = null;
    var fallback: u64 = null_id;

    var column_index: usize = 0;
    while (column_index < topology.column_count) {
        var all_removed = topology.columns[column_index].count > 0;
        const window_slice = topology.columnWindowSliceConst(column_index);
        for (window_slice[0..topology.columns[column_index].count]) |window_id| {
            if (containsId(desired_ids, window_id)) {
                all_removed = false;
                break;
            }
        }
        if (all_removed and first_removed_full_column == null) {
            first_removed_full_column = column_index;
            fallback = fallbackSelectionOnColumnRemoval(topology, column_index);
        }
        column_index += 1;
    }

    if (first_removed_full_column) |removed_column| {
        planColumnRemoval(topology, input, removed_column, result);
        if (fallback != null_id) {
            result.fallback_window_id = fallback;
        }
    }

    var existing_ids_count = topology.totalWindowCount();
    const allocator = std.heap.page_allocator;
    const existing_ids = try allocator.alloc(u64, existing_ids_count);
    defer allocator.free(existing_ids);
    var existing_cursor: usize = 0;
    for (topology.columns[0..topology.column_count], 0..) |column, idx| {
        const slice = topology.columnWindowSliceConst(idx);
        for (slice[0..column.count]) |window_id| {
            existing_ids[existing_cursor] = window_id;
            existing_cursor += 1;
        }
    }
    existing_ids_count = existing_cursor;

    var cursor_column: usize = 0;
    while (cursor_column < topology.column_count) {
        if (topology.columns[cursor_column].count == 0) {
            cursor_column += 1;
            continue;
        }

        var cursor_window: usize = 0;
        while (cursor_window < topology.columns[cursor_column].count) {
            const id = topology.columnWindowSliceConst(cursor_column)[cursor_window];
            if (!containsId(desired_ids, id)) {
                _ = topology.removeWindowAt(.{ .column = cursor_column, .window = cursor_window });
                if (topology.columns[cursor_column].count == 0) {
                    topology.removeColumn(cursor_column);
                    break;
                }
            } else {
                cursor_window += 1;
            }
        }
        if (cursor_column < topology.column_count and topology.columns[cursor_column].count > 0) {
            cursor_column += 1;
        }
    }

    var inserted_before_active_count: usize = 0;
    var inserted_before_active_span: f64 = 0;
    const original_active = activeIndex(input, topology);

    for (desired_ids) |desired_id| {
        if (!containsId(existing_ids[0..existing_ids_count], desired_id)) {
            const before_columns = topology.column_count;
            const active_before_insert = activeIndex(input, topology);
            if (!addWindow(topology, input, desired_id)) return false;
            result.new_window_id = desired_id;
            if (topology.column_count > before_columns) {
                const new_column_index = firstColumnWithWindow(topology, desired_id) orelse topology.column_count - 1;
                if (existing_window_count > 0 and first_removed_full_column == null and new_column_index <= original_active) {
                    inserted_before_active_count += 1;
                    inserted_before_active_span += topology.columns[new_column_index].span + input.gap;
                }
                result.effect_kind = if (result.effect_kind == effect_none) effect_add_column else result.effect_kind;
                result.target_column_index = @intCast(new_column_index);
            } else {
                _ = active_before_insert;
            }
        }
    }

    if (topology.totalWindowCount() == 0) {
        cleanupEmptyColumns(topology, default_span);
    }

    var selected = input.selected_window_id;
    if (selected != null_id and topology.findWindow(selected) == null) {
        selected = if (result.fallback_window_id != null_id) result.fallback_window_id else topology.firstWindow();
    }
    if (selected == null_id) {
        selected = topology.firstWindow();
    }

    var active = activeIndex(input, topology);
    if (inserted_before_active_count > 0) {
        active = @min(active + inserted_before_active_count, if (topology.column_count == 0) 0 else topology.column_count - 1);
        result.viewport_offset_delta -= inserted_before_active_span;
        result.inserted_before_active = 1;
    } else if (result.effect_kind == effect_remove_column and result.active_column_index >= 0) {
        active = @intCast(result.active_column_index);
    }

    result.active_column_index = @intCast(@min(active, if (topology.column_count == 0) 0 else topology.column_count - 1));
    result.selected_window_id = selected;

    if (input.reset_for_single_window != 0) {
        result.active_column_index = 0;
        result.viewport_action = viewport_set_static;
        result.viewport_target_offset = 0;
        result.viewport_offset_delta = 0;
    } else if (input.viewport_is_gesture_or_animation == 0 and input.is_active_workspace != 0 and selected != null_id) {
        if (topology.findWindow(selected)) |location| {
            var visibility_input = input;
            visibility_input.active_column_index = result.active_column_index;
            visibility_input.stationary_view_offset = input.stationary_view_offset + result.viewport_offset_delta;
            const from_index = if (first_removed_full_column) |removed| removed else activeIndex(input, topology);
            const plan = planEnsureVisible(topology, visibility_input, location.column, null, from_index);
            applyViewportPlan(result, plan);
            result.active_column_index = @intCast(location.column);
        }
    }

    if (input.has_completed_initial_refresh != 0 and input.is_active_workspace != 0 and result.new_window_id != null_id) {
        selected = result.new_window_id;
        result.selected_window_id = selected;
        result.remembered_focus_window_id = selected;
        if (topology.findWindow(selected)) |location| {
            if (existing_window_count == 0) {
                if (input.reset_for_single_window != 0) {
                    result.active_column_index = 0;
                    result.viewport_action = viewport_set_static;
                    result.viewport_target_offset = 0;
                    result.viewport_offset_delta = 0;
                } else {
                    const plan = planTransitionToColumn(topology, input, 0);
                    result.active_column_index = 0;
                    result.viewport_offset_delta = plan.offset_delta;
                    result.viewport_target_offset = plan.target_offset;
                    result.viewport_action = plan.action;
                }
            } else {
                var arrival_input = input;
                arrival_input.active_column_index = result.active_column_index;
                arrival_input.stationary_view_offset = input.stationary_view_offset + result.viewport_offset_delta;
                const previous_active = activeIndex(input, topology);
                const plan = planEnsureVisible(topology, arrival_input, location.column, null, previous_active);
                applyViewportPlan(result, plan);
                result.active_column_index = @intCast(location.column);
                if (location.column == previous_active + 1) {
                    result.has_activate_prev_column_on_removal = 1;
                    result.activate_prev_column_on_removal = input.stationary_view_offset + result.viewport_offset_delta;
                }
            }
        }
    }

    if (initial_column_count == 0 and topology.column_count > 0 and result.effect_kind == effect_none) {
        result.effect_kind = effect_add_column;
        result.target_column_index = 0;
    }

    _ = removed_seed_ids;
    return true;
}

fn moveColumn(topology: *Topology, input: TopologyInput, result: *TopologyResult) bool {
    if (!(input.direction == direction_left or input.direction == direction_right)) return false;
    const current_location = topology.findWindow(input.subject_window_id) orelse return false;
    const current_index = current_location.column;
    const step: i32 = if (input.direction == direction_right) 1 else -1;
    const target_index = wrapIndex(
        @as(i32, @intCast(current_index)) + step,
        topology.column_count,
        input.infinite_loop != 0,
    ) orelse return false;
    if (target_index == current_index) return false;

    const current_pos_before = columnPosition(topology, current_index, input.gap);
    topology.swapColumns(current_index, target_index);
    const new_current_pos_at_original_index = columnPosition(topology, current_index, input.gap);

    result.viewport_offset_delta = -new_current_pos_at_original_index + current_pos_before;
    result.effect_kind = effect_move_column;
    result.source_column_index = @intCast(current_index);
    result.target_column_index = @intCast(target_index);
    result.selected_window_id = input.selected_window_id;

    var visibility_input = input;
    visibility_input.active_column_index = input.active_column_index;
    visibility_input.stationary_view_offset = input.stationary_view_offset + result.viewport_offset_delta;
    const plan = planEnsureVisible(topology, visibility_input, target_index, null, current_index);
    applyViewportPlan(result, plan);
    result.active_column_index = @intCast(target_index);
    return true;
}

fn moveWindow(topology: *Topology, input: TopologyInput, result: *TopologyResult) bool {
    const location = topology.findWindow(input.subject_window_id) orelse return false;
    const subject_mode = topology.windowModeAt(location);

    if (directionSecondaryStep(input.direction, input.orientation)) |step| {
        const column = &topology.columns[location.column];
        const target_i32 = @as(i32, @intCast(location.window)) + step;
        if (target_i32 < 0 or target_i32 >= @as(i32, @intCast(column.count))) return false;
        const target: usize = @intCast(target_i32);
        const slice = topology.columnWindowSlice(location.column);
        const mode_slice = topology.columnWindowModeSlice(location.column);
        const other_id = slice[target];
        const other_mode = mode_slice[target];
        slice[target] = input.subject_window_id;
        mode_slice[target] = subject_mode;
        slice[location.window] = other_id;
        mode_slice[location.window] = other_mode;
        if (column.is_tabbed) {
            const active = if (column.active < 0) 0 else @as(usize, @intCast(column.active));
            if (active == location.window) {
                column.active = @intCast(target);
            } else if (active == target) {
                column.active = @intCast(location.window);
            }
        }
        result.effect_kind = effect_reorder_window;
        result.source_column_index = @intCast(location.column);
        result.target_column_index = @intCast(location.column);
        result.source_window_index = @intCast(location.window);
        result.target_window_index = @intCast(target);
        result.selected_window_id = input.selected_window_id;
        result.active_column_index = input.active_column_index;
        return true;
    }

    if (!(input.direction == direction_left or input.direction == direction_right)) return false;

    const current_column_index = location.column;
    const current_column = topology.columns[current_column_index];
    const step: i32 = if (input.direction == direction_right) 1 else -1;

    if (current_column.count > 1) {
        const new_column_index = if (input.direction == direction_right) current_column_index + 1 else current_column_index;
        _ = topology.removeWindowAt(location);
        if (!topology.insertColumn(new_column_index, 0, input.default_new_column_span, false)) return false;
        if (!topology.insertWindow(new_column_index, 0, input.subject_window_id, subject_mode)) return false;
        result.effect_kind = effect_expel_window;
        result.source_column_index = @intCast(current_column_index);
        result.target_column_index = @intCast(new_column_index);
        result.source_window_index = @intCast(location.window);
        result.target_window_index = 0;
        result.selected_window_id = input.selected_window_id;
        const plan = planEnsureVisible(topology, input, new_column_index, null, activeIndex(input, topology));
        applyViewportPlan(result, plan);
        result.active_column_index = @intCast(new_column_index);
        return true;
    }

    const neighbor_index = wrapIndex(
        @as(i32, @intCast(current_column_index)) + step,
        topology.column_count,
        input.infinite_loop != 0,
    ) orelse return false;
    if (neighbor_index == current_column_index) return false;
    if (topology.columns[neighbor_index].count >= @as(usize, @intCast(@max(input.max_windows_per_column, 1)))) return false;

    const previous_active = activeIndex(input, topology);
    const previous_active_position = columnPosition(topology, previous_active, input.gap);
    _ = topology.removeWindowAt(location);
    var adjusted_neighbor = neighbor_index;
    if (current_column_index < neighbor_index) {
        topology.removeColumn(current_column_index);
        adjusted_neighbor -= 1;
    } else {
        topology.removeColumn(current_column_index);
    }
    if (!topology.insertWindow(adjusted_neighbor, 0, input.subject_window_id, subject_mode)) return false;
    if (topology.columns[adjusted_neighbor].is_tabbed) {
        topology.columns[adjusted_neighbor].active = 0;
    }

    result.effect_kind = effect_consume_window;
    result.source_column_index = @intCast(current_column_index);
    result.target_column_index = @intCast(adjusted_neighbor);
    result.source_window_index = @intCast(location.window);
    result.target_window_index = 0;
    result.source_column_became_empty = 1;
    result.selected_window_id = input.subject_window_id;
    const plan = planEnsureVisible(topology, input, adjusted_neighbor, previous_active_position, previous_active);
    applyViewportPlan(result, plan);
    result.active_column_index = @intCast(adjusted_neighbor);
    return true;
}

fn insertWindowInNewColumn(topology: *Topology, input: TopologyInput, result: *TopologyResult) bool {
    const location = topology.findWindow(input.subject_window_id) orelse return false;
    const subject_mode = topology.windowModeAt(location);
    const source_column_index = location.column;
    _ = topology.removeWindowAt(location);

    var insert_index: usize = if (input.insert_index < 0) 0 else @intCast(input.insert_index);
    insert_index = @min(insert_index, topology.column_count);
    if (!topology.insertColumn(insert_index, 0, input.default_new_column_span, false)) return false;
    if (!topology.insertWindow(insert_index, 0, input.subject_window_id, subject_mode)) return false;

    var adjusted_source = source_column_index;
    if (insert_index <= source_column_index) {
        adjusted_source += 1;
    }
    if (adjusted_source < topology.column_count and topology.columns[adjusted_source].count == 0) {
        topology.removeColumn(adjusted_source);
        if (adjusted_source < insert_index) {
            insert_index -= 1;
        }
    }

    result.effect_kind = effect_add_column;
    result.source_column_index = @intCast(source_column_index);
    result.target_column_index = @intCast(insert_index);
    result.source_window_index = @intCast(location.window);
    result.target_window_index = 0;
    result.selected_window_id = input.subject_window_id;
    const plan = planEnsureVisible(topology, input, insert_index, null, activeIndex(input, topology));
    applyViewportPlan(result, plan);
    result.active_column_index = @intCast(insert_index);
    return true;
}

fn swapWindows(topology: *Topology, input: TopologyInput, result: *TopologyResult) bool {
    const source_location = topology.findWindow(input.subject_window_id) orelse return false;
    const target_location = topology.findWindow(input.target_window_id) orelse return false;
    if (source_location.column == target_location.column and source_location.window == target_location.window) {
        return false;
    }

    const source_slice = topology.columnWindowSlice(source_location.column);
    const target_slice = topology.columnWindowSlice(target_location.column);
    const source_mode_slice = topology.columnWindowModeSlice(source_location.column);
    const target_mode_slice = topology.columnWindowModeSlice(target_location.column);
    const source_mode = source_mode_slice[source_location.window];
    const target_mode = target_mode_slice[target_location.window];
    source_slice[source_location.window] = input.target_window_id;
    source_mode_slice[source_location.window] = target_mode;
    target_slice[target_location.window] = input.subject_window_id;
    target_mode_slice[target_location.window] = source_mode;

    clampActive(&topology.columns[source_location.column]);
    if (target_location.column != source_location.column) {
        clampActive(&topology.columns[target_location.column]);
    }

    result.effect_kind = effect_reorder_window;
    result.source_column_index = @intCast(source_location.column);
    result.target_column_index = @intCast(target_location.column);
    result.source_window_index = @intCast(source_location.window);
    result.target_window_index = @intCast(target_location.window);
    result.selected_window_id = input.selected_window_id;

    const previous_position = columnPosition(topology, activeIndex(input, topology), input.gap);
    const plan = planEnsureVisible(topology, input, target_location.column, previous_position, activeIndex(input, topology));
    applyViewportPlan(result, plan);
    result.active_column_index = @intCast(target_location.column);
    return true;
}

fn insertWindowByMove(topology: *Topology, input: TopologyInput, result: *TopologyResult) bool {
    const source_location = topology.findWindow(input.subject_window_id) orelse return false;
    const subject_mode = topology.windowModeAt(source_location);
    const target_location_before_removal = topology.findWindow(input.target_window_id) orelse return false;
    if (source_location.column == target_location_before_removal.column and
        source_location.window == target_location_before_removal.window)
    {
        return false;
    }
    if (input.insert_index != @as(i32, @intCast(insert_before)) and
        input.insert_index != @as(i32, @intCast(insert_after)))
    {
        return false;
    }

    const same_column = source_location.column == target_location_before_removal.column;
    const source_column_will_be_empty = topology.columns[source_location.column].count == 1 and !same_column;

    _ = topology.removeWindowAtWithoutActiveAdjustment(source_location);

    var target_column_index = target_location_before_removal.column;
    var target_window_index = target_location_before_removal.window;
    if (same_column) {
        const target_after_removal = topology.findWindow(input.target_window_id) orelse return false;
        target_column_index = target_after_removal.column;
        target_window_index = target_after_removal.window;
    } else if (source_location.column < target_column_index and source_column_will_be_empty) {
        topology.removeColumn(source_location.column);
        target_column_index -= 1;
    } else if (source_column_will_be_empty) {
        topology.removeColumn(source_location.column);
    }

    var insert_index = target_window_index;
    if (input.insert_index == @as(i32, @intCast(insert_after))) {
        insert_index += 1;
    }

    if (!topology.insertWindow(target_column_index, insert_index, input.subject_window_id, subject_mode)) return false;
    const inserted_location = topology.findWindow(input.subject_window_id) orelse return false;

    clampActive(&topology.columns[inserted_location.column]);
    if (source_location.column < topology.column_count) {
        clampActive(&topology.columns[source_location.column]);
    }

    result.effect_kind = effect_reorder_window;
    result.source_column_index = @intCast(source_location.column);
    result.target_column_index = @intCast(inserted_location.column);
    result.source_window_index = @intCast(source_location.window);
    result.target_window_index = @intCast(inserted_location.window);
    result.source_column_became_empty = @intFromBool(source_column_will_be_empty);
    result.selected_window_id = input.selected_window_id;
    const plan = planEnsureVisible(topology, input, inserted_location.column, null, activeIndex(input, topology));
    applyViewportPlan(result, plan);
    result.active_column_index = @intCast(inserted_location.column);
    return true;
}

fn writeOutputs(
    topology: *const Topology,
    column_outputs: []TopologyColumnOutput,
    window_outputs: []TopologyWindowOutput,
    result: *TopologyResult,
) i32 {
    const total_windows = topology.totalWindowCount();
    if (column_outputs.len < topology.column_count or window_outputs.len < total_windows) {
        result.column_count = topology.column_count;
        result.window_count = total_windows;
        return status_buffer_too_small;
    }

    var window_cursor: usize = 0;
    for (topology.columns[0..topology.column_count], 0..) |column, column_index| {
        column_outputs[column_index] = .{
            .id = column.id,
            .window_start_index = @intCast(window_cursor),
            .window_count = @intCast(column.count),
            .active_window_index = column.active,
            .is_tabbed = @intFromBool(column.is_tabbed),
        };
        const slice = topology.columnWindowSliceConst(column_index);
        for (slice[0..column.count]) |id| {
            window_outputs[window_cursor] = .{ .id = id };
            window_cursor += 1;
        }
    }

    result.column_count = topology.column_count;
    result.window_count = total_windows;
    return status_ok;
}

fn buildTopology(
    allocator: std.mem.Allocator,
    columns: []const TopologyColumnInput,
    windows: []const TopologyWindowInput,
    desired_count: usize,
) !Topology {
    const column_capacity = columns.len + desired_count + 2;
    const window_capacity = @max(windows.len + desired_count + 1, 1);
    var topology = try Topology.init(allocator, column_capacity, window_capacity);
    errdefer topology.deinit(allocator);

    for (columns, 0..) |column_input, index| {
        topology.columns[index] = .{
            .id = column_input.id,
            .span = column_input.span,
            .count = 0,
            .active = column_input.active_window_index,
            .is_tabbed = column_input.is_tabbed != 0,
        };
        topology.column_count += 1;

        const start: usize = @intCast(column_input.window_start_index);
        const count: usize = @intCast(column_input.window_count);
        if (start + count > windows.len or count > topology.window_capacity) {
            return error.InvalidTopology;
        }
        const slice = topology.columnWindowSlice(index);
        const mode_slice = topology.columnWindowModeSlice(index);
        for (0..count) |window_index| {
            slice[window_index] = windows[start + window_index].id;
            mode_slice[window_index] = windows[start + window_index].sizing_mode;
        }
        topology.columns[index].count = count;
        clampActive(&topology.columns[index]);
    }

    topology.recomputeViewportMetadata();
    return topology;
}

pub export fn omniwm_niri_topology_plan(
    input_ptr: [*c]const TopologyInput,
    columns_ptr: [*c]const TopologyColumnInput,
    column_count: usize,
    windows_ptr: [*c]const TopologyWindowInput,
    window_count: usize,
    desired_ids_ptr: [*c]const u64,
    desired_id_count: usize,
    removed_ids_ptr: [*c]const u64,
    removed_id_count: usize,
    column_outputs_ptr: [*c]TopologyColumnOutput,
    column_output_capacity: usize,
    window_outputs_ptr: [*c]TopologyWindowOutput,
    window_output_capacity: usize,
    result_ptr: [*c]TopologyResult,
) i32 {
    if (input_ptr == null or result_ptr == null) return status_invalid_argument;
    if ((column_count > 0 and columns_ptr == null) or (window_count > 0 and windows_ptr == null)) {
        return status_invalid_argument;
    }
    if ((desired_id_count > 0 and desired_ids_ptr == null) or (removed_id_count > 0 and removed_ids_ptr == null)) {
        return status_invalid_argument;
    }
    if ((column_output_capacity > 0 and column_outputs_ptr == null) or (window_output_capacity > 0 and window_outputs_ptr == null)) {
        return status_invalid_argument;
    }

    const input_pointer: *const TopologyInput = @ptrCast(input_ptr);
    const result: *TopologyResult = @ptrCast(result_ptr);
    const input = input_pointer.*;
    const columns = if (column_count == 0) &[_]TopologyColumnInput{} else @as([*]const TopologyColumnInput, @ptrCast(columns_ptr))[0..column_count];
    const windows = if (window_count == 0) &[_]TopologyWindowInput{} else @as([*]const TopologyWindowInput, @ptrCast(windows_ptr))[0..window_count];
    const desired_ids = if (desired_id_count == 0) &[_]u64{} else @as([*]const u64, @ptrCast(desired_ids_ptr))[0..desired_id_count];
    const removed_ids = if (removed_id_count == 0) &[_]u64{} else @as([*]const u64, @ptrCast(removed_ids_ptr))[0..removed_id_count];
    var empty_column_outputs: [0]TopologyColumnOutput = .{};
    var empty_window_outputs: [0]TopologyWindowOutput = .{};
    const column_outputs = if (column_output_capacity == 0)
        empty_column_outputs[0..0]
    else
        @as([*]TopologyColumnOutput, @ptrCast(column_outputs_ptr))[0..column_output_capacity];
    const window_outputs = if (window_output_capacity == 0)
        empty_window_outputs[0..0]
    else
        @as([*]TopologyWindowOutput, @ptrCast(window_outputs_ptr))[0..window_output_capacity];
    result.* = .{
        .column_count = 0,
        .window_count = 0,
        .selected_window_id = input.selected_window_id,
        .remembered_focus_window_id = null_id,
        .new_window_id = null_id,
        .fallback_window_id = null_id,
        .active_column_index = input.active_column_index,
        .source_column_index = -1,
        .target_column_index = -1,
        .source_window_index = -1,
        .target_window_index = -1,
        .viewport_action = viewport_none,
        .effect_kind = effect_none,
        .viewport_offset_delta = 0,
        .viewport_target_offset = input.stationary_view_offset,
        .restore_previous_view_offset = 0,
        .activate_prev_column_on_removal = 0,
        .has_restore_previous_view_offset = 0,
        .has_activate_prev_column_on_removal = 0,
        .should_clear_activate_prev_column_on_removal = 0,
        .source_column_became_empty = 0,
        .inserted_before_active = 0,
        .did_apply = 0,
    };

    const allocator = std.heap.page_allocator;
    var topology = buildTopology(allocator, columns, windows, desired_id_count) catch |err| switch (err) {
        error.OutOfMemory => return status_allocation_failed,
        else => return status_invalid_argument,
    };
    defer topology.deinit(allocator);

    const default_span = if (input.default_new_column_span > 0) input.default_new_column_span else 1;
    const applied = switch (input.operation) {
        op_add_window => blk: {
            const added = addWindow(&topology, input, input.subject_window_id);
            result.new_window_id = if (added) input.subject_window_id else null_id;
            result.effect_kind = if (added) effect_add_column else effect_none;
            if (topology.findWindow(input.subject_window_id)) |location| {
                result.target_column_index = @intCast(location.column);
                result.selected_window_id = input.subject_window_id;
            }
            break :blk added;
        },
        op_remove_window => blk: {
            result.fallback_window_id = fallbackSelectionOnRemoval(&topology, input.subject_window_id);
            const removed = removeWindow(&topology, input.subject_window_id, default_span);
            result.selected_window_id = if (input.selected_window_id == input.subject_window_id) result.fallback_window_id else input.selected_window_id;
            if (result.selected_window_id == null_id or topology.findWindow(result.selected_window_id) == null) {
                result.selected_window_id = topology.firstWindow();
            }
            break :blk removed;
        },
        op_sync_windows => syncWindows(&topology, input, desired_ids, removed_ids, result) catch |err| switch (err) {
            error.OutOfMemory => return status_allocation_failed,
        },
        op_focus => focusByDirection(&topology, input, result),
        op_focus_column => blk: {
            const target = asOptionalIndex(input.target_index) orelse break :blk false;
            if (target >= topology.column_count or topology.columns[target].count == 0) break :blk false;
            const active = @min(if (topology.columns[target].active < 0) 0 else @as(usize, @intCast(topology.columns[target].active)), topology.columns[target].count - 1);
            const target_id = topology.columnWindowSliceConst(target)[active];
            break :blk focusWindowById(&topology, input, target_id, result);
        },
        op_focus_window_in_column => blk: {
            const current = topology.findWindow(input.selected_window_id) orelse break :blk false;
            const target_window = asOptionalIndex(input.target_index) orelse break :blk false;
            if (target_window >= topology.columns[current.column].count) break :blk false;
            const target_id = topology.columnWindowSliceConst(current.column)[target_window];
            break :blk focusWindowById(&topology, input, target_id, result);
        },
        op_focus_combined => focusCombined(&topology, input, result),
        op_ensure_visible => blk: {
            const location = topology.findWindow(input.subject_window_id) orelse break :blk false;
            const previous_position = if (input.has_previous_active_position != 0) input.previous_active_position else null;
            const from_column = asOptionalIndex(input.from_column_index) orelse activeIndex(input, &topology);
            const plan = planEnsureVisible(&topology, input, location.column, previous_position, from_column);
            applyViewportPlan(result, plan);
            result.active_column_index = @intCast(location.column);
            result.should_clear_activate_prev_column_on_removal = 1;
            break :blk true;
        },
        op_move_column => moveColumn(&topology, input, result),
        op_move_window => moveWindow(&topology, input, result),
        op_column_removal => blk: {
            const target = asOptionalIndex(input.target_index) orelse break :blk false;
            if (target >= topology.column_count) break :blk false;
            planColumnRemoval(&topology, input, target, result);
            break :blk true;
        },
        op_insert_window_in_new_column => insertWindowInNewColumn(&topology, input, result),
        op_swap_windows => swapWindows(&topology, input, result),
        op_insert_window_by_move => insertWindowByMove(&topology, input, result),
        else => return status_invalid_argument,
    };
    result.did_apply = @intFromBool(applied);

    if (result.active_column_index < 0 and topology.column_count > 0) {
        result.active_column_index = 0;
    } else if (topology.column_count > 0 and @as(usize, @intCast(result.active_column_index)) >= topology.column_count) {
        result.active_column_index = @intCast(topology.column_count - 1);
    }

    return writeOutputs(&topology, column_outputs, window_outputs, result);
}

test "niri topology fallback prefers next sibling" {
    const allocator = std.testing.allocator;
    const columns = [_]TopologyColumnInput{.{
        .id = 1,
        .span = 500,
        .window_start_index = 0,
        .window_count = 3,
        .active_window_index = 1,
        .is_tabbed = 0,
    }};
    const windows = [_]TopologyWindowInput{
        .{ .id = 10, .sizing_mode = viewport_policy.sizing_mode_normal },
        .{ .id = 20, .sizing_mode = viewport_policy.sizing_mode_normal },
        .{ .id = 30, .sizing_mode = viewport_policy.sizing_mode_normal },
    };
    var topology = try buildTopology(allocator, &columns, &windows, 0);
    defer topology.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 30), fallbackSelectionOnRemoval(&topology, 20));
}

test "niri topology focus right centers overflowing edge pair in overflow mode" {
    var input = TopologyInput{
        .operation = op_focus,
        .direction = direction_right,
        .orientation = orientation_horizontal,
        .center_mode = center_on_overflow,
        .subject_window_id = 0,
        .target_window_id = 0,
        .selected_window_id = 2,
        .focused_window_id = 0,
        .active_column_index = 1,
        .insert_index = 0,
        .target_index = 0,
        .from_column_index = -1,
        .max_windows_per_column = 1,
        .gap = 8,
        .viewport_span = 1008,
        .current_view_offset = -508,
        .stationary_view_offset = -508,
        .scale = 2,
        .default_new_column_span = 500,
        .previous_active_position = 0,
        .activate_prev_column_on_removal = 0,
        .infinite_loop = 0,
        .always_center_single_column = 0,
        .animate = 0,
        .has_previous_active_position = 0,
        .has_activate_prev_column_on_removal = 0,
        .reset_for_single_window = 0,
        .is_active_workspace = 1,
        .has_completed_initial_refresh = 1,
        .viewport_is_gesture_or_animation = 0,
    };
    const columns = [_]TopologyColumnInput{
        .{ .id = 1, .span = 500, .window_start_index = 0, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
        .{ .id = 2, .span = 500, .window_start_index = 1, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
        .{ .id = 3, .span = 500, .window_start_index = 2, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
    };
    const windows = [_]TopologyWindowInput{
        .{ .id = 1, .sizing_mode = viewport_policy.sizing_mode_normal },
        .{ .id = 2, .sizing_mode = viewport_policy.sizing_mode_normal },
        .{ .id = 3, .sizing_mode = viewport_policy.sizing_mode_normal },
    };
    var column_outputs: [3]TopologyColumnOutput = undefined;
    var window_outputs: [3]TopologyWindowOutput = undefined;
    var result: TopologyResult = undefined;

    const status = omniwm_niri_topology_plan(
        &input,
        &columns,
        columns.len,
        &windows,
        windows.len,
        null,
        0,
        null,
        0,
        &column_outputs,
        column_outputs.len,
        &window_outputs,
        window_outputs.len,
        &result,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(@as(u64, 3), result.selected_window_id);
    try std.testing.expectEqual(@as(i32, 2), result.active_column_index);
    try std.testing.expectEqual(viewport_set_static, result.viewport_action);
    try std.testing.expect(@abs(result.viewport_target_offset + 254) < 0.01);
}

test "niri topology focus at edge preserves selected window" {
    var input = TopologyInput{
        .operation = op_focus,
        .direction = direction_left,
        .orientation = orientation_horizontal,
        .center_mode = center_on_overflow,
        .subject_window_id = 0,
        .target_window_id = 0,
        .selected_window_id = 10,
        .focused_window_id = 0,
        .active_column_index = 0,
        .insert_index = 0,
        .target_index = 0,
        .from_column_index = -1,
        .max_windows_per_column = 1,
        .gap = 8,
        .viewport_span = 1000,
        .current_view_offset = 0,
        .stationary_view_offset = 0,
        .scale = 2,
        .default_new_column_span = 400,
        .previous_active_position = 0,
        .activate_prev_column_on_removal = 0,
        .infinite_loop = 0,
        .always_center_single_column = 0,
        .animate = 0,
        .has_previous_active_position = 0,
        .has_activate_prev_column_on_removal = 0,
        .reset_for_single_window = 0,
        .is_active_workspace = 1,
        .has_completed_initial_refresh = 1,
        .viewport_is_gesture_or_animation = 0,
    };
    const columns = [_]TopologyColumnInput{
        .{ .id = 1, .span = 400, .window_start_index = 0, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
    };
    const windows = [_]TopologyWindowInput{
        .{ .id = 10, .sizing_mode = viewport_policy.sizing_mode_normal },
    };
    var column_outputs: [1]TopologyColumnOutput = undefined;
    var window_outputs: [1]TopologyWindowOutput = undefined;
    var result: TopologyResult = undefined;

    const status = omniwm_niri_topology_plan(
        &input,
        &columns,
        columns.len,
        &windows,
        windows.len,
        null,
        0,
        null,
        0,
        &column_outputs,
        column_outputs.len,
        &window_outputs,
        window_outputs.len,
        &result,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(@as(u64, 10), result.selected_window_id);
    try std.testing.expectEqual(@as(i32, 0), result.active_column_index);
    try std.testing.expectEqual(@as(u8, 0), result.did_apply);
    try std.testing.expectEqual(@as(usize, 1), result.window_count);
}

test "niri topology failed focus keeps active window index stable" {
    var input = TopologyInput{
        .operation = op_focus,
        .direction = direction_left,
        .orientation = orientation_horizontal,
        .center_mode = center_on_overflow,
        .subject_window_id = 0,
        .target_window_id = 0,
        .selected_window_id = 10,
        .focused_window_id = 0,
        .active_column_index = 0,
        .insert_index = 0,
        .target_index = 0,
        .from_column_index = -1,
        .max_windows_per_column = 3,
        .gap = 8,
        .viewport_span = 1000,
        .current_view_offset = 0,
        .stationary_view_offset = 0,
        .scale = 2,
        .default_new_column_span = 400,
        .previous_active_position = 0,
        .activate_prev_column_on_removal = 0,
        .infinite_loop = 0,
        .always_center_single_column = 0,
        .animate = 0,
        .has_previous_active_position = 0,
        .has_activate_prev_column_on_removal = 0,
        .reset_for_single_window = 0,
        .is_active_workspace = 1,
        .has_completed_initial_refresh = 1,
        .viewport_is_gesture_or_animation = 0,
    };
    const columns = [_]TopologyColumnInput{
        .{ .id = 1, .span = 400, .window_start_index = 0, .window_count = 2, .active_window_index = 1, .is_tabbed = 1 },
        .{ .id = 2, .span = 400, .window_start_index = 2, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
    };
    const windows = [_]TopologyWindowInput{
        .{ .id = 10, .sizing_mode = viewport_policy.sizing_mode_normal },
        .{ .id = 20, .sizing_mode = viewport_policy.sizing_mode_normal },
        .{ .id = 30, .sizing_mode = viewport_policy.sizing_mode_normal },
    };
    var column_outputs: [2]TopologyColumnOutput = undefined;
    var window_outputs: [3]TopologyWindowOutput = undefined;
    var result: TopologyResult = undefined;

    const status = omniwm_niri_topology_plan(
        &input,
        &columns,
        columns.len,
        &windows,
        windows.len,
        null,
        0,
        null,
        0,
        &column_outputs,
        column_outputs.len,
        &window_outputs,
        window_outputs.len,
        &result,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(@as(u64, 10), result.selected_window_id);
    try std.testing.expectEqual(@as(i32, 1), column_outputs[0].active_window_index);
    try std.testing.expectEqual(@as(i32, 0), result.active_column_index);
    try std.testing.expectEqual(@as(u8, 0), result.did_apply);
}

test "niri topology combined focus at edge preserves selected window" {
    var input = TopologyInput{
        .operation = op_focus_combined,
        .direction = direction_left,
        .orientation = orientation_horizontal,
        .center_mode = center_on_overflow,
        .subject_window_id = 0,
        .target_window_id = 0,
        .selected_window_id = 10,
        .focused_window_id = 0,
        .active_column_index = 0,
        .insert_index = 0,
        .target_index = 0,
        .from_column_index = -1,
        .max_windows_per_column = 1,
        .gap = 8,
        .viewport_span = 1000,
        .current_view_offset = 0,
        .stationary_view_offset = 0,
        .scale = 2,
        .default_new_column_span = 400,
        .previous_active_position = 0,
        .activate_prev_column_on_removal = 0,
        .infinite_loop = 0,
        .always_center_single_column = 0,
        .animate = 0,
        .has_previous_active_position = 0,
        .has_activate_prev_column_on_removal = 0,
        .reset_for_single_window = 0,
        .is_active_workspace = 1,
        .has_completed_initial_refresh = 1,
        .viewport_is_gesture_or_animation = 0,
    };
    const columns = [_]TopologyColumnInput{
        .{ .id = 1, .span = 400, .window_start_index = 0, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
    };
    const windows = [_]TopologyWindowInput{
        .{ .id = 10, .sizing_mode = viewport_policy.sizing_mode_normal },
    };
    var column_outputs: [1]TopologyColumnOutput = undefined;
    var window_outputs: [1]TopologyWindowOutput = undefined;
    var result: TopologyResult = undefined;

    const status = omniwm_niri_topology_plan(
        &input,
        &columns,
        columns.len,
        &windows,
        windows.len,
        null,
        0,
        null,
        0,
        &column_outputs,
        column_outputs.len,
        &window_outputs,
        window_outputs.len,
        &result,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(@as(u64, 10), result.selected_window_id);
    try std.testing.expectEqual(@as(i32, 0), result.active_column_index);
    try std.testing.expectEqual(@as(u8, 0), result.did_apply);
    try std.testing.expectEqual(@as(usize, 1), result.window_count);
}

test "niri topology move window consumes single column into neighbor" {
    var input = TopologyInput{
        .operation = op_move_window,
        .direction = direction_right,
        .orientation = orientation_horizontal,
        .center_mode = center_never,
        .subject_window_id = 1,
        .target_window_id = 0,
        .selected_window_id = 1,
        .focused_window_id = 0,
        .active_column_index = 0,
        .insert_index = 0,
        .target_index = 0,
        .from_column_index = -1,
        .max_windows_per_column = 3,
        .gap = 8,
        .viewport_span = 1200,
        .current_view_offset = 0,
        .stationary_view_offset = 0,
        .scale = 2,
        .default_new_column_span = 500,
        .previous_active_position = 0,
        .activate_prev_column_on_removal = 0,
        .infinite_loop = 0,
        .always_center_single_column = 0,
        .animate = 0,
        .has_previous_active_position = 0,
        .has_activate_prev_column_on_removal = 0,
        .reset_for_single_window = 0,
        .is_active_workspace = 1,
        .has_completed_initial_refresh = 1,
        .viewport_is_gesture_or_animation = 0,
    };
    const columns = [_]TopologyColumnInput{
        .{ .id = 1, .span = 500, .window_start_index = 0, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
        .{ .id = 2, .span = 500, .window_start_index = 1, .window_count = 1, .active_window_index = 0, .is_tabbed = 0 },
    };
    const windows = [_]TopologyWindowInput{
        .{ .id = 1, .sizing_mode = viewport_policy.sizing_mode_normal },
        .{ .id = 2, .sizing_mode = viewport_policy.sizing_mode_normal },
    };
    var column_outputs: [2]TopologyColumnOutput = undefined;
    var window_outputs: [2]TopologyWindowOutput = undefined;
    var result: TopologyResult = undefined;

    const status = omniwm_niri_topology_plan(
        &input,
        &columns,
        columns.len,
        &windows,
        windows.len,
        null,
        0,
        null,
        0,
        &column_outputs,
        column_outputs.len,
        &window_outputs,
        window_outputs.len,
        &result,
    );

    try std.testing.expectEqual(status_ok, status);
    try std.testing.expectEqual(@as(usize, 1), result.column_count);
    try std.testing.expectEqual(effect_consume_window, result.effect_kind);
    try std.testing.expectEqual(@as(u64, 1), window_outputs[0].id);
    try std.testing.expectEqual(@as(u64, 2), window_outputs[1].id);
}
