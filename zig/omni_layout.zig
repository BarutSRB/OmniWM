/// omni_layout.zig — Zig port of NiriAxisSolver
///
/// Matches NiriConstraintSolver.swift exactly so that Swift can delegate
/// the hot path to this compiled static library while keeping the Swift
/// reference implementation around for correctness assertions.

const std = @import("std");

// ──────────────────────────────────────────────────────────────────────────────
// ABI types (must match omni_layout.h exactly)
// ──────────────────────────────────────────────────────────────────────────────

pub const OmniAxisInput = extern struct {
    weight: f64,
    min_constraint: f64,
    max_constraint: f64,
    has_max_constraint: u8,
    is_constraint_fixed: u8,
    has_fixed_value: u8,
    fixed_value: f64, // ignored when has_fixed_value == 0
};

pub const OmniAxisOutput = extern struct {
    value: f64,
    was_constrained: u8,
};

pub const OmniSnapResult = extern struct {
    view_pos: f64,
    column_index: usize,
};

pub const OmniNiriColumnInput = extern struct {
    span: f64,
    render_offset_x: f64,
    render_offset_y: f64,
    is_tabbed: u8,
    tab_indicator_width: f64,
    window_start: usize,
    window_count: usize,
};

pub const OmniNiriWindowInput = extern struct {
    weight: f64,
    min_constraint: f64,
    max_constraint: f64,
    has_max_constraint: u8,
    is_constraint_fixed: u8,
    has_fixed_value: u8,
    fixed_value: f64,
    sizing_mode: u8,
    render_offset_x: f64,
    render_offset_y: f64,
};

pub const OmniNiriWindowOutput = extern struct {
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
    animated_x: f64,
    animated_y: f64,
    animated_width: f64,
    animated_height: f64,
    resolved_span: f64,
    was_constrained: u8,
    hide_side: u8,
    column_index: usize,
};

pub const OmniNiriColumnOutput = extern struct {
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
    hide_side: u8,
    is_visible: u8,
};

pub const OmniNiriHitTestWindow = extern struct {
    window_index: usize,
    column_index: usize,
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
    is_fullscreen: u8,
};

pub const OmniNiriResizeHitResult = extern struct {
    window_index: i64,
    edges: u8,
};

pub const OmniNiriResizeInput = extern struct {
    edges: u8,
    start_x: f64,
    start_y: f64,
    current_x: f64,
    current_y: f64,
    original_column_width: f64,
    min_column_width: f64,
    max_column_width: f64,
    original_window_weight: f64,
    min_window_weight: f64,
    max_window_weight: f64,
    pixels_per_weight: f64,
    has_original_view_offset: u8,
    original_view_offset: f64,
};

pub const OmniNiriResizeResult = extern struct {
    changed_width: u8,
    new_column_width: f64,
    changed_weight: u8,
    new_window_weight: f64,
    adjust_view_offset: u8,
    new_view_offset: f64,
};

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

// Stack-buffer cap — realistic window counts are < 50; 512 is a safe ceiling.
const MAX_WINDOWS = 512;

const OMNI_OK: i32 = 0;
const OMNI_ERR_INVALID_ARGS: i32 = -1;
const OMNI_ERR_OUT_OF_RANGE: i32 = -2;

const OMNI_CENTER_NEVER: u8 = 0;
const OMNI_CENTER_ALWAYS: u8 = 1;
const OMNI_CENTER_ON_OVERFLOW: u8 = 2;

const OMNI_NIRI_ORIENTATION_HORIZONTAL: u8 = 0;
const OMNI_NIRI_ORIENTATION_VERTICAL: u8 = 1;

const OMNI_NIRI_SIZING_NORMAL: u8 = 0;
const OMNI_NIRI_SIZING_FULLSCREEN: u8 = 1;

const OMNI_NIRI_HIDE_NONE: u8 = 0;
const OMNI_NIRI_HIDE_LEFT: u8 = 1;
const OMNI_NIRI_HIDE_RIGHT: u8 = 2;

const OMNI_NIRI_RESIZE_EDGE_TOP: u8 = 0b0001;
const OMNI_NIRI_RESIZE_EDGE_BOTTOM: u8 = 0b0010;
const OMNI_NIRI_RESIZE_EDGE_LEFT: u8 = 0b0100;
const OMNI_NIRI_RESIZE_EDGE_RIGHT: u8 = 0b1000;

// ──────────────────────────────────────────────────────────────────────────────
// Exported entry points
// ──────────────────────────────────────────────────────────────────────────────

/// Solve axis layout for `window_count` windows.
/// Returns 0 on success, -1 when out_count < window_count or window_count
/// exceeds the internal stack limit.
export fn omni_axis_solve(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    is_tabbed: u8,
    out: [*]OmniAxisOutput,
    out_count: usize,
) i32 {
    if (out_count < window_count) return -1;
    if (window_count == 0) return 0;
    if (window_count > MAX_WINDOWS) return -1;

    if (is_tabbed != 0) {
        return omni_axis_solve_tabbed(windows, window_count, available_space, gap_size, out, out_count);
    }

    solveNormal(windows, window_count, available_space, gap_size, out);
    return 0;
}

