// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;
const kernel_allocation_failed: i32 = 2;
const orientation_horizontal: u32 = 0;
const orientation_vertical: u32 = 1;
const window_sizing_normal: u8 = 0;
const window_sizing_fullscreen: u8 = 1;
const hidden_edge_none: u8 = 0;
const hidden_edge_minimum: u8 = 1;
const hidden_edge_maximum: u8 = 2;
const stack_window_capacity = 256;

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

extern fn omniwm_axis_solve(
    inputs_ptr: [*c]const AxisInput,
    count: usize,
    available_space: f64,
    gap_size: f64,
    is_tabbed: u8,
    outputs_ptr: [*c]AxisOutput,
) i32;

const NiriLayoutInput = extern struct {
    working_x: f64,
    working_y: f64,
    working_width: f64,
    working_height: f64,
    view_x: f64,
    view_y: f64,
    view_width: f64,
    view_height: f64,
    scale: f64,
    primary_gap: f64,
    secondary_gap: f64,
    tab_indicator_width: f64,
    view_offset: f64,
    workspace_offset: f64,
    single_window_aspect_ratio: f64,
    single_window_aspect_tolerance: f64,
    active_container_index: i32,
    hidden_placement_monitor_index: i32,
    orientation: u32,
    single_window_mode: u8,
};

const NiriContainerInput = extern struct {
    span: f64,
    render_offset_x: f64,
    render_offset_y: f64,
    window_start_index: u32,
    window_count: u32,
    is_tabbed: u8,
    has_manual_single_window_width_override: u8,
};

const NiriWindowInput = extern struct {
    weight: f64,
    min_constraint: f64,
    max_constraint: f64,
    fixed_value: f64,
    render_offset_x: f64,
    render_offset_y: f64,
    has_max_constraint: u8,
    is_constraint_fixed: u8,
    has_fixed_value: u8,
    sizing_mode: u8,
};

const HiddenPlacementMonitor = extern struct {
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
    visible_x: f64,
    visible_y: f64,
    visible_width: f64,
    visible_height: f64,
};

const NiriContainerOutput = extern struct {
    canonical_x: f64,
    canonical_y: f64,
    canonical_width: f64,
    canonical_height: f64,
    rendered_x: f64,
    rendered_y: f64,
    rendered_width: f64,
    rendered_height: f64,
};

const NiriWindowOutput = extern struct {
    canonical_x: f64,
    canonical_y: f64,
    canonical_width: f64,
    canonical_height: f64,
    rendered_x: f64,
    rendered_y: f64,
    rendered_width: f64,
    rendered_height: f64,
    resolved_span: f64,
    hidden_edge: u8,
    physical_hidden_edge: u8,
};

const Point = struct {
    x: f64,
    y: f64,
};

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const OverflowRegion = struct {
    edge: u8,
    rect: Rect,
};

const OverflowRegions = struct {
    items: [2]OverflowRegion = undefined,
    len: usize = 0,

    fn append(self: *OverflowRegions, item: OverflowRegion) void {
        if (self.len >= self.items.len) {
            return;
        }
        self.items[self.len] = item;
        self.len += 1;
    }
};

const HiddenPlacementOrigin = struct {
    origin: Point,
    edge: u8,
};

const HiddenRenderedContainer = struct {
    rect: Rect,
    physical_edge: u8,
};

fn swiftMax(lhs: f64, rhs: f64) f64 {
    return if (rhs > lhs) rhs else lhs;
}

fn swiftMin(lhs: f64, rhs: f64) f64 {
    return if (rhs < lhs) rhs else lhs;
}

fn sanitizeScale(scale: f64) f64 {
    if (!std.math.isFinite(scale) or scale <= 0) {
        return 1;
    }
    return scale;
}

fn roundToPhysicalPixel(value: f64, scale: f64) f64 {
    const safe_scale = sanitizeScale(scale);
    return @round(value * safe_scale) / safe_scale;
}

fn roundRect(rect: Rect, scale: f64) Rect {
    return .{
        .x = roundToPhysicalPixel(rect.x, scale),
        .y = roundToPhysicalPixel(rect.y, scale),
        .width = roundToPhysicalPixel(rect.width, scale),
        .height = roundToPhysicalPixel(rect.height, scale),
    };
}

fn offsetRect(rect: Rect, dx: f64, dy: f64) Rect {
    return .{
        .x = rect.x + dx,
        .y = rect.y + dy,
        .width = rect.width,
        .height = rect.height,
    };
}

fn rectMaxX(rect: Rect) f64 {
    return rect.x + rect.width;
}

fn rectMaxY(rect: Rect) f64 {
    return rect.y + rect.height;
}

fn rectIntersects(lhs: Rect, rhs: Rect) bool {
    return rectMaxX(lhs) > rhs.x and lhs.x < rectMaxX(rhs) and rectMaxY(lhs) > rhs.y and lhs.y < rectMaxY(rhs);
}

fn intersectionArea(lhs: Rect, rhs: Rect) f64 {
    const min_x = swiftMax(lhs.x, rhs.x);
    const max_x = swiftMin(rectMaxX(lhs), rectMaxX(rhs));
    if (max_x <= min_x) {
        return 0;
    }

    const min_y = swiftMax(lhs.y, rhs.y);
    const max_y = swiftMin(rectMaxY(lhs), rectMaxY(rhs));
    if (max_y <= min_y) {
        return 0;
    }

    return (max_x - min_x) * (max_y - min_y);
}

fn workingRect(input: NiriLayoutInput) Rect {
    return .{
        .x = input.working_x,
        .y = input.working_y,
        .width = input.working_width,
        .height = input.working_height,
    };
}

fn viewRect(input: NiriLayoutInput) Rect {
    return .{
        .x = input.view_x,
        .y = input.view_y,
        .width = input.view_width,
        .height = input.view_height,
    };
}

