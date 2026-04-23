// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");
const dwindle_layout = @import("dwindle_layout.zig");
const ipc_support = @import("ipc_support.zig");
const niri_layout = @import("niri_layout.zig");
const niri_topology = @import("niri_topology.zig");
const orchestration = @import("orchestration.zig");
const overview_projection = @import("overview_projection.zig");
const reconcile = @import("reconcile.zig");
const restore_planner = @import("restore_planner.zig");
const viewport_policy = @import("viewport_policy.zig");
const window_decision = @import("window_decision.zig");
const workspace_navigation = @import("workspace_navigation.zig");
const workspace_session = @import("workspace_session.zig");

comptime {
    _ = dwindle_layout;
    _ = ipc_support;
    _ = niri_layout;
    _ = niri_topology;
    _ = orchestration;
    _ = overview_projection;
    _ = reconcile;
    _ = restore_planner;
    _ = window_decision;
    _ = workspace_navigation;
    _ = workspace_session;
}

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;
const kernel_allocation_failed: i32 = 2;
const epsilon: f64 = 0.001;
const stack_axis_capacity = 64;

const AxisInput = extern struct {
    weight: f64,
    min_constraint: f64,
    max_constraint: f64,
    fixed_value: f64,
    has_max_constraint: u8,
    is_constraint_fixed: u8,
    has_fixed_value: u8,
};

const AxisOutput = extern struct {
    value: f64,
    was_constrained: u8,
};

const RestoreSnapshot = extern struct {
    display_id: u32,
    anchor_x: f64,
    anchor_y: f64,
    frame_width: f64,
    frame_height: f64,
};

const RestoreMonitor = extern struct {
    display_id: u32,
    frame_min_x: f64,
    frame_max_y: f64,
    anchor_x: f64,
    anchor_y: f64,
    frame_width: f64,
    frame_height: f64,
};

const RestoreAssignment = extern struct {
    snapshot_index: u32,
    monitor_index: u32,
};

const AxisScratch = struct {
    minimums: []f64,
    scaled_minimums: []f64,
    maximums: []f64,
    weights: []f64,
    fixed_values: []f64,
    values: []f64,
    has_maximums: []u8,
    has_fixed_values: []u8,
    non_fixed_indices: []usize,
};

fn swiftMax(lhs: f64, rhs: f64) f64 {
    return if (rhs > lhs) rhs else lhs;
}

fn swiftMin(lhs: f64, rhs: f64) f64 {
    return if (rhs < lhs) rhs else lhs;
}

fn sanitizeNonNegative(value: f64) f64 {
    if (!std.math.isFinite(value)) {
        return 0;
    }
    return swiftMax(0, value);
}

fn sanitizeMaximum(has_maximum: bool, value: f64) ?f64 {
    if (!has_maximum or !std.math.isFinite(value) or value <= 0) {
        return null;
    }
    return swiftMax(0, value);
}

fn clampFixedValue(value: f64, minimum: f64, maximum: ?f64) f64 {
    var clamped = sanitizeNonNegative(value);
    clamped = swiftMax(clamped, minimum);
    if (maximum) |max_value| {
        clamped = swiftMin(clamped, max_value);
    }
    return clamped;
}

fn absDiff(lhs: f64, rhs: f64) f64 {
    return @abs(lhs - rhs);
}

fn solveAxisTabbed(inputs: []const AxisInput, available_space: f64, outputs: []AxisOutput) void {
    var max_min_constraint = inputs[0].min_constraint;
    var fixed_value: ?f64 = null;
    var max_max_constraint: ?f64 = null;

    for (inputs) |input| {
        max_min_constraint = swiftMax(max_min_constraint, input.min_constraint);

        if (fixed_value == null and input.has_fixed_value != 0) {
            fixed_value = input.fixed_value;
        }

        if (sanitizeMaximum(input.has_max_constraint != 0, input.max_constraint)) |max_value| {
            if (max_max_constraint) |current_maximum| {
                max_max_constraint = swiftMin(current_maximum, max_value);
            } else {
                max_max_constraint = max_value;
            }
        }
    }

    var shared_value = if (fixed_value) |fixed|
        swiftMax(fixed, max_min_constraint)
    else
        swiftMax(available_space, max_min_constraint);

    if (max_max_constraint) |max_value| {
        shared_value = swiftMin(shared_value, swiftMax(max_value, max_min_constraint));
    }

    shared_value = swiftMax(1, shared_value);

    for (inputs, outputs) |input, *output| {
        const constrained_by_minimum = shared_value == input.min_constraint;
        const constrained_by_maximum = input.has_max_constraint != 0 and shared_value == input.max_constraint;
        output.* = .{
            .value = shared_value,
            .was_constrained = @intFromBool(constrained_by_minimum or constrained_by_maximum),
        };
    }
}

