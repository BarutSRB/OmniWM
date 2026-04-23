// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;
const kernel_allocation_failed: i32 = 2;
const node_kind_split: u32 = 0;
const node_kind_leaf: u32 = 1;
const orientation_horizontal: u32 = 0;
const orientation_vertical: u32 = 1;
const stack_node_capacity = 128;

const DwindleLayoutInput = extern struct {
    root_index: i32,
    screen_x: f64,
    screen_y: f64,
    screen_width: f64,
    screen_height: f64,
    inner_gap: f64,
    outer_gap_top: f64,
    outer_gap_bottom: f64,
    outer_gap_left: f64,
    outer_gap_right: f64,
    single_window_aspect_width: f64,
    single_window_aspect_height: f64,
    single_window_aspect_tolerance: f64,
    minimum_dimension: f64,
    gap_sticks_tolerance: f64,
    split_ratio_min: f64,
    split_ratio_max: f64,
    split_fraction_divisor: f64,
    split_fraction_min: f64,
    split_fraction_max: f64,
};

const DwindleNodeInput = extern struct {
    first_child_index: i32,
    second_child_index: i32,
    split_ratio: f64,
    min_width: f64,
    min_height: f64,
    kind: u32,
    orientation: u32,
    has_window: u8,
    fullscreen: u8,
};

const DwindleNodeFrame = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    has_frame: u8,
};

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const Size = struct {
    width: f64,
    height: f64,
};

const SplitRects = struct {
    first: Rect,
    second: Rect,
};

const VisitState = enum(u8) {
    unvisited,
    visiting,
    done,
};

fn swiftMax(lhs: f64, rhs: f64) f64 {
    return if (rhs > lhs) rhs else lhs;
}

fn swiftMin(lhs: f64, rhs: f64) f64 {
    return if (rhs < lhs) rhs else lhs;
}

fn sanitizeMinimum(value: f64) f64 {
    if (!std.math.isFinite(value) or value <= 0) {
        return 1;
    }
    return value;
}

fn fallbackSize(input: DwindleLayoutInput) Size {
    const minimum = sanitizeMinimum(input.minimum_dimension);
    return .{
        .width = minimum,
        .height = minimum,
    };
}

fn sanitizeLeafDimension(value: f64, input: DwindleLayoutInput) f64 {
    const minimum = sanitizeMinimum(input.minimum_dimension);
    if (!std.math.isFinite(value) or value < minimum) {
        return minimum;
    }
    return value;
}

fn screenRect(input: DwindleLayoutInput) Rect {
    return .{
        .x = input.screen_x,
        .y = input.screen_y,
        .width = input.screen_width,
        .height = input.screen_height,
    };
}

fn rectMaxX(rect: Rect) f64 {
    return rect.x + rect.width;
}

fn rectMaxY(rect: Rect) f64 {
    return rect.y + rect.height;
}

fn applyOuterGapsOnly(rect: Rect, input: DwindleLayoutInput) Rect {
    const minimum = sanitizeMinimum(input.minimum_dimension);
    return .{
        .x = rect.x + input.outer_gap_left,
        .y = rect.y + input.outer_gap_bottom,
        .width = swiftMax(minimum, rect.width - input.outer_gap_left - input.outer_gap_right),
        .height = swiftMax(minimum, rect.height - input.outer_gap_top - input.outer_gap_bottom),
    };
}

fn applyGaps(rect: Rect, tiling_area: Rect, input: DwindleLayoutInput) Rect {
    const tolerance = input.gap_sticks_tolerance;
    const minimum = sanitizeMinimum(input.minimum_dimension);
    const at_left = @abs(rect.x - tiling_area.x) < tolerance;
    const at_right = @abs(rectMaxX(rect) - rectMaxX(tiling_area)) < tolerance;
    const at_bottom = @abs(rect.y - tiling_area.y) < tolerance;
    const at_top = @abs(rectMaxY(rect) - rectMaxY(tiling_area)) < tolerance;

    const half_inner_gap = input.inner_gap / 2.0;
    const left_gap = if (at_left) input.outer_gap_left else half_inner_gap;
    const right_gap = if (at_right) input.outer_gap_right else half_inner_gap;
    const bottom_gap = if (at_bottom) input.outer_gap_bottom else half_inner_gap;
    const top_gap = if (at_top) input.outer_gap_top else half_inner_gap;

    return .{
        .x = rect.x + left_gap,
        .y = rect.y + bottom_gap,
        .width = swiftMax(minimum, rect.width - left_gap - right_gap),
        .height = swiftMax(minimum, rect.height - top_gap - bottom_gap),
    };
}