fn monitorFrame(monitor: HiddenPlacementMonitor) Rect {
    return .{
        .x = monitor.frame_x,
        .y = monitor.frame_y,
        .width = monitor.frame_width,
        .height = monitor.frame_height,
    };
}

fn monitorVisibleFrame(monitor: HiddenPlacementMonitor) Rect {
    return .{
        .x = monitor.visible_x,
        .y = monitor.visible_y,
        .width = monitor.visible_width,
        .height = monitor.visible_height,
    };
}

fn canonicalFullscreenRect(input: NiriLayoutInput) Rect {
    return roundRect(workingRect(input), input.scale);
}

fn renderedFullscreenRect(input: NiriLayoutInput) Rect {
    return roundRect(
        offsetRect(canonicalFullscreenRect(input), input.workspace_offset, 0),
        input.scale,
    );
}

fn canonicalContainerRect(
    position: f64,
    span: f64,
    input: NiriLayoutInput,
) Rect {
    return switch (input.orientation) {
        orientation_horizontal => roundRect(.{
            .x = input.working_x + position,
            .y = input.working_y,
            .width = roundToPhysicalPixel(span, input.scale),
            .height = input.working_height,
        }, input.scale),
        orientation_vertical => roundRect(.{
            .x = input.working_x,
            .y = input.working_y + position,
            .width = input.working_width,
            .height = roundToPhysicalPixel(span, input.scale),
        }, input.scale),
        else => .{
            .x = input.working_x,
            .y = input.working_y,
            .width = 0,
            .height = 0,
        },
    };
}

fn visibleRenderedContainerRect(
    canonical_rect: Rect,
    view_position: f64,
    container: NiriContainerInput,
    input: NiriLayoutInput,
) Rect {
    const translation = switch (input.orientation) {
        orientation_horizontal => Point{
            .x = -view_position + input.workspace_offset + container.render_offset_x,
            .y = container.render_offset_y,
        },
        orientation_vertical => Point{
            .x = input.workspace_offset + container.render_offset_x,
            .y = -view_position + container.render_offset_y,
        },
        else => Point{ .x = 0, .y = 0 },
    };

    return roundRect(offsetRect(canonical_rect, translation.x, translation.y), input.scale);
}

fn containerIntersectsViewport(
    container_rect: Rect,
    viewport_frame: Rect,
    orientation: u32,
) bool {
    return switch (orientation) {
        orientation_horizontal => rectMaxX(container_rect) > viewport_frame.x and container_rect.x < rectMaxX(viewport_frame),
        orientation_vertical => rectMaxY(container_rect) > viewport_frame.y and container_rect.y < rectMaxY(viewport_frame),
        else => false,
    };
}

fn hiddenEdge(
    rendered_rect: Rect,
    viewport_frame: Rect,
    fallback: u8,
    orientation: u32,
) u8 {
    switch (orientation) {
        orientation_horizontal => {
            const left_overflow = viewport_frame.x - rendered_rect.x;
            const right_overflow = rectMaxX(rendered_rect) - rectMaxX(viewport_frame);
            if (left_overflow > right_overflow and left_overflow > 0) {
                return hidden_edge_minimum;
            }
            if (right_overflow > left_overflow and right_overflow > 0) {
                return hidden_edge_maximum;
            }
        },
        orientation_vertical => {
            const top_overflow = viewport_frame.y - rendered_rect.y;
            const bottom_overflow = rectMaxY(rendered_rect) - rectMaxY(viewport_frame);
            if (top_overflow > bottom_overflow and top_overflow > 0) {
                return hidden_edge_minimum;
            }
            if (bottom_overflow > top_overflow and bottom_overflow > 0) {
                return hidden_edge_maximum;
            }
        },
        else => {},
    }

    return fallback;
}

fn containerOverflowRegions(
    rendered_rect: Rect,
    viewport_frame: Rect,
    orientation: u32,
) OverflowRegions {
    var regions = OverflowRegions{};

    switch (orientation) {
        orientation_horizontal => {
            if (rendered_rect.x < viewport_frame.x) {
                const overflow_max_x = swiftMin(rectMaxX(rendered_rect), viewport_frame.x);
                if (overflow_max_x > rendered_rect.x) {
                    regions.append(.{
                        .edge = hidden_edge_minimum,
                        .rect = .{
                            .x = rendered_rect.x,
                            .y = rendered_rect.y,
                            .width = overflow_max_x - rendered_rect.x,
                            .height = rendered_rect.height,
                        },
                    });
                }
            }
            if (rectMaxX(rendered_rect) > rectMaxX(viewport_frame)) {
                const overflow_min_x = swiftMax(rendered_rect.x, rectMaxX(viewport_frame));
                if (rectMaxX(rendered_rect) > overflow_min_x) {
                    regions.append(.{
                        .edge = hidden_edge_maximum,
                        .rect = .{
                            .x = overflow_min_x,
                            .y = rendered_rect.y,
                            .width = rectMaxX(rendered_rect) - overflow_min_x,
                            .height = rendered_rect.height,
                        },
                    });
                }
            }
        },
        orientation_vertical => {
            if (rendered_rect.y < viewport_frame.y) {
                const overflow_max_y = swiftMin(rectMaxY(rendered_rect), viewport_frame.y);
                if (overflow_max_y > rendered_rect.y) {
                    regions.append(.{
                        .edge = hidden_edge_minimum,
                        .rect = .{
                            .x = rendered_rect.x,
                            .y = rendered_rect.y,
                            .width = rendered_rect.width,
                            .height = overflow_max_y - rendered_rect.y,
                        },
                    });
                }
            }
            if (rectMaxY(rendered_rect) > rectMaxY(viewport_frame)) {
                const overflow_min_y = swiftMax(rendered_rect.y, rectMaxY(viewport_frame));
                if (rectMaxY(rendered_rect) > overflow_min_y) {
                    regions.append(.{
                        .edge = hidden_edge_maximum,
                        .rect = .{
                            .x = rendered_rect.x,
                            .y = overflow_min_y,
                            .width = rendered_rect.width,
                            .height = rectMaxY(rendered_rect) - overflow_min_y,
                        },
                    });
                }
            }
        },
        else => {},
    }

    return regions;
}

