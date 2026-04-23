// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

pub const center_never: u32 = 0;
pub const center_always: u32 = 1;
pub const center_on_overflow: u32 = 2;

pub const sizing_mode_normal: u8 = 0;
pub const sizing_mode_fullscreen: u8 = 1;

pub const SnapTarget = extern struct {
    view_pos: f64,
    column_index: i32,
};

const Edges = struct {
    left: f64,
    right: f64,
};

fn max(lhs: f64, rhs: f64) f64 {
    return if (rhs > lhs) rhs else lhs;
}

fn min(lhs: f64, rhs: f64) f64 {
    return if (rhs < lhs) rhs else lhs;
}

fn sanitizeSizingMode(mode: u8) u8 {
    return if (mode == sizing_mode_fullscreen) sizing_mode_fullscreen else sizing_mode_normal;
}

pub fn effectiveColumnMode(window_modes: []const u8) u8 {
    for (window_modes) |mode| {
        if (sanitizeSizingMode(mode) == sizing_mode_fullscreen) {
            return sizing_mode_fullscreen;
        }
    }
    return sizing_mode_normal;
}

pub fn modeAt(modes: []const u8, index: usize) u8 {
    if (index >= modes.len) {
        return sizing_mode_normal;
    }
    return sanitizeSizingMode(modes[index]);
}

pub fn totalSpan(spans: []const f64, gap: f64) f64 {
    if (spans.len == 0) {
        return 0;
    }

    var size_sum: f64 = 0;
    for (spans) |span| {
        size_sum += span;
    }
    const gap_sum = @as(f64, @floatFromInt(spans.len - 1)) * gap;
    return size_sum + gap_sum;
}

pub fn containerPosition(spans: []const f64, gap: f64, index: usize) f64 {
    var pos: f64 = 0;
    var i: usize = 0;
    while (i < index) : (i += 1) {
        if (i >= spans.len) {
            break;
        }
        pos += spans[i] + gap;
    }
    return pos;
}

fn effectiveSpan(span: f64, mode: u8, viewport_span: f64) f64 {
    return if (sanitizeSizingMode(mode) == sizing_mode_fullscreen) viewport_span else span;
}

fn fitPadding(view_span: f64, target_span: f64, gap: f64) f64 {
    return min(max((view_span - target_span) / 2.0, 0), gap);
}

fn centeredOffsetForColumn(span: f64, mode: u8, viewport_span: f64) f64 {
    return -(viewport_span - effectiveSpan(span, mode, viewport_span)) / 2.0;
}

pub fn centeredOffset(
    spans: []const f64,
    modes: []const u8,
    gap: f64,
    viewport_span: f64,
    index: usize,
) f64 {
    _ = gap;
    if (spans.len == 0 or index >= spans.len) {
        return 0;
    }

    return centeredOffsetForColumn(spans[index], modeAt(modes, index), viewport_span);
}

fn exactFitOffset(
    current_view_pos: f64,
    view_span: f64,
    target_pos: f64,
    target_span: f64,
    scale: f64,
) f64 {
    const pixel_epsilon = 1.0 / max(scale, 1.0);

    if (view_span <= target_span + pixel_epsilon) {
        return 0;
    }

    const target_end = target_pos + target_span;
    if (current_view_pos - pixel_epsilon <= target_pos and target_end <= current_view_pos + view_span + pixel_epsilon) {
        return current_view_pos - target_pos;
    }

    const exact_start = target_pos;
    const exact_end = target_end - view_span;
    const dist_to_start = @abs(current_view_pos - exact_start);
    const dist_to_end = @abs(current_view_pos - exact_end);

    if (dist_to_start <= dist_to_end) {
        return exact_start - target_pos;
    }
    return exact_end - target_pos;
}

fn paddedFitOffset(
    current_view_pos: f64,
    view_span: f64,
    target_pos: f64,
    target_span: f64,
    gap: f64,
    scale: f64,
) f64 {
    const pixel_epsilon = 1.0 / max(scale, 1.0);

    if (view_span <= target_span + pixel_epsilon) {
        return 0;
    }

    const padding = fitPadding(view_span, target_span, gap);
    const target_start = target_pos - padding;
    const target_end = target_pos + target_span + padding;

    if (current_view_pos - pixel_epsilon <= target_start and target_end <= current_view_pos + view_span + pixel_epsilon) {
        return current_view_pos - target_pos;
    }

    const dist_to_start = @abs(current_view_pos - target_start);
    const dist_to_end = @abs(current_view_pos - target_end + view_span);

    if (dist_to_start <= dist_to_end) {
        return -padding;
    }
    return -(view_span - padding - target_span);
}

pub fn onOverflowSourceIndex(target_index: usize, from_index: usize, count: usize) ?usize {
    if (count == 0 or from_index == target_index or from_index >= count) {
        return null;
    }

    if (from_index > target_index) {
        return if (target_index + 1 < count) target_index + 1 else null;
    }

    return if (target_index > 0) target_index - 1 else null;
}

