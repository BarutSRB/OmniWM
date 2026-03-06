const std = @import("std");
const abi = @import("abi_types.zig");
const geometry = @import("geometry.zig");

const OmniNiriStateColumnInput = abi.OmniNiriStateColumnInput;
const OmniNiriStateWindowInput = abi.OmniNiriStateWindowInput;
const OmniNiriMutationRequest = abi.OmniNiriMutationRequest;
const OmniNiriMutationResult = abi.OmniNiriMutationResult;
const OmniNiriMutationEdit = abi.OmniNiriMutationEdit;

const OMNI_OK = abi.OMNI_OK;
const OMNI_ERR_INVALID_ARGS = abi.OMNI_ERR_INVALID_ARGS;
const OMNI_ERR_OUT_OF_RANGE = abi.OMNI_ERR_OUT_OF_RANGE;

const OMNI_NIRI_DIRECTION_LEFT = abi.OMNI_NIRI_DIRECTION_LEFT;
const OMNI_NIRI_DIRECTION_RIGHT = abi.OMNI_NIRI_DIRECTION_RIGHT;
const OMNI_NIRI_DIRECTION_UP = abi.OMNI_NIRI_DIRECTION_UP;
const OMNI_NIRI_DIRECTION_DOWN = abi.OMNI_NIRI_DIRECTION_DOWN;

const OMNI_NIRI_INSERT_BEFORE = abi.OMNI_NIRI_INSERT_BEFORE;
const OMNI_NIRI_INSERT_AFTER = abi.OMNI_NIRI_INSERT_AFTER;
const OMNI_NIRI_SPAWN_NEW_COLUMN = abi.OMNI_NIRI_SPAWN_NEW_COLUMN;
const OMNI_NIRI_SPAWN_FOCUSED_COLUMN = abi.OMNI_NIRI_SPAWN_FOCUSED_COLUMN;

const OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL = abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL;
const OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL = abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL;
const OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL = abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL;
const OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL = abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL;
const OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE = abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE;
const OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE = abi.OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE;
const OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN = abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN;
const OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE = abi.OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE;
const OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN = abi.OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN;
const OMNI_NIRI_MUTATION_OP_MOVE_COLUMN = abi.OMNI_NIRI_MUTATION_OP_MOVE_COLUMN;
const OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW = abi.OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW;
const OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW = abi.OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW;
const OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN = abi.OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN;
const OMNI_NIRI_MUTATION_OP_NORMALIZE_COLUMN_SIZES = abi.OMNI_NIRI_MUTATION_OP_NORMALIZE_COLUMN_SIZES;
const OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES = abi.OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES;
const OMNI_NIRI_MUTATION_OP_BALANCE_SIZES = abi.OMNI_NIRI_MUTATION_OP_BALANCE_SIZES;
const OMNI_NIRI_MUTATION_OP_ADD_WINDOW = abi.OMNI_NIRI_MUTATION_OP_ADD_WINDOW;
const OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW = abi.OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW;
const OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION = abi.OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION;
const OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL = abi.OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL;

const OMNI_NIRI_MUTATION_NODE_NONE = abi.OMNI_NIRI_MUTATION_NODE_NONE;
const OMNI_NIRI_MUTATION_NODE_WINDOW = abi.OMNI_NIRI_MUTATION_NODE_WINDOW;
const OMNI_NIRI_MUTATION_NODE_COLUMN = abi.OMNI_NIRI_MUTATION_NODE_COLUMN;

const OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE = abi.OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE;
const OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS = abi.OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS;
const OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX = abi.OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX;
const OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE = abi.OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE;
const OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT = abi.OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT;
const OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT = abi.OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT;
const OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY = abi.OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY;
const OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY = abi.OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY;
const OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN = abi.OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN;
const OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW = abi.OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW;
const OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW = abi.OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW;
const OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS = abi.OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS;
const OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR = abi.OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR;
const OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR = abi.OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR;
const OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS = abi.OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS;
const OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN = abi.OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN;
const OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN = abi.OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN;
const OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX = abi.OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX;
const OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS = abi.OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS;

const OMNI_NIRI_MUTATION_MAX_EDITS = abi.OMNI_NIRI_MUTATION_MAX_EDITS;

const SelectedContext = struct {
    column_index: usize,
    row_index: usize,
    window_index: usize,
};

const NodeTarget = struct {
    kind: u8,
    index: usize,
};

fn parseColumnIndex(raw: i64, column_count: usize) ?usize {
    const idx = std.math.cast(usize, raw) orelse return null;
    if (idx >= column_count) return null;
    return idx;
}

fn wrappedColumnIndex(idx: i64, total: usize, infinite_loop: bool) ?usize {
    if (total == 0) return null;

    if (infinite_loop) {
        const modulo = std.math.cast(i64, total) orelse return null;
        const wrapped = @mod(idx, modulo);
        return std.math.cast(usize, wrapped);
    }

    if (idx < 0) return null;
    const casted = std.math.cast(usize, idx) orelse return null;
    if (casted >= total) return null;
    return casted;
}