fn ownsViewport(
    candidate_index: usize,
    input: NiriLayoutInput,
    monitors: []const HiddenPlacementMonitor,
    viewport_frame: Rect,
) bool {
    if (input.hidden_placement_monitor_index >= 0) {
        return candidate_index == @as(usize, @intCast(input.hidden_placement_monitor_index));
    }

    const monitor = monitors[candidate_index];
    return rectIntersects(monitorFrame(monitor), viewport_frame) or rectIntersects(monitorVisibleFrame(monitor), viewport_frame);
}

fn overflowEdgeIntersectingNeighboringMonitor(
    rendered_rect: Rect,
    input: NiriLayoutInput,
    monitors: []const HiddenPlacementMonitor,
    viewport_frame: Rect,
) u8 {
    const overflow_regions = containerOverflowRegions(rendered_rect, viewport_frame, input.orientation);
    if (overflow_regions.len == 0) {
        return hidden_edge_none;
    }

    for (overflow_regions.items[0..overflow_regions.len]) |overflow_region| {
        for (monitors, 0..) |monitor, index| {
            if (ownsViewport(index, input, monitors, viewport_frame)) {
                continue;
            }
            if (rectIntersects(overflow_region.rect, monitorFrame(monitor))) {
                return overflow_region.edge;
            }
        }
    }

    return hidden_edge_none;
}

fn overlapArea(
    rect: Rect,
    own_monitor_index: usize,
    monitors: []const HiddenPlacementMonitor,
) f64 {
    var area: f64 = 0;
    for (monitors, 0..) |monitor, index| {
        if (index == own_monitor_index) {
            continue;
        }
        area += intersectionArea(rect, monitorFrame(monitor));
    }
    return area;
}

fn oppositeHiddenEdge(edge: u8) u8 {
    return switch (edge) {
        hidden_edge_minimum => hidden_edge_maximum,
        hidden_edge_maximum => hidden_edge_minimum,
        else => hidden_edge_none,
    };
}

fn hiddenPlacementOrigin(
    width: f64,
    height: f64,
    requested_edge: u8,
    orthogonal_origin: f64,
    input: NiriLayoutInput,
    own_monitor_index: usize,
    monitors: []const HiddenPlacementMonitor,
) HiddenPlacementOrigin {
    const reveal = 1.0 / swiftMax(1.0, sanitizeScale(input.scale));
    const monitor = monitors[own_monitor_index];
    const visible_frame = monitorVisibleFrame(monitor);

    const originFor = struct {
        fn call(
            edge: u8,
            orientation: u32,
            visible_frame_inner: Rect,
            orthogonal_origin_inner: f64,
            reveal_inner: f64,
            width_inner: f64,
            height_inner: f64,
        ) Point {
            return switch (orientation) {
                orientation_horizontal => switch (edge) {
                    hidden_edge_minimum => .{
                        .x = visible_frame_inner.x - width_inner + reveal_inner,
                        .y = orthogonal_origin_inner,
                    },
                    hidden_edge_maximum => .{
                        .x = rectMaxX(visible_frame_inner) - reveal_inner,
                        .y = orthogonal_origin_inner,
                    },
                    else => .{
                        .x = visible_frame_inner.x,
                        .y = orthogonal_origin_inner,
                    },
                },
                orientation_vertical => switch (edge) {
                    hidden_edge_minimum => .{
                        .x = orthogonal_origin_inner,
                        .y = visible_frame_inner.y - height_inner + reveal_inner,
                    },
                    hidden_edge_maximum => .{
                        .x = orthogonal_origin_inner,
                        .y = rectMaxY(visible_frame_inner) - reveal_inner,
                    },
                    else => .{
                        .x = orthogonal_origin_inner,
                        .y = visible_frame_inner.y,
                    },
                },
                else => .{
                    .x = visible_frame_inner.x,
                    .y = visible_frame_inner.y,
                },
            };
        }
    }.call;

    const primary_origin = originFor(
        requested_edge,
        input.orientation,
        visible_frame,
        orthogonal_origin,
        reveal,
        width,
        height,
    );
    const primary_overlap = overlapArea(
        Rect{ .x = primary_origin.x, .y = primary_origin.y, .width = width, .height = height },
        own_monitor_index,
        monitors,
    );
    if (primary_overlap == 0) {
        return .{ .origin = primary_origin, .edge = requested_edge };
    }

    const alternate_edge = oppositeHiddenEdge(requested_edge);
    const alternate_origin = originFor(
        alternate_edge,
        input.orientation,
        visible_frame,
        orthogonal_origin,
        reveal,
        width,
        height,
    );
    const alternate_overlap = overlapArea(
        Rect{ .x = alternate_origin.x, .y = alternate_origin.y, .width = width, .height = height },
        own_monitor_index,
        monitors,
    );

    if (alternate_overlap < primary_overlap) {
        return .{ .origin = alternate_origin, .edge = alternate_edge };
    }
    return .{ .origin = primary_origin, .edge = requested_edge };
}

fn hiddenColumnRect(
    edge: u8,
    canonical_rect: Rect,
    view_frame: Rect,
    scale: f64,
) Rect {
    const reveal = 1.0 / swiftMax(1.0, sanitizeScale(scale));
    const x = switch (edge) {
        hidden_edge_minimum => view_frame.x - canonical_rect.width + reveal,
        hidden_edge_maximum => rectMaxX(view_frame) - reveal,
        else => canonical_rect.x,
    };
    return .{
        .x = x,
        .y = canonical_rect.y,
        .width = canonical_rect.width,
        .height = canonical_rect.height,
    };
}

