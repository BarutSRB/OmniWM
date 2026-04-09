const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;
const kernel_allocation_failed: i32 = 2;
const thumbnail_aspect_ratio: f64 = 16.0 / 10.0;

const OverviewContext = extern struct {
    screen_x: f64,
    screen_y: f64,
    screen_width: f64,
    screen_height: f64,
    metrics_scale: f64,
    available_width: f64,
    scaled_window_padding: f64,
    scaled_workspace_label_height: f64,
    scaled_workspace_section_padding: f64,
    scaled_window_spacing: f64,
    thumbnail_width: f64,
    initial_content_y: f64,
    content_bottom_padding: f64,
    total_content_height_override: f64,
    has_total_content_height_override: u8,
};

const OverviewWorkspaceInput = extern struct {
    generic_window_start_index: u32,
    generic_window_count: u32,
    niri_column_start_index: u32,
    niri_column_count: u32,
};

const OverviewGenericWindowInput = extern struct {
    workspace_index: u32,
    source_x: f64,
    source_y: f64,
    source_width: f64,
    source_height: f64,
    title_sort_rank: u32,
};

const OverviewNiriTileInput = extern struct {
    preferred_height: f64,
};

const OverviewNiriColumnInput = extern struct {
    workspace_index: u32,
    column_index: i32,
    width_weight: f64,
    preferred_width: f64,
    tile_start_index: u32,
    tile_count: u32,
    has_preferred_width: u8,
};

const OverviewSectionOutput = extern struct {
    workspace_index: u32,
    section_x: f64,
    section_y: f64,
    section_width: f64,
    section_height: f64,
    label_x: f64,
    label_y: f64,
    label_width: f64,
    label_height: f64,
    grid_x: f64,
    grid_y: f64,
    grid_width: f64,
    grid_height: f64,
    generic_window_output_start_index: u32,
    generic_window_output_count: u32,
    niri_column_output_start_index: u32,
    niri_column_output_count: u32,
    niri_tile_output_start_index: u32,
    niri_tile_output_count: u32,
    drop_zone_output_start_index: u32,
    drop_zone_output_count: u32,
};

const OverviewGenericWindowOutput = extern struct {
    input_index: u32,
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
};

const OverviewNiriTileOutput = extern struct {
    input_index: u32,
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
};

const OverviewNiriColumnOutput = extern struct {
    input_index: u32,
    column_index: i32,
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
    tile_output_start_index: u32,
    tile_output_count: u32,
};

const OverviewDropZoneOutput = extern struct {
    workspace_index: u32,
    insert_index: u32,
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
};

const OverviewResult = extern struct {
    total_content_height: f64,
    min_scroll_offset: f64,
    max_scroll_offset: f64,
    section_count: usize,
    generic_window_output_count: usize,
    niri_column_output_count: usize,
    niri_tile_output_count: usize,
    drop_zone_output_count: usize,
};

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const IndexRange = struct {
    start: usize,
    end: usize,
};

const ScrollRange = struct {
    min: f64,
    max: f64,
};

fn swiftMax(lhs: f64, rhs: f64) f64 {
    return if (rhs > lhs) rhs else lhs;
}

fn swiftMin(lhs: f64, rhs: f64) f64 {
    return if (rhs < lhs) rhs else lhs;
}

fn rectMaxX(rect: Rect) f64 {
    return rect.x + rect.width;
}

fn rectMaxY(rect: Rect) f64 {
    return rect.y + rect.height;
}

fn normalizedSourceRect(input: OverviewGenericWindowInput) Rect {
    var x = input.source_x;
    var y = input.source_y;
    var width = input.source_width;
    var height = input.source_height;

    if (width < 0) {
        x += width;
        width = -width;
    }
    if (height < 0) {
        y += height;
        height = -height;
    }

    return .{
        .x = x,
        .y = y,
        .width = swiftMax(width, 1),
        .height = swiftMax(height, 1),
    };
}