/// Tabbed variant: every window in the container shares the same span.
export fn omni_axis_solve_tabbed(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    out: [*]OmniAxisOutput,
    out_count: usize,
) i32 {
    _ = gap_size; // tabbed layout ignores gaps
    if (out_count < window_count) return -1;
    if (window_count == 0) return 0;

    solveTabbedImpl(windows, window_count, available_space, out);
    return 0;
}

// ──────────────────────────────────────────────────────────────────────────────
// Internal implementations
// ──────────────────────────────────────────────────────────────────────────────

/// Ports `NiriAxisSolver.solve()` (the non-tabbed branch).
fn solveNormal(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    out: [*]OmniAxisOutput,
) void {
    const n = window_count;

    // Total gap space between n windows
    const gap_count: f64 = @floatFromInt(if (n > 0) n - 1 else 0);
    const total_gaps = gap_size * gap_count;
    const space_for_windows = available_space - total_gaps;

    // If there is no usable space every window falls back to its minimum.
    if (space_for_windows <= 0) {
        for (0..n) |i| {
            out[i] = .{ .value = windows[i].min_constraint, .was_constrained = 1 };
        }
        return;
    }

    // Working buffers on the stack
    var values: [MAX_WINDOWS]f64 = undefined;
    var is_fixed: [MAX_WINDOWS]bool = undefined;
    var used_space: f64 = 0.0;

    for (0..n) |i| {
        values[i] = 0.0;
        is_fixed[i] = false;
    }

    // Pass 1 — pin windows that already have a known size
    for (0..n) |i| {
        const w = windows[i];
        if (w.has_fixed_value != 0) {
            // Clamp fixed value to [min, max]
            var clamped = w.fixed_value;
            clamped = @max(clamped, w.min_constraint);
            if (w.has_max_constraint != 0) clamped = @min(clamped, w.max_constraint);
            values[i] = clamped;
            is_fixed[i] = true;
            used_space += clamped;
        } else if (w.is_constraint_fixed != 0) {
            values[i] = w.min_constraint;
            is_fixed[i] = true;
            used_space += values[i];
        }
    }

    // Pass 2 — iteratively distribute remaining space by weight, fixing any
    //           window that would violate its minimum constraint.
    const max_iterations = n + 1;
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        const remaining_space = space_for_windows - used_space;

        var total_weight: f64 = 0.0;
        for (0..n) |i| {
            if (!is_fixed[i]) total_weight += windows[i].weight;
        }

        if (total_weight <= 0.0) break;

        // Find the first window whose proportional allocation is below its min.
        var any_violation = false;
        for (0..n) |i| {
            if (is_fixed[i]) continue;
            const proposed = remaining_space * (windows[i].weight / total_weight);
            if (proposed < windows[i].min_constraint) {
                values[i] = windows[i].min_constraint;
                is_fixed[i] = true;
                used_space += windows[i].min_constraint;
                any_violation = true;
                break; // restart with updated used_space
            }
        }

        if (!any_violation) {
            // No violations: assign final proportional values and stop.
            for (0..n) |i| {
                if (!is_fixed[i]) {
                    values[i] = remaining_space * (windows[i].weight / total_weight);
                }
            }
            break;
        }
    }

    // Pass 3 — cap windows that exceed their maximum constraint and redistribute
    //           the freed excess to unconstrained windows.
    var excess_space: f64 = 0.0;
    for (0..n) |i| {
        const w = windows[i];
        if (w.has_max_constraint != 0 and values[i] > w.max_constraint) {
            excess_space += values[i] - w.max_constraint;
            values[i] = w.max_constraint;
            is_fixed[i] = true;
        }
    }

    if (excess_space > 0.0) {
        var remaining_weight: f64 = 0.0;
        for (0..n) |i| {
            if (!is_fixed[i]) remaining_weight += windows[i].weight;
        }
        if (remaining_weight > 0.0) {
            for (0..n) |i| {
                if (!is_fixed[i]) {
                    values[i] += excess_space * (windows[i].weight / remaining_weight);
                }
            }
        }
    }

    // Build output — wasConstrained iff the window was pinned at a constraint edge.
    for (0..n) |i| {
        const w = windows[i];
        const was_constrained = is_fixed[i] and
            (values[i] == w.min_constraint or values[i] == w.max_constraint);
        out[i] = .{
            .value = @max(1.0, values[i]),
            .was_constrained = @intFromBool(was_constrained),
        };
    }
}

/// Ports `NiriAxisSolver.solveTabbed()`.
/// All windows receive the same span value.
fn solveTabbedImpl(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    out: [*]OmniAxisOutput,
) void {
    const n = window_count;

    // Maximum of all minimum constraints (Swift: .max() ?? 1 — but ?? 1 only
    // fires for empty arrays which we've already handled above).
    var max_min_constraint: f64 = 0.0;
    for (0..n) |i| {
        max_min_constraint = @max(max_min_constraint, windows[i].min_constraint);
    }

    // First fixed value, if any window carries one.
    var fixed_value: ?f64 = null;
    for (0..n) |i| {
        if (windows[i].has_fixed_value != 0) {
            fixed_value = windows[i].fixed_value;
            break;
        }
    }

    var shared_value: f64 = if (fixed_value) |fv|
        @max(fv, max_min_constraint)
    else
        @max(available_space, max_min_constraint);

    // Apply the tightest maximum constraint across all windows.
    var min_max_constraint: ?f64 = null;
    for (0..n) |i| {
        const w = windows[i];
        if (w.has_max_constraint != 0) {
            if (min_max_constraint == null or w.max_constraint < min_max_constraint.?) {
                min_max_constraint = w.max_constraint;
            }
        }
    }
    if (min_max_constraint) |mc| {
        shared_value = @min(shared_value, mc);
    }

    shared_value = @max(1.0, shared_value);

    for (0..n) |i| {
        const w = windows[i];
        const was_constrained = shared_value == w.min_constraint or
            (w.has_max_constraint != 0 and shared_value == w.max_constraint);
        out[i] = .{
            .value = shared_value,
            .was_constrained = @intFromBool(was_constrained),
        };
    }
}