fn validAspectRatio(width: f64, height: f64) ?f64 {
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0) {
        return null;
    }

    const ratio = width / height;
    if (!std.math.isFinite(ratio) or ratio <= 0) {
        return null;
    }
    return ratio;
}

fn singleWindowRect(rect: Rect, input: DwindleLayoutInput) Rect {
    const target_ratio = validAspectRatio(
        input.single_window_aspect_width,
        input.single_window_aspect_height,
    ) orelse return rect;
    const current_ratio = validAspectRatio(rect.width, rect.height) orelse return rect;

    if (@abs(target_ratio - current_ratio) < input.single_window_aspect_tolerance) {
        return rect;
    }

    var width = rect.width;
    var height = rect.height;
    if (current_ratio > target_ratio) {
        width = height * target_ratio;
    } else {
        height = width / target_ratio;
    }

    return .{
        .x = rect.x + (rect.width - width) / 2.0,
        .y = rect.y + (rect.height - height) / 2.0,
        .width = width,
        .height = height,
    };
}

fn ratioToFraction(ratio: f64, input: DwindleLayoutInput) f64 {
    const safe_divisor = if (std.math.isFinite(input.split_fraction_divisor) and input.split_fraction_divisor > 0)
        input.split_fraction_divisor
    else
        2.0;

    var clamped_ratio = if (std.math.isFinite(ratio)) ratio else 1.0;
    clamped_ratio = swiftMax(input.split_ratio_min, swiftMin(input.split_ratio_max, clamped_ratio));
    const fraction = clamped_ratio / safe_divisor;
    return swiftMax(input.split_fraction_min, swiftMin(input.split_fraction_max, fraction));
}

fn parseChildIndex(raw_index: i32, node_count: usize) !?usize {
    if (raw_index == -1) {
        return null;
    }
    if (raw_index < -1) {
        return error.InvalidArgument;
    }

    const index: usize = @intCast(raw_index);
    if (index >= node_count) {
        return error.InvalidArgument;
    }
    return index;
}

fn leafMinSize(node: DwindleNodeInput, input: DwindleLayoutInput) Size {
    return .{
        .width = sanitizeLeafDimension(node.min_width, input),
        .height = sanitizeLeafDimension(node.min_height, input),
    };
}

fn computeSubtreeMinSize(
    index: usize,
    nodes: []const DwindleNodeInput,
    input: DwindleLayoutInput,
    min_cache: []Size,
    visit_states: []VisitState,
) !Size {
    switch (visit_states[index]) {
        .done => return min_cache[index],
        .visiting => return error.InvalidArgument,
        .unvisited => {},
    }

    visit_states[index] = .visiting;
    const node = nodes[index];

    const result = switch (node.kind) {
        node_kind_leaf => leafMinSize(node, input),
        node_kind_split => blk: {
            const first_index = try parseChildIndex(node.first_child_index, nodes.len) orelse {
                break :blk fallbackSize(input);
            };
            const second_index = try parseChildIndex(node.second_child_index, nodes.len) orelse {
                break :blk fallbackSize(input);
            };

            const first_min = try computeSubtreeMinSize(first_index, nodes, input, min_cache, visit_states);
            const second_min = try computeSubtreeMinSize(second_index, nodes, input, min_cache, visit_states);

            break :blk switch (node.orientation) {
                orientation_horizontal => Size{
                    .width = first_min.width + second_min.width,
                    .height = swiftMax(first_min.height, second_min.height),
                },
                orientation_vertical => Size{
                    .width = swiftMax(first_min.width, second_min.width),
                    .height = first_min.height + second_min.height,
                },
                else => return error.InvalidArgument,
            };
        },
        else => return error.InvalidArgument,
    };

    min_cache[index] = result;
    visit_states[index] = .done;
    return result;
}