fn solveAxisInternal(
    inputs: []const AxisInput,
    available_space: f64,
    gap_size: f64,
    is_tabbed: bool,
    outputs: []AxisOutput,
    scratch: AxisScratch,
) void {
    if (is_tabbed) {
        solveAxisTabbed(inputs, available_space, outputs);
        return;
    }

    const total_gaps = gap_size * @as(f64, @floatFromInt(if (inputs.len > 0) inputs.len - 1 else 0));
    const usable_space = swiftMax(0, available_space - total_gaps);

    var fixed_sum: f64 = 0;
    var non_fixed_count: usize = 0;

    for (inputs, 0..) |input, index| {
        const minimum = sanitizeNonNegative(input.min_constraint);
        scratch.minimums[index] = minimum;
        scratch.scaled_minimums[index] = minimum;
        scratch.weights[index] = sanitizeNonNegative(input.weight);

        if (sanitizeMaximum(input.has_max_constraint != 0, input.max_constraint)) |maximum| {
            scratch.maximums[index] = maximum;
            scratch.has_maximums[index] = 1;
        } else {
            scratch.maximums[index] = 0;
            scratch.has_maximums[index] = 0;
        }

        const maximum = if (scratch.has_maximums[index] != 0) scratch.maximums[index] else null;

        if (input.has_fixed_value != 0) {
            const fixed = clampFixedValue(input.fixed_value, minimum, maximum);
            scratch.fixed_values[index] = fixed;
            scratch.has_fixed_values[index] = 1;
            fixed_sum += fixed;
        } else if (input.is_constraint_fixed != 0) {
            const fixed = clampFixedValue(minimum, minimum, maximum);
            scratch.fixed_values[index] = fixed;
            scratch.has_fixed_values[index] = 1;
            fixed_sum += fixed;
        } else {
            scratch.fixed_values[index] = 0;
            scratch.has_fixed_values[index] = 0;
            scratch.non_fixed_indices[non_fixed_count] = index;
            non_fixed_count += 1;
        }

        scratch.values[index] = 0;
    }

    if (fixed_sum > usable_space and fixed_sum > epsilon) {
        const scale = usable_space / fixed_sum;
        for (0..inputs.len) |index| {
            outputs[index] = .{
                .value = if (scratch.has_fixed_values[index] != 0) swiftMax(1, scratch.fixed_values[index] * scale) else 0,
                .was_constrained = scratch.has_fixed_values[index],
            };
        }
        return;
    }

    const remaining_for_minimums = swiftMax(0, usable_space - fixed_sum);
    var minimum_sum: f64 = 0;
    for (scratch.non_fixed_indices[0..non_fixed_count]) |index| {
        minimum_sum += scratch.scaled_minimums[index];
    }

    if (minimum_sum > remaining_for_minimums and minimum_sum > epsilon) {
        const scale = remaining_for_minimums / minimum_sum;
        for (scratch.non_fixed_indices[0..non_fixed_count]) |index| {
            scratch.scaled_minimums[index] *= scale;
        }
    }

    var remaining_space = usable_space;

    for (0..inputs.len) |index| {
        if (scratch.has_fixed_values[index] == 0) {
            continue;
        }
        const assigned = swiftMin(scratch.fixed_values[index], remaining_space);
        scratch.values[index] = assigned;
        remaining_space = swiftMax(0, remaining_space - assigned);
    }

    for (scratch.non_fixed_indices[0..non_fixed_count]) |index| {
        const assigned = swiftMin(scratch.scaled_minimums[index], remaining_space);
        scratch.values[index] += assigned;
        remaining_space = swiftMax(0, remaining_space - assigned);
    }

    while (remaining_space > epsilon) {
        var growable_count: usize = 0;
        var total_weight: f64 = 0;

        for (scratch.non_fixed_indices[0..non_fixed_count]) |index| {
            if (scratch.has_maximums[index] != 0 and !(scratch.values[index] + epsilon < scratch.maximums[index])) {
                continue;
            }
            growable_count += 1;
            total_weight += scratch.weights[index];
        }

        if (growable_count == 0) {
            break;
        }

        var consumed: f64 = 0;

        if (total_weight > epsilon) {
            for (scratch.non_fixed_indices[0..non_fixed_count]) |index| {
                if (scratch.has_maximums[index] != 0 and !(scratch.values[index] + epsilon < scratch.maximums[index])) {
                    continue;
                }

                const share = remaining_space * (scratch.weights[index] / total_weight);
                const cap = if (scratch.has_maximums[index] != 0)
                    swiftMax(0, scratch.maximums[index] - scratch.values[index])
                else
                    share;
                const delta = swiftMin(share, cap);
                scratch.values[index] += delta;
                consumed += delta;
            }
        } else {
            const equal_share = remaining_space / @as(f64, @floatFromInt(growable_count));
            for (scratch.non_fixed_indices[0..non_fixed_count]) |index| {
                if (scratch.has_maximums[index] != 0 and !(scratch.values[index] + epsilon < scratch.maximums[index])) {
                    continue;
                }

                const cap = if (scratch.has_maximums[index] != 0)
                    swiftMax(0, scratch.maximums[index] - scratch.values[index])
                else
                    equal_share;
                const delta = swiftMin(equal_share, cap);
                scratch.values[index] += delta;
                consumed += delta;
            }
        }

        if (consumed <= epsilon) {
            break;
        }

        remaining_space = swiftMax(0, remaining_space - consumed);
    }

    for (inputs, 0..) |input, index| {
        const is_at_minimum = scratch.minimums[index] > epsilon and absDiff(scratch.values[index], scratch.minimums[index]) <= epsilon;
        const is_at_maximum = scratch.has_maximums[index] != 0 and absDiff(scratch.values[index], scratch.maximums[index]) <= epsilon;
        outputs[index] = .{
            .value = swiftMax(1, scratch.values[index]),
            .was_constrained = @intFromBool(input.is_constraint_fixed != 0 or is_at_minimum or is_at_maximum),
        };
    }
}