fn parseNiriOrientation(orientation: u8) ?u8 {
    return switch (orientation) {
        OMNI_NIRI_ORIENTATION_HORIZONTAL, OMNI_NIRI_ORIENTATION_VERTICAL => orientation,
        else => null,
    };
}

fn isValidNiriSizingMode(mode: u8) bool {
    return mode == OMNI_NIRI_SIZING_NORMAL or mode == OMNI_NIRI_SIZING_FULLSCREEN;
}

fn makeHiddenColumnRect(
    side: u8,
    hidden_span: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    workspace_offset: f64,
    scale: f64,
) Rect {
    const edge_reveal = 1.0 / @max(1.0, scale);
    const x = if (side == OMNI_NIRI_HIDE_LEFT)
        view_x - hidden_span + edge_reveal
    else
        view_x + view_width - edge_reveal;

    return .{
        .x = x + workspace_offset,
        .y = view_y + view_height - 2.0,
        .width = hidden_span,
        .height = working_height,
    };
}

fn makeHiddenRowRect(
    working_width: f64,
    hidden_span: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    workspace_offset: f64,
) Rect {
    return .{
        .x = view_x + view_width - 2.0 + workspace_offset,
        .y = view_y + view_height - 2.0,
        .width = working_width,
        .height = hidden_span,
    };
}

fn solveAndLayoutNiriColumn(
    col: OmniNiriColumnInput,
    windows: [*c]const OmniNiriWindowInput,
    window_count: usize,
    secondary_gap: f64,
    orientation: u8,
    container_rect: Rect,
    fullscreen_rect: Rect,
    container_render_x: f64,
    container_render_y: f64,
    scale: f64,
    hide_side: u8,
    column_index: usize,
    out_windows: [*c]OmniNiriWindowOutput,
) i32 {
    if (col.window_start + col.window_count > window_count) return OMNI_ERR_OUT_OF_RANGE;
    if (col.window_count == 0) return OMNI_OK;
    if (col.window_count > MAX_WINDOWS) return OMNI_ERR_OUT_OF_RANGE;

    const tab_offset: f64 = if (col.is_tabbed != 0) col.tab_indicator_width else 0.0;
    const content_rect = Rect{
        .x = container_rect.x + tab_offset,
        .y = container_rect.y,
        .width = @max(0.0, container_rect.width - tab_offset),
        .height = container_rect.height,
    };

    const available_space = if (orientation == OMNI_NIRI_ORIENTATION_HORIZONTAL)
        content_rect.height
    else
        content_rect.width;

    var axis_inputs: [MAX_WINDOWS]OmniAxisInput = undefined;
    var axis_outputs: [MAX_WINDOWS]OmniAxisOutput = undefined;

    for (0..col.window_count) |local_idx| {
        const global_idx = col.window_start + local_idx;
        const w = windows[global_idx];
        if (!isValidNiriSizingMode(w.sizing_mode)) return OMNI_ERR_INVALID_ARGS;

        axis_inputs[local_idx] = .{
            .weight = w.weight,
            .min_constraint = w.min_constraint,
            .max_constraint = w.max_constraint,
            .has_max_constraint = w.has_max_constraint,
            .is_constraint_fixed = w.is_constraint_fixed,
            .has_fixed_value = w.has_fixed_value,
            .fixed_value = w.fixed_value,
        };
    }

    if (col.is_tabbed != 0) {
        solveTabbedImpl(
            axis_inputs[0..].ptr,
            col.window_count,
            available_space,
            axis_outputs[0..].ptr,
        );
    } else {
        solveNormal(
            axis_inputs[0..].ptr,
            col.window_count,
            available_space,
            secondary_gap,
            axis_outputs[0..].ptr,
        );
    }

    var pos: f64 = if (orientation == OMNI_NIRI_ORIENTATION_HORIZONTAL)
        content_rect.y
    else
        content_rect.x;

    for (0..col.window_count) |local_idx| {
        const global_idx = col.window_start + local_idx;
        const w = windows[global_idx];
        const span = axis_outputs[local_idx].value;

        const base_rect_unrounded: Rect = if (w.sizing_mode == OMNI_NIRI_SIZING_FULLSCREEN)
            fullscreen_rect
        else if (orientation == OMNI_NIRI_ORIENTATION_HORIZONTAL)
            .{
                .x = content_rect.x,
                .y = if (col.is_tabbed != 0) content_rect.y else pos,
                .width = content_rect.width,
                .height = span,
            }
        else
            .{
                .x = if (col.is_tabbed != 0) content_rect.x else pos,
                .y = content_rect.y,
                .width = span,
                .height = content_rect.height,
            };

        const base_rect = roundRectToPhysicalPixels(base_rect_unrounded, scale);
        const animated_rect = roundRectToPhysicalPixels(
            .{
                .x = base_rect.x + container_render_x + w.render_offset_x,
                .y = base_rect.y + container_render_y + w.render_offset_y,
                .width = base_rect.width,
                .height = base_rect.height,
            },
            scale,
        );

        out_windows[global_idx] = .{
            .frame_x = base_rect.x,
            .frame_y = base_rect.y,
            .frame_width = base_rect.width,
            .frame_height = base_rect.height,
            .animated_x = animated_rect.x,
            .animated_y = animated_rect.y,
            .animated_width = animated_rect.width,
            .animated_height = animated_rect.height,
            .resolved_span = span,
            .was_constrained = axis_outputs[local_idx].was_constrained,
            .hide_side = hide_side,
            .column_index = column_index,
        };

        if (col.is_tabbed == 0) {
            pos += span;
            if (local_idx < col.window_count - 1) {
                pos += secondary_gap;
            }
        }
    }

    return OMNI_OK;
}