fn splitRect(
    rect: Rect,
    orientation: u32,
    ratio: f64,
    first_min: Size,
    second_min: Size,
    input: DwindleLayoutInput,
) !SplitRects {
    const minimum = sanitizeMinimum(input.minimum_dimension);
    var fraction = ratioToFraction(ratio, input);

    return switch (orientation) {
        orientation_horizontal => blk: {
            const total_min = first_min.width + second_min.width;
            if (total_min > rect.width) {
                fraction = first_min.width / swiftMax(total_min, minimum);
            } else {
                const min_fraction = first_min.width / rect.width;
                const max_fraction = (rect.width - second_min.width) / rect.width;
                fraction = swiftMax(min_fraction, swiftMin(max_fraction, fraction));
            }

            const first_width = rect.width * fraction;
            const second_width = rect.width - first_width;
            break :blk .{
                .first = .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = first_width,
                    .height = rect.height,
                },
                .second = .{
                    .x = rect.x + first_width,
                    .y = rect.y,
                    .width = second_width,
                    .height = rect.height,
                },
            };
        },
        orientation_vertical => blk: {
            const total_min = first_min.height + second_min.height;
            if (total_min > rect.height) {
                fraction = first_min.height / swiftMax(total_min, minimum);
            } else {
                const min_fraction = first_min.height / rect.height;
                const max_fraction = (rect.height - second_min.height) / rect.height;
                fraction = swiftMax(min_fraction, swiftMin(max_fraction, fraction));
            }

            const first_height = rect.height * fraction;
            const second_height = rect.height - first_height;
            break :blk .{
                .first = .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = first_height,
                },
                .second = .{
                    .x = rect.x,
                    .y = rect.y + first_height,
                    .width = rect.width,
                    .height = second_height,
                },
            };
        },
        else => error.InvalidArgument,
    };
}

fn writeFrame(output: *DwindleNodeFrame, rect: Rect) void {
    output.* = .{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .has_frame = 1,
    };
}

fn solveNode(
    index: usize,
    rect: Rect,
    tiling_area: Rect,
    nodes: []const DwindleNodeInput,
    input: DwindleLayoutInput,
    min_cache: []Size,
    visit_states: []VisitState,
    outputs: []DwindleNodeFrame,
) !void {
    const node = nodes[index];

    switch (node.kind) {
        node_kind_leaf => {
            if (node.has_window == 0) {
                return;
            }

            const target = if (node.fullscreen != 0)
                tiling_area
            else
                applyGaps(rect, tiling_area, input);
            writeFrame(&outputs[index], target);
        },
        node_kind_split => {
            writeFrame(&outputs[index], rect);

            const first_index = try parseChildIndex(node.first_child_index, nodes.len);
            const second_index = try parseChildIndex(node.second_child_index, nodes.len);
            const first_min = if (first_index) |child_index|
                try computeSubtreeMinSize(child_index, nodes, input, min_cache, visit_states)
            else
                fallbackSize(input);
            const second_min = if (second_index) |child_index|
                try computeSubtreeMinSize(child_index, nodes, input, min_cache, visit_states)
            else
                fallbackSize(input);

            const split_rects = try splitRect(rect, node.orientation, node.split_ratio, first_min, second_min, input);
            if (first_index) |child_index| {
                try solveNode(child_index, split_rects.first, tiling_area, nodes, input, min_cache, visit_states, outputs);
            }
            if (second_index) |child_index| {
                try solveNode(child_index, split_rects.second, tiling_area, nodes, input, min_cache, visit_states, outputs);
            }
        },
        else => return error.InvalidArgument,
    }
}