fn unionRect(lhs: Rect, rhs: Rect) Rect {
    const min_x = swiftMin(lhs.x, rhs.x);
    const min_y = swiftMin(lhs.y, rhs.y);
    const max_x = swiftMax(rectMaxX(lhs), rectMaxX(rhs));
    const max_y = swiftMax(rectMaxY(lhs), rectMaxY(rhs));
    return .{
        .x = min_x,
        .y = min_y,
        .width = swiftMax(max_x - min_x, 1),
        .height = swiftMax(max_y - min_y, 1),
    };
}

fn resolveRange(start_index: u32, count: u32, limit: usize) ?IndexRange {
    const start: usize = @intCast(start_index);
    const count_usize: usize = @intCast(count);
    if (start > limit or count_usize > limit - start) {
        return null;
    }
    return .{
        .start = start,
        .end = start + count_usize,
    };
}

fn workspacePreviewScale(context: OverviewContext, source_width: f64, source_height: f64) f64 {
    const safe_width = swiftMax(source_width, 1);
    const safe_height = swiftMax(source_height, 1);
    const max_preview_width = swiftMin(
        context.available_width,
        context.screen_width * 0.72 * context.metrics_scale,
    );
    const max_preview_height = swiftMax(
        context.thumbnail_width / thumbnail_aspect_ratio,
        context.screen_height * 0.42 * context.metrics_scale,
    );
    return swiftMax(0.01, swiftMin(max_preview_width / safe_width, max_preview_height / safe_height));
}

fn projectFrame(source_rect: Rect, source_bounds: Rect, preview_origin_x: f64, preview_origin_y: f64, scale: f64) Rect {
    return .{
        .x = preview_origin_x + (source_rect.x - source_bounds.x) * scale,
        .y = preview_origin_y + (source_rect.y - source_bounds.y) * scale,
        .width = source_rect.width * scale,
        .height = source_rect.height * scale,
    };
}

fn totalContentHeight(current_y: f64, context: OverviewContext) f64 {
    const content_bottom = current_y + context.scaled_workspace_section_padding - context.content_bottom_padding;
    return context.initial_content_y - content_bottom;
}

fn scrollRangeForTotalContent(context: OverviewContext, total_content_height: f64) ScrollRange {
    const content_bottom = context.initial_content_y - total_content_height;
    return .{
        .min = swiftMin(0, content_bottom - context.screen_y),
        .max = 0,
    };
}

fn genericLessThan(inputs: []const OverviewGenericWindowInput, lhs_index: usize, rhs_index: usize) bool {
    const lhs = normalizedSourceRect(inputs[lhs_index]);
    const rhs = normalizedSourceRect(inputs[rhs_index]);

    if (@abs(rectMaxY(lhs) - rectMaxY(rhs)) > 1) {
        return rectMaxY(lhs) > rectMaxY(rhs);
    }
    if (@abs(lhs.x - rhs.x) > 1) {
        return lhs.x < rhs.x;
    }
    if (inputs[lhs_index].title_sort_rank != inputs[rhs_index].title_sort_rank) {
        return inputs[lhs_index].title_sort_rank < inputs[rhs_index].title_sort_rank;
    }
    return lhs_index < rhs_index;
}

fn sortGenericIndices(indices: []usize, inputs: []const OverviewGenericWindowInput) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const value = indices[i];
        var j = i;
        while (j > 0 and genericLessThan(inputs, value, indices[j - 1])) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = value;
    }
}

fn genericBounds(indices: []const usize, inputs: []const OverviewGenericWindowInput) Rect {
    if (indices.len == 0) {
        return .{
            .x = 0,
            .y = 0,
            .width = 1,
            .height = 1,
        };
    }

    var bounds = normalizedSourceRect(inputs[indices[0]]);
    for (indices[1..]) |index| {
        bounds = unionRect(bounds, normalizedSourceRect(inputs[index]));
    }
    return bounds;
}

fn preferredNiriColumnWidth(column: OverviewNiriColumnInput, total_weight: f64, column_count: usize, context: OverviewContext) f64 {
    if (column.has_preferred_width != 0 and column.preferred_width > 0) {
        return column.preferred_width;
    }
    const normalized_weight = swiftMax(column.width_weight, 0.001) / swiftMax(total_weight, 0.001);
    return context.thumbnail_width * @as(f64, @floatFromInt(column_count)) * normalized_weight;
}