fn hiddenRowRect(
    edge: u8,
    canonical_rect: Rect,
    view_frame: Rect,
    scale: f64,
) Rect {
    const reveal = 1.0 / swiftMax(1.0, sanitizeScale(scale));
    const y = switch (edge) {
        hidden_edge_minimum => view_frame.y - canonical_rect.height + reveal,
        hidden_edge_maximum => rectMaxY(view_frame) - reveal,
        else => canonical_rect.y,
    };
    return .{
        .x = canonical_rect.x,
        .y = y,
        .width = canonical_rect.width,
        .height = canonical_rect.height,
    };
}

fn hiddenRenderedContainerRect(
    canonical_rect: Rect,
    edge: u8,
    input: NiriLayoutInput,
    monitors: []const HiddenPlacementMonitor,
) HiddenRenderedContainer {
    if (input.hidden_placement_monitor_index >= 0 and @as(usize, @intCast(input.hidden_placement_monitor_index)) < monitors.len) {
        const own_monitor_index: usize = @intCast(input.hidden_placement_monitor_index);
        const orthogonal_origin = switch (input.orientation) {
            orientation_horizontal => canonical_rect.y,
            orientation_vertical => canonical_rect.x,
            else => canonical_rect.y,
        };
        const placement = hiddenPlacementOrigin(
            canonical_rect.width,
            canonical_rect.height,
            edge,
            orthogonal_origin,
            input,
            own_monitor_index,
            monitors,
        );
        return .{
            .rect = roundRect(
                Rect{
                    .x = placement.origin.x,
                    .y = placement.origin.y,
                    .width = canonical_rect.width,
                    .height = canonical_rect.height,
                },
                input.scale,
            ),
            .physical_edge = placement.edge,
        };
    }

    return switch (input.orientation) {
        orientation_horizontal => .{
            .rect = roundRect(hiddenColumnRect(edge, canonical_rect, viewRect(input), input.scale), input.scale),
            .physical_edge = edge,
        },
        orientation_vertical => .{
            .rect = roundRect(hiddenRowRect(edge, canonical_rect, viewRect(input), input.scale), input.scale),
            .physical_edge = edge,
        },
        else => .{
            .rect = canonical_rect,
            .physical_edge = edge,
        },
    };
}

fn aspectFittedSingleWindowRect(
    input: NiriLayoutInput,
) Rect {
    const working = workingRect(input);
    if (input.single_window_aspect_ratio <= 0 or working.width <= 0 or working.height <= 0) {
        return roundRect(working, input.scale);
    }

    const current_ratio = working.width / working.height;
    if (@abs(current_ratio - input.single_window_aspect_ratio) < input.single_window_aspect_tolerance) {
        return roundRect(working, input.scale);
    }

    var width = working.width;
    var height = working.height;
    if (current_ratio > input.single_window_aspect_ratio) {
        width = height * input.single_window_aspect_ratio;
    } else {
        height = width / input.single_window_aspect_ratio;
    }

    return roundRect(.{
        .x = working.x + (working.width - width) / 2.0,
        .y = working.y + (working.height - height) / 2.0,
        .width = width,
        .height = height,
    }, input.scale);
}

fn centeredSingleWindowRect(
    input: NiriLayoutInput,
    width: f64,
) Rect {
    const working = workingRect(input);
    return roundRect(.{
        .x = working.x + (working.width - width) / 2.0,
        .y = working.y,
        .width = width,
        .height = working.height,
    }, input.scale);
}

fn resolvedSingleWindowRect(
    container: NiriContainerInput,
    input: NiriLayoutInput,
) Rect {
    if (container.has_manual_single_window_width_override == 0) {
        return aspectFittedSingleWindowRect(input);
    }

    const working = workingRect(input);
    const resolved_width = swiftMin(working.width, swiftMax(0, container.span));
    if (resolved_width <= 0) {
        return roundRect(working, input.scale);
    }

    return centeredSingleWindowRect(input, resolved_width);
}

fn writeContainerOutput(
    output: *NiriContainerOutput,
    canonical_rect: Rect,
    rendered_rect: Rect,
) void {
    output.* = .{
        .canonical_x = canonical_rect.x,
        .canonical_y = canonical_rect.y,
        .canonical_width = canonical_rect.width,
        .canonical_height = canonical_rect.height,
        .rendered_x = rendered_rect.x,
        .rendered_y = rendered_rect.y,
        .rendered_width = rendered_rect.width,
        .rendered_height = rendered_rect.height,
    };
}

fn writeWindowOutput(
    output: *NiriWindowOutput,
    canonical_rect: Rect,
    rendered_rect: Rect,
    resolved_span: f64,
    hidden_edge: u8,
    physical_hidden_edge: u8,
) void {
    output.* = .{
        .canonical_x = canonical_rect.x,
        .canonical_y = canonical_rect.y,
        .canonical_width = canonical_rect.width,
        .canonical_height = canonical_rect.height,
        .rendered_x = rendered_rect.x,
        .rendered_y = rendered_rect.y,
        .rendered_width = rendered_rect.width,
        .rendered_height = rendered_rect.height,
        .resolved_span = resolved_span,
        .hidden_edge = hidden_edge,
        .physical_hidden_edge = physical_hidden_edge,
    };
}