fn pairSpan(
    spans: []const f64,
    modes: []const u8,
    gap: f64,
    viewport_span: f64,
    lhs: usize,
    rhs: usize,
) f64 {
    const lhs_pos = containerPosition(spans, gap, lhs);
    const rhs_pos = containerPosition(spans, gap, rhs);
    const lhs_span = effectiveSpan(spans[lhs], modeAt(modes, lhs), viewport_span);
    const rhs_span = effectiveSpan(spans[rhs], modeAt(modes, rhs), viewport_span);

    return if (lhs_pos < rhs_pos)
        rhs_pos - lhs_pos + rhs_span
    else
        lhs_pos - rhs_pos + lhs_span;
}

pub fn visibleOffset(
    spans: []const f64,
    modes: []const u8,
    gap: f64,
    viewport_span: f64,
    raw_index: i32,
    current_view_start: f64,
    center_mode: u32,
    always_center_single_column: bool,
    from_index: ?usize,
    scale: f64,
) f64 {
    if (spans.len == 0 or raw_index < 0) {
        return 0;
    }

    const index: usize = @intCast(raw_index);
    if (index >= spans.len) {
        return 0;
    }

    const effective_center_mode: u32 = if (spans.len == 1 and always_center_single_column)
        center_always
    else
        center_mode;

    const pixel_epsilon = 1.0 / max(scale, 1.0);
    const target_pos = containerPosition(spans, gap, index);
    const target_span = effectiveSpan(spans[index], modeAt(modes, index), viewport_span);

    return switch (effective_center_mode) {
        center_always => centeredOffset(spans, modes, gap, viewport_span, index),
        center_on_overflow => blk: {
            if (from_index) |prior_index| {
                if (onOverflowSourceIndex(index, prior_index, spans.len)) |source_index| {
                    if (pairSpan(spans, modes, gap, viewport_span, source_index, index) + gap * 2 <= viewport_span + pixel_epsilon) {
                        break :blk paddedFitOffset(
                            current_view_start,
                            viewport_span,
                            target_pos,
                            target_span,
                            gap,
                            scale,
                        );
                    }

                    break :blk centeredOffset(spans, modes, gap, viewport_span, index);
                }
            }

            break :blk paddedFitOffset(
                current_view_start,
                viewport_span,
                target_pos,
                target_span,
                gap,
                scale,
            );
        },
        else => exactFitOffset(
            current_view_start,
            viewport_span,
            target_pos,
            target_span,
            scale,
        ),
    };
}

fn centeredViewPos(column_x: f64, span: f64, mode: u8, viewport_span: f64) f64 {
    return column_x + centeredOffsetForColumn(span, mode, viewport_span);
}

fn visibilityBounds(column_x: f64, span: f64, mode: u8, gap: f64, viewport_span: f64) Edges {
    if (sanitizeSizingMode(mode) == sizing_mode_fullscreen) {
        const fullscreen_span = effectiveSpan(span, mode, viewport_span);
        return .{
            .left = column_x,
            .right = column_x + fullscreen_span,
        };
    }

    const padding = fitPadding(viewport_span, span, gap);
    return .{
        .left = column_x - padding,
        .right = column_x + span + padding,
    };
}

fn snapEdges(
    column_x: f64,
    span: f64,
    mode: u8,
    prev_span: ?f64,
    prev_mode: ?u8,
    next_span: ?f64,
    next_mode: ?u8,
    gap: f64,
    viewport_span: f64,
    use_center_on_overflow: bool,
) Edges {
    const resolved_mode = sanitizeSizingMode(mode);
    if (resolved_mode == sizing_mode_fullscreen) {
        return visibilityBounds(column_x, span, resolved_mode, gap, viewport_span);
    }

    if (!use_center_on_overflow) {
        return visibilityBounds(column_x, span, resolved_mode, gap, viewport_span);
    }

    const center = centeredViewPos(column_x, span, resolved_mode, viewport_span);
    const padding = fitPadding(viewport_span, span, gap);
    const target_span = effectiveSpan(span, resolved_mode, viewport_span);
    const overflowsWithNeighbor = struct {
        fn check(adj_span: ?f64, adj_mode: ?u8, target_span_inner: f64, gap_inner: f64, viewport_span_inner: f64) bool {
            const neighbor_span = adj_span orelse return false;
            const neighbor_mode = adj_mode orelse sizing_mode_normal;
            return effectiveSpan(neighbor_span, neighbor_mode, viewport_span_inner) + 3.0 * gap_inner + target_span_inner > viewport_span_inner;
        }
    }.check;

    return .{
        .left = if (overflowsWithNeighbor(next_span, next_mode, target_span, gap, viewport_span))
            center
        else
            column_x - padding,
        .right = if (overflowsWithNeighbor(prev_span, prev_mode, target_span, gap, viewport_span))
            center + viewport_span
        else
            column_x + span + padding,
    };
}