fn solveSingleWindow(
    root_index: usize,
    nodes: []const DwindleNodeInput,
    input: DwindleLayoutInput,
    outputs: []DwindleNodeFrame,
) !void {
    var current_index = root_index;
    var steps: usize = 0;

    while (steps < nodes.len) : (steps += 1) {
        const node = nodes[current_index];
        if (node.kind != node_kind_split) {
            break;
        }

        const first_index = try parseChildIndex(node.first_child_index, nodes.len) orelse break;
        current_index = first_index;
    }

    if (steps == nodes.len and nodes[current_index].kind == node_kind_split) {
        return error.InvalidArgument;
    }

    const node = nodes[current_index];
    if (node.kind != node_kind_leaf or node.has_window == 0) {
        return;
    }

    const tiling_area = applyOuterGapsOnly(screenRect(input), input);
    const rect = if (node.fullscreen != 0)
        screenRect(input)
    else
        singleWindowRect(tiling_area, input);
    writeFrame(&outputs[current_index], rect);
}

fn countWindows(nodes: []const DwindleNodeInput) !usize {
    var count: usize = 0;
    for (nodes) |node| {
        switch (node.kind) {
            node_kind_leaf => {
                if (node.has_window != 0) {
                    count += 1;
                }
            },
            node_kind_split => {},
            else => return error.InvalidArgument,
        }
    }
    return count;
}

fn solveWithScratch(
    input: DwindleLayoutInput,
    nodes: []const DwindleNodeInput,
    outputs: []DwindleNodeFrame,
    min_cache: []Size,
    visit_states: []VisitState,
) !void {
    const root_index = try parseChildIndex(input.root_index, nodes.len) orelse return error.InvalidArgument;
    const window_count = try countWindows(nodes);

    for (outputs) |*output| {
        output.* = .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .has_frame = 0,
        };
    }

    for (visit_states) |*state| {
        state.* = .unvisited;
    }

    if (window_count == 0) {
        return;
    }
    if (window_count == 1) {
        try solveSingleWindow(root_index, nodes, input, outputs);
        return;
    }

    const tiling_area = applyOuterGapsOnly(screenRect(input), input);
    try solveNode(root_index, tiling_area, tiling_area, nodes, input, min_cache, visit_states, outputs);
}

pub export fn omniwm_dwindle_solve(
    input_ptr: [*c]const DwindleLayoutInput,
    nodes_ptr: [*c]const DwindleNodeInput,
    node_count: usize,
    outputs_ptr: [*c]DwindleNodeFrame,
    output_count: usize,
) i32 {
    if (node_count == 0) {
        return kernel_ok;
    }
    if (input_ptr == null or nodes_ptr == null or outputs_ptr == null or output_count < node_count) {
        return kernel_invalid_argument;
    }

    const input = input_ptr[0];
    const nodes = @as([*]const DwindleNodeInput, @ptrCast(nodes_ptr))[0..node_count];
    const outputs = @as([*]DwindleNodeFrame, @ptrCast(outputs_ptr))[0..node_count];

    if (node_count <= stack_node_capacity) {
        var min_cache: [stack_node_capacity]Size = undefined;
        var visit_states: [stack_node_capacity]VisitState = undefined;

        solveWithScratch(
            input,
            nodes,
            outputs,
            min_cache[0..node_count],
            visit_states[0..node_count],
        ) catch |err| switch (err) {
            error.InvalidArgument => return kernel_invalid_argument,
        };
        return kernel_ok;
    }

    const allocator = std.heap.page_allocator;
    const min_cache = allocator.alloc(Size, node_count) catch return kernel_allocation_failed;
    defer allocator.free(min_cache);
    const visit_states = allocator.alloc(VisitState, node_count) catch return kernel_allocation_failed;
    defer allocator.free(visit_states);

    solveWithScratch(input, nodes, outputs, min_cache, visit_states) catch |err| switch (err) {
        error.InvalidArgument => return kernel_invalid_argument,
    };
    return kernel_ok;
}

fn expectFrame(
    actual: DwindleNodeFrame,
    expected: Rect,
) !void {
    try std.testing.expectEqual(@as(u8, 1), actual.has_frame);
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.001);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.001);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, 0.001);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.001);
}