fn layoutWindowsForContainer(
    input: NiriLayoutInput,
    container: NiriContainerInput,
    canonical_container_rect: Rect,
    rendered_container_rect: Rect,
    hidden_edge: u8,
    physical_hidden_edge: u8,
    windows: []const NiriWindowInput,
    axis_inputs: []AxisInput,
    axis_outputs: []AxisOutput,
    outputs: []NiriWindowOutput,
) i32 {
    if (windows.len == 0) {
        return kernel_ok;
    }

    const tab_offset = if (container.is_tabbed != 0) input.tab_indicator_width else 0;
    const content_rect = Rect{
        .x = canonical_container_rect.x + tab_offset,
        .y = canonical_container_rect.y,
        .width = swiftMax(0, canonical_container_rect.width - tab_offset),
        .height = canonical_container_rect.height,
    };

    const available_space = switch (input.orientation) {
        orientation_horizontal => content_rect.height,
        orientation_vertical => content_rect.width,
        else => return kernel_invalid_argument,
    };

    for (windows, 0..) |window, index| {
        axis_inputs[index] = .{
            .weight = window.weight,
            .min_constraint = window.min_constraint,
            .max_constraint = window.max_constraint,
            .fixed_value = window.fixed_value,
            .has_max_constraint = window.has_max_constraint,
            .is_constraint_fixed = window.is_constraint_fixed,
            .has_fixed_value = window.has_fixed_value,
        };
    }

    const axis_status = omniwm_axis_solve(
        axis_inputs.ptr,
        windows.len,
        available_space,
        input.secondary_gap,
        if (container.is_tabbed != 0) 1 else 0,
        axis_outputs.ptr,
    );
    if (axis_status != kernel_ok) {
        return axis_status;
    }

    const fullscreen_canonical_rect = canonicalFullscreenRect(input);
    const fullscreen_rendered_rect = renderedFullscreenRect(input);

    var position = switch (input.orientation) {
        orientation_horizontal => content_rect.y,
        orientation_vertical => content_rect.x,
        else => return kernel_invalid_argument,
    };

    for (windows, 0..) |window, index| {
        const span = axis_outputs[index].value;
        const canonical_rect: Rect = switch (window.sizing_mode) {
            window_sizing_fullscreen => fullscreen_canonical_rect,
            window_sizing_normal => switch (input.orientation) {
                orientation_horizontal => roundRect(.{
                    .x = content_rect.x,
                    .y = if (container.is_tabbed != 0) content_rect.y else position,
                    .width = content_rect.width,
                    .height = span,
                }, input.scale),
                orientation_vertical => roundRect(.{
                    .x = if (container.is_tabbed != 0) content_rect.x else position,
                    .y = content_rect.y,
                    .width = span,
                    .height = content_rect.height,
                }, input.scale),
                else => return kernel_invalid_argument,
            },
            else => return kernel_invalid_argument,
        };

        const rendered_base_rect = switch (window.sizing_mode) {
            window_sizing_fullscreen => roundRect(fullscreen_rendered_rect, input.scale),
            window_sizing_normal => roundRect(
                offsetRect(
                    canonical_rect,
                    rendered_container_rect.x - canonical_container_rect.x,
                    rendered_container_rect.y - canonical_container_rect.y,
                ),
                input.scale,
            ),
            else => return kernel_invalid_argument,
        };

        const rendered_rect = switch (window.sizing_mode) {
            window_sizing_fullscreen => roundRect(rendered_base_rect, input.scale),
            window_sizing_normal => roundRect(
                offsetRect(rendered_base_rect, window.render_offset_x, window.render_offset_y),
                input.scale,
            ),
            else => return kernel_invalid_argument,
        };

        const resolved_span = switch (window.sizing_mode) {
            window_sizing_fullscreen => switch (input.orientation) {
                orientation_horizontal => fullscreen_canonical_rect.height,
                orientation_vertical => fullscreen_canonical_rect.width,
                else => return kernel_invalid_argument,
            },
            window_sizing_normal => span,
            else => return kernel_invalid_argument,
        };

        writeWindowOutput(
            &outputs[index],
            canonical_rect,
            rendered_rect,
            resolved_span,
            if (window.sizing_mode == window_sizing_fullscreen) hidden_edge_none else hidden_edge,
            if (window.sizing_mode == window_sizing_fullscreen) hidden_edge_none else physical_hidden_edge,
        );

        if (container.is_tabbed == 0) {
            position += span;
            if (index + 1 < windows.len) {
                position += input.secondary_gap;
            }
        }
    }

    return kernel_ok;
}