pub fn snapTarget(
    spans: []const f64,
    modes: []const u8,
    gap: f64,
    viewport_span: f64,
    projected_view_pos: f64,
    current_view_pos: f64,
    center_mode: u32,
    always_center_single_column: bool,
) SnapTarget {
    if (spans.len == 0) {
        return .{
            .view_pos = 0,
            .column_index = 0,
        };
    }

    const effective_center_mode: u32 = if (spans.len == 1 and always_center_single_column)
        center_always
    else
        center_mode;
    const use_center_on_overflow = effective_center_mode == center_on_overflow;

    var closest_view_pos: f64 = 0;
    var closest_column_index: usize = 0;
    var closest_distance = std.math.inf(f64);

    const consider = struct {
        fn apply(
            candidate_view_pos: f64,
            candidate_column_index: usize,
            projected_view_pos_inner: f64,
            closest_view_pos_inner: *f64,
            closest_column_index_inner: *usize,
            closest_distance_inner: *f64,
        ) void {
            const distance = @abs(candidate_view_pos - projected_view_pos_inner);
            if (distance < closest_distance_inner.*) {
                closest_distance_inner.* = distance;
                closest_view_pos_inner.* = candidate_view_pos;
                closest_column_index_inner.* = candidate_column_index;
            }
        }
    }.apply;

    if (effective_center_mode == center_always) {
        for (spans, 0..) |span, index| {
            const column_x = containerPosition(spans, gap, index);
            consider(
                centeredViewPos(column_x, span, modeAt(modes, index), viewport_span),
                index,
                projected_view_pos,
                &closest_view_pos,
                &closest_column_index,
                &closest_distance,
            );
        }
    } else {
        const first_edges = snapEdges(
            0,
            spans[0],
            modeAt(modes, 0),
            null,
            null,
            if (spans.len > 1) spans[1] else null,
            if (spans.len > 1) modeAt(modes, 1) else null,
            gap,
            viewport_span,
            use_center_on_overflow,
        );
        const leftmost_snap = first_edges.left;

        const last_index = spans.len - 1;
        const last_column_x = containerPosition(spans, gap, last_index);
        const last_edges = snapEdges(
            last_column_x,
            spans[last_index],
            modeAt(modes, last_index),
            if (last_index > 0) spans[last_index - 1] else null,
            if (last_index > 0) modeAt(modes, last_index - 1) else null,
            null,
            null,
            gap,
            viewport_span,
            use_center_on_overflow,
        );
        const rightmost_snap = last_edges.right - viewport_span;

        consider(leftmost_snap, 0, projected_view_pos, &closest_view_pos, &closest_column_index, &closest_distance);
        consider(rightmost_snap, last_index, projected_view_pos, &closest_view_pos, &closest_column_index, &closest_distance);

        for (spans, 0..) |span, index| {
            const column_x = containerPosition(spans, gap, index);
            const edges = snapEdges(
                column_x,
                span,
                modeAt(modes, index),
                if (index > 0) spans[index - 1] else null,
                if (index > 0) modeAt(modes, index - 1) else null,
                if (index + 1 < spans.len) spans[index + 1] else null,
                if (index + 1 < spans.len) modeAt(modes, index + 1) else null,
                gap,
                viewport_span,
                use_center_on_overflow,
            );

            if (leftmost_snap < edges.left and edges.left < rightmost_snap) {
                consider(edges.left, index, projected_view_pos, &closest_view_pos, &closest_column_index, &closest_distance);
            }

            const right_snap = edges.right - viewport_span;
            if (leftmost_snap < right_snap and right_snap < rightmost_snap) {
                consider(right_snap, index, projected_view_pos, &closest_view_pos, &closest_column_index, &closest_distance);
            }
        }
    }

    var new_column_index = closest_column_index;
    if (effective_center_mode != center_always) {
        const scrolling_right = projected_view_pos >= current_view_pos;
        if (scrolling_right) {
            var index = new_column_index + 1;
            while (index < spans.len) : (index += 1) {
                const column_x = containerPosition(spans, gap, index);
                const bounds = visibilityBounds(
                    column_x,
                    spans[index],
                    modeAt(modes, index),
                    gap,
                    viewport_span,
                );

                if (closest_view_pos + viewport_span >= bounds.right) {
                    new_column_index = index;
                } else {
                    break;
                }
            }
        } else {
            var index = new_column_index;
            while (index > 0) {
                index -= 1;
                const column_x = containerPosition(spans, gap, index);
                const bounds = visibilityBounds(
                    column_x,
                    spans[index],
                    modeAt(modes, index),
                    gap,
                    viewport_span,
                );

                if (bounds.left >= closest_view_pos) {
                    new_column_index = index;
                } else {
                    break;
                }
            }
        }
    }

    return .{
        .view_pos = closest_view_pos,
        .column_index = @intCast(new_column_index),
    };
}