export fn omni_niri_layout_pass(
    columns: [*c]const OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const OmniNiriWindowInput,
    window_count: usize,
    working_x: f64,
    working_y: f64,
    working_width: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    fullscreen_x: f64,
    fullscreen_y: f64,
    fullscreen_width: f64,
    fullscreen_height: f64,
    primary_gap: f64,
    secondary_gap: f64,
    view_start: f64,
    viewport_span: f64,
    workspace_offset: f64,
    scale: f64,
    orientation: u8,
    out_windows: [*c]OmniNiriWindowOutput,
    out_window_count: usize,
) i32 {
    return omni_niri_layout_pass_v2(
        columns,
        column_count,
        windows,
        window_count,
        working_x,
        working_y,
        working_width,
        working_height,
        view_x,
        view_y,
        view_width,
        view_height,
        fullscreen_x,
        fullscreen_y,
        fullscreen_width,
        fullscreen_height,
        primary_gap,
        secondary_gap,
        view_start,
        viewport_span,
        workspace_offset,
        scale,
        orientation,
        out_windows,
        out_window_count,
        null,
        0,
    );
}

export fn omni_niri_layout_pass_v2(
    columns: [*c]const OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const OmniNiriWindowInput,
    window_count: usize,
    working_x: f64,
    working_y: f64,
    working_width: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    fullscreen_x: f64,
    fullscreen_y: f64,
    fullscreen_width: f64,
    fullscreen_height: f64,
    primary_gap: f64,
    secondary_gap: f64,
    view_start: f64,
    viewport_span: f64,
    workspace_offset: f64,
    scale: f64,
    orientation: u8,
    out_windows: [*c]OmniNiriWindowOutput,
    out_window_count: usize,
    out_columns: [*c]OmniNiriColumnOutput,
    out_column_count: usize,
) i32 {
    if (out_windows == null) return OMNI_ERR_INVALID_ARGS;
    if (out_window_count < window_count) return OMNI_ERR_INVALID_ARGS;
    if (column_count > 0 and columns == null) return OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return OMNI_ERR_INVALID_ARGS;
    if (out_column_count > 0 and out_columns == null) return OMNI_ERR_INVALID_ARGS;
    if (out_column_count > 0 and out_column_count < column_count) return OMNI_ERR_INVALID_ARGS;

    const parsed_orientation = parseNiriOrientation(orientation) orelse return OMNI_ERR_INVALID_ARGS;

    for (0..window_count) |i| {
        out_windows[i] = .{
            .frame_x = 0.0,
            .frame_y = 0.0,
            .frame_width = 0.0,
            .frame_height = 0.0,
            .animated_x = 0.0,
            .animated_y = 0.0,
            .animated_width = 0.0,
            .animated_height = 0.0,
            .resolved_span = 0.0,
            .was_constrained = 0,
            .hide_side = OMNI_NIRI_HIDE_NONE,
            .column_index = 0,
        };
    }

    if (out_columns != null and out_column_count > 0) {
        for (0..column_count) |i| {
            out_columns[i] = .{
                .frame_x = 0.0,
                .frame_y = 0.0,
                .frame_width = 0.0,
                .frame_height = 0.0,
                .hide_side = OMNI_NIRI_HIDE_NONE,
                .is_visible = 0,
            };
        }
    }

    if (column_count == 0) {
        return if (window_count == 0) OMNI_OK else OMNI_ERR_OUT_OF_RANGE;
    }

    const fullscreen_rect = Rect{
        .x = fullscreen_x,
        .y = fullscreen_y,
        .width = fullscreen_width,
        .height = fullscreen_height,
    };

    const view_end = view_start + viewport_span;
    var running_pos: f64 = 0.0;
    var total_span: f64 = 0.0;
    var total_windows_seen: usize = 0;

    for (0..column_count) |idx| {
        const col = columns[idx];
        if (col.window_start + col.window_count > window_count) return OMNI_ERR_OUT_OF_RANGE;
        total_windows_seen += col.window_count;

        const container_pos = running_pos;
        const container_span = col.span;
        const container_end = container_pos + container_span;
        const is_visible = container_end > view_start and container_pos < view_end;

        if (is_visible) {
            const container_rect = if (parsed_orientation == OMNI_NIRI_ORIENTATION_HORIZONTAL)
                roundRectToPhysicalPixels(
                    .{
                        .x = working_x + container_pos - view_start + col.render_offset_x + workspace_offset,
                        .y = working_y,
                        .width = roundToPhysicalPixel(container_span, scale),
                        .height = working_height,
                    },
                    scale,
                )
            else
                roundRectToPhysicalPixels(
                    .{
                        .x = working_x + workspace_offset,
                        .y = working_y + container_pos - view_start + col.render_offset_y,
                        .width = working_width,
                        .height = roundToPhysicalPixel(container_span, scale),
                    },
                    scale,
                );

            if (out_columns != null and out_column_count >= column_count) {
                out_columns[idx] = .{
                    .frame_x = container_rect.x,
                    .frame_y = container_rect.y,
                    .frame_width = container_rect.width,
                    .frame_height = container_rect.height,
                    .hide_side = OMNI_NIRI_HIDE_NONE,
                    .is_visible = 1,
                };
            }

            const rc = solveAndLayoutNiriColumn(
                col,
                windows,
                window_count,
                secondary_gap,
                parsed_orientation,
                container_rect,
                fullscreen_rect,
                col.render_offset_x,
                col.render_offset_y,
                scale,
                OMNI_NIRI_HIDE_NONE,
                idx,
                out_windows,
            );
            if (rc != OMNI_OK) return rc;
        }

        running_pos += container_span;
        total_span += container_span;
        if (idx < column_count - 1) {
            running_pos += primary_gap;
            total_span += primary_gap;
        }
    }

    if (total_windows_seen != window_count) return OMNI_ERR_OUT_OF_RANGE;

    const avg_span = total_span / @as(f64, @floatFromInt(@max(@as(usize, 1), column_count)));
    const hidden_span = roundToPhysicalPixel(@max(1.0, avg_span), scale);

    running_pos = 0.0;
    for (0..column_count) |idx| {
        const col = columns[idx];
        const container_pos = running_pos;
        const container_span = col.span;
        const container_end = container_pos + container_span;
        const is_visible = container_end > view_start and container_pos < view_end;

        if (!is_visible) {
            const hide_side: u8 = if (container_end <= view_start)
                OMNI_NIRI_HIDE_LEFT
            else
                OMNI_NIRI_HIDE_RIGHT;

            const container_rect_unrounded = if (parsed_orientation == OMNI_NIRI_ORIENTATION_HORIZONTAL)
                makeHiddenColumnRect(
                    hide_side,
                    hidden_span,
                    working_height,
                    view_x,
                    view_y,
                    view_width,
                    view_height,
                    workspace_offset,
                    scale,
                )
            else
                makeHiddenRowRect(
                    working_width,
                    hidden_span,
                    view_x,
                    view_y,
                    view_width,
                    view_height,
                    workspace_offset,
                );
            const container_rect = roundRectToPhysicalPixels(container_rect_unrounded, scale);

            if (out_columns != null and out_column_count >= column_count) {
                out_columns[idx] = .{
                    .frame_x = container_rect.x,
                    .frame_y = container_rect.y,
                    .frame_width = container_rect.width,
                    .frame_height = container_rect.height,
                    .hide_side = hide_side,
                    .is_visible = 0,
                };
            }

            const rc = solveAndLayoutNiriColumn(
                col,
                windows,
                window_count,
                secondary_gap,
                parsed_orientation,
                container_rect,
                fullscreen_rect,
                0.0,
                0.0,
                scale,
                hide_side,
                idx,
                out_windows,
            );
            if (rc != OMNI_OK) return rc;
        }

        running_pos += container_span;
        if (idx < column_count - 1) {
            running_pos += primary_gap;
        }
    }

    return OMNI_OK;
}