fn testInput() DwindleLayoutInput {
    return .{
        .root_index = 0,
        .screen_x = 0,
        .screen_y = 0,
        .screen_width = 1600,
        .screen_height = 1000,
        .inner_gap = 8,
        .outer_gap_top = 0,
        .outer_gap_bottom = 0,
        .outer_gap_left = 0,
        .outer_gap_right = 0,
        .single_window_aspect_width = 4,
        .single_window_aspect_height = 3,
        .single_window_aspect_tolerance = 0.1,
        .minimum_dimension = 1,
        .gap_sticks_tolerance = 2,
        .split_ratio_min = 0.1,
        .split_ratio_max = 1.9,
        .split_fraction_divisor = 2,
        .split_fraction_min = 0.05,
        .split_fraction_max = 0.95,
    };
}

test "dwindle solver applies outer gaps before single-window aspect math" {
    var input = testInput();
    input.outer_gap_top = 50;
    input.outer_gap_bottom = 50;
    input.outer_gap_left = 100;
    input.outer_gap_right = 100;

    const nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
    };
    var outputs = [_]DwindleNodeFrame{std.mem.zeroes(DwindleNodeFrame)};

    try std.testing.expectEqual(kernel_ok, omniwm_dwindle_solve(&input, &nodes, nodes.len, &outputs, outputs.len));
    try expectFrame(outputs[0], .{
        .x = 200,
        .y = 50,
        .width = 1200,
        .height = 900,
    });
}

test "dwindle solver treats zero aspect ratio as fill mode" {
    var input = testInput();
    input.single_window_aspect_width = 0;
    input.single_window_aspect_height = 0;
    input.outer_gap_left = 20;
    input.outer_gap_right = 40;
    input.outer_gap_top = 10;
    input.outer_gap_bottom = 30;

    const nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
    };
    var outputs = [_]DwindleNodeFrame{std.mem.zeroes(DwindleNodeFrame)};

    try std.testing.expectEqual(kernel_ok, omniwm_dwindle_solve(&input, &nodes, nodes.len, &outputs, outputs.len));
    try expectFrame(outputs[0], .{
        .x = 20,
        .y = 30,
        .width = 1540,
        .height = 960,
    });
}

test "dwindle solver keeps single fullscreen windows on the full screen rect" {
    var input = testInput();
    input.screen_x = 10;
    input.screen_y = 20;
    input.screen_width = 1280;
    input.screen_height = 720;
    input.outer_gap_left = 50;
    input.outer_gap_right = 60;

    const nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 1,
        },
    };
    var outputs = [_]DwindleNodeFrame{std.mem.zeroes(DwindleNodeFrame)};

    try std.testing.expectEqual(kernel_ok, omniwm_dwindle_solve(&input, &nodes, nodes.len, &outputs, outputs.len));
    try expectFrame(outputs[0], .{
        .x = 10,
        .y = 20,
        .width = 1280,
        .height = 720,
    });
}

test "dwindle solver gives fullscreen leaves the full tiling area in multi-window layouts" {
    var input = testInput();
    input.screen_width = 1000;
    input.screen_height = 500;
    input.inner_gap = 10;
    input.outer_gap_top = 10;
    input.outer_gap_bottom = 20;
    input.outer_gap_left = 30;
    input.outer_gap_right = 40;

    const nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = 1,
            .second_child_index = 2,
            .split_ratio = 1.0,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_horizontal,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 1,
        },
    };
    var outputs = [_]DwindleNodeFrame{
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
    };

    try std.testing.expectEqual(kernel_ok, omniwm_dwindle_solve(&input, &nodes, nodes.len, &outputs, outputs.len));
    try expectFrame(outputs[0], .{
        .x = 30,
        .y = 20,
        .width = 930,
        .height = 470,
    });
    try expectFrame(outputs[1], .{
        .x = 60,
        .y = 40,
        .width = 430,
        .height = 440,
    });
    try expectFrame(outputs[2], .{
        .x = 30,
        .y = 20,
        .width = 930,
        .height = 470,
    });
}