pub export fn omniwm_axis_solve(
    inputs_ptr: [*c]const AxisInput,
    count: usize,
    available_space: f64,
    gap_size: f64,
    is_tabbed: u8,
    outputs_ptr: [*c]AxisOutput,
) i32 {
    if (count == 0) {
        return kernel_ok;
    }
    if (inputs_ptr == null or outputs_ptr == null) {
        return kernel_invalid_argument;
    }

    const inputs = @as([*]const AxisInput, @ptrCast(inputs_ptr))[0..count];
    const outputs = @as([*]AxisOutput, @ptrCast(outputs_ptr))[0..count];

    if (count <= stack_axis_capacity) {
        var minimums: [stack_axis_capacity]f64 = undefined;
        var scaled_minimums: [stack_axis_capacity]f64 = undefined;
        var maximums: [stack_axis_capacity]f64 = undefined;
        var weights: [stack_axis_capacity]f64 = undefined;
        var fixed_values: [stack_axis_capacity]f64 = undefined;
        var values: [stack_axis_capacity]f64 = undefined;
        var has_maximums: [stack_axis_capacity]u8 = undefined;
        var has_fixed_values: [stack_axis_capacity]u8 = undefined;
        var non_fixed_indices: [stack_axis_capacity]usize = undefined;

        solveAxisInternal(inputs, available_space, gap_size, is_tabbed != 0, outputs, .{
            .minimums = minimums[0..count],
            .scaled_minimums = scaled_minimums[0..count],
            .maximums = maximums[0..count],
            .weights = weights[0..count],
            .fixed_values = fixed_values[0..count],
            .values = values[0..count],
            .has_maximums = has_maximums[0..count],
            .has_fixed_values = has_fixed_values[0..count],
            .non_fixed_indices = non_fixed_indices[0..count],
        });
        return kernel_ok;
    }

    const allocator = std.heap.page_allocator;
    const minimums = allocator.alloc(f64, count) catch return kernel_allocation_failed;
    defer allocator.free(minimums);
    const scaled_minimums = allocator.alloc(f64, count) catch return kernel_allocation_failed;
    defer allocator.free(scaled_minimums);
    const maximums = allocator.alloc(f64, count) catch return kernel_allocation_failed;
    defer allocator.free(maximums);
    const weights = allocator.alloc(f64, count) catch return kernel_allocation_failed;
    defer allocator.free(weights);
    const fixed_values = allocator.alloc(f64, count) catch return kernel_allocation_failed;
    defer allocator.free(fixed_values);
    const values = allocator.alloc(f64, count) catch return kernel_allocation_failed;
    defer allocator.free(values);
    const has_maximums = allocator.alloc(u8, count) catch return kernel_allocation_failed;
    defer allocator.free(has_maximums);
    const has_fixed_values = allocator.alloc(u8, count) catch return kernel_allocation_failed;
    defer allocator.free(has_fixed_values);
    const non_fixed_indices = allocator.alloc(usize, count) catch return kernel_allocation_failed;
    defer allocator.free(non_fixed_indices);

    solveAxisInternal(inputs, available_space, gap_size, is_tabbed != 0, outputs, .{
        .minimums = minimums,
        .scaled_minimums = scaled_minimums,
        .maximums = maximums,
        .weights = weights,
        .fixed_values = fixed_values,
        .values = values,
        .has_maximums = has_maximums,
        .has_fixed_values = has_fixed_values,
        .non_fixed_indices = non_fixed_indices,
    });
    return kernel_ok;
}

fn totalSpan(spans: []const f64, gap: f64) f64 {
    return viewport_policy.totalSpan(spans, gap);
}

fn containerPosition(spans: []const f64, gap: f64, index: usize) f64 {
    return viewport_policy.containerPosition(spans, gap, index);
}

pub export fn omniwm_geometry_container_position(
    spans_ptr: [*c]const f64,
    count: usize,
    gap: f64,
    index: usize,
) f64 {
    const spans = if (count == 0 or spans_ptr == null)
        &[_]f64{}
    else
        @as([*]const f64, @ptrCast(spans_ptr))[0..count];
    return containerPosition(spans, gap, index);
}

pub export fn omniwm_geometry_total_span(
    spans_ptr: [*c]const f64,
    count: usize,
    gap: f64,
) f64 {
    const spans = if (count == 0 or spans_ptr == null)
        &[_]f64{}
    else
        @as([*]const f64, @ptrCast(spans_ptr))[0..count];
    return totalSpan(spans, gap);
}

pub export fn omniwm_geometry_centered_offset(
    spans_ptr: [*c]const f64,
    modes_ptr: [*c]const u8,
    count: usize,
    gap: f64,
    viewport_span: f64,
    index: usize,
) f64 {
    const spans = if (count == 0 or spans_ptr == null)
        &[_]f64{}
    else
        @as([*]const f64, @ptrCast(spans_ptr))[0..count];
    const modes = if (count == 0 or modes_ptr == null)
        &[_]u8{}
    else
        @as([*]const u8, @ptrCast(modes_ptr))[0..count];
    return viewport_policy.centeredOffset(spans, modes, gap, viewport_span, index);
}

pub export fn omniwm_geometry_visible_offset(
    spans_ptr: [*c]const f64,
    modes_ptr: [*c]const u8,
    count: usize,
    gap: f64,
    viewport_span: f64,
    index: i32,
    current_view_start: f64,
    center_mode: u32,
    always_center_single_column: u8,
    from_index: i32,
    scale: f64,
) f64 {
    const spans = if (count == 0 or spans_ptr == null)
        &[_]f64{}
    else
        @as([*]const f64, @ptrCast(spans_ptr))[0..count];
    const modes = if (count == 0 or modes_ptr == null)
        &[_]u8{}
    else
        @as([*]const u8, @ptrCast(modes_ptr))[0..count];

    return viewport_policy.visibleOffset(
        spans,
        modes,
        gap,
        viewport_span,
        index,
        current_view_start,
        center_mode,
        always_center_single_column != 0,
        if (from_index >= 0) @as(?usize, @intCast(from_index)) else null,
        scale,
    );
}

pub export fn omniwm_geometry_snap_target(
    spans_ptr: [*c]const f64,
    modes_ptr: [*c]const u8,
    count: usize,
    gap: f64,
    viewport_span: f64,
    projected_view_pos: f64,
    current_view_pos: f64,
    center_mode: u32,
    always_center_single_column: u8,
) viewport_policy.SnapTarget {
    const spans = if (count == 0 or spans_ptr == null)
        &[_]f64{}
    else
        @as([*]const f64, @ptrCast(spans_ptr))[0..count];
    const modes = if (count == 0 or modes_ptr == null)
        &[_]u8{}
    else
        @as([*]const u8, @ptrCast(modes_ptr))[0..count];

    return viewport_policy.snapTarget(
        spans,
        modes,
        gap,
        viewport_span,
        projected_view_pos,
        current_view_pos,
        center_mode,
        always_center_single_column != 0,
    );
}

fn restoreSnapshotLessThan(lhs: RestoreSnapshot, rhs: RestoreSnapshot) bool {
    if (lhs.anchor_x != rhs.anchor_x) {
        return lhs.anchor_x < rhs.anchor_x;
    }
    if (lhs.anchor_y != rhs.anchor_y) {
        return lhs.anchor_y > rhs.anchor_y;
    }
    return lhs.display_id < rhs.display_id;
}