fn pointInRect(point_x: f64, point_y: f64, rect: Rect) bool {
    if (rect.width < 0.0 or rect.height < 0.0) return false;
    const max_x = rect.x + rect.width;
    const max_y = rect.y + rect.height;
    return point_x >= rect.x and point_x <= max_x and point_y >= rect.y and point_y <= max_y;
}

fn detectResizeEdgesForPoint(point_x: f64, point_y: f64, rect: Rect, threshold: f64) u8 {
    const expanded = Rect{
        .x = rect.x - threshold,
        .y = rect.y - threshold,
        .width = rect.width + threshold * 2.0,
        .height = rect.height + threshold * 2.0,
    };
    if (!pointInRect(point_x, point_y, expanded)) return 0;

    const inner = Rect{
        .x = rect.x + threshold,
        .y = rect.y + threshold,
        .width = rect.width - threshold * 2.0,
        .height = rect.height - threshold * 2.0,
    };
    if (pointInRect(point_x, point_y, inner)) return 0;

    const min_x = rect.x;
    const max_x = rect.x + rect.width;
    const min_y = rect.y;
    const max_y = rect.y + rect.height;

    var edges: u8 = 0;
    if (point_x <= min_x + threshold and point_x >= min_x - threshold) {
        edges |= OMNI_NIRI_RESIZE_EDGE_LEFT;
    }
    if (point_x >= max_x - threshold and point_x <= max_x + threshold) {
        edges |= OMNI_NIRI_RESIZE_EDGE_RIGHT;
    }
    if (point_y <= min_y + threshold and point_y >= min_y - threshold) {
        edges |= OMNI_NIRI_RESIZE_EDGE_BOTTOM;
    }
    if (point_y >= max_y - threshold and point_y <= max_y + threshold) {
        edges |= OMNI_NIRI_RESIZE_EDGE_TOP;
    }
    return edges;
}