fn solveWithScratch(
    input: NiriLayoutInput,
    containers: []const NiriContainerInput,
    windows: []const NiriWindowInput,
    monitors: []const HiddenPlacementMonitor,
    container_outputs: []NiriContainerOutput,
    window_outputs: []NiriWindowOutput,
    axis_inputs: []AxisInput,
    axis_outputs: []AxisOutput,
) i32 {
    for (container_outputs) |*output| {
        output.* = std.mem.zeroes(NiriContainerOutput);
    }
    for (window_outputs) |*output| {
        output.* = std.mem.zeroes(NiriWindowOutput);
    }

    for (containers) |container| {
        const window_start = container.window_start_index;
        const window_count = container.window_count;
        if (@as(usize, window_start) > windows.len) {
            return kernel_invalid_argument;
        }
        if (@as(usize, window_start) + @as(usize, window_count) > windows.len) {
            return kernel_invalid_argument;
        }
    }

    if (input.single_window_mode != 0) {
        if (containers.len != 1) {
            return kernel_invalid_argument;
        }
        const container = containers[0];
        const window_start: usize = @intCast(container.window_start_index);
        const window_count: usize = @intCast(container.window_count);
        const canonical_rect = resolvedSingleWindowRect(container, input);
        const rendered_rect = roundRect(
            offsetRect(
                canonical_rect,
                input.workspace_offset + container.render_offset_x,
                container.render_offset_y,
            ),
            input.scale,
        );
        writeContainerOutput(&container_outputs[0], canonical_rect, rendered_rect);
        return layoutWindowsForContainer(
            input,
            container,
            canonical_rect,
            rendered_rect,
            hidden_edge_none,
            hidden_edge_none,
            windows[window_start .. window_start + window_count],
            axis_inputs[window_start .. window_start + window_count],
            axis_outputs[window_start .. window_start + window_count],
            window_outputs[window_start .. window_start + window_count],
        );
    }

    if (input.orientation != orientation_horizontal and input.orientation != orientation_vertical) {
        return kernel_invalid_argument;
    }

    if (input.hidden_placement_monitor_index >= 0 and @as(usize, @intCast(input.hidden_placement_monitor_index)) >= monitors.len) {
        return kernel_invalid_argument;
    }

    var active_index: usize = 0;
    if (containers.len > 1 and input.active_container_index > 0) {
        active_index = @min(@as(usize, @intCast(input.active_container_index)), containers.len - 1);
    }

    var active_position: f64 = 0;
    var running_position: f64 = 0;
    for (containers, 0..) |container, index| {
        if (index == active_index) {
            active_position = running_position;
            break;
        }
        running_position += container.span + input.primary_gap;
    }

    const view_position = active_position + input.view_offset;
    const viewport_frame = workingRect(input);

    running_position = 0;
    for (containers, 0..) |container, index| {
        const fallback_edge = if (index == 0) hidden_edge_minimum else hidden_edge_maximum;
        const canonical_rect = canonicalContainerRect(running_position, container.span, input);
        const visibility_rect = visibleRenderedContainerRect(canonical_rect, view_position, container, input);

        var resolved_hidden_edge: u8 = hidden_edge_none;
        var physical_hidden_edge: u8 = hidden_edge_none;
        var rendered_rect = visibility_rect;
        if (!containerIntersectsViewport(visibility_rect, viewport_frame, input.orientation)) {
            resolved_hidden_edge = hiddenEdge(visibility_rect, viewport_frame, fallback_edge, input.orientation);
            const hidden_container = hiddenRenderedContainerRect(canonical_rect, resolved_hidden_edge, input, monitors);
            rendered_rect = hidden_container.rect;
            physical_hidden_edge = hidden_container.physical_edge;
        } else {
            const neighboring_edge = overflowEdgeIntersectingNeighboringMonitor(
                visibility_rect,
                input,
                monitors,
                viewport_frame,
            );
            if (neighboring_edge != hidden_edge_none) {
                resolved_hidden_edge = neighboring_edge;
                const hidden_container = hiddenRenderedContainerRect(canonical_rect, resolved_hidden_edge, input, monitors);
                rendered_rect = hidden_container.rect;
                physical_hidden_edge = hidden_container.physical_edge;
            }
        }

        writeContainerOutput(&container_outputs[index], canonical_rect, rendered_rect);

        const window_start: usize = @intCast(container.window_start_index);
        const window_count: usize = @intCast(container.window_count);
        const status = layoutWindowsForContainer(
            input,
            container,
            canonical_rect,
            rendered_rect,
            resolved_hidden_edge,
            physical_hidden_edge,
            windows[window_start .. window_start + window_count],
            axis_inputs[window_start .. window_start + window_count],
            axis_outputs[window_start .. window_start + window_count],
            window_outputs[window_start .. window_start + window_count],
        );
        if (status != kernel_ok) {
            return status;
        }

        running_position += container.span + input.primary_gap;
    }

    return kernel_ok;
}

pub export fn omniwm_niri_layout_solve(
    input_ptr: [*c]const NiriLayoutInput,
    containers_ptr: [*c]const NiriContainerInput,
    container_count: usize,
    windows_ptr: [*c]const NiriWindowInput,
    window_count: usize,
    monitors_ptr: [*c]const HiddenPlacementMonitor,
    monitor_count: usize,
    container_outputs_ptr: [*c]NiriContainerOutput,
    container_output_count: usize,
    window_outputs_ptr: [*c]NiriWindowOutput,
    window_output_count: usize,
) i32 {
    if (container_count == 0) {
        return kernel_ok;
    }
    if (input_ptr == null or containers_ptr == null or container_outputs_ptr == null) {
        return kernel_invalid_argument;
    }
    if (container_output_count < container_count or window_output_count < window_count) {
        return kernel_invalid_argument;
    }
    if (window_count > 0 and (windows_ptr == null or window_outputs_ptr == null)) {
        return kernel_invalid_argument;
    }
    if (monitor_count > 0 and monitors_ptr == null) {
        return kernel_invalid_argument;
    }

    const input = input_ptr[0];
    var empty_windows: [0]NiriWindowInput = .{};
    var empty_window_outputs: [0]NiriWindowOutput = .{};
    var empty_monitors: [0]HiddenPlacementMonitor = .{};
    const containers = @as([*]const NiriContainerInput, @ptrCast(containers_ptr))[0..container_count];
    const windows = if (window_count == 0)
        empty_windows[0..]
    else
        @as([*]const NiriWindowInput, @ptrCast(windows_ptr))[0..window_count];
    const monitors = if (monitor_count == 0)
        empty_monitors[0..]
    else
        @as([*]const HiddenPlacementMonitor, @ptrCast(monitors_ptr))[0..monitor_count];
    const container_outputs = @as([*]NiriContainerOutput, @ptrCast(container_outputs_ptr))[0..container_count];
    const window_outputs = if (window_count == 0)
        empty_window_outputs[0..]
    else
        @as([*]NiriWindowOutput, @ptrCast(window_outputs_ptr))[0..window_count];

    if (window_count <= stack_window_capacity) {
        var stack_axis_inputs: [stack_window_capacity]AxisInput = undefined;
        var stack_axis_outputs: [stack_window_capacity]AxisOutput = undefined;
        return solveWithScratch(
            input,
            containers,
            windows,
            monitors,
            container_outputs,
            window_outputs,
            stack_axis_inputs[0..window_count],
            stack_axis_outputs[0..window_count],
        );
    }

    const allocator = std.heap.page_allocator;
    const heap_axis_inputs = allocator.alloc(AxisInput, window_count) catch return kernel_allocation_failed;
    defer allocator.free(heap_axis_inputs);
    const heap_axis_outputs = allocator.alloc(AxisOutput, window_count) catch return kernel_allocation_failed;
    defer allocator.free(heap_axis_outputs);

    return solveWithScratch(
        input,
        containers,
        windows,
        monitors,
        container_outputs,
        window_outputs,
        heap_axis_inputs,
        heap_axis_outputs,
    );
}