fn restoreMonitorLessThan(lhs: RestoreMonitor, rhs: RestoreMonitor) bool {
    if (lhs.frame_min_x != rhs.frame_min_x) {
        return lhs.frame_min_x < rhs.frame_min_x;
    }
    if (lhs.frame_max_y != rhs.frame_max_y) {
        return lhs.frame_max_y > rhs.frame_max_y;
    }
    return lhs.display_id < rhs.display_id;
}

fn sortSnapshotIndices(indices: []usize, snapshots: []const RestoreSnapshot) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const value = indices[i];
        var j = i;
        while (j > 0 and restoreSnapshotLessThan(snapshots[value], snapshots[indices[j - 1]])) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = value;
    }
}

fn sortMonitorIndices(indices: []usize, monitors: []const RestoreMonitor) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const value = indices[i];
        var j = i;
        while (j > 0 and restoreMonitorLessThan(monitors[value], monitors[indices[j - 1]])) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = value;
    }
}

fn restoreGeometryDelta(snapshot: RestoreSnapshot, monitor: RestoreMonitor) f64 {
    const dx = snapshot.anchor_x - monitor.anchor_x;
    const dy = snapshot.anchor_y - monitor.anchor_y;
    const anchor_distance = dx * dx + dy * dy;
    const width_delta = @abs(snapshot.frame_width - monitor.frame_width);
    const height_delta = @abs(snapshot.frame_height - monitor.frame_height);
    return anchor_distance + width_delta + height_delta;
}

fn prefersAssignments(
    current_assigned_count: usize,
    current_name_penalty: usize,
    current_geometry_delta: f64,
    current_assignments: []const i32,
    best_assigned_count: usize,
    best_name_penalty: usize,
    best_geometry_delta: f64,
    best_assignments: []const i32,
    monitors: []const RestoreMonitor,
) bool {
    if (current_assigned_count != best_assigned_count) {
        return current_assigned_count > best_assigned_count;
    }
    if (current_name_penalty != best_name_penalty) {
        return current_name_penalty < best_name_penalty;
    }
    if (current_geometry_delta != best_geometry_delta) {
        return current_geometry_delta < best_geometry_delta;
    }

    for (current_assignments, best_assignments) |current_monitor_index, best_monitor_index| {
        switch (std.math.order(current_monitor_index, best_monitor_index)) {
            .eq => continue,
            else => {},
        }

        if (current_monitor_index >= 0 and best_monitor_index < 0) {
            return true;
        }
        if (current_monitor_index < 0 and best_monitor_index >= 0) {
            return false;
        }

        const current_monitor = monitors[@intCast(current_monitor_index)];
        const best_monitor = monitors[@intCast(best_monitor_index)];
        return restoreMonitorLessThan(current_monitor, best_monitor);
    }

    return false;
}