export fn omni_niri_hit_test_tiled(
    windows: [*c]const OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    out_window_index: [*c]i64,
) i32 {
    if (out_window_index == null) return OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return OMNI_ERR_INVALID_ARGS;

    out_window_index[0] = -1;
    for (0..window_count) |i| {
        const w = windows[i];
        const rect = Rect{
            .x = w.frame_x,
            .y = w.frame_y,
            .width = w.frame_width,
            .height = w.frame_height,
        };
        if (pointInRect(point_x, point_y, rect)) {
            out_window_index[0] = @as(i64, @intCast(i));
            return OMNI_OK;
        }
    }

    return OMNI_OK;
}

export fn omni_niri_hit_test_resize(
    windows: [*c]const OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    threshold: f64,
    out_result: [*c]OmniNiriResizeHitResult,
) i32 {
    if (out_result == null) return OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return OMNI_ERR_INVALID_ARGS;

    out_result[0] = .{
        .window_index = -1,
        .edges = 0,
    };

    const safe_threshold = @max(0.0, threshold);
    for (0..window_count) |i| {
        const w = windows[i];
        if (w.is_fullscreen != 0) continue;

        const rect = Rect{
            .x = w.frame_x,
            .y = w.frame_y,
            .width = w.frame_width,
            .height = w.frame_height,
        };
        const edges = detectResizeEdgesForPoint(point_x, point_y, rect, safe_threshold);
        if (edges != 0) {
            out_result[0] = .{
                .window_index = @as(i64, @intCast(i)),
                .edges = edges,
            };
            return OMNI_OK;
        }
    }

    return OMNI_OK;
}

export fn omni_niri_resize_compute(
    input: [*c]const OmniNiriResizeInput,
    out_result: [*c]OmniNiriResizeResult,
) i32 {
    if (input == null or out_result == null) return OMNI_ERR_INVALID_ARGS;

    const in = input[0];
    out_result[0] = .{
        .changed_width = 0,
        .new_column_width = in.original_column_width,
        .changed_weight = 0,
        .new_window_weight = in.original_window_weight,
        .adjust_view_offset = 0,
        .new_view_offset = in.original_view_offset,
    };

    const delta_x = in.current_x - in.start_x;
    const delta_y = in.current_y - in.start_y;
    const has_horizontal = (in.edges & (OMNI_NIRI_RESIZE_EDGE_LEFT | OMNI_NIRI_RESIZE_EDGE_RIGHT)) != 0;
    const has_vertical = (in.edges & (OMNI_NIRI_RESIZE_EDGE_TOP | OMNI_NIRI_RESIZE_EDGE_BOTTOM)) != 0;
    const has_left = (in.edges & OMNI_NIRI_RESIZE_EDGE_LEFT) != 0;
    const has_bottom = (in.edges & OMNI_NIRI_RESIZE_EDGE_BOTTOM) != 0;

    if (has_horizontal) {
        var dx = delta_x;
        if (has_left) dx = -dx;

        const min_width = @min(in.min_column_width, in.max_column_width);
        const max_width = @max(in.min_column_width, in.max_column_width);
        const next_width = clampFloat(in.original_column_width + dx, min_width, max_width);
        out_result[0].new_column_width = next_width;
        out_result[0].changed_width = @intFromBool(@abs(next_width - in.original_column_width) > 0.0001);

        if (has_left and in.has_original_view_offset != 0) {
            out_result[0].adjust_view_offset = 1;
            out_result[0].new_view_offset = in.original_view_offset + (next_width - in.original_column_width);
        }
    }

    if (has_vertical and in.pixels_per_weight > 0.0) {
        var dy = delta_y;
        if (has_bottom) dy = -dy;

        const weight_delta = dy / in.pixels_per_weight;
        const min_weight = @min(in.min_window_weight, in.max_window_weight);
        const max_weight = @max(in.min_window_weight, in.max_window_weight);
        const next_weight = clampFloat(in.original_window_weight + weight_delta, min_weight, max_weight);
        out_result[0].new_window_weight = next_weight;
        out_result[0].changed_weight = @intFromBool(@abs(next_weight - in.original_window_weight) > 0.0001);
    }

    return OMNI_OK;
}

fn roundToPhysicalPixel(value: f64, scale: f64) f64 {
    const safe_scale = @max(1.0, scale);
    return @round(value * safe_scale) / safe_scale;
}

fn roundRectToPhysicalPixels(rect: Rect, scale: f64) Rect {
    return .{
        .x = roundToPhysicalPixel(rect.x, scale),
        .y = roundToPhysicalPixel(rect.y, scale),
        .width = roundToPhysicalPixel(rect.width, scale),
        .height = roundToPhysicalPixel(rect.height, scale),
    };
}