fn testInput() NiriLayoutInput {
    return .{
        .working_x = 0,
        .working_y = 0,
        .working_width = 1600,
        .working_height = 900,
        .view_x = 0,
        .view_y = 0,
        .view_width = 1600,
        .view_height = 900,
        .scale = 2.0,
        .primary_gap = 8,
        .secondary_gap = 8,
        .tab_indicator_width = 0,
        .view_offset = 0,
        .workspace_offset = 0,
        .single_window_aspect_ratio = 4.0 / 3.0,
        .single_window_aspect_tolerance = 0.001,
        .active_container_index = 0,
        .hidden_placement_monitor_index = -1,
        .orientation = orientation_horizontal,
        .single_window_mode = 0,
    };
}

fn expectContainerRect(
    output: NiriContainerOutput,
    canonical_rect: Rect,
    rendered_rect: Rect,
) !void {
    try std.testing.expectApproxEqAbs(canonical_rect.x, output.canonical_x, 0.001);
    try std.testing.expectApproxEqAbs(canonical_rect.y, output.canonical_y, 0.001);
    try std.testing.expectApproxEqAbs(canonical_rect.width, output.canonical_width, 0.001);
    try std.testing.expectApproxEqAbs(canonical_rect.height, output.canonical_height, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.x, output.rendered_x, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.y, output.rendered_y, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.width, output.rendered_width, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.height, output.rendered_height, 0.001);
}

fn expectWindowRect(
    output: NiriWindowOutput,
    canonical_rect: Rect,
    rendered_rect: Rect,
    resolved_span: f64,
    hidden_edge: u8,
) !void {
    try std.testing.expectApproxEqAbs(canonical_rect.x, output.canonical_x, 0.001);
    try std.testing.expectApproxEqAbs(canonical_rect.y, output.canonical_y, 0.001);
    try std.testing.expectApproxEqAbs(canonical_rect.width, output.canonical_width, 0.001);
    try std.testing.expectApproxEqAbs(canonical_rect.height, output.canonical_height, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.x, output.rendered_x, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.y, output.rendered_y, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.width, output.rendered_width, 0.001);
    try std.testing.expectApproxEqAbs(rendered_rect.height, output.rendered_height, 0.001);
    try std.testing.expectApproxEqAbs(resolved_span, output.resolved_span, 0.001);
    try std.testing.expectEqual(hidden_edge, output.hidden_edge);
    try std.testing.expectEqual(hidden_edge, output.physical_hidden_edge);
}

test "niri solver handles empty inputs" {
    try std.testing.expectEqual(
        kernel_ok,
        omniwm_niri_layout_solve(null, null, 0, null, 0, null, 0, null, 0, null, 0),
    );
}

test "niri solver aspect fits a single-window workspace" {
    var input = testInput();
    input.single_window_mode = 1;

    const containers = [_]NiriContainerInput{
        .{
            .span = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 0,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
    };
    const windows = [_]NiriWindowInput{
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
    };
    var container_outputs = [_]NiriContainerOutput{std.mem.zeroes(NiriContainerOutput)};
    var window_outputs = [_]NiriWindowOutput{std.mem.zeroes(NiriWindowOutput)};

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_niri_layout_solve(
            &input,
            &containers,
            containers.len,
            &windows,
            windows.len,
            null,
            0,
            &container_outputs,
            container_outputs.len,
            &window_outputs,
            window_outputs.len,
        ),
    );
    try expectContainerRect(
        container_outputs[0],
        .{ .x = 200, .y = 0, .width = 1200, .height = 900 },
        .{ .x = 200, .y = 0, .width = 1200, .height = 900 },
    );
    try expectWindowRect(
        window_outputs[0],
        .{ .x = 200, .y = 0, .width = 1200, .height = 900 },
        .{ .x = 200, .y = 0, .width = 1200, .height = 900 },
        900,
        hidden_edge_none,
    );
}