test "dwindle solver applies inner gaps and writes split frames" {
    var input = testInput();
    input.screen_width = 1000;
    input.screen_height = 500;
    input.inner_gap = 10;

    const nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = 1,
            .second_child_index = 2,
            .split_ratio = 1.0,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_horizontal,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
    };
    var outputs = [_]DwindleNodeFrame{
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
    };

    try std.testing.expectEqual(kernel_ok, omniwm_dwindle_solve(&input, &nodes, nodes.len, &outputs, outputs.len));
    try expectFrame(outputs[0], .{
        .x = 0,
        .y = 0,
        .width = 1000,
        .height = 500,
    });
    try expectFrame(outputs[1], .{
        .x = 0,
        .y = 0,
        .width = 495,
        .height = 500,
    });
    try expectFrame(outputs[2], .{
        .x = 505,
        .y = 0,
        .width = 495,
        .height = 500,
    });
}

test "dwindle solver clamps split ratios using aggregated subtree minima" {
    var input = testInput();
    input.screen_width = 700;
    input.screen_height = 800;
    input.inner_gap = 0;

    const nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = 1,
            .second_child_index = 4,
            .split_ratio = 0.3,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_horizontal,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = 2,
            .second_child_index = 3,
            .split_ratio = 1.0,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_vertical,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 300,
            .min_height = 200,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 100,
            .min_height = 400,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 200,
            .min_height = 100,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
    };
    var outputs = [_]DwindleNodeFrame{
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
    };

    try std.testing.expectEqual(kernel_ok, omniwm_dwindle_solve(&input, &nodes, nodes.len, &outputs, outputs.len));
    try expectFrame(outputs[1], .{
        .x = 0,
        .y = 0,
        .width = 300,
        .height = 800,
    });
    try expectFrame(outputs[2], .{
        .x = 0,
        .y = 0,
        .width = 300,
        .height = 400,
    });
    try expectFrame(outputs[3], .{
        .x = 0,
        .y = 400,
        .width = 300,
        .height = 400,
    });
    try expectFrame(outputs[4], .{
        .x = 300,
        .y = 0,
        .width = 400,
        .height = 800,
    });
}

test "dwindle solver falls back for placeholder leaves and missing children" {
    var input = testInput();
    input.screen_width = 400;
    input.screen_height = 200;
    input.inner_gap = 0;

    const placeholder_nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = 1,
            .second_child_index = 2,
            .split_ratio = 1.0,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_vertical,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 1,
            .min_height = 1,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = 3,
            .second_child_index = 4,
            .split_ratio = 1.0,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_horizontal,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 100,
            .min_height = 400,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 100,
            .min_height = 400,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
    };
    var placeholder_outputs = [_]DwindleNodeFrame{
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
    };

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_dwindle_solve(&input, &placeholder_nodes, placeholder_nodes.len, &placeholder_outputs, placeholder_outputs.len),
    );
    try std.testing.expectEqual(@as(u8, 0), placeholder_outputs[1].has_frame);
    try expectFrame(placeholder_outputs[2], .{
        .x = 0,
        .y = 200.0 / 401.0,
        .width = 400,
        .height = 200.0 * (400.0 / 401.0),
    });

    const missing_nodes = [_]DwindleNodeInput{
        .{
            .first_child_index = 1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_vertical,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = 2,
            .second_child_index = 3,
            .split_ratio = 1.0,
            .min_width = 0,
            .min_height = 0,
            .kind = node_kind_split,
            .orientation = orientation_horizontal,
            .has_window = 0,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 100,
            .min_height = 500,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
        .{
            .first_child_index = -1,
            .second_child_index = -1,
            .split_ratio = 1.0,
            .min_width = 100,
            .min_height = 500,
            .kind = node_kind_leaf,
            .orientation = orientation_horizontal,
            .has_window = 1,
            .fullscreen = 0,
        },
    };
    var missing_outputs = [_]DwindleNodeFrame{
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
        std.mem.zeroes(DwindleNodeFrame),
    };
    input.screen_width = 600;
    input.screen_height = 300;

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_dwindle_solve(&input, &missing_nodes, missing_nodes.len, &missing_outputs, missing_outputs.len),
    );
    try expectFrame(missing_outputs[1], .{
        .x = 0,
        .y = 0,
        .width = 600,
        .height = 300.0 * (500.0 / 501.0),
    });
}