fn parseCenterMode(mode: u8) ?u8 {
    return switch (mode) {
        OMNI_CENTER_NEVER, OMNI_CENTER_ALWAYS, OMNI_CENTER_ON_OVERFLOW => mode,
        else => null,
    };
}

fn clampFloat(value: f64, min_value: f64, max_value: f64) f64 {
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}

fn containerPositionFromSpans(spans: [*c]const f64, span_count: usize, index: usize, gap: f64) f64 {
    _ = span_count;
    var pos: f64 = 0.0;
    var i: usize = 0;
    while (i < index) : (i += 1) {
        pos += spans[i] + gap;
    }
    return pos;
}

fn totalSpanFromSpans(spans: [*c]const f64, span_count: usize, gap: f64) f64 {
    if (span_count == 0) return 0.0;

    var total: f64 = 0.0;
    for (0..span_count) |i| {
        total += spans[i];
    }
    total += @as(f64, @floatFromInt(span_count - 1)) * gap;
    return total;
}

fn computeCenteredOffsetFromSpans(
    spans: [*c]const f64,
    span_count: usize,
    container_index: usize,
    gap: f64,
    viewport_span: f64,
) f64 {
    if (span_count == 0 or container_index >= span_count) return 0.0;

    const total = totalSpanFromSpans(spans, span_count, gap);
    const pos = containerPositionFromSpans(spans, span_count, container_index, gap);

    if (total <= viewport_span) {
        return -pos - (viewport_span - total) / 2.0;
    }

    const container_size = spans[container_index];
    const centered_offset = -(viewport_span - container_size) / 2.0;
    const max_offset: f64 = 0.0;
    const min_offset = viewport_span - total;
    return clampFloat(centered_offset, min_offset, max_offset);
}

fn computeFitOffset(
    current_view_pos: f64,
    view_span: f64,
    target_pos: f64,
    target_span: f64,
    gaps: f64,
) f64 {
    if (view_span <= target_span) {
        return 0.0;
    }

    const padding = clampFloat((view_span - target_span) / 2.0, 0.0, gaps);
    const new_pos = target_pos - padding;
    const new_end_pos = target_pos + target_span + padding;

    if (current_view_pos <= new_pos and new_end_pos <= current_view_pos + view_span) {
        return -(target_pos - current_view_pos);
    }

    const dist_to_start = @abs(current_view_pos - new_pos);
    const dist_to_end = @abs((current_view_pos + view_span) - new_end_pos);

    if (dist_to_start <= dist_to_end) {
        return -padding;
    }

    return -(view_span - padding - target_span);
}

fn considerSnapPoint(
    candidate_view_pos: f64,
    candidate_col_idx: usize,
    projected_view_pos: f64,
    min_view_pos: f64,
    max_view_pos: f64,
    best_is_set: *bool,
    best_view_pos: *f64,
    best_col_idx: *usize,
    best_distance: *f64,
) void {
    const clamped = @min(@max(candidate_view_pos, min_view_pos), max_view_pos);
    const distance = @abs(clamped - projected_view_pos);
    if (!best_is_set.* or distance < best_distance.*) {
        best_is_set.* = true;
        best_view_pos.* = clamped;
        best_col_idx.* = candidate_col_idx;
        best_distance.* = distance;
    }
}

export fn omni_viewport_compute_visible_offset(
    spans: [*c]const f64,
    span_count: usize,
    container_index: usize,
    gap: f64,
    viewport_span: f64,
    current_view_start: f64,
    center_mode: u8,
    always_center_single_column: u8,
    from_container_index: i64,
    out_target_offset: [*c]f64,
) i32 {
    if (out_target_offset == null) return OMNI_ERR_INVALID_ARGS;
    if (span_count == 0 or container_index >= span_count) return OMNI_ERR_OUT_OF_RANGE;
    if (spans == null) return OMNI_ERR_INVALID_ARGS;

    const parsed_mode = parseCenterMode(center_mode) orelse return OMNI_ERR_INVALID_ARGS;
    const effective_center_mode = if (span_count == 1 and always_center_single_column != 0)
        OMNI_CENTER_ALWAYS
    else
        parsed_mode;

    const target_pos = containerPositionFromSpans(spans, span_count, container_index, gap);
    const target_size = spans[container_index];

    var target_offset: f64 = 0.0;

    switch (effective_center_mode) {
        OMNI_CENTER_ALWAYS => {
            target_offset = computeCenteredOffsetFromSpans(
                spans,
                span_count,
                container_index,
                gap,
                viewport_span,
            );
        },
        OMNI_CENTER_ON_OVERFLOW => {
            if (target_size > viewport_span) {
                target_offset = computeCenteredOffsetFromSpans(
                    spans,
                    span_count,
                    container_index,
                    gap,
                    viewport_span,
                );
            } else if (from_container_index != -1 and from_container_index != @as(i64, @intCast(container_index))) {
                const source_idx = if (from_container_index > @as(i64, @intCast(container_index)))
                    @min(container_index + 1, span_count - 1)
                else
                    if (container_index > 0) container_index - 1 else 0;

                const source_pos = containerPositionFromSpans(spans, span_count, source_idx, gap);
                const source_size = spans[source_idx];

                const total_span_needed: f64 = if (source_pos < target_pos)
                    target_pos - source_pos + target_size + gap * 2.0
                else
                    source_pos - target_pos + source_size + gap * 2.0;

                if (total_span_needed <= viewport_span) {
                    target_offset = computeFitOffset(
                        current_view_start,
                        viewport_span,
                        target_pos,
                        target_size,
                        gap,
                    );
                } else {
                    target_offset = computeCenteredOffsetFromSpans(
                        spans,
                        span_count,
                        container_index,
                        gap,
                        viewport_span,
                    );
                }
            } else {
                target_offset = computeFitOffset(
                    current_view_start,
                    viewport_span,
                    target_pos,
                    target_size,
                    gap,
                );
            }
        },
        OMNI_CENTER_NEVER => {
            target_offset = computeFitOffset(
                current_view_start,
                viewport_span,
                target_pos,
                target_size,
                gap,
            );
        },
        else => return OMNI_ERR_INVALID_ARGS,
    }

    const total = totalSpanFromSpans(spans, span_count, gap);
    const max_offset: f64 = 0.0;
    const min_offset = viewport_span - total;
    if (min_offset < max_offset) {
        target_offset = clampFloat(target_offset, min_offset, max_offset);
    }

    out_target_offset[0] = target_offset;
    return OMNI_OK;
}