pub export fn omniwm_restore_resolve_assignments(
    snapshots_ptr: [*c]const RestoreSnapshot,
    snapshot_count: usize,
    monitors_ptr: [*c]const RestoreMonitor,
    monitor_count: usize,
    name_penalties_ptr: [*c]const u8,
    name_penalty_count: usize,
    assignments_ptr: [*c]RestoreAssignment,
    assignment_capacity: usize,
    assignment_count_ptr: [*c]usize,
) i32 {
    if (assignment_count_ptr == null) {
        return kernel_invalid_argument;
    }

    assignment_count_ptr[0] = 0;

    if (snapshot_count == 0 or monitor_count == 0) {
        return kernel_ok;
    }
    if (snapshots_ptr == null or monitors_ptr == null or name_penalties_ptr == null or assignments_ptr == null) {
        return kernel_invalid_argument;
    }
    if (snapshot_count > std.math.maxInt(usize) / monitor_count) {
        return kernel_invalid_argument;
    }

    const expected_name_penalties = snapshot_count * monitor_count;
    if (name_penalty_count != expected_name_penalties) {
        return kernel_invalid_argument;
    }
    if (assignment_capacity < @min(snapshot_count, monitor_count)) {
        return kernel_invalid_argument;
    }

    const snapshots = @as([*]const RestoreSnapshot, @ptrCast(snapshots_ptr))[0..snapshot_count];
    const monitors = @as([*]const RestoreMonitor, @ptrCast(monitors_ptr))[0..monitor_count];
    const name_penalties = @as([*]const u8, @ptrCast(name_penalties_ptr))[0..name_penalty_count];
    const assignments = @as([*]RestoreAssignment, @ptrCast(assignments_ptr))[0..assignment_capacity];

    const allocator = std.heap.page_allocator;

    const sorted_snapshot_indices = allocator.alloc(usize, snapshot_count) catch return kernel_allocation_failed;
    defer allocator.free(sorted_snapshot_indices);
    const sorted_monitor_indices = allocator.alloc(usize, monitor_count) catch return kernel_allocation_failed;
    defer allocator.free(sorted_monitor_indices);
    const used_monitor_positions = allocator.alloc(bool, monitor_count) catch return kernel_allocation_failed;
    defer allocator.free(used_monitor_positions);
    const snapshot_matched_exactly = allocator.alloc(bool, snapshot_count) catch return kernel_allocation_failed;
    defer allocator.free(snapshot_matched_exactly);

    for (0..snapshot_count) |index| {
        sorted_snapshot_indices[index] = index;
        snapshot_matched_exactly[index] = false;
    }
    for (0..monitor_count) |index| {
        sorted_monitor_indices[index] = index;
        used_monitor_positions[index] = false;
    }

    sortSnapshotIndices(sorted_snapshot_indices, snapshots);
    sortMonitorIndices(sorted_monitor_indices, monitors);

    var resolved_count: usize = 0;

    for (sorted_snapshot_indices) |snapshot_input_index| {
        const snapshot = snapshots[snapshot_input_index];
        for (sorted_monitor_indices, 0..) |monitor_input_index, monitor_position| {
            if (used_monitor_positions[monitor_position]) {
                continue;
            }
            if (monitors[monitor_input_index].display_id != snapshot.display_id) {
                continue;
            }

            assignments[resolved_count] = .{
                .snapshot_index = @intCast(snapshot_input_index),
                .monitor_index = @intCast(monitor_input_index),
            };
            resolved_count += 1;
            used_monitor_positions[monitor_position] = true;
            snapshot_matched_exactly[snapshot_input_index] = true;
            break;
        }
    }

    const remaining_snapshot_indices = allocator.alloc(usize, snapshot_count) catch return kernel_allocation_failed;
    defer allocator.free(remaining_snapshot_indices);
    const remaining_monitor_indices = allocator.alloc(usize, monitor_count) catch return kernel_allocation_failed;
    defer allocator.free(remaining_monitor_indices);

    var remaining_snapshot_count: usize = 0;
    for (sorted_snapshot_indices) |snapshot_input_index| {
        if (snapshot_matched_exactly[snapshot_input_index]) {
            continue;
        }
        remaining_snapshot_indices[remaining_snapshot_count] = snapshot_input_index;
        remaining_snapshot_count += 1;
    }

    var remaining_monitor_count: usize = 0;
    for (sorted_monitor_indices, 0..) |monitor_input_index, monitor_position| {
        if (used_monitor_positions[monitor_position]) {
            continue;
        }
        remaining_monitor_indices[remaining_monitor_count] = monitor_input_index;
        remaining_monitor_count += 1;
    }

    if (remaining_snapshot_count == 0 or remaining_monitor_count == 0) {
        assignment_count_ptr[0] = resolved_count;
        return kernel_ok;
    }

    const current_assignments = allocator.alloc(i32, remaining_snapshot_count) catch return kernel_allocation_failed;
    defer allocator.free(current_assignments);
    const best_assignments = allocator.alloc(i32, remaining_snapshot_count) catch return kernel_allocation_failed;
    defer allocator.free(best_assignments);
    const used_remaining_monitors = allocator.alloc(bool, remaining_monitor_count) catch return kernel_allocation_failed;
    defer allocator.free(used_remaining_monitors);

    @memset(current_assignments, -1);
    @memset(best_assignments, -1);
    @memset(used_remaining_monitors, false);

    var best_valid = false;
    var best_assigned_count: usize = 0;
    var best_name_penalty: usize = 0;
    var best_geometry_delta: f64 = 0;

    const SearchContext = struct {
        snapshots: []const RestoreSnapshot,
        monitors: []const RestoreMonitor,
        remaining_snapshot_indices: []const usize,
        remaining_monitor_indices: []const usize,
        name_penalties: []const u8,
        monitor_count: usize,
        current_assignments: []i32,
        best_assignments: []i32,
        used_remaining_monitors: []bool,
        best_valid: *bool,
        best_assigned_count: *usize,
        best_name_penalty: *usize,
        best_geometry_delta: *f64,

        fn search(
            self: *@This(),
            snapshot_position: usize,
            current_assigned_count: usize,
            current_name_penalty: usize,
            current_geometry_delta: f64,
        ) void {
            if (snapshot_position == self.remaining_snapshot_indices.len) {
                if (!self.best_valid.* or prefersAssignments(
                    current_assigned_count,
                    current_name_penalty,
                    current_geometry_delta,
                    self.current_assignments,
                    self.best_assigned_count.*,
                    self.best_name_penalty.*,
                    self.best_geometry_delta.*,
                    self.best_assignments,
                    self.monitors,
                )) {
                    @memcpy(self.best_assignments, self.current_assignments);
                    self.best_valid.* = true;
                    self.best_assigned_count.* = current_assigned_count;
                    self.best_name_penalty.* = current_name_penalty;
                    self.best_geometry_delta.* = current_geometry_delta;
                }
                return;
            }

            self.search(snapshot_position + 1, current_assigned_count, current_name_penalty, current_geometry_delta);

            const snapshot_input_index = self.remaining_snapshot_indices[snapshot_position];
            const snapshot = self.snapshots[snapshot_input_index];

            for (self.remaining_monitor_indices, 0..) |monitor_input_index, monitor_position| {
                if (self.used_remaining_monitors[monitor_position]) {
                    continue;
                }

                self.used_remaining_monitors[monitor_position] = true;
                self.current_assignments[snapshot_position] = @intCast(monitor_input_index);

                const penalty_index = snapshot_input_index * self.monitor_count + monitor_input_index;
                const name_penalty = self.name_penalties[penalty_index];
                const geometry_delta = restoreGeometryDelta(snapshot, self.monitors[monitor_input_index]);

                self.search(
                    snapshot_position + 1,
                    current_assigned_count + 1,
                    current_name_penalty + name_penalty,
                    current_geometry_delta + geometry_delta,
                );

                self.current_assignments[snapshot_position] = -1;
                self.used_remaining_monitors[monitor_position] = false;
            }
        }
    };

    var context = SearchContext{
        .snapshots = snapshots,
        .monitors = monitors,
        .remaining_snapshot_indices = remaining_snapshot_indices[0..remaining_snapshot_count],
        .remaining_monitor_indices = remaining_monitor_indices[0..remaining_monitor_count],
        .name_penalties = name_penalties,
        .monitor_count = monitor_count,
        .current_assignments = current_assignments,
        .best_assignments = best_assignments,
        .used_remaining_monitors = used_remaining_monitors,
        .best_valid = &best_valid,
        .best_assigned_count = &best_assigned_count,
        .best_name_penalty = &best_name_penalty,
        .best_geometry_delta = &best_geometry_delta,
    };

    context.search(0, 0, 0, 0);

    if (best_valid) {
        for (best_assignments, 0..) |monitor_input_index, snapshot_position| {
            if (monitor_input_index < 0) {
                continue;
            }
            assignments[resolved_count] = .{
                .snapshot_index = @intCast(remaining_snapshot_indices[snapshot_position]),
                .monitor_index = @intCast(monitor_input_index),
            };
            resolved_count += 1;
        }
    }

    assignment_count_ptr[0] = resolved_count;
    return kernel_ok;
}