fn preferredNiriColumnHeight(column: OverviewNiriColumnInput, tiles: []const OverviewNiriTileInput, spacing: f64) f64 {
    const tile_range = resolveRange(column.tile_start_index, column.tile_count, tiles.len) orelse return 1;
    if (tile_range.start == tile_range.end) {
        return 1;
    }

    var total_height: f64 = 0;
    for (tiles[tile_range.start..tile_range.end]) |tile| {
        total_height += swiftMax(tile.preferred_height, 1);
    }
    const gap_count = tile_range.end - tile_range.start - 1;
    return total_height + spacing * @as(f64, @floatFromInt(gap_count));
}

pub export fn omniwm_overview_projection_solve(
    context_ptr: [*c]const OverviewContext,
    workspaces_ptr: [*c]const OverviewWorkspaceInput,
    workspace_count: usize,
    generic_windows_ptr: [*c]const OverviewGenericWindowInput,
    generic_window_count: usize,
    niri_columns_ptr: [*c]const OverviewNiriColumnInput,
    niri_column_count: usize,
    niri_tiles_ptr: [*c]const OverviewNiriTileInput,
    niri_tile_count: usize,
    section_outputs_ptr: [*c]OverviewSectionOutput,
    section_output_capacity: usize,
    generic_window_outputs_ptr: [*c]OverviewGenericWindowOutput,
    generic_window_output_capacity: usize,
    niri_column_outputs_ptr: [*c]OverviewNiriColumnOutput,
    niri_column_output_capacity: usize,
    niri_tile_outputs_ptr: [*c]OverviewNiriTileOutput,
    niri_tile_output_capacity: usize,
    drop_zone_outputs_ptr: [*c]OverviewDropZoneOutput,
    drop_zone_output_capacity: usize,
    result_ptr: [*c]OverviewResult,
) i32 {
    if (context_ptr == null or result_ptr == null) {
        return kernel_invalid_argument;
    }

    result_ptr[0] = std.mem.zeroes(OverviewResult);

    if (workspace_count > std.math.maxInt(u32) or
        generic_window_count > std.math.maxInt(u32) or
        niri_column_count > std.math.maxInt(u32) or
        niri_tile_count > std.math.maxInt(u32))
    {
        return kernel_invalid_argument;
    }

    if (workspace_count > 0 and workspaces_ptr == null) {
        return kernel_invalid_argument;
    }
    if (generic_window_count > 0 and generic_windows_ptr == null) {
        return kernel_invalid_argument;
    }
    if (niri_column_count > 0 and niri_columns_ptr == null) {
        return kernel_invalid_argument;
    }
    if (niri_tile_count > 0 and niri_tiles_ptr == null) {
        return kernel_invalid_argument;
    }
    if (section_output_capacity > 0 and section_outputs_ptr == null) {
        return kernel_invalid_argument;
    }
    if (generic_window_output_capacity > 0 and generic_window_outputs_ptr == null) {
        return kernel_invalid_argument;
    }
    if (niri_column_output_capacity > 0 and niri_column_outputs_ptr == null) {
        return kernel_invalid_argument;
    }
    if (niri_tile_output_capacity > 0 and niri_tile_outputs_ptr == null) {
        return kernel_invalid_argument;
    }
    if (drop_zone_output_capacity > 0 and drop_zone_outputs_ptr == null) {
        return kernel_invalid_argument;
    }

    const context = context_ptr[0];
    const workspaces = if (workspace_count == 0)
        &[_]OverviewWorkspaceInput{}
    else
        @as([*]const OverviewWorkspaceInput, @ptrCast(workspaces_ptr))[0..workspace_count];
    const generic_windows = if (generic_window_count == 0)
        &[_]OverviewGenericWindowInput{}
    else
        @as([*]const OverviewGenericWindowInput, @ptrCast(generic_windows_ptr))[0..generic_window_count];
    const niri_columns = if (niri_column_count == 0)
        &[_]OverviewNiriColumnInput{}
    else
        @as([*]const OverviewNiriColumnInput, @ptrCast(niri_columns_ptr))[0..niri_column_count];
    const niri_tiles = if (niri_tile_count == 0)
        &[_]OverviewNiriTileInput{}
    else
        @as([*]const OverviewNiriTileInput, @ptrCast(niri_tiles_ptr))[0..niri_tile_count];

    var empty_sections: [0]OverviewSectionOutput = .{};
    var empty_generic_outputs: [0]OverviewGenericWindowOutput = .{};
    var empty_niri_column_outputs: [0]OverviewNiriColumnOutput = .{};
    var empty_niri_tile_outputs: [0]OverviewNiriTileOutput = .{};
    var empty_drop_zone_outputs: [0]OverviewDropZoneOutput = .{};

    const section_outputs = if (section_output_capacity == 0)
        empty_sections[0..]
    else
        @as([*]OverviewSectionOutput, @ptrCast(section_outputs_ptr))[0..section_output_capacity];
    const generic_window_outputs = if (generic_window_output_capacity == 0)
        empty_generic_outputs[0..]
    else
        @as([*]OverviewGenericWindowOutput, @ptrCast(generic_window_outputs_ptr))[0..generic_window_output_capacity];
    const niri_column_outputs = if (niri_column_output_capacity == 0)
        empty_niri_column_outputs[0..]
    else
        @as([*]OverviewNiriColumnOutput, @ptrCast(niri_column_outputs_ptr))[0..niri_column_output_capacity];
    const niri_tile_outputs = if (niri_tile_output_capacity == 0)
        empty_niri_tile_outputs[0..]
    else
        @as([*]OverviewNiriTileOutput, @ptrCast(niri_tile_outputs_ptr))[0..niri_tile_output_capacity];
    const drop_zone_outputs = if (drop_zone_output_capacity == 0)
        empty_drop_zone_outputs[0..]
    else
        @as([*]OverviewDropZoneOutput, @ptrCast(drop_zone_outputs_ptr))[0..drop_zone_output_capacity];

    const allocator = std.heap.page_allocator;

    var current_y = context.initial_content_y;
    var section_count: usize = 0;
    var generic_output_count: usize = 0;
    var niri_column_output_count: usize = 0;
    var niri_tile_output_count: usize = 0;
    var drop_zone_output_count: usize = 0;

    for (workspaces, 0..) |workspace, workspace_index| {
        const generic_range = resolveRange(
            workspace.generic_window_start_index,
            workspace.generic_window_count,
            generic_windows.len,
        ) orelse return kernel_invalid_argument;
        const niri_column_range = resolveRange(
            workspace.niri_column_start_index,
            workspace.niri_column_count,
            niri_columns.len,
        ) orelse return kernel_invalid_argument;

        const has_generic = generic_range.start != generic_range.end;
        const has_niri = niri_column_range.start != niri_column_range.end;
        if (has_generic and has_niri) {
            return kernel_invalid_argument;
        }
        if (!has_generic and !has_niri) {
            continue;
        }
        if (section_count >= section_outputs.len) {
            return kernel_invalid_argument;
        }

        current_y -= context.scaled_workspace_label_height;
        const label_rect = Rect{
            .x = context.screen_x + context.scaled_window_padding,
            .y = current_y,
            .width = context.available_width,
            .height = context.scaled_workspace_label_height,
        };

        current_y -= context.scaled_workspace_section_padding;

        var grid_rect = Rect{
            .x = context.screen_x,
            .y = current_y,
            .width = 0,
            .height = 0,
        };
        const generic_output_start = generic_output_count;
        const niri_column_output_start = niri_column_output_count;
        const niri_tile_output_start = niri_tile_output_count;
        const drop_zone_output_start = drop_zone_output_count;

        if (has_generic) {
            const range_len = generic_range.end - generic_range.start;
            const sorted_indices = allocator.alloc(usize, range_len) catch return kernel_allocation_failed;
            defer allocator.free(sorted_indices);

            for (sorted_indices, 0..) |*slot, offset| {
                slot.* = generic_range.start + offset;
            }
            sortGenericIndices(sorted_indices, generic_windows);

            const source_bounds = genericBounds(sorted_indices, generic_windows);
            const preview_scale = workspacePreviewScale(context, source_bounds.width, source_bounds.height);
            const projected_width = source_bounds.width * preview_scale;
            const projected_height = source_bounds.height * preview_scale;
            const preview_origin_x = context.screen_x + (context.screen_width - projected_width) / 2;
            const preview_origin_y = current_y - projected_height;
            grid_rect = .{
                .x = preview_origin_x,
                .y = preview_origin_y,
                .width = projected_width,
                .height = projected_height,
            };

            for (sorted_indices) |input_index| {
                if (generic_windows[input_index].workspace_index != workspace_index) {
                    return kernel_invalid_argument;
                }
                if (generic_output_count >= generic_window_outputs.len) {
                    return kernel_invalid_argument;
                }

                const projected = projectFrame(
                    normalizedSourceRect(generic_windows[input_index]),
                    source_bounds,
                    preview_origin_x,
                    preview_origin_y,
                    preview_scale,
                );
                generic_window_outputs[generic_output_count] = .{
                    .input_index = @intCast(input_index),
                    .frame_x = projected.x,
                    .frame_y = projected.y,
                    .frame_width = projected.width,
                    .frame_height = projected.height,
                };
                generic_output_count += 1;
            }
        } else {
            var total_weight: f64 = 0;
            for (niri_columns[niri_column_range.start..niri_column_range.end]) |column| {
                if (column.workspace_index != workspace_index) {
                    return kernel_invalid_argument;
                }
                const tile_range = resolveRange(column.tile_start_index, column.tile_count, niri_tiles.len) orelse return kernel_invalid_argument;
                _ = tile_range;
                total_weight += swiftMax(column.width_weight, 0.001);
            }

            const local_column_count = niri_column_range.end - niri_column_range.start;
            const raw_widths = allocator.alloc(f64, local_column_count) catch return kernel_allocation_failed;
            defer allocator.free(raw_widths);
            const raw_heights = allocator.alloc(f64, local_column_count) catch return kernel_allocation_failed;
            defer allocator.free(raw_heights);

            var raw_total_width: f64 = 0;
            var raw_max_height: f64 = 1;
            for (niri_columns[niri_column_range.start..niri_column_range.end], 0..) |column, local_index| {
                const raw_width = preferredNiriColumnWidth(column, total_weight, local_column_count, context);
                const raw_height = preferredNiriColumnHeight(column, niri_tiles, context.scaled_window_spacing);
                raw_widths[local_index] = raw_width;
                raw_heights[local_index] = raw_height;
                raw_total_width += raw_width;
                raw_max_height = swiftMax(raw_max_height, raw_height);
            }
            raw_total_width += context.scaled_window_spacing * @as(f64, @floatFromInt(if (local_column_count > 0) local_column_count - 1 else 0));

            const workspace_scale = workspacePreviewScale(context, raw_total_width, raw_max_height);
            const total_grid_width = raw_total_width * workspace_scale;
            const grid_height = raw_max_height * workspace_scale;
            const grid_start_x = context.screen_x + (context.screen_width - total_grid_width) / 2;
            grid_rect = .{
                .x = grid_start_x,
                .y = current_y - grid_height,
                .width = total_grid_width,
                .height = grid_height,
            };

            var current_x = grid_start_x;
            for (niri_columns[niri_column_range.start..niri_column_range.end], 0..) |column, local_index| {
                const tile_range = resolveRange(column.tile_start_index, column.tile_count, niri_tiles.len) orelse return kernel_invalid_argument;
                const column_frame = Rect{
                    .x = current_x,
                    .y = grid_rect.y,
                    .width = raw_widths[local_index] * workspace_scale,
                    .height = raw_heights[local_index] * workspace_scale,
                };

                const tile_output_start = niri_tile_output_count;
                var next_tile_y = rectMaxY(column_frame);
                for (niri_tiles[tile_range.start..tile_range.end], tile_range.start..) |tile, tile_input_index| {
                    if (niri_tile_output_count >= niri_tile_outputs.len) {
                        return kernel_invalid_argument;
                    }

                    const tile_height = swiftMax(tile.preferred_height, 1) * workspace_scale;
                    const tile_y = next_tile_y - tile_height;
                    niri_tile_outputs[niri_tile_output_count] = .{
                        .input_index = @intCast(tile_input_index),
                        .frame_x = column_frame.x,
                        .frame_y = tile_y,
                        .frame_width = column_frame.width,
                        .frame_height = tile_height,
                    };
                    niri_tile_output_count += 1;
                    next_tile_y = tile_y - context.scaled_window_spacing;
                }

                if (niri_column_output_count >= niri_column_outputs.len) {
                    return kernel_invalid_argument;
                }
                niri_column_outputs[niri_column_output_count] = .{
                    .input_index = @intCast(niri_column_range.start + local_index),
                    .column_index = column.column_index,
                    .frame_x = column_frame.x,
                    .frame_y = column_frame.y,
                    .frame_width = column_frame.width,
                    .frame_height = column_frame.height,
                    .tile_output_start_index = @intCast(tile_output_start),
                    .tile_output_count = @intCast(niri_tile_output_count - tile_output_start),
                };
                niri_column_output_count += 1;
                current_x += column_frame.width + context.scaled_window_spacing;
            }

            const edge_zone_width = swiftMax(
                12 * context.metrics_scale,
                swiftMin(30 * context.metrics_scale, context.scaled_window_spacing),
            );
            if (drop_zone_output_count >= drop_zone_outputs.len) {
                return kernel_invalid_argument;
            }
            drop_zone_outputs[drop_zone_output_count] = .{
                .workspace_index = @intCast(workspace_index),
                .insert_index = 0,
                .frame_x = grid_rect.x - edge_zone_width,
                .frame_y = grid_rect.y,
                .frame_width = edge_zone_width,
                .frame_height = grid_rect.height,
            };
            drop_zone_output_count += 1;

            if (local_column_count > 1) {
                var local_index: usize = 0;
                while (local_index + 1 < local_column_count) : (local_index += 1) {
                    if (drop_zone_output_count >= drop_zone_outputs.len) {
                        return kernel_invalid_argument;
                    }
                    const left = niri_column_outputs[niri_column_output_start + local_index];
                    const right = niri_column_outputs[niri_column_output_start + local_index + 1];
                    drop_zone_outputs[drop_zone_output_count] = .{
                        .workspace_index = @intCast(workspace_index),
                        .insert_index = @intCast(local_index + 1),
                        .frame_x = left.frame_x + left.frame_width,
                        .frame_y = grid_rect.y,
                        .frame_width = swiftMax(0, right.frame_x - (left.frame_x + left.frame_width)),
                        .frame_height = grid_rect.height,
                    };
                    drop_zone_output_count += 1;
                }
            }

            if (drop_zone_output_count >= drop_zone_outputs.len) {
                return kernel_invalid_argument;
            }
            drop_zone_outputs[drop_zone_output_count] = .{
                .workspace_index = @intCast(workspace_index),
                .insert_index = @intCast(local_column_count),
                .frame_x = rectMaxX(grid_rect),
                .frame_y = grid_rect.y,
                .frame_width = edge_zone_width,
                .frame_height = grid_rect.height,
            };
            drop_zone_output_count += 1;
        }

        const section_bottom = grid_rect.y;
        const section_rect = Rect{
            .x = context.screen_x,
            .y = section_bottom,
            .width = context.screen_width,
            .height = current_y + context.scaled_workspace_label_height - section_bottom,
        };

        section_outputs[section_count] = .{
            .workspace_index = @intCast(workspace_index),
            .section_x = section_rect.x,
            .section_y = section_rect.y,
            .section_width = section_rect.width,
            .section_height = section_rect.height,
            .label_x = label_rect.x,
            .label_y = label_rect.y,
            .label_width = label_rect.width,
            .label_height = label_rect.height,
            .grid_x = grid_rect.x,
            .grid_y = grid_rect.y,
            .grid_width = grid_rect.width,
            .grid_height = grid_rect.height,
            .generic_window_output_start_index = @intCast(generic_output_start),
            .generic_window_output_count = @intCast(generic_output_count - generic_output_start),
            .niri_column_output_start_index = @intCast(niri_column_output_start),
            .niri_column_output_count = @intCast(niri_column_output_count - niri_column_output_start),
            .niri_tile_output_start_index = @intCast(niri_tile_output_start),
            .niri_tile_output_count = @intCast(niri_tile_output_count - niri_tile_output_start),
            .drop_zone_output_start_index = @intCast(drop_zone_output_start),
            .drop_zone_output_count = @intCast(drop_zone_output_count - drop_zone_output_start),
        };
        section_count += 1;
        current_y = section_rect.y - context.scaled_workspace_section_padding;
    }

    const use_override = context.has_total_content_height_override != 0 and
        workspace_count == 0 and
        generic_window_count == 0 and
        niri_column_count == 0 and
        niri_tile_count == 0;
    const total_content_height = if (use_override)
        context.total_content_height_override
    else
        totalContentHeight(current_y, context);
    const scroll_range = scrollRangeForTotalContent(context, total_content_height);

    result_ptr[0] = .{
        .total_content_height = total_content_height,
        .min_scroll_offset = scroll_range.min,
        .max_scroll_offset = scroll_range.max,
        .section_count = section_count,
        .generic_window_output_count = generic_output_count,
        .niri_column_output_count = niri_column_output_count,
        .niri_tile_output_count = niri_tile_output_count,
        .drop_zone_output_count = drop_zone_output_count,
    };
    return kernel_ok;
}