fn initMutationResult(out_result: *OmniNiriMutationResult) void {
    const empty_edit = OmniNiriMutationEdit{
        .kind = OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
        .subject_index = -1,
        .related_index = -1,
        .value_a = -1,
        .value_b = -1,
        .scalar_a = 0,
        .scalar_b = 0,
    };
    out_result.* = .{
        .applied = 0,
        .has_target_window = 0,
        .target_window_index = -1,
        .has_target_node = 0,
        .target_node_kind = OMNI_NIRI_MUTATION_NODE_NONE,
        .target_node_index = -1,
        .edit_count = 0,
        .edits = [_]OmniNiriMutationEdit{empty_edit} ** OMNI_NIRI_MUTATION_MAX_EDITS,
    };
}

fn addMutationEdit(
    out_result: *OmniNiriMutationResult,
    kind: u8,
    subject_index: i64,
    related_index: i64,
    value_a: i64,
    value_b: i64,
) i32 {
    return addMutationEditWithScalars(
        out_result,
        kind,
        subject_index,
        related_index,
        value_a,
        value_b,
        0,
        0,
    );
}

fn addMutationEditWithScalars(
    out_result: *OmniNiriMutationResult,
    kind: u8,
    subject_index: i64,
    related_index: i64,
    value_a: i64,
    value_b: i64,
    scalar_a: f64,
    scalar_b: f64,
) i32 {
    if (out_result.edit_count >= OMNI_NIRI_MUTATION_MAX_EDITS) return OMNI_ERR_OUT_OF_RANGE;
    out_result.edits[out_result.edit_count] = .{
        .kind = kind,
        .subject_index = subject_index,
        .related_index = related_index,
        .value_a = value_a,
        .value_b = value_b,
        .scalar_a = scalar_a,
        .scalar_b = scalar_b,
    };
    out_result.edit_count += 1;
    return OMNI_OK;
}

fn setMutationTargetNode(out_result: *OmniNiriMutationResult, node_kind: u8, node_index: usize) i32 {
    const target_i64 = std.math.cast(i64, node_index) orelse return OMNI_ERR_OUT_OF_RANGE;
    out_result.has_target_node = 1;
    out_result.target_node_kind = node_kind;
    out_result.target_node_index = target_i64;
    if (node_kind == OMNI_NIRI_MUTATION_NODE_WINDOW) {
        out_result.has_target_window = 1;
        out_result.target_window_index = target_i64;
    }
    return OMNI_OK;
}

fn setMutationTargetWindow(out_result: *OmniNiriMutationResult, window_index: usize) i32 {
    return setMutationTargetNode(out_result, OMNI_NIRI_MUTATION_NODE_WINDOW, window_index);
}

fn parseWindowContextByIndex(
    columns: [*c]const OmniNiriStateColumnInput,
    windows: [*c]const OmniNiriStateWindowInput,
    column_count: usize,
    window_count: usize,
    window_index_raw: i64,
    out_context: *SelectedContext,
) i32 {
    const window_index = std.math.cast(usize, window_index_raw) orelse return OMNI_ERR_OUT_OF_RANGE;
    if (window_index >= window_count) return OMNI_ERR_OUT_OF_RANGE;

    const column_index = windows[window_index].column_index;
    if (column_index >= column_count) return OMNI_ERR_OUT_OF_RANGE;

    const column = columns[column_index];
    if (!geometry.rangeContains(column.window_start, column.window_count, window_index)) return OMNI_ERR_OUT_OF_RANGE;

    out_context.* = .{
        .column_index = column_index,
        .row_index = window_index - column.window_start,
        .window_index = window_index,
    };
    return OMNI_OK;
}

fn parseNodeTargetRequest(
    column_count: usize,
    window_count: usize,
    node_kind: u8,
    node_index_raw: i64,
    out_target: *?NodeTarget,
) i32 {
    switch (node_kind) {
        OMNI_NIRI_MUTATION_NODE_NONE => {
            out_target.* = null;
            return OMNI_OK;
        },
        OMNI_NIRI_MUTATION_NODE_WINDOW => {
            if (node_index_raw < 0) return OMNI_ERR_OUT_OF_RANGE;
            const node_index = std.math.cast(usize, node_index_raw) orelse return OMNI_ERR_OUT_OF_RANGE;
            if (node_index >= window_count) return OMNI_ERR_OUT_OF_RANGE;
            out_target.* = NodeTarget{
                .kind = node_kind,
                .index = node_index,
            };
            return OMNI_OK;
        },
        OMNI_NIRI_MUTATION_NODE_COLUMN => {
            if (node_index_raw < 0) return OMNI_ERR_OUT_OF_RANGE;
            const node_index = parseColumnIndex(node_index_raw, column_count) orelse return OMNI_ERR_OUT_OF_RANGE;
            out_target.* = NodeTarget{
                .kind = node_kind,
                .index = node_index,
            };
            return OMNI_OK;
        },
        else => return OMNI_ERR_INVALID_ARGS,
    }
}

fn columnIndexForNodeTarget(
    windows: [*c]const OmniNiriStateWindowInput,
    column_count: usize,
    target: NodeTarget,
) ?usize {
    switch (target.kind) {
        OMNI_NIRI_MUTATION_NODE_WINDOW => {
            const column_index = windows[target.index].column_index;
            if (column_index >= column_count) return null;
            return column_index;
        },
        OMNI_NIRI_MUTATION_NODE_COLUMN => {
            if (target.index >= column_count) return null;
            return target.index;
        },
        else => return null,
    }
}