test "axis solver covers fixed overflow and weighted growth" {
    var outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 3;
    const inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 80, .max_constraint = 0, .fixed_value = 80, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 1 },
        .{ .weight = 1, .min_constraint = 0, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
        .{ .weight = 3, .min_constraint = 0, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 200, 0, 0, &outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 80), outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30), outputs[1].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 90), outputs[2].value, 0.001);
}

test "axis solver keeps all fixed values" {
    var outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 3;
    const inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 100, .max_constraint = 0, .fixed_value = 100, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 1 },
        .{ .weight = 1, .min_constraint = 80, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 1, .has_fixed_value = 0 },
        .{ .weight = 1, .min_constraint = 60, .max_constraint = 0, .fixed_value = 60, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 1 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 240, 0, 0, &outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 100), outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 80), outputs[1].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 60), outputs[2].value, 0.001);
    try std.testing.expectEqual(@as(u8, 1), outputs[0].was_constrained);
    try std.testing.expectEqual(@as(u8, 1), outputs[1].was_constrained);
    try std.testing.expectEqual(@as(u8, 1), outputs[2].was_constrained);
}

test "axis solver handles empty input and minimum scaling" {
    var no_outputs = [_]AxisOutput{};
    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(null, 0, 120, 8, 0, &no_outputs));

    var scaled_outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 2;
    const inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 80, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
        .{ .weight = 1, .min_constraint = 120, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 100, 0, 0, &scaled_outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 40), scaled_outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 60), scaled_outputs[1].value, 0.001);
}

test "axis solver keeps fixed assignments and clamps fixed values to maxima" {
    var outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 3;
    const inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 100, .max_constraint = 0, .fixed_value = 100, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 1 },
        .{ .weight = 1, .min_constraint = 80, .max_constraint = 120, .fixed_value = 0, .has_max_constraint = 1, .is_constraint_fixed = 1, .has_fixed_value = 0 },
        .{ .weight = 1, .min_constraint = 40, .max_constraint = 120, .fixed_value = 300, .has_max_constraint = 1, .is_constraint_fixed = 0, .has_fixed_value = 1 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 320, 0, 0, &outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 100), outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 80), outputs[1].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 120), outputs[2].value, 0.001);
    try std.testing.expectEqual(@as(u8, 1), outputs[0].was_constrained);
    try std.testing.expectEqual(@as(u8, 1), outputs[1].was_constrained);
    try std.testing.expectEqual(@as(u8, 1), outputs[2].was_constrained);
}

test "axis solver handles tabbed mode and sanitization" {
    var outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 2;
    const inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 100, .max_constraint = 0, .fixed_value = -50, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 1 },
        .{ .weight = 1, .min_constraint = 250, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 200, 0, 1, &outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 250), outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 250), outputs[1].value, 0.001);
}

test "axis solver tabbed mode clamps to the tightest maximum" {
    var outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 2;
    const inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 100, .max_constraint = 180, .fixed_value = 0, .has_max_constraint = 1, .is_constraint_fixed = 0, .has_fixed_value = 0 },
        .{ .weight = 1, .min_constraint = 120, .max_constraint = 140, .fixed_value = 0, .has_max_constraint = 1, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 300, 0, 1, &outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 140), outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 140), outputs[1].value, 0.001);
    try std.testing.expectEqual(@as(u8, 0), outputs[0].was_constrained);
    try std.testing.expectEqual(@as(u8, 1), outputs[1].was_constrained);
}

test "axis solver redistributes around max caps and zero weights" {
    var capped_outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 3;
    const capped_inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 0, .max_constraint = 100, .fixed_value = 0, .has_max_constraint = 1, .is_constraint_fixed = 0, .has_fixed_value = 0 },
        .{ .weight = 1, .min_constraint = 0, .max_constraint = 400, .fixed_value = 0, .has_max_constraint = 1, .is_constraint_fixed = 0, .has_fixed_value = 0 },
        .{ .weight = 1, .min_constraint = 0, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&capped_inputs, capped_inputs.len, 1200, 0, 0, &capped_outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 100), capped_outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 400), capped_outputs[1].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 700), capped_outputs[2].value, 0.001);

    var zero_weight_outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 2;
    const zero_weight_inputs = [_]AxisInput{
        .{ .weight = -5, .min_constraint = 0, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
        .{ .weight = std.math.nan(f64), .min_constraint = 0, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&zero_weight_inputs, zero_weight_inputs.len, 120, 0, 0, &zero_weight_outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 60), zero_weight_outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 60), zero_weight_outputs[1].value, 0.001);
}

test "axis solver subtracts gaps before distributing space" {
    var outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 2;
    const inputs = [_]AxisInput{
        .{ .weight = 1, .min_constraint = 0, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
        .{ .weight = 1, .min_constraint = 0, .max_constraint = 0, .fixed_value = 0, .has_max_constraint = 0, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 120, 20, 0, &outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 50), outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50), outputs[1].value, 0.001);
}

test "axis solver sanitizes non-finite and negative inputs in non-tabbed mode" {
    var outputs = [_]AxisOutput{.{ .value = 0, .was_constrained = 0 }} ** 2;
    const inputs = [_]AxisInput{
        .{ .weight = 0, .min_constraint = 20, .max_constraint = std.math.nan(f64), .fixed_value = -50, .has_max_constraint = 1, .is_constraint_fixed = 0, .has_fixed_value = 1 },
        .{ .weight = std.math.nan(f64), .min_constraint = -10, .max_constraint = -100, .fixed_value = 0, .has_max_constraint = 1, .is_constraint_fixed = 0, .has_fixed_value = 0 },
    };

    try std.testing.expectEqual(kernel_ok, omniwm_axis_solve(&inputs, inputs.len, 100, 0, 0, &outputs));
    try std.testing.expectApproxEqAbs(@as(f64, 20), outputs[0].value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 80), outputs[1].value, 0.001);
    try std.testing.expectEqual(@as(u8, 1), outputs[0].was_constrained);
    try std.testing.expectEqual(@as(u8, 0), outputs[1].was_constrained);
}