test "overview solver handles empty inputs and overridden scroll bounds" {
    var context = std.mem.zeroes(OverviewContext);
    context.screen_y = 0;
    context.initial_content_y = 880;
    context.scaled_workspace_section_padding = 16;
    context.content_bottom_padding = 40;
    context.total_content_height_override = 1300;
    context.has_total_content_height_override = 1;
    var result = std.mem.zeroes(OverviewResult);

    try std.testing.expectEqual(@as(i32, kernel_ok), omniwm_overview_projection_solve(
        &context,
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
        null,
        0,
        null,
        0,
        null,
        0,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 0), result.section_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1300), result.total_content_height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -420), result.min_scroll_offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.max_scroll_offset, 0.001);
}

test "overview solver projects generic windows in title rank order" {
    var context = std.mem.zeroes(OverviewContext);
    context.screen_width = 1440;
    context.screen_height = 900;
    context.metrics_scale = 1;
    context.available_width = 1392;
    context.scaled_window_padding = 24;
    context.scaled_workspace_label_height = 32;
    context.scaled_workspace_section_padding = 16;
    context.scaled_window_spacing = 16;
    context.thumbnail_width = 348;
    context.initial_content_y = 816;
    context.content_bottom_padding = 40;

    const workspaces = [_]OverviewWorkspaceInput{
        .{
            .generic_window_start_index = 0,
            .generic_window_count = 2,
            .niri_column_start_index = 0,
            .niri_column_count = 0,
        },
    };
    const generic_windows = [_]OverviewGenericWindowInput{
        .{
            .workspace_index = 0,
            .source_x = 120.4,
            .source_y = 100,
            .source_width = 800,
            .source_height = 520,
            .title_sort_rank = 1,
        },
        .{
            .workspace_index = 0,
            .source_x = 120.0,
            .source_y = 100,
            .source_width = 800,
            .source_height = 520,
            .title_sort_rank = 0,
        },
    };
    var sections = [_]OverviewSectionOutput{std.mem.zeroes(OverviewSectionOutput)};
    var window_outputs = [_]OverviewGenericWindowOutput{
        std.mem.zeroes(OverviewGenericWindowOutput),
        std.mem.zeroes(OverviewGenericWindowOutput),
    };
    var result = std.mem.zeroes(OverviewResult);

    try std.testing.expectEqual(@as(i32, kernel_ok), omniwm_overview_projection_solve(
        &context,
        &workspaces,
        workspaces.len,
        &generic_windows,
        generic_windows.len,
        null,
        0,
        null,
        0,
        &sections,
        sections.len,
        &window_outputs,
        window_outputs.len,
        null,
        0,
        null,
        0,
        null,
        0,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 1), result.section_count);
    try std.testing.expectEqual(@as(usize, 2), result.generic_window_output_count);
    try std.testing.expectEqual(@as(u32, 1), window_outputs[0].input_index);
    try std.testing.expectEqual(@as(u32, 0), window_outputs[1].input_index);
    try std.testing.expect(window_outputs[0].frame_width > 0);
    try std.testing.expect(window_outputs[0].frame_height > 0);
}