test "niri solver hides fully offscreen containers on the fallback edge" {
    var input = testInput();
    input.working_width = 600;
    input.view_width = 600;

    const containers = [_]NiriContainerInput{
        .{
            .span = 600,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 0,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
        .{
            .span = 600,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 1,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
    };
    const windows = [_]NiriWindowInput{
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
    };
    var container_outputs = [_]NiriContainerOutput{
        std.mem.zeroes(NiriContainerOutput),
        std.mem.zeroes(NiriContainerOutput),
    };
    var window_outputs = [_]NiriWindowOutput{
        std.mem.zeroes(NiriWindowOutput),
        std.mem.zeroes(NiriWindowOutput),
    };

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_niri_layout_solve(
            &input,
            &containers,
            containers.len,
            &windows,
            windows.len,
            null,
            0,
            &container_outputs,
            container_outputs.len,
            &window_outputs,
            window_outputs.len,
        ),
    );
    try expectContainerRect(
        container_outputs[1],
        .{ .x = 608, .y = 0, .width = 600, .height = 900 },
        .{ .x = 599.5, .y = 0, .width = 600, .height = 900 },
    );
    try expectWindowRect(
        window_outputs[1],
        .{ .x = 608, .y = 0, .width = 600, .height = 900 },
        .{ .x = 599.5, .y = 0, .width = 600, .height = 900 },
        900,
        hidden_edge_maximum,
    );
}

test "niri solver keeps neighboring-monitor overflow hidden until fully contained" {
    var input = testInput();
    input.hidden_placement_monitor_index = 0;

    const containers = [_]NiriContainerInput{
        .{
            .span = 1200,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 0,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
        .{
            .span = 1200,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 1,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
    };
    const windows = [_]NiriWindowInput{
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
    };
    const monitors = [_]HiddenPlacementMonitor{
        .{
            .frame_x = 0,
            .frame_y = 0,
            .frame_width = 1600,
            .frame_height = 900,
            .visible_x = 0,
            .visible_y = 0,
            .visible_width = 1600,
            .visible_height = 900,
        },
        .{
            .frame_x = 1600,
            .frame_y = 0,
            .frame_width = 1600,
            .frame_height = 900,
            .visible_x = 1600,
            .visible_y = 0,
            .visible_width = 1600,
            .visible_height = 900,
        },
    };
    var container_outputs = [_]NiriContainerOutput{
        std.mem.zeroes(NiriContainerOutput),
        std.mem.zeroes(NiriContainerOutput),
    };
    var window_outputs = [_]NiriWindowOutput{
        std.mem.zeroes(NiriWindowOutput),
        std.mem.zeroes(NiriWindowOutput),
    };

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_niri_layout_solve(
            &input,
            &containers,
            containers.len,
            &windows,
            windows.len,
            &monitors,
            monitors.len,
            &container_outputs,
            container_outputs.len,
            &window_outputs,
            window_outputs.len,
        ),
    );
    try std.testing.expectEqual(hidden_edge_maximum, window_outputs[1].hidden_edge);
    try std.testing.expectEqual(hidden_edge_minimum, window_outputs[1].physical_hidden_edge);
    try std.testing.expect(window_outputs[1].rendered_x < monitors[1].frame_x);
}

test "niri solver reports physical hidden edge when monitor boundary flips placement" {
    var input = testInput();
    input.working_x = 1600;
    input.view_x = 1600;
    input.active_container_index = 2;
    input.hidden_placement_monitor_index = 1;

    const containers = [_]NiriContainerInput{
        .{
            .span = 1200,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 0,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
        .{
            .span = 1200,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 1,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
        .{
            .span = 1200,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 2,
            .window_count = 1,
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
    };
    const windows = [_]NiriWindowInput{
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
        .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        },
    };
    const monitors = [_]HiddenPlacementMonitor{
        .{
            .frame_x = 0,
            .frame_y = 0,
            .frame_width = 1600,
            .frame_height = 900,
            .visible_x = 0,
            .visible_y = 0,
            .visible_width = 1600,
            .visible_height = 900,
        },
        .{
            .frame_x = 1600,
            .frame_y = 0,
            .frame_width = 1600,
            .frame_height = 900,
            .visible_x = 1600,
            .visible_y = 0,
            .visible_width = 1600,
            .visible_height = 900,
        },
    };
    var container_outputs = [_]NiriContainerOutput{
        std.mem.zeroes(NiriContainerOutput),
        std.mem.zeroes(NiriContainerOutput),
        std.mem.zeroes(NiriContainerOutput),
    };
    var window_outputs = [_]NiriWindowOutput{
        std.mem.zeroes(NiriWindowOutput),
        std.mem.zeroes(NiriWindowOutput),
        std.mem.zeroes(NiriWindowOutput),
    };

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_niri_layout_solve(
            &input,
            &containers,
            containers.len,
            &windows,
            windows.len,
            &monitors,
            monitors.len,
            &container_outputs,
            container_outputs.len,
            &window_outputs,
            window_outputs.len,
        ),
    );
    try std.testing.expectEqual(hidden_edge_minimum, window_outputs[0].hidden_edge);
    try std.testing.expectEqual(hidden_edge_maximum, window_outputs[0].physical_hidden_edge);
    try std.testing.expect(window_outputs[0].rendered_x >= monitors[1].frame_x);
}

test "niri solver handles large window counts through heap scratch" {
    var input = testInput();
    input.working_width = 800;
    input.view_width = 800;
    input.secondary_gap = 4;

    const containers = [_]NiriContainerInput{
        .{
            .span = 800,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .window_start_index = 0,
            .window_count = @intCast(stack_window_capacity + 1),
            .is_tabbed = 0,
            .has_manual_single_window_width_override = 0,
        },
    };
    var windows: [stack_window_capacity + 1]NiriWindowInput = undefined;
    for (&windows) |*window| {
        window.* = .{
            .weight = 1,
            .min_constraint = 1,
            .max_constraint = 0,
            .fixed_value = 0,
            .render_offset_x = 0,
            .render_offset_y = 0,
            .has_max_constraint = 0,
            .is_constraint_fixed = 0,
            .has_fixed_value = 0,
            .sizing_mode = window_sizing_normal,
        };
    }

    var container_outputs = [_]NiriContainerOutput{std.mem.zeroes(NiriContainerOutput)};
    var window_outputs: [stack_window_capacity + 1]NiriWindowOutput = undefined;
    @memset(&window_outputs, std.mem.zeroes(NiriWindowOutput));

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_niri_layout_solve(
            &input,
            &containers,
            containers.len,
            &windows,
            windows.len,
            null,
            0,
            &container_outputs,
            container_outputs.len,
            &window_outputs,
            window_outputs.len,
        ),
    );
    try std.testing.expect(window_outputs[0].resolved_span > 0);
    try std.testing.expect(window_outputs[windows.len - 1].canonical_y > window_outputs[0].canonical_y);
    try std.testing.expectEqual(hidden_edge_none, window_outputs[windows.len - 1].hidden_edge);
}