test "geometry preserves centering and pixel epsilon behavior" {
    const widths = [_]f64{ 100, 100, 100 };
    try std.testing.expectApproxEqAbs(@as(f64, -25), omniwm_geometry_centered_offset(&widths, null, widths.len, 10, 150, 2), 0.001);
    const oversized = [_]f64{200};
    try std.testing.expectApproxEqAbs(@as(f64, 25), omniwm_geometry_centered_offset(&oversized, null, oversized.len, 0, 150, 0), 0.001);

    const single = [_]f64{100};
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), omniwm_geometry_visible_offset(&single, null, single.len, 0, 101, 0, 0.4, 0, 0, -1, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), omniwm_geometry_visible_offset(&single, null, single.len, 0, 101, 0, 0.4, 0, 0, -1, 10), 0.001);
}

test "geometry preserves exact fit semantics in never mode" {
    const widths = [_]f64{ 100, 100, 100 };
    try std.testing.expectApproxEqAbs(@as(f64, -110), omniwm_geometry_visible_offset(&widths, null, widths.len, 10, 220, 1, 0, 0, 0, -1, 2), 0.001);
}

test "geometry handles empty spans and on-overflow pair visibility" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), omniwm_geometry_total_span(null, 0, 8), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), omniwm_geometry_centered_offset(null, null, 0, 8, 300, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), omniwm_geometry_visible_offset(null, null, 0, 8, 300, 0, 0, 0, 0, -1, 2), 0.001);

    const visible_pair = [_]f64{ 100, 100, 100 };
    try std.testing.expectApproxEqAbs(@as(f64, -60), omniwm_geometry_visible_offset(&visible_pair, null, visible_pair.len, 10, 220, 1, 0, 2, 0, 0, 2), 0.001);

    const overflowing_pair = [_]f64{ 100, 100, 100, 100 };
    try std.testing.expectApproxEqAbs(@as(f64, -25), omniwm_geometry_visible_offset(&overflowing_pair, null, overflowing_pair.len, 10, 150, 2, 0, 2, 0, 0, 2), 0.001);
}

test "geometry preserves out of range span helper semantics and always mode centering" {
    const heights = [_]f64{ 50, 70, 90 };
    try std.testing.expectApproxEqAbs(@as(f64, 130), omniwm_geometry_container_position(&heights, heights.len, 5, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 220), omniwm_geometry_total_span(&heights, heights.len, 5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 225), omniwm_geometry_container_position(&heights, heights.len, 5, 10), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), omniwm_geometry_visible_offset(&heights, null, heights.len, 5, 100, -1, 0, 0, 0, -1, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), omniwm_geometry_centered_offset(&heights, null, heights.len, 5, 100, 10), 0.001);

    const widths = [_]f64{ 100, 100, 100, 100 };
    try std.testing.expectApproxEqAbs(@as(f64, -25), omniwm_geometry_visible_offset(&widths, null, widths.len, 10, 150, 2, 0, 1, 0, -1, 2), 0.001);
}

test "geometry preserves out-of-range position semantics" {
    const spans = [_]f64{ 50, 70, 90 };
    try std.testing.expectApproxEqAbs(@as(f64, 220), omniwm_geometry_total_span(&spans, spans.len, 5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 130), omniwm_geometry_container_position(&spans, spans.len, 5, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 225), omniwm_geometry_container_position(&spans, spans.len, 5, 10), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), omniwm_geometry_centered_offset(&spans, null, spans.len, 5, 100, 10), 0.001);
}

test "geometry centers a single column when requested" {
    const single = [_]f64{100};
    try std.testing.expectApproxEqAbs(@as(f64, -50), omniwm_geometry_visible_offset(&single, null, single.len, 8, 200, 0, 0, 0, 1, -1, 2), 0.001);
}

test "geometry centers edge columns even when the full strip fits" {
    const widths = [_]f64{ 400, 400 };
    try std.testing.expectApproxEqAbs(@as(f64, -400), omniwm_geometry_visible_offset(&widths, null, widths.len, 8, 1200, 0, 0, 1, 0, -1, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -400), omniwm_geometry_visible_offset(&widths, null, widths.len, 8, 1200, 1, 0, 1, 0, -1, 2), 0.001);
}

test "restore assignments return no matches for empty inputs" {
    var no_assignments = [_]RestoreAssignment{};
    var assignment_count: usize = 99;

    try std.testing.expectEqual(kernel_ok, omniwm_restore_resolve_assignments(null, 0, null, 0, null, 0, &no_assignments, no_assignments.len, &assignment_count));
    try std.testing.expectEqual(@as(usize, 0), assignment_count);
}