fn adjustedTabbedActiveAfterRemoval(column: OmniNiriStateColumnInput, removed_row: usize) usize {
    if (column.window_count == 0) return 0;
    var active = column.active_tile_idx;

    if (removed_row == active) {
        if (column.window_count > 1 and removed_row >= column.window_count - 1) {
            active = if (removed_row > 0) removed_row - 1 else 0;
        }
    } else if (removed_row < active) {
        active = if (active > 0) active - 1 else 0;
    }

    return active;
}

fn clampedActiveAfterRemoval(column: OmniNiriStateColumnInput) usize {
    if (column.window_count <= 1) return 0;
    const max_idx_after = column.window_count - 2;
    return @min(column.active_tile_idx, max_idx_after);
}

fn appendTabbedRemovalEdits(
    column: OmniNiriStateColumnInput,
    column_index: usize,
    removed_row: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (column.is_tabbed == 0) return OMNI_OK;
    const remaining_count = column.window_count - 1;
    if (remaining_count == 0) return OMNI_OK;

    const updated_active = adjustedTabbedActiveAfterRemoval(column, removed_row);
    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
        std.math.cast(i64, column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        std.math.cast(i64, updated_active) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY,
        std.math.cast(i64, column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    return rc;
}

fn appendNonTabbedClampRemovalEdit(
    column: OmniNiriStateColumnInput,
    column_index: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (column.is_tabbed != 0) return OMNI_OK;
    const remaining_count = column.window_count - 1;
    if (remaining_count == 0) return OMNI_OK;

    const clamped_active = @min(column.active_tile_idx, remaining_count - 1);
    return addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
        std.math.cast(i64, column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        std.math.cast(i64, clamped_active) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
}

fn planMoveWindowVertical(
    columns: [*c]const OmniNiriStateColumnInput,
    selected: SelectedContext,
    direction: u8,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_column = columns[selected.column_index];
    if (source_column.window_count == 0) return OMNI_OK;

    const target_row_opt: ?usize = switch (direction) {
        OMNI_NIRI_DIRECTION_UP => if (selected.row_index + 1 < source_column.window_count) selected.row_index + 1 else null,
        OMNI_NIRI_DIRECTION_DOWN => if (selected.row_index > 0) selected.row_index - 1 else null,
        else => return OMNI_ERR_INVALID_ARGS,
    };

    const target_row = target_row_opt orelse return OMNI_OK;
    const target_window_index = source_column.window_start + target_row;

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS,
        std.math.cast(i64, selected.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    if (source_column.is_tabbed != 0) {
        if (selected.row_index == source_column.active_tile_idx) {
            rc = addMutationEdit(
                out_result,
                OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
                std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
                std.math.cast(i64, target_row) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
            );
            if (rc != OMNI_OK) return rc;
        } else if (target_row == source_column.active_tile_idx) {
            rc = addMutationEdit(
                out_result,
                OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
                std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
                std.math.cast(i64, selected.row_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
            );
            if (rc != OMNI_OK) return rc;
        }
    }

    rc = setMutationTargetWindow(out_result, selected.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planMoveWindowHorizontal(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
    direction: u8,
    infinite_loop: bool,
    max_windows_per_column: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_column = columns[selected.column_index];
    const source_col_i64 = std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE;
    const step: i64 = switch (direction) {
        OMNI_NIRI_DIRECTION_RIGHT => 1,
        OMNI_NIRI_DIRECTION_LEFT => -1,
        else => return OMNI_ERR_INVALID_ARGS,
    };

    const target_col_index = wrappedColumnIndex(source_col_i64 + step, column_count, infinite_loop) orelse return OMNI_OK;
    if (target_col_index == selected.column_index) return OMNI_OK;
    const target_column = columns[target_col_index];
    if (target_column.window_count >= max_windows_per_column) return OMNI_OK;

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX,
        std.math.cast(i64, selected.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_col_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_column.window_count) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    if (source_column.is_tabbed != 0) {
        const remaining_count = source_column.window_count - 1;
        if (remaining_count > 0) {
            const updated_active = adjustedTabbedActiveAfterRemoval(source_column, selected.row_index);
            rc = addMutationEdit(
                out_result,
                OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
                std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
                std.math.cast(i64, updated_active) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
            );
            if (rc != OMNI_OK) return rc;
            rc = addMutationEdit(
                out_result,
                OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY,
                std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
                -1,
                -1,
            );
            if (rc != OMNI_OK) return rc;
        }
    } else {
        const remaining_count = source_column.window_count - 1;
        if (remaining_count > 0) {
            const clamped_active = @min(source_column.active_tile_idx, remaining_count - 1);
            rc = addMutationEdit(
                out_result,
                OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
                std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
                std.math.cast(i64, clamped_active) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
            );
            if (rc != OMNI_OK) return rc;
        }
    }

    if (target_column.is_tabbed != 0) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY,
            std.math.cast(i64, target_col_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = setMutationTargetWindow(out_result, selected.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planSwapWindowHorizontal(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
    direction: u8,
    infinite_loop: bool,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_col_i64 = std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE;
    const step: i64 = switch (direction) {
        OMNI_NIRI_DIRECTION_RIGHT => 1,
        OMNI_NIRI_DIRECTION_LEFT => -1,
        else => return OMNI_ERR_INVALID_ARGS,
    };

    const target_col_index = wrappedColumnIndex(source_col_i64 + step, column_count, infinite_loop) orelse return OMNI_OK;
    if (target_col_index == selected.column_index) return OMNI_OK;

    const source_column = columns[selected.column_index];
    const target_column = columns[target_col_index];
    if (target_column.window_count == 0) return OMNI_OK;

    if (source_column.window_count == 1 and target_column.window_count == 1) {
        const rc_delegate = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN,
            std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            std.math.cast(i64, direction) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
        );
        if (rc_delegate != OMNI_OK) return rc_delegate;
        out_result.applied = 1;
        return OMNI_OK;
    }

    const source_active_row = @min(source_column.active_tile_idx, source_column.window_count - 1);
    const target_active_row = @min(target_column.active_tile_idx, target_column.window_count - 1);
    const source_active_window = source_column.window_start + source_active_row;
    const target_active_window = target_column.window_start + target_active_row;

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS,
        std.math.cast(i64, source_active_window) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_active_window) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_col_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        std.math.cast(i64, source_active_row) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
        std.math.cast(i64, target_col_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        std.math.cast(i64, target_active_row) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    if (source_column.is_tabbed != 0) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY,
            std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }
    if (target_column.is_tabbed != 0) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY,
            std.math.cast(i64, target_col_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    rc = setMutationTargetWindow(out_result, source_active_window);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planSwapWindowsByMove(
    columns: [*c]const OmniNiriStateColumnInput,
    source: SelectedContext,
    target: SelectedContext,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_column = columns[source.column_index];
    const target_column = columns[target.column_index];

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS,
        std.math.cast(i64, source.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    if (source.column_index != target.column_index) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT,
            std.math.cast(i64, source.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            std.math.cast(i64, target.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    if (source_column.is_tabbed != 0) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
            std.math.cast(i64, source.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            std.math.cast(i64, @min(source_column.active_tile_idx, source_column.window_count - 1)) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    if (target.column_index != source.column_index and target_column.is_tabbed != 0) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
            std.math.cast(i64, target.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            std.math.cast(i64, @min(target_column.active_tile_idx, target_column.window_count - 1)) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    rc = setMutationTargetWindow(out_result, source.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planInsertWindowByMove(
    columns: [*c]const OmniNiriStateColumnInput,
    source: SelectedContext,
    target: SelectedContext,
    insert_position: u8,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (insert_position != OMNI_NIRI_INSERT_BEFORE and insert_position != OMNI_NIRI_INSERT_AFTER) {
        return OMNI_ERR_INVALID_ARGS;
    }

    const source_column = columns[source.column_index];
    const target_column = columns[target.column_index];
    const same_column = source.column_index == target.column_index;

    var insert_row: usize = 0;
    if (same_column) {
        var current_target_row = target.row_index;
        if (source.row_index < target.row_index and current_target_row > 0) {
            current_target_row -= 1;
        }
        insert_row = if (insert_position == OMNI_NIRI_INSERT_BEFORE) current_target_row else current_target_row + 1;
    } else {
        insert_row = if (insert_position == OMNI_NIRI_INSERT_BEFORE) target.row_index else target.row_index + 1;
    }

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX,
        std.math.cast(i64, source.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, insert_row) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT,
        std.math.cast(i64, source.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    if (!same_column and source_column.window_count == 1) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
            std.math.cast(i64, source.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    if (same_column) {
        if (source_column.is_tabbed != 0) {
            const source_active_same = @min(source_column.active_tile_idx, source_column.window_count - 1);
            rc = addMutationEdit(
                out_result,
                OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
                std.math.cast(i64, source.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
                std.math.cast(i64, source_active_same) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
            );
            if (rc != OMNI_OK) return rc;
        }
    } else if (source_column.window_count > 1) {
        const source_active = clampedActiveAfterRemoval(source_column);
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
            std.math.cast(i64, source.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            std.math.cast(i64, source_active) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    if (target_column.is_tabbed != 0) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
            std.math.cast(i64, target.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            std.math.cast(i64, @min(target_column.active_tile_idx, target_column.window_count - 1)) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    rc = setMutationTargetWindow(out_result, source.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planMoveWindowToColumn(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
    target_column_index_raw: i64,
    out_result: *OmniNiriMutationResult,
) i32 {
    const target_column_index = parseColumnIndex(target_column_index_raw, column_count) orelse return OMNI_ERR_OUT_OF_RANGE;
    if (target_column_index == selected.column_index) return OMNI_OK;

    const source_column = columns[selected.column_index];
    const target_column = columns[target_column_index];

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX,
        std.math.cast(i64, selected.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_column.window_count) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = appendTabbedRemovalEdits(source_column, selected.column_index, selected.row_index, out_result);
    if (rc != OMNI_OK) return rc;
    rc = appendNonTabbedClampRemovalEdit(source_column, selected.column_index, out_result);
    if (rc != OMNI_OK) return rc;

    if (target_column.is_tabbed != 0) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY,
            std.math.cast(i64, target_column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = setMutationTargetWindow(out_result, selected.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planCreateColumnAndMove(
    columns: [*c]const OmniNiriStateColumnInput,
    selected: SelectedContext,
    direction: u8,
    max_visible_columns: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (direction != OMNI_NIRI_DIRECTION_LEFT and direction != OMNI_NIRI_DIRECTION_RIGHT) {
        return OMNI_ERR_INVALID_ARGS;
    }
    if (max_visible_columns == 0) return OMNI_ERR_INVALID_ARGS;

    const source_column = columns[selected.column_index];
    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW,
        std.math.cast(i64, selected.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, direction) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, max_visible_columns) orelse return OMNI_ERR_OUT_OF_RANGE,
    );
    if (rc != OMNI_OK) return rc;

    rc = appendTabbedRemovalEdits(source_column, selected.column_index, selected.row_index, out_result);
    if (rc != OMNI_OK) return rc;
    rc = appendNonTabbedClampRemovalEdit(source_column, selected.column_index, out_result);
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = setMutationTargetWindow(out_result, selected.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planInsertWindowInNewColumn(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
    insert_column_index_raw: i64,
    max_visible_columns: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (max_visible_columns == 0) return OMNI_ERR_INVALID_ARGS;
    const source_column = columns[selected.column_index];

    var insert_column_index: usize = 0;
    if (insert_column_index_raw > 0) {
        const raw_cast = std.math.cast(usize, insert_column_index_raw) orelse return OMNI_ERR_OUT_OF_RANGE;
        insert_column_index = @min(raw_cast, column_count);
    }

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW,
        std.math.cast(i64, selected.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, insert_column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, max_visible_columns) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = appendTabbedRemovalEdits(source_column, selected.column_index, selected.row_index, out_result);
    if (rc != OMNI_OK) return rc;
    rc = appendNonTabbedClampRemovalEdit(source_column, selected.column_index, out_result);
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = setMutationTargetWindow(out_result, selected.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planMoveColumn(
    column_count: usize,
    source_column_index: usize,
    direction: u8,
    infinite_loop: bool,
    out_result: *OmniNiriMutationResult,
) i32 {
    const step: i64 = switch (direction) {
        OMNI_NIRI_DIRECTION_RIGHT => 1,
        OMNI_NIRI_DIRECTION_LEFT => -1,
        else => return OMNI_ERR_INVALID_ARGS,
    };

    const source_col_i64 = std.math.cast(i64, source_column_index) orelse return OMNI_ERR_OUT_OF_RANGE;
    const target_column_index = wrappedColumnIndex(source_col_i64 + step, column_count, infinite_loop) orelse return OMNI_OK;
    if (target_column_index == source_column_index) return OMNI_OK;

    const rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS,
        std.math.cast(i64, source_column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, target_column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planConsumeWindow(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
    direction: u8,
    infinite_loop: bool,
    max_windows_per_column: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (direction != OMNI_NIRI_DIRECTION_LEFT and direction != OMNI_NIRI_DIRECTION_RIGHT) {
        return OMNI_ERR_INVALID_ARGS;
    }
    if (max_windows_per_column == 0) return OMNI_ERR_INVALID_ARGS;

    const current_column = columns[selected.column_index];
    if (current_column.window_count >= max_windows_per_column) return OMNI_OK;

    const step: i64 = if (direction == OMNI_NIRI_DIRECTION_RIGHT) 1 else -1;
    const current_col_i64 = std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE;
    const neighbor_index = wrappedColumnIndex(current_col_i64 + step, column_count, infinite_loop) orelse return OMNI_OK;
    if (neighbor_index == selected.column_index) return OMNI_OK;

    const neighbor_column = columns[neighbor_index];
    if (neighbor_column.window_count == 0) return OMNI_OK;

    const consumed_row: usize = if (direction == OMNI_NIRI_DIRECTION_RIGHT) 0 else neighbor_column.window_count - 1;
    const consumed_window_index = neighbor_column.window_start + consumed_row;
    const insert_row: usize = if (direction == OMNI_NIRI_DIRECTION_RIGHT) current_column.window_count else 0;

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX,
        std.math.cast(i64, consumed_window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, insert_row) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = appendTabbedRemovalEdits(neighbor_column, neighbor_index, consumed_row, out_result);
    if (rc != OMNI_OK) return rc;
    rc = appendNonTabbedClampRemovalEdit(neighbor_column, neighbor_index, out_result);
    if (rc != OMNI_OK) return rc;

    if (current_column.is_tabbed != 0) {
        if (direction == OMNI_NIRI_DIRECTION_LEFT) {
            rc = addMutationEdit(
                out_result,
                OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE,
                std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
                std.math.cast(i64, current_column.active_tile_idx + 1) orelse return OMNI_ERR_OUT_OF_RANGE,
                -1,
            );
            if (rc != OMNI_OK) return rc;
        }
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY,
            std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, neighbor_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = setMutationTargetWindow(out_result, selected.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planExpelWindow(
    columns: [*c]const OmniNiriStateColumnInput,
    selected: SelectedContext,
    direction: u8,
    max_visible_columns: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (direction != OMNI_NIRI_DIRECTION_LEFT and direction != OMNI_NIRI_DIRECTION_RIGHT) {
        return OMNI_ERR_INVALID_ARGS;
    }
    if (max_visible_columns == 0) return OMNI_ERR_INVALID_ARGS;

    const source_column = columns[selected.column_index];
    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW,
        std.math.cast(i64, selected.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, direction) orelse return OMNI_ERR_OUT_OF_RANGE,
        std.math.cast(i64, max_visible_columns) orelse return OMNI_ERR_OUT_OF_RANGE,
    );
    if (rc != OMNI_OK) return rc;

    rc = appendTabbedRemovalEdits(source_column, selected.column_index, selected.row_index, out_result);
    if (rc != OMNI_OK) return rc;
    rc = appendNonTabbedClampRemovalEdit(source_column, selected.column_index, out_result);
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = setMutationTargetWindow(out_result, selected.window_index);
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planCleanupEmptyColumn(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    source_column_index_raw: i64,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_column_index = parseColumnIndex(source_column_index_raw, column_count) orelse return OMNI_ERR_OUT_OF_RANGE;
    if (columns[source_column_index].window_count != 0) return OMNI_OK;
    // Preserve the root placeholder invariant in planner decisions.
    if (column_count <= 1) return OMNI_OK;

    const rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, source_column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planNormalizeColumnSizes(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (column_count <= 1) return OMNI_OK;

    var total_size: f64 = 0;
    for (0..column_count) |idx| {
        total_size += columns[idx].size_value;
    }
    if (total_size <= 0) return OMNI_OK;

    const avg_size = total_size / @as(f64, @floatFromInt(column_count));
    if (avg_size <= 0) return OMNI_OK;
    const factor = 1.0 / avg_size;

    const rc = addMutationEditWithScalars(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR,
        -1,
        -1,
        -1,
        -1,
        factor,
        0,
    );
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planNormalizeWindowSizes(
    columns: [*c]const OmniNiriStateColumnInput,
    windows: [*c]const OmniNiriStateWindowInput,
    column_count: usize,
    window_count: usize,
    source_column_index_raw: i64,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_column_index = parseColumnIndex(source_column_index_raw, column_count) orelse return OMNI_ERR_OUT_OF_RANGE;
    const column = columns[source_column_index];
    if (column.window_count == 0) return OMNI_OK;

    var total_size: f64 = 0;
    var idx: usize = 0;
    while (idx < column.window_count) : (idx += 1) {
        const window_index = column.window_start + idx;
        if (window_index >= window_count) return OMNI_ERR_OUT_OF_RANGE;
        total_size += windows[window_index].size_value;
    }
    if (total_size <= 0) return OMNI_OK;

    const avg_size = total_size / @as(f64, @floatFromInt(column.window_count));
    if (avg_size <= 0) return OMNI_OK;
    const factor = 1.0 / avg_size;

    const rc = addMutationEditWithScalars(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR,
        std.math.cast(i64, source_column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
        factor,
        0,
    );
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planBalanceSizes(
    column_count: usize,
    max_visible_columns: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (column_count == 0) return OMNI_OK;
    if (max_visible_columns == 0) return OMNI_ERR_INVALID_ARGS;

    const balanced_width = 1.0 / @as(f64, @floatFromInt(max_visible_columns));
    const rc = addMutationEditWithScalars(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS,
        -1,
        -1,
        std.math.cast(i64, max_visible_columns) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        balanced_width,
        0,
    );
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planAddWindow(
    columns: [*c]const OmniNiriStateColumnInput,
    windows: [*c]const OmniNiriStateWindowInput,
    column_count: usize,
    window_count: usize,
    selected_target: ?NodeTarget,
    focused_window_index_raw: i64,
    incoming_spawn_mode: u8,
    max_visible_columns: usize,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (max_visible_columns == 0) return OMNI_ERR_INVALID_ARGS;
    if (column_count == 0) return OMNI_OK;

    if (window_count == 0) {
        for (0..column_count) |idx| {
            if (columns[idx].window_count == 0) {
                const rc_empty = addMutationEdit(
                    out_result,
                    OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN,
                    std.math.cast(i64, idx) orelse return OMNI_ERR_OUT_OF_RANGE,
                    -1,
                    std.math.cast(i64, max_visible_columns) orelse return OMNI_ERR_OUT_OF_RANGE,
                    -1,
                );
                if (rc_empty != OMNI_OK) return rc_empty;
                out_result.applied = 1;
                return OMNI_OK;
            }
        }
    }

    var reference_column_index: ?usize = null;
    if (focused_window_index_raw >= 0) {
        var focused: SelectedContext = undefined;
        const focused_rc = parseWindowContextByIndex(
            columns,
            windows,
            column_count,
            window_count,
            focused_window_index_raw,
            &focused,
        );
        if (focused_rc == OMNI_OK) {
            reference_column_index = focused.column_index;
        }
    }

    if (reference_column_index == null) {
        if (selected_target) |target| {
            reference_column_index = columnIndexForNodeTarget(windows, column_count, target);
        }
    }

    if (reference_column_index == null) {
        reference_column_index = column_count - 1;
    }

    if (incoming_spawn_mode == OMNI_NIRI_SPAWN_FOCUSED_COLUMN) {
        const rc_focused = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN,
            std.math.cast(i64, reference_column_index.?) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
            std.math.cast(i64, max_visible_columns) orelse return OMNI_ERR_OUT_OF_RANGE,
            -1,
        );
        if (rc_focused != OMNI_OK) return rc_focused;
        out_result.applied = 1;
        return OMNI_OK;
    }

    if (incoming_spawn_mode != OMNI_NIRI_SPAWN_NEW_COLUMN) {
        return OMNI_ERR_INVALID_ARGS;
    }

    const rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN,
        std.math.cast(i64, reference_column_index.?) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        std.math.cast(i64, max_visible_columns) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
    );
    if (rc != OMNI_OK) return rc;
    out_result.applied = 1;
    return OMNI_OK;
}

fn planRemoveWindow(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_column = columns[selected.column_index];

    var rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX,
        std.math.cast(i64, selected.window_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    rc = appendTabbedRemovalEdits(source_column, selected.column_index, selected.row_index, out_result);
    if (rc != OMNI_OK) return rc;
    rc = appendNonTabbedClampRemovalEdit(source_column, selected.column_index, out_result);
    if (rc != OMNI_OK) return rc;

    rc = addMutationEdit(
        out_result,
        OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY,
        std.math.cast(i64, selected.column_index) orelse return OMNI_ERR_OUT_OF_RANGE,
        -1,
        -1,
        -1,
    );
    if (rc != OMNI_OK) return rc;

    if (source_column.window_count == 1 and column_count > 1) {
        rc = addMutationEdit(
            out_result,
            OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS,
            -1,
            -1,
            -1,
            -1,
        );
        if (rc != OMNI_OK) return rc;
    }

    out_result.applied = 1;
    return OMNI_OK;
}

fn planValidateSelection(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected_target: ?NodeTarget,
    out_result: *OmniNiriMutationResult,
) i32 {
    if (selected_target) |target| {
        return setMutationTargetNode(out_result, target.kind, target.index);
    }

    if (column_count == 0) return OMNI_OK;
    for (0..column_count) |idx| {
        const column = columns[idx];
        if (column.window_count > 0) {
            return setMutationTargetWindow(out_result, column.window_start);
        }
    }

    return OMNI_OK;
}

fn planFallbackSelectionOnRemoval(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    selected: SelectedContext,
    out_result: *OmniNiriMutationResult,
) i32 {
    const source_column = columns[selected.column_index];
    if (source_column.window_count == 0) return OMNI_OK;

    if (selected.row_index + 1 < source_column.window_count) {
        return setMutationTargetWindow(out_result, source_column.window_start + selected.row_index + 1);
    }

    if (selected.row_index > 0) {
        return setMutationTargetWindow(out_result, source_column.window_start + selected.row_index - 1);
    }

    if (selected.column_index > 0) {
        const prev_column = columns[selected.column_index - 1];
        if (prev_column.window_count > 0) {
            return setMutationTargetWindow(out_result, prev_column.window_start);
        }
    }

    if (selected.column_index + 1 < column_count) {
        const next_idx = selected.column_index + 1;
        const next_column = columns[next_idx];
        if (next_column.window_count > 0) {
            return setMutationTargetWindow(out_result, next_column.window_start);
        }
    }

    var idx: usize = 0;
    while (idx < column_count) : (idx += 1) {
        if (idx == selected.column_index) continue;
        const column = columns[idx];
        if (column.window_count > 0) {
            return setMutationTargetWindow(out_result, column.window_start);
        }
    }

    return OMNI_OK;
}

pub fn omni_niri_mutation_plan_impl(
    columns: [*c]const OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const OmniNiriStateWindowInput,
    window_count: usize,
    request: [*c]const OmniNiriMutationRequest,
    out_result: [*c]OmniNiriMutationResult,
) i32 {
    if (request == null or out_result == null) return OMNI_ERR_INVALID_ARGS;
    if (column_count > 0 and columns == null) return OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return OMNI_ERR_INVALID_ARGS;

    var resolved_result: OmniNiriMutationResult = undefined;
    initMutationResult(&resolved_result);

    const req = request[0];

    const rc: i32 = blk: {
        switch (req.op) {
            OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL,
            OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL,
            => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                break :blk planMoveWindowVertical(columns, source, req.direction, &resolved_result);
            },
            OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                const max_windows_per_column = std.math.cast(usize, req.max_windows_per_column) orelse break :blk OMNI_ERR_INVALID_ARGS;
                if (max_windows_per_column == 0) break :blk OMNI_ERR_INVALID_ARGS;
                break :blk planMoveWindowHorizontal(
                    columns,
                    column_count,
                    source,
                    req.direction,
                    req.infinite_loop != 0,
                    max_windows_per_column,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                break :blk planSwapWindowHorizontal(
                    columns,
                    column_count,
                    source,
                    req.direction,
                    req.infinite_loop != 0,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                var target: SelectedContext = undefined;
                const target_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.target_window_index,
                    &target,
                );
                if (target_rc != OMNI_OK) break :blk target_rc;
                break :blk planSwapWindowsByMove(columns, source, target, &resolved_result);
            },
            OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                var target: SelectedContext = undefined;
                const target_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.target_window_index,
                    &target,
                );
                if (target_rc != OMNI_OK) break :blk target_rc;
                break :blk planInsertWindowByMove(
                    columns,
                    source,
                    target,
                    req.insert_position,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                break :blk planMoveWindowToColumn(
                    columns,
                    column_count,
                    source,
                    req.target_column_index,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                const max_visible_columns = std.math.cast(usize, req.max_visible_columns) orelse break :blk OMNI_ERR_INVALID_ARGS;
                break :blk planCreateColumnAndMove(
                    columns,
                    source,
                    req.direction,
                    max_visible_columns,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                const max_visible_columns = std.math.cast(usize, req.max_visible_columns) orelse break :blk OMNI_ERR_INVALID_ARGS;
                break :blk planInsertWindowInNewColumn(
                    columns,
                    column_count,
                    source,
                    req.insert_column_index,
                    max_visible_columns,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_MOVE_COLUMN => {
                const source_column_index = parseColumnIndex(req.source_column_index, column_count) orelse break :blk OMNI_ERR_OUT_OF_RANGE;
                break :blk planMoveColumn(
                    column_count,
                    source_column_index,
                    req.direction,
                    req.infinite_loop != 0,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                const max_windows_per_column = std.math.cast(usize, req.max_windows_per_column) orelse break :blk OMNI_ERR_INVALID_ARGS;
                break :blk planConsumeWindow(
                    columns,
                    column_count,
                    source,
                    req.direction,
                    req.infinite_loop != 0,
                    max_windows_per_column,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk source_rc;
                const max_visible_columns = std.math.cast(usize, req.max_visible_columns) orelse break :blk OMNI_ERR_INVALID_ARGS;
                break :blk planExpelWindow(
                    columns,
                    source,
                    req.direction,
                    max_visible_columns,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN => break :blk planCleanupEmptyColumn(
                columns,
                column_count,
                req.source_column_index,
                &resolved_result,
            ),
            OMNI_NIRI_MUTATION_OP_NORMALIZE_COLUMN_SIZES => break :blk planNormalizeColumnSizes(
                columns,
                column_count,
                &resolved_result,
            ),
            OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES => break :blk planNormalizeWindowSizes(
                columns,
                windows,
                column_count,
                window_count,
                req.source_column_index,
                &resolved_result,
            ),
            OMNI_NIRI_MUTATION_OP_BALANCE_SIZES => {
                const max_visible_columns = std.math.cast(usize, req.max_visible_columns) orelse break :blk OMNI_ERR_INVALID_ARGS;
                break :blk planBalanceSizes(
                    column_count,
                    max_visible_columns,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_ADD_WINDOW => {
                const max_visible_columns = std.math.cast(usize, req.max_visible_columns) orelse break :blk OMNI_ERR_INVALID_ARGS;
                if (max_visible_columns == 0) break :blk OMNI_ERR_INVALID_ARGS;

                var selected_target: ?NodeTarget = null;
                const selected_rc = parseNodeTargetRequest(
                    column_count,
                    window_count,
                    req.selected_node_kind,
                    req.selected_node_index,
                    &selected_target,
                );
                if (selected_rc == OMNI_ERR_INVALID_ARGS) break :blk selected_rc;
                if (selected_rc == OMNI_ERR_OUT_OF_RANGE) {
                    selected_target = null;
                } else if (selected_rc != OMNI_OK) {
                    break :blk selected_rc;
                }

                break :blk planAddWindow(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    selected_target,
                    req.focused_window_index,
                    req.incoming_spawn_mode,
                    max_visible_columns,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk OMNI_OK;
                break :blk planRemoveWindow(
                    columns,
                    column_count,
                    source,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION => {
                var selected_target: ?NodeTarget = null;
                const selected_rc = parseNodeTargetRequest(
                    column_count,
                    window_count,
                    req.selected_node_kind,
                    req.selected_node_index,
                    &selected_target,
                );
                if (selected_rc == OMNI_ERR_INVALID_ARGS) break :blk selected_rc;
                if (selected_rc == OMNI_ERR_OUT_OF_RANGE) {
                    selected_target = null;
                } else if (selected_rc != OMNI_OK) {
                    break :blk selected_rc;
                }

                break :blk planValidateSelection(
                    columns,
                    column_count,
                    selected_target,
                    &resolved_result,
                );
            },
            OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL => {
                var source: SelectedContext = undefined;
                const source_rc = parseWindowContextByIndex(
                    columns,
                    windows,
                    column_count,
                    window_count,
                    req.source_window_index,
                    &source,
                );
                if (source_rc != OMNI_OK) break :blk OMNI_OK;

                break :blk planFallbackSelectionOnRemoval(
                    columns,
                    column_count,
                    source,
                    &resolved_result,
                );
            },
            else => break :blk OMNI_ERR_INVALID_ARGS,
        }
    };

    if (rc != OMNI_OK) return rc;

    out_result[0] = resolved_result;
    return OMNI_OK;
}