test "overview solver projects niri columns and stable drop zone indices" {
    var context = std.mem.zeroes(OverviewContext);
    context.screen_width = 1440;
    context.screen_height = 900;
    context.metrics_scale = 1;
    context.available_width = 1392;
    context.scaled_window_padding = 24;
    context.scaled_workspace_label_height = 32;
    context.scaled_workspace_section_padding = 16;
    context.scaled_window_spacing = 16;
    context.thumbnail_width = 348;
    context.initial_content_y = 816;
    context.content_bottom_padding = 40;

    const workspaces = [_]OverviewWorkspaceInput{
        .{
            .generic_window_start_index = 0,
            .generic_window_count = 0,
            .niri_column_start_index = 0,
            .niri_column_count = 2,
        },
    };
    const columns = [_]OverviewNiriColumnInput{
        .{
            .workspace_index = 0,
            .column_index = 0,
            .width_weight = 1,
            .preferred_width = 0,
            .tile_start_index = 0,
            .tile_count = 1,
            .has_preferred_width = 0,
        },
        .{
            .workspace_index = 0,
            .column_index = 1,
            .width_weight = 1,
            .preferred_width = 0,
            .tile_start_index = 1,
            .tile_count = 1,
            .has_preferred_width = 0,
        },
    };
    const tiles = [_]OverviewNiriTileInput{
        .{ .preferred_height = 420 },
        .{ .preferred_height = 240 },
    };
    var sections = [_]OverviewSectionOutput{std.mem.zeroes(OverviewSectionOutput)};
    var column_outputs = [_]OverviewNiriColumnOutput{
        std.mem.zeroes(OverviewNiriColumnOutput),
        std.mem.zeroes(OverviewNiriColumnOutput),
    };
    var tile_outputs = [_]OverviewNiriTileOutput{
        std.mem.zeroes(OverviewNiriTileOutput),
        std.mem.zeroes(OverviewNiriTileOutput),
    };
    var drop_zones = [_]OverviewDropZoneOutput{
        std.mem.zeroes(OverviewDropZoneOutput),
        std.mem.zeroes(OverviewDropZoneOutput),
        std.mem.zeroes(OverviewDropZoneOutput),
    };
    var result = std.mem.zeroes(OverviewResult);

    try std.testing.expectEqual(@as(i32, kernel_ok), omniwm_overview_projection_solve(
        &context,
        &workspaces,
        workspaces.len,
        null,
        0,
        &columns,
        columns.len,
        &tiles,
        tiles.len,
        &sections,
        sections.len,
        null,
        0,
        &column_outputs,
        column_outputs.len,
        &tile_outputs,
        tile_outputs.len,
        &drop_zones,
        drop_zones.len,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 1), result.section_count);
    try std.testing.expectEqual(@as(usize, 2), result.niri_column_output_count);
    try std.testing.expectEqual(@as(usize, 2), result.niri_tile_output_count);
    try std.testing.expectEqual(@as(usize, 3), result.drop_zone_output_count);
    try std.testing.expectEqual(@as(u32, 0), drop_zones[0].insert_index);
    try std.testing.expectEqual(@as(u32, 1), drop_zones[1].insert_index);
    try std.testing.expectEqual(@as(u32, 2), drop_zones[2].insert_index);
    try std.testing.expect(column_outputs[0].frame_x < column_outputs[1].frame_x);
}