export fn omni_viewport_find_snap_target(
    spans: [*c]const f64,
    span_count: usize,
    gap: f64,
    viewport_span: f64,
    projected_view_pos: f64,
    current_view_pos: f64,
    center_mode: u8,
    always_center_single_column: u8,
    out_result: [*c]OmniSnapResult,
) i32 {
    if (out_result == null) return OMNI_ERR_INVALID_ARGS;
    if (span_count == 0) {
        out_result[0] = .{ .view_pos = 0.0, .column_index = 0 };
        return OMNI_OK;
    }
    if (spans == null) return OMNI_ERR_INVALID_ARGS;

    const parsed_mode = parseCenterMode(center_mode) orelse return OMNI_ERR_INVALID_ARGS;
    const effective_center_mode = if (span_count == 1 and always_center_single_column != 0)
        OMNI_CENTER_ALWAYS
    else
        parsed_mode;

    const vw = viewport_span;
    const gaps = gap;
    const total_w = totalSpanFromSpans(spans, span_count, gap);
    const max_view_pos: f64 = 0.0;
    const min_view_pos = vw - total_w;

    var best_is_set = false;
    var best_view_pos: f64 = 0.0;
    var best_col_idx: usize = 0;
    var best_distance: f64 = 0.0;

    if (effective_center_mode == OMNI_CENTER_ALWAYS) {
        for (0..span_count) |idx| {
            const col_x = containerPositionFromSpans(spans, span_count, idx, gap);
            const offset = computeCenteredOffsetFromSpans(spans, span_count, idx, gap, viewport_span);
            const snap_view_pos = col_x + offset;
            considerSnapPoint(
                snap_view_pos,
                idx,
                projected_view_pos,
                min_view_pos,
                max_view_pos,
                &best_is_set,
                &best_view_pos,
                &best_col_idx,
                &best_distance,
            );
        }
    } else {
        var col_x: f64 = 0.0;
        for (0..span_count) |idx| {
            const col_w = spans[idx];
            const padding = clampFloat((vw - col_w) / 2.0, 0.0, gaps);
            const left_snap = col_x - padding;
            const right_snap = col_x + col_w + padding - vw;

            considerSnapPoint(
                left_snap,
                idx,
                projected_view_pos,
                min_view_pos,
                max_view_pos,
                &best_is_set,
                &best_view_pos,
                &best_col_idx,
                &best_distance,
            );
            if (right_snap != left_snap) {
                considerSnapPoint(
                    right_snap,
                    idx,
                    projected_view_pos,
                    min_view_pos,
                    max_view_pos,
                    &best_is_set,
                    &best_view_pos,
                    &best_col_idx,
                    &best_distance,
                );
            }

            col_x += col_w + gaps;
        }
    }

    if (!best_is_set) {
        out_result[0] = .{ .view_pos = 0.0, .column_index = 0 };
        return OMNI_OK;
    }

    var new_col_idx = best_col_idx;

    if (effective_center_mode != OMNI_CENTER_ALWAYS) {
        const scrolling_right = projected_view_pos >= current_view_pos;
        if (scrolling_right) {
            var idx = new_col_idx + 1;
            while (idx < span_count) : (idx += 1) {
                const col_x = containerPositionFromSpans(spans, span_count, idx, gap);
                const col_w = spans[idx];
                const padding = clampFloat((vw - col_w) / 2.0, 0.0, gaps);
                if (best_view_pos + vw >= col_x + col_w + padding) {
                    new_col_idx = idx;
                } else {
                    break;
                }
            }
        } else {
            var idx_i: isize = @intCast(new_col_idx);
            while (idx_i > 0) {
                idx_i -= 1;
                const idx: usize = @intCast(idx_i);
                const col_x = containerPositionFromSpans(spans, span_count, idx, gap);
                const col_w = spans[idx];
                const padding = clampFloat((vw - col_w) / 2.0, 0.0, gaps);
                if (col_x - padding >= best_view_pos) {
                    new_col_idx = idx;
                } else {
                    break;
                }
            }
        }
    }

    out_result[0] = .{ .view_pos = best_view_pos, .column_index = new_col_idx };
    return OMNI_OK;
}