test "restore assignments prefer exact ids and lower name penalty" {
    const snapshots = [_]RestoreSnapshot{
        .{ .display_id = 100, .anchor_x = 0, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 200, .anchor_x = 2000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const monitors = [_]RestoreMonitor{
        .{ .display_id = 300, .frame_min_x = 0, .frame_max_y = 1080, .anchor_x = 0, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 100, .frame_min_x = 4000, .frame_max_y = 1080, .anchor_x = 4000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const name_penalties = [_]u8{
        1, 0,
        0, 1,
    };
    var assignments = [_]RestoreAssignment{.{ .snapshot_index = 0, .monitor_index = 0 }} ** 2;
    var assignment_count: usize = 0;

    try std.testing.expectEqual(kernel_ok, omniwm_restore_resolve_assignments(&snapshots, snapshots.len, &monitors, monitors.len, &name_penalties, name_penalties.len, &assignments, assignments.len, &assignment_count));
    try std.testing.expectEqual(@as(usize, 2), assignment_count);
    try std.testing.expectEqual(@as(u32, 0), assignments[0].snapshot_index);
    try std.testing.expectEqual(@as(u32, 1), assignments[0].monitor_index);
}

test "restore assignments accept empty input" {
    var assignment_count: usize = 7;
    try std.testing.expectEqual(kernel_ok, omniwm_restore_resolve_assignments(null, 0, null, 0, null, 0, null, 0, &assignment_count));
    try std.testing.expectEqual(@as(usize, 0), assignment_count);
}

test "restore assignments prefer lower name penalty before geometry delta" {
    const snapshots = [_]RestoreSnapshot{
        .{ .display_id = 500, .anchor_x = 0, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const monitors = [_]RestoreMonitor{
        .{ .display_id = 510, .frame_min_x = 0, .frame_max_y = 1080, .anchor_x = 0, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 520, .frame_min_x = 300, .frame_max_y = 1080, .anchor_x = 300, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const name_penalties = [_]u8{
        1, 0,
    };
    var assignments = [_]RestoreAssignment{.{ .snapshot_index = 0, .monitor_index = 0 }} ** 1;
    var assignment_count: usize = 0;

    try std.testing.expectEqual(kernel_ok, omniwm_restore_resolve_assignments(&snapshots, snapshots.len, &monitors, monitors.len, &name_penalties, name_penalties.len, &assignments, assignments.len, &assignment_count));
    try std.testing.expectEqual(@as(usize, 1), assignment_count);
    try std.testing.expectEqual(@as(u32, 1), assignments[0].monitor_index);
}

test "restore assignments prefer lower geometry delta and stable ties" {
    const snapshots = [_]RestoreSnapshot{
        .{ .display_id = 10, .anchor_x = 0, .anchor_y = 0, .frame_width = 1000, .frame_height = 800 },
        .{ .display_id = 20, .anchor_x = 2000, .anchor_y = 0, .frame_width = 1000, .frame_height = 800 },
    };
    const monitors = [_]RestoreMonitor{
        .{ .display_id = 30, .frame_min_x = 1000, .frame_max_y = 800, .anchor_x = 1000, .anchor_y = 0, .frame_width = 1000, .frame_height = 800 },
        .{ .display_id = 40, .frame_min_x = 3000, .frame_max_y = 800, .anchor_x = 3000, .anchor_y = 0, .frame_width = 1000, .frame_height = 800 },
    };
    const name_penalties = [_]u8{
        0, 0,
        0, 0,
    };
    var assignments = [_]RestoreAssignment{.{ .snapshot_index = 0, .monitor_index = 0 }} ** 2;
    var assignment_count: usize = 0;

    try std.testing.expectEqual(kernel_ok, omniwm_restore_resolve_assignments(&snapshots, snapshots.len, &monitors, monitors.len, &name_penalties, name_penalties.len, &assignments, assignments.len, &assignment_count));
    try std.testing.expectEqual(@as(usize, 2), assignment_count);
    try std.testing.expectEqual(@as(u32, 0), assignments[0].snapshot_index);
    try std.testing.expectEqual(@as(u32, 0), assignments[0].monitor_index);
    try std.testing.expectEqual(@as(u32, 1), assignments[1].snapshot_index);
    try std.testing.expectEqual(@as(u32, 1), assignments[1].monitor_index);
}

test "restore assignments preserve later exact fit when an inserted display is present" {
    const snapshots = [_]RestoreSnapshot{
        .{ .display_id = 20, .anchor_x = 3000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 10, .anchor_x = 1000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const monitors = [_]RestoreMonitor{
        .{ .display_id = 30, .frame_min_x = 0, .frame_max_y = 1080, .anchor_x = 0, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 40, .frame_min_x = 1000, .frame_max_y = 1080, .anchor_x = 1000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 50, .frame_min_x = 3000, .frame_max_y = 1080, .anchor_x = 3000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const name_penalties = [_]u8{
        1, 1, 0,
        1, 0, 1,
    };
    var assignments = [_]RestoreAssignment{.{ .snapshot_index = 0, .monitor_index = 0 }} ** 2;
    var assignment_count: usize = 0;

    try std.testing.expectEqual(kernel_ok, omniwm_restore_resolve_assignments(&snapshots, snapshots.len, &monitors, monitors.len, &name_penalties, name_penalties.len, &assignments, assignments.len, &assignment_count));
    try std.testing.expectEqual(@as(usize, 2), assignment_count);
    try std.testing.expectEqual(@as(u32, 1), assignments[0].snapshot_index);
    try std.testing.expectEqual(@as(u32, 1), assignments[0].monitor_index);
    try std.testing.expectEqual(@as(u32, 0), assignments[1].snapshot_index);
    try std.testing.expectEqual(@as(u32, 2), assignments[1].monitor_index);
}

test "restore assignments prefer higher assignment count before lower penalties" {
    const snapshots = [_]RestoreSnapshot{
        .{ .display_id = 100, .anchor_x = 0, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 200, .anchor_x = 2000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const monitors = [_]RestoreMonitor{
        .{ .display_id = 300, .frame_min_x = 0, .frame_max_y = 1080, .anchor_x = 0, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
        .{ .display_id = 400, .frame_min_x = 2000, .frame_max_y = 1080, .anchor_x = 2000, .anchor_y = 0, .frame_width = 1920, .frame_height = 1080 },
    };
    const name_penalties = [_]u8{
        0, 1,
        1, 1,
    };
    var assignments = [_]RestoreAssignment{.{ .snapshot_index = 0, .monitor_index = 0 }} ** 2;
    var assignment_count: usize = 0;

    try std.testing.expectEqual(kernel_ok, omniwm_restore_resolve_assignments(&snapshots, snapshots.len, &monitors, monitors.len, &name_penalties, name_penalties.len, &assignments, assignments.len, &assignment_count));
    try std.testing.expectEqual(@as(usize, 2), assignment_count);
    try std.testing.expectEqual(@as(u32, 0), assignments[0].snapshot_index);
    try std.testing.expectEqual(@as(u32, 0), assignments[0].monitor_index);
    try std.testing.expectEqual(@as(u32, 1), assignments[1].snapshot_index);
    try std.testing.expectEqual(@as(u32, 1), assignments[1].monitor_index);
}
