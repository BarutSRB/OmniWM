const std = @import("std");
const abi = @import("abi_types.zig");
const geometry = @import("geometry.zig");
const interaction = @import("interaction.zig");
const layout_pass = @import("layout_pass.zig");
const state_validation = @import("state_validation.zig");
const navigation = @import("navigation.zig");
const mutation = @import("mutation.zig");
const workspace = @import("workspace.zig");

const ID_SLOT_COUNT: usize = abi.MAX_WINDOWS * 2;
const EMPTY_SLOT: i64 = -1;

pub const OmniNiriLayoutContext = extern struct {
    interaction_window_count: usize,
    interaction_windows: [abi.MAX_WINDOWS]abi.OmniNiriHitTestWindow,
    column_count: usize,
    column_dropzones: [abi.MAX_WINDOWS]abi.OmniNiriColumnDropzoneMeta,

    runtime_column_count: usize,
    runtime_columns: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeColumnState,
    runtime_window_count: usize,
    runtime_windows: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,

    runtime_column_id_slots: [ID_SLOT_COUNT]i64,
    runtime_window_id_slots: [ID_SLOT_COUNT]i64,

    last_delta_generation: u64,
    last_delta_column_count: usize,
    last_delta_columns: [abi.MAX_WINDOWS]abi.OmniNiriDeltaColumnRecord,
    last_delta_window_count: usize,
    last_delta_windows: [abi.MAX_WINDOWS]abi.OmniNiriDeltaWindowRecord,
    last_delta_removed_column_count: usize,
    last_delta_removed_column_ids: [abi.MAX_WINDOWS]abi.OmniUuid128,
    last_delta_removed_window_count: usize,
    last_delta_removed_window_ids: [abi.MAX_WINDOWS]abi.OmniUuid128,
    last_delta_refresh_count: u8,
    last_delta_refresh_column_ids: [abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS]abi.OmniUuid128,
    last_delta_reset_all_column_cached_widths: u8,
    last_delta_has_delegate_move_column: u8,
    last_delta_delegate_move_column_id: abi.OmniUuid128,
    last_delta_delegate_move_direction: u8,
    last_delta_has_target_window_id: u8,
    last_delta_target_window_id: abi.OmniUuid128,
    last_delta_has_target_node_id: u8,
    last_delta_target_node_kind: u8,
    last_delta_target_node_id: abi.OmniUuid128,
    last_delta_has_source_selection_window_id: u8,
    last_delta_source_selection_window_id: abi.OmniUuid128,
    last_delta_has_target_selection_window_id: u8,
    last_delta_target_selection_window_id: abi.OmniUuid128,
    last_delta_has_moved_window_id: u8,
    last_delta_moved_window_id: abi.OmniUuid128,
};

const RuntimeState = struct {
    column_count: usize,
    columns: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeColumnState,
    window_count: usize,
    windows: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,
    column_id_slots: [ID_SLOT_COUNT]i64,
    window_id_slots: [ID_SLOT_COUNT]i64,
};

const MutationApplyHints = struct {
    refresh_count: usize,
    refresh_column_ids: [abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS]abi.OmniUuid128,
    reset_all_column_cached_widths: bool,
    has_delegate_move_column: bool,
    delegate_move_column_id: abi.OmniUuid128,
    delegate_move_direction: u8,
};

const TxnDeltaMeta = struct {
    refresh_count: usize,
    refresh_column_ids: [abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS]abi.OmniUuid128,
    reset_all_column_cached_widths: bool,
    has_delegate_move_column: bool,
    delegate_move_column_id: abi.OmniUuid128,
    delegate_move_direction: u8,
    has_target_window_id: bool,
    target_window_id: abi.OmniUuid128,
    has_target_node_id: bool,
    target_node_kind: u8,
    target_node_id: abi.OmniUuid128,
    has_source_selection_window_id: bool,
    source_selection_window_id: abi.OmniUuid128,
    has_target_selection_window_id: bool,
    target_selection_window_id: abi.OmniUuid128,
    has_moved_window_id: bool,
    moved_window_id: abi.OmniUuid128,
};

fn zeroUuid() abi.OmniUuid128 {
    return .{ .bytes = [_]u8{0} ** 16 };
}

fn initMutationApplyHints() MutationApplyHints {
    return .{
        .refresh_count = 0,
        .refresh_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS,
        .reset_all_column_cached_widths = false,
        .has_delegate_move_column = false,
        .delegate_move_column_id = zeroUuid(),
        .delegate_move_direction = 0,
    };
}

fn initTxnDeltaMeta() TxnDeltaMeta {
    return .{
        .refresh_count = 0,
        .refresh_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS,
        .reset_all_column_cached_widths = false,
        .has_delegate_move_column = false,
        .delegate_move_column_id = zeroUuid(),
        .delegate_move_direction = 0,
        .has_target_window_id = false,
        .target_window_id = zeroUuid(),
        .has_target_node_id = false,
        .target_node_kind = abi.OMNI_NIRI_MUTATION_NODE_NONE,
        .target_node_id = zeroUuid(),
        .has_source_selection_window_id = false,
        .source_selection_window_id = zeroUuid(),
        .has_target_selection_window_id = false,
        .target_selection_window_id = zeroUuid(),
        .has_moved_window_id = false,
        .moved_window_id = zeroUuid(),
    };
}

fn resetDeltaBuffers(ctx: *OmniNiriLayoutContext) void {
    ctx.last_delta_generation = 0;
    ctx.last_delta_column_count = 0;
    ctx.last_delta_window_count = 0;
    ctx.last_delta_removed_column_count = 0;
    ctx.last_delta_removed_window_count = 0;
    ctx.last_delta_refresh_count = 0;
    ctx.last_delta_reset_all_column_cached_widths = 0;
    ctx.last_delta_has_delegate_move_column = 0;
    ctx.last_delta_delegate_move_column_id = zeroUuid();
    ctx.last_delta_delegate_move_direction = 0;
    ctx.last_delta_has_target_window_id = 0;
    ctx.last_delta_target_window_id = zeroUuid();
    ctx.last_delta_has_target_node_id = 0;
    ctx.last_delta_target_node_kind = abi.OMNI_NIRI_MUTATION_NODE_NONE;
    ctx.last_delta_target_node_id = zeroUuid();
    ctx.last_delta_has_source_selection_window_id = 0;
    ctx.last_delta_source_selection_window_id = zeroUuid();
    ctx.last_delta_has_target_selection_window_id = 0;
    ctx.last_delta_target_selection_window_id = zeroUuid();
    ctx.last_delta_has_moved_window_id = 0;
    ctx.last_delta_moved_window_id = zeroUuid();
}

fn initMutationApplyResult(out_result: [*c]abi.OmniNiriMutationApplyResult) void {
    out_result[0] = .{
        .applied = 0,
        .has_target_window_id = 0,
        .target_window_id = zeroUuid(),
        .has_target_node_id = 0,
        .target_node_kind = abi.OMNI_NIRI_MUTATION_NODE_NONE,
        .target_node_id = zeroUuid(),
        .refresh_tabbed_visibility_count = 0,
        .refresh_tabbed_visibility_column_ids = [_]abi.OmniUuid128{zeroUuid()} ** abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS,
        .reset_all_column_cached_widths = 0,
        .has_delegate_move_column = 0,
        .delegate_move_column_id = zeroUuid(),
        .delegate_move_direction = 0,
    };
}

fn initWorkspaceApplyResult(out_result: [*c]abi.OmniNiriWorkspaceApplyResult) void {
    out_result[0] = .{
        .applied = 0,
        .has_source_selection_window_id = 0,
        .source_selection_window_id = zeroUuid(),
        .has_target_selection_window_id = 0,
        .target_selection_window_id = zeroUuid(),
        .has_moved_window_id = 0,
        .moved_window_id = zeroUuid(),
    };
}

fn initNavigationApplyResult(out_result: [*c]abi.OmniNiriNavigationApplyResult) void {
    out_result[0] = .{
        .applied = 0,
        .has_target_window_id = 0,
        .target_window_id = zeroUuid(),
        .update_source_active_tile = 0,
        .source_column_id = zeroUuid(),
        .source_active_tile_idx = -1,
        .update_target_active_tile = 0,
        .target_column_id = zeroUuid(),
        .target_active_tile_idx = -1,
        .refresh_tabbed_visibility_source = 0,
        .refresh_source_column_id = zeroUuid(),
        .refresh_tabbed_visibility_target = 0,
        .refresh_target_column_id = zeroUuid(),
    };
}

fn resetContext(ctx: *OmniNiriLayoutContext) void {
    ctx.interaction_window_count = 0;
    ctx.column_count = 0;

    ctx.runtime_column_count = 0;
    ctx.runtime_window_count = 0;

    for (0..ID_SLOT_COUNT) |idx| {
        ctx.runtime_column_id_slots[idx] = EMPTY_SLOT;
        ctx.runtime_window_id_slots[idx] = EMPTY_SLOT;
    }

    resetDeltaBuffers(ctx);
}

fn asMutableContext(context: [*c]OmniNiriLayoutContext) ?*OmniNiriLayoutContext {
    if (context == null) return null;
    const ptr: *OmniNiriLayoutContext = @ptrCast(&context[0]);
    return ptr;
}

fn asConstContext(context: [*c]const OmniNiriLayoutContext) ?*const OmniNiriLayoutContext {
    if (context == null) return null;
    const ptr: *const OmniNiriLayoutContext = @ptrCast(&context[0]);
    return ptr;
}

fn contextHitWindowsPtr(ctx: *const OmniNiriLayoutContext) [*c]const abi.OmniNiriHitTestWindow {
    if (ctx.interaction_window_count == 0) return null;
    const ptr: *const abi.OmniNiriHitTestWindow = &ctx.interaction_windows[0];
    return @ptrCast(ptr);
}

fn runtimeColumnsStatePtr(state: *const RuntimeState) [*c]const abi.OmniNiriStateColumnInput {
    if (state.column_count == 0) return null;
    const ptr: *const abi.OmniNiriStateColumnInput = @ptrCast(&state.columns[0]);
    return @ptrCast(ptr);
}

fn runtimeWindowsStatePtr(state: *const RuntimeState) [*c]const abi.OmniNiriStateWindowInput {
    if (state.window_count == 0) return null;
    const ptr: *const abi.OmniNiriStateWindowInput = @ptrCast(&state.windows[0]);
    return @ptrCast(ptr);
}

fn clearSlots(slots: *[ID_SLOT_COUNT]i64) void {
    for (0..ID_SLOT_COUNT) |idx| {
        slots[idx] = EMPTY_SLOT;
    }
}

fn uuidEqual(a: abi.OmniUuid128, b: abi.OmniUuid128) bool {
    return std.mem.eql(u8, a.bytes[0..], b.bytes[0..]);
}

fn uuidHash(uuid: abi.OmniUuid128) u64 {
    var hash: u64 = 1469598103934665603;
    for (uuid.bytes) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 1099511628211;
    }
    return hash;
}

fn slotForUuid(uuid: abi.OmniUuid128) usize {
    const hashed = uuidHash(uuid) % @as(u64, ID_SLOT_COUNT);
    return @intCast(hashed);
}

fn insertColumnIdSlot(state: *RuntimeState, column_index: usize) i32 {
    const column_id = state.columns[column_index].column_id;
    var slot = slotForUuid(column_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.column_id_slots[slot];
        if (raw == EMPTY_SLOT) {
            state.column_id_slots[slot] = std.math.cast(i64, column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            return abi.OMNI_OK;
        }

        const existing_index = std.math.cast(usize, raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (existing_index >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;
        if (uuidEqual(state.columns[existing_index].column_id, column_id)) return abi.OMNI_ERR_INVALID_ARGS;

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return abi.OMNI_ERR_OUT_OF_RANGE;
}

fn insertWindowIdSlot(state: *RuntimeState, window_index: usize) i32 {
    const window_id = state.windows[window_index].window_id;
    var slot = slotForUuid(window_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.window_id_slots[slot];
        if (raw == EMPTY_SLOT) {
            state.window_id_slots[slot] = std.math.cast(i64, window_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            return abi.OMNI_OK;
        }

        const existing_index = std.math.cast(usize, raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (existing_index >= state.window_count) return abi.OMNI_ERR_OUT_OF_RANGE;
        if (uuidEqual(state.windows[existing_index].window_id, window_id)) return abi.OMNI_ERR_INVALID_ARGS;

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return abi.OMNI_ERR_OUT_OF_RANGE;
}

fn rebuildRuntimeIdCaches(state: *RuntimeState) i32 {
    clearSlots(&state.column_id_slots);
    clearSlots(&state.window_id_slots);

    for (0..state.column_count) |idx| {
        const rc = insertColumnIdSlot(state, idx);
        if (rc != abi.OMNI_OK) return rc;
    }

    for (0..state.window_count) |idx| {
        const rc = insertWindowIdSlot(state, idx);
        if (rc != abi.OMNI_OK) return rc;
    }

    return abi.OMNI_OK;
}

fn findColumnIndexById(state: *const RuntimeState, column_id: abi.OmniUuid128) ?usize {
    if (state.column_count == 0) return null;
    var slot = slotForUuid(column_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.column_id_slots[slot];
        if (raw == EMPTY_SLOT) return null;

        const idx = std.math.cast(usize, raw) orelse return null;
        if (idx < state.column_count and uuidEqual(state.columns[idx].column_id, column_id)) {
            return idx;
        }

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return null;
}

fn findColumnIndexByIdLinear(state: *const RuntimeState, column_id: abi.OmniUuid128) ?usize {
    for (0..state.column_count) |idx| {
        if (uuidEqual(state.columns[idx].column_id, column_id)) return idx;
    }
    return null;
}

fn findColumnIndexByIdCoherent(state: *const RuntimeState, column_id: abi.OmniUuid128) ?usize {
    return findColumnIndexById(state, column_id) orelse findColumnIndexByIdLinear(state, column_id);
}

fn findWindowIndexById(state: *const RuntimeState, window_id: abi.OmniUuid128) ?usize {
    if (state.window_count == 0) return null;
    var slot = slotForUuid(window_id);

    var probe: usize = 0;
    while (probe < ID_SLOT_COUNT) : (probe += 1) {
        const raw = state.window_id_slots[slot];
        if (raw == EMPTY_SLOT) return null;

        const idx = std.math.cast(usize, raw) orelse return null;
        if (idx < state.window_count and uuidEqual(state.windows[idx].window_id, window_id)) {
            return idx;
        }

        slot = (slot + 1) % ID_SLOT_COUNT;
    }

    return null;
}

fn findWindowIndexByIdLinear(state: *const RuntimeState, window_id: abi.OmniUuid128) ?usize {
    for (0..state.window_count) |idx| {
        if (uuidEqual(state.windows[idx].window_id, window_id)) return idx;
    }
    return null;
}

fn findWindowIndexByIdCoherent(state: *const RuntimeState, window_id: abi.OmniUuid128) ?usize {
    return findWindowIndexById(state, window_id) orelse findWindowIndexByIdLinear(state, window_id);
}

fn runtimeStateFromContext(ctx: *const OmniNiriLayoutContext) RuntimeState {
    return .{
        .column_count = ctx.runtime_column_count,
        .columns = ctx.runtime_columns,
        .window_count = ctx.runtime_window_count,
        .windows = ctx.runtime_windows,
        .column_id_slots = ctx.runtime_column_id_slots,
        .window_id_slots = ctx.runtime_window_id_slots,
    };
}

fn commitRuntimeState(ctx: *OmniNiriLayoutContext, state: *const RuntimeState) void {
    ctx.runtime_column_count = state.column_count;
    ctx.runtime_columns = state.columns;
    ctx.runtime_window_count = state.window_count;
    ctx.runtime_windows = state.windows;
    ctx.runtime_column_id_slots = state.column_id_slots;
    ctx.runtime_window_id_slots = state.window_id_slots;
}

fn initTxnResult(out_result: [*c]abi.OmniNiriTxnResult) void {
    out_result[0] = .{
        .applied = 0,
        .kind = 0,
        .structural_animation_active = 0,
        .has_target_window_id = 0,
        .target_window_id = zeroUuid(),
        .has_target_node_id = 0,
        .target_node_kind = abi.OMNI_NIRI_MUTATION_NODE_NONE,
        .target_node_id = zeroUuid(),
        .changed_source_context = 0,
        .changed_target_context = 0,
        .error_code = abi.OMNI_OK,
        .delta_column_count = 0,
        .delta_window_count = 0,
        .removed_column_count = 0,
        .removed_window_count = 0,
    };
}

fn storeTxnDeltaForContext(
    ctx: *OmniNiriLayoutContext,
    pre_state: ?*const RuntimeState,
    meta: *const TxnDeltaMeta,
) i32 {
    var post_state = runtimeStateFromContext(ctx);

    ctx.last_delta_generation +%= 1;
    ctx.last_delta_column_count = post_state.column_count;
    ctx.last_delta_window_count = post_state.window_count;
    ctx.last_delta_removed_column_count = 0;
    ctx.last_delta_removed_window_count = 0;

    for (0..post_state.column_count) |idx| {
        const column = post_state.columns[idx];
        ctx.last_delta_columns[idx] = .{
            .column_id = column.column_id,
            .order_index = idx,
            .window_start = column.window_start,
            .window_count = column.window_count,
            .active_tile_idx = column.active_tile_idx,
            .is_tabbed = column.is_tabbed,
            .size_value = column.size_value,
            .width_kind = column.width_kind,
            .is_full_width = column.is_full_width,
            .has_saved_width = column.has_saved_width,
            .saved_width_kind = column.saved_width_kind,
            .saved_width_value = column.saved_width_value,
        };
    }

    for (0..post_state.window_count) |idx| {
        const window = post_state.windows[idx];
        var row_index: usize = 0;
        if (window.column_index < post_state.column_count) {
            const column = post_state.columns[window.column_index];
            if (idx >= column.window_start and idx < column.window_start + column.window_count) {
                row_index = idx - column.window_start;
            }
        }

        ctx.last_delta_windows[idx] = .{
            .window_id = window.window_id,
            .column_id = window.column_id,
            .column_order_index = window.column_index,
            .row_index = row_index,
            .size_value = window.size_value,
            .height_kind = window.height_kind,
            .height_value = window.height_value,
        };
    }

    if (pre_state) |before| {
        for (0..before.column_count) |idx| {
            const column_id = before.columns[idx].column_id;
            if (findColumnIndexById(&post_state, column_id) == null) {
                if (ctx.last_delta_removed_column_count >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
                ctx.last_delta_removed_column_ids[ctx.last_delta_removed_column_count] = column_id;
                ctx.last_delta_removed_column_count += 1;
            }
        }

        for (0..before.window_count) |idx| {
            const window_id = before.windows[idx].window_id;
            if (findWindowIndexById(&post_state, window_id) == null) {
                if (ctx.last_delta_removed_window_count >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
                ctx.last_delta_removed_window_ids[ctx.last_delta_removed_window_count] = window_id;
                ctx.last_delta_removed_window_count += 1;
            }
        }
    }

    ctx.last_delta_refresh_count = std.math.cast(u8, @min(meta.refresh_count, abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS)) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    const refresh_count: usize = @intCast(ctx.last_delta_refresh_count);
    for (0..refresh_count) |idx| {
        ctx.last_delta_refresh_column_ids[idx] = meta.refresh_column_ids[idx];
    }
    ctx.last_delta_reset_all_column_cached_widths = @intFromBool(meta.reset_all_column_cached_widths);
    ctx.last_delta_has_delegate_move_column = @intFromBool(meta.has_delegate_move_column);
    ctx.last_delta_delegate_move_column_id = meta.delegate_move_column_id;
    ctx.last_delta_delegate_move_direction = meta.delegate_move_direction;

    ctx.last_delta_has_target_window_id = @intFromBool(meta.has_target_window_id);
    ctx.last_delta_target_window_id = meta.target_window_id;
    ctx.last_delta_has_target_node_id = @intFromBool(meta.has_target_node_id);
    ctx.last_delta_target_node_kind = meta.target_node_kind;
    ctx.last_delta_target_node_id = meta.target_node_id;
    ctx.last_delta_has_source_selection_window_id = @intFromBool(meta.has_source_selection_window_id);
    ctx.last_delta_source_selection_window_id = meta.source_selection_window_id;
    ctx.last_delta_has_target_selection_window_id = @intFromBool(meta.has_target_selection_window_id);
    ctx.last_delta_target_selection_window_id = meta.target_selection_window_id;
    ctx.last_delta_has_moved_window_id = @intFromBool(meta.has_moved_window_id);
    ctx.last_delta_moved_window_id = meta.moved_window_id;

    return abi.OMNI_OK;
}

fn validateRuntimeState(state: *RuntimeState) i32 {
    var validation = abi.OmniNiriStateValidationResult{
        .column_count = 0,
        .window_count = 0,
        .first_invalid_column_index = -1,
        .first_invalid_window_index = -1,
        .first_error_code = abi.OMNI_OK,
    };

    return state_validation.omni_niri_validate_state_snapshot_impl(
        runtimeColumnsStatePtr(state),
        state.column_count,
        runtimeWindowsStatePtr(state),
        state.window_count,
        &validation,
    );
}

fn recomputeRuntimeTopology(state: *RuntimeState) i32 {
    if (state.column_count > abi.MAX_WINDOWS or state.window_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    var cursor: usize = 0;
    for (0..state.column_count) |column_idx| {
        var column = &state.columns[column_idx];
        if (column.window_count > state.window_count - cursor) {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }

        column.window_start = cursor;
        if (column.window_count == 0) {
            column.active_tile_idx = 0;
        } else if (column.active_tile_idx >= column.window_count) {
            column.active_tile_idx = column.window_count - 1;
        }

        for (0..column.window_count) |row_idx| {
            const window_idx = cursor + row_idx;
            state.windows[window_idx].column_index = column_idx;
            state.windows[window_idx].column_id = column.column_id;
        }

        cursor += column.window_count;
    }

    if (cursor != state.window_count) return abi.OMNI_ERR_INVALID_ARGS;
    return abi.OMNI_OK;
}

fn refreshRuntimeState(state: *RuntimeState) i32 {
    const topology_rc = recomputeRuntimeTopology(state);
    if (topology_rc != abi.OMNI_OK) return topology_rc;

    const validation_rc = validateRuntimeState(state);
    if (validation_rc != abi.OMNI_OK) return validation_rc;

    return rebuildRuntimeIdCaches(state);
}

fn refreshRuntimeStateFast(state: *RuntimeState) i32 {
    // Fast-path recompute used in hot mutation loops. Callers should validate at txn boundaries.
    const topology_rc = recomputeRuntimeTopology(state);
    if (topology_rc != abi.OMNI_OK) return topology_rc;
    return rebuildRuntimeIdCaches(state);
}

fn removeWindowAt(state: *RuntimeState, index: usize) abi.OmniNiriRuntimeWindowState {
    const removed = state.windows[index];
    var cursor = index;
    while (cursor + 1 < state.window_count) : (cursor += 1) {
        state.windows[cursor] = state.windows[cursor + 1];
    }
    state.window_count -= 1;
    return removed;
}

fn insertWindowAt(state: *RuntimeState, index: usize, window: abi.OmniNiriRuntimeWindowState) i32 {
    if (state.window_count >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (index > state.window_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    var cursor = state.window_count;
    while (cursor > index) : (cursor -= 1) {
        state.windows[cursor] = state.windows[cursor - 1];
    }

    state.windows[index] = window;
    state.window_count += 1;
    return abi.OMNI_OK;
}

fn removeColumnAt(state: *RuntimeState, index: usize) abi.OmniNiriRuntimeColumnState {
    const removed = state.columns[index];
    var cursor = index;
    while (cursor + 1 < state.column_count) : (cursor += 1) {
        state.columns[cursor] = state.columns[cursor + 1];
    }
    state.column_count -= 1;
    return removed;
}

fn insertColumnAt(state: *RuntimeState, index: usize, column: abi.OmniNiriRuntimeColumnState) i32 {
    if (state.column_count >= abi.MAX_WINDOWS) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (index > state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;

    var cursor = state.column_count;
    while (cursor > index) : (cursor -= 1) {
        state.columns[cursor] = state.columns[cursor - 1];
    }

    state.columns[index] = column;
    state.column_count += 1;
    return abi.OMNI_OK;
}

fn removeWindowRange(
    state: *RuntimeState,
    start_index: usize,
    count: usize,
    out_removed: *[abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,
) i32 {
    if (count == 0) return abi.OMNI_OK;
    if (start_index > state.window_count) return abi.OMNI_ERR_OUT_OF_RANGE;
    if (count > state.window_count - start_index) return abi.OMNI_ERR_OUT_OF_RANGE;

    for (0..count) |idx| {
        out_removed[idx] = state.windows[start_index + idx];
    }

    var cursor = start_index;
    while (cursor + count < state.window_count) : (cursor += 1) {
        state.windows[cursor] = state.windows[cursor + count];
    }

    state.window_count -= count;
    return abi.OMNI_OK;
}

fn appendWindowBatch(
    state: *RuntimeState,
    windows: *const [abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState,
    count: usize,
) i32 {
    if (state.window_count > abi.MAX_WINDOWS - count) return abi.OMNI_ERR_OUT_OF_RANGE;
    for (0..count) |idx| {
        state.windows[state.window_count + idx] = windows[idx];
    }
    state.window_count += count;
    return abi.OMNI_OK;
}

fn clampSizeValue(value: f64) f64 {
    return @max(0.5, @min(2.0, value));
}

fn visibleCountFromRaw(raw_count: i64) i32 {
    const count = std.math.cast(usize, raw_count) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (count == 0) return abi.OMNI_ERR_INVALID_ARGS;
    return std.math.cast(i32, count) orelse abi.OMNI_ERR_OUT_OF_RANGE;
}

fn proportionalSizeForVisibleCount(raw_count: i64) i32 {
    const count_i32 = visibleCountFromRaw(raw_count);
    if (count_i32 < 0) return count_i32;
    return count_i32;
}

fn columnWindowStart(state: *const RuntimeState, column_index: usize) usize {
    var start: usize = 0;
    for (0..column_index) |idx| {
        start += state.columns[idx].window_count;
    }
    return start;
}

fn preColumnId(
    ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    count: usize,
    raw_index: i64,
) ?abi.OmniUuid128 {
    const idx = std.math.cast(usize, raw_index) orelse return null;
    if (idx >= count) return null;
    return ids[idx];
}

fn preWindowId(
    ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    count: usize,
    raw_index: i64,
) ?abi.OmniUuid128 {
    const idx = std.math.cast(usize, raw_index) orelse return null;
    if (idx >= count) return null;
    return ids[idx];
}

fn capturePreIds(
    state: *const RuntimeState,
    out_column_ids: *[abi.MAX_WINDOWS]abi.OmniUuid128,
    out_window_ids: *[abi.MAX_WINDOWS]abi.OmniUuid128,
) void {
    for (0..state.column_count) |idx| {
        out_column_ids[idx] = state.columns[idx].column_id;
    }

    for (0..state.window_count) |idx| {
        out_window_ids[idx] = state.windows[idx].window_id;
    }
}

fn ensureUniqueColumnId(state: *const RuntimeState, column_id: abi.OmniUuid128) i32 {
    if (findColumnIndexByIdLinear(state, column_id) != null) return abi.OMNI_ERR_INVALID_ARGS;
    return abi.OMNI_OK;
}

fn ensureUniqueWindowId(state: *const RuntimeState, window_id: abi.OmniUuid128) i32 {
    if (findWindowIndexByIdLinear(state, window_id) != null) return abi.OMNI_ERR_INVALID_ARGS;
    return abi.OMNI_OK;
}

fn appendRefreshHint(hints: *MutationApplyHints, column_id: abi.OmniUuid128) void {
    var idx: usize = 0;
    while (idx < hints.refresh_count) : (idx += 1) {
        if (uuidEqual(hints.refresh_column_ids[idx], column_id)) return;
    }

    if (hints.refresh_count >= abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS) return;
    hints.refresh_column_ids[hints.refresh_count] = column_id;
    hints.refresh_count += 1;
}

fn i64ToU8(raw: i64) i32 {
    const value = std.math.cast(u8, raw) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    return std.math.cast(i32, value) orelse abi.OMNI_ERR_OUT_OF_RANGE;
}

fn workspaceFail(code: i32, tag: []const u8) i32 {
    _ = tag;
    return code;
}

fn applyMutationEdit(
    state: *RuntimeState,
    apply_request: abi.OmniNiriMutationApplyRequest,
    edit: abi.OmniNiriMutationEdit,
    pre_column_ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    pre_window_ids: *const [abi.MAX_WINDOWS]abi.OmniUuid128,
    pre_column_count: usize,
    pre_window_count: usize,
    hints: *MutationApplyHints,
) i32 {
    var mutated = false;
    var requires_refresh = false;

    switch (edit.kind) {
        abi.OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column_idx = findColumnIndexById(state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            var next_active: usize = 0;
            if (edit.value_a >= 0) {
                next_active = std.math.cast(usize, edit.value_a) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            }
            state.columns[column_idx].active_tile_idx = next_active;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS => {
            const lhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findWindowIndexById(state, lhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findWindowIndexById(state, rhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const temp = state.windows[lhs_idx];
            state.windows[lhs_idx] = state.windows[rhs_idx];
            state.windows[rhs_idx] = temp;
            mutated = true;
            requires_refresh = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX => {
            const moving_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const moving_idx = findWindowIndexById(state, moving_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = state.windows[moving_idx].column_index;
            if (source_column_idx >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;

            const target_column_idx = findColumnIndexById(state, target_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column = state.columns[target_column_idx];
            const source_column = state.columns[source_column_idx];

            var insert_row: usize = 0;
            if (edit.value_a >= 0) {
                const raw_row = std.math.cast(usize, edit.value_a) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                insert_row = @min(raw_row, target_column.window_count);
            }

            var target_abs = target_column.window_start + insert_row;
            if (source_column_idx == target_column_idx) {
                if (moving_idx < target_abs and target_abs > 0) {
                    target_abs -= 1;
                }
            } else if (source_column_idx < target_column_idx and target_abs > 0) {
                target_abs -= 1;
            }

            const moved = removeWindowAt(state, moving_idx);
            if (source_column.window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;
            state.columns[source_column_idx].window_count -= 1;

            const insert_rc = insertWindowAt(state, target_abs, moved);
            if (insert_rc != abi.OMNI_OK) return insert_rc;
            state.columns[target_column_idx].window_count += 1;
            mutated = true;
            requires_refresh = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE => {
            const lhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findColumnIndexById(state, lhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findColumnIndexById(state, rhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const temp = state.columns[lhs_idx];
            state.columns[lhs_idx].size_value = state.columns[rhs_idx].size_value;
            state.columns[lhs_idx].width_kind = state.columns[rhs_idx].width_kind;
            state.columns[lhs_idx].is_full_width = state.columns[rhs_idx].is_full_width;
            state.columns[lhs_idx].has_saved_width = state.columns[rhs_idx].has_saved_width;
            state.columns[lhs_idx].saved_width_kind = state.columns[rhs_idx].saved_width_kind;
            state.columns[lhs_idx].saved_width_value = state.columns[rhs_idx].saved_width_value;

            state.columns[rhs_idx].size_value = temp.size_value;
            state.columns[rhs_idx].width_kind = temp.width_kind;
            state.columns[rhs_idx].is_full_width = temp.is_full_width;
            state.columns[rhs_idx].has_saved_width = temp.has_saved_width;
            state.columns[rhs_idx].saved_width_kind = temp.saved_width_kind;
            state.columns[rhs_idx].saved_width_value = temp.saved_width_value;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT => {
            const lhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_window_id = preWindowId(pre_window_ids, pre_window_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findWindowIndexById(state, lhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findWindowIndexById(state, rhs_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const temp = state.windows[lhs_idx];
            state.windows[lhs_idx].size_value = state.windows[rhs_idx].size_value;
            state.windows[lhs_idx].height_kind = state.windows[rhs_idx].height_kind;
            state.windows[lhs_idx].height_value = state.windows[rhs_idx].height_value;

            state.windows[rhs_idx].size_value = temp.size_value;
            state.windows[rhs_idx].height_kind = temp.height_kind;
            state.windows[rhs_idx].height_value = temp.height_value;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT => {
            const window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const window_idx = findWindowIndexById(state, window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            state.windows[window_idx].size_value = 1.0;
            state.windows[window_idx].height_kind = abi.OMNI_NIRI_HEIGHT_KIND_AUTO;
            state.windows[window_idx].height_value = 1.0;
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column_idx_opt = findColumnIndexById(state, column_id);

            if (column_idx_opt) |column_idx| {
                if (state.columns[column_idx].window_count == 0) {
                    _ = removeColumnAt(state, column_idx);
                    mutated = true;
                    requires_refresh = true;

                    if (state.column_count == 0) {
                        if (apply_request.has_placeholder_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
                        const placeholder_id = apply_request.placeholder_column_id;
                        const unique_rc = ensureUniqueColumnId(state, placeholder_id);
                        if (unique_rc != abi.OMNI_OK) return unique_rc;

                        const add_rc = insertColumnAt(state, 0, .{
                            .column_id = placeholder_id,
                            .window_start = 0,
                            .window_count = 0,
                            .active_tile_idx = 0,
                            .is_tabbed = 0,
                            .size_value = 1.0,
                            .width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                            .is_full_width = 0,
                            .has_saved_width = 0,
                            .saved_width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                            .saved_width_value = 1.0,
                        });
                        if (add_rc != abi.OMNI_OK) return add_rc;
                    }
                }
            }
        },
        abi.OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            appendRefreshHint(hints, column_id);
        },
        abi.OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN => {
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const direction_i32 = i64ToU8(edit.value_a);
            if (direction_i32 < 0) return direction_i32;

            hints.has_delegate_move_column = true;
            hints.delegate_move_column_id = column_id;
            hints.delegate_move_direction = @intCast(direction_i32);
        },
        abi.OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW => {
            if (apply_request.has_created_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            const unique_rc = ensureUniqueColumnId(state, apply_request.created_column_id);
            if (unique_rc != abi.OMNI_OK) return unique_rc;

            const moving_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const source_column_idx_initial = findColumnIndexByIdCoherent(state, source_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const direction_i32 = i64ToU8(edit.value_a);
            if (direction_i32 < 0) return direction_i32;
            const direction: u8 = @intCast(direction_i32);
            if (direction != abi.OMNI_NIRI_DIRECTION_LEFT and direction != abi.OMNI_NIRI_DIRECTION_RIGHT) {
                return abi.OMNI_ERR_INVALID_ARGS;
            }

            const visible_i32 = proportionalSizeForVisibleCount(edit.value_b);
            if (visible_i32 < 0) return visible_i32;
            const visible_count: usize = @intCast(visible_i32);

            const insert_index = if (direction == abi.OMNI_NIRI_DIRECTION_RIGHT)
                source_column_idx_initial + 1
            else
                source_column_idx_initial;

            const add_rc = insertColumnAt(state, insert_index, .{
                .column_id = apply_request.created_column_id,
                .window_start = 0,
                .window_count = 0,
                .active_tile_idx = 0,
                .is_tabbed = 0,
                .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
                .width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                .is_full_width = 0,
                .has_saved_width = 0,
                .saved_width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                .saved_width_value = 1.0,
            });
            if (add_rc != abi.OMNI_OK) return add_rc;

            const moving_idx = findWindowIndexByIdCoherent(state, moving_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = findColumnIndexByIdCoherent(state, source_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const new_column_idx = findColumnIndexByIdCoherent(state, apply_request.created_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const target_start = columnWindowStart(state, new_column_idx);
            var insert_abs = target_start;
            if (moving_idx < insert_abs and insert_abs > 0) insert_abs -= 1;

            const moved = removeWindowAt(state, moving_idx);
            if (state.columns[source_column_idx].window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;
            state.columns[source_column_idx].window_count -= 1;

            const insert_rc = insertWindowAt(state, insert_abs, moved);
            if (insert_rc != abi.OMNI_OK) return insert_rc;
            state.columns[new_column_idx].window_count += 1;
            mutated = true;
            requires_refresh = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW => {
            if (apply_request.has_created_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            const unique_rc = ensureUniqueColumnId(state, apply_request.created_column_id);
            if (unique_rc != abi.OMNI_OK) return unique_rc;

            const moving_window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const visible_i32 = proportionalSizeForVisibleCount(edit.value_a);
            if (visible_i32 < 0) return visible_i32;
            const visible_count: usize = @intCast(visible_i32);

            var insert_index: usize = 0;
            if (edit.related_index > 0) {
                const raw_index = std.math.cast(usize, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                insert_index = @min(raw_index, state.column_count);
            }

            const add_rc = insertColumnAt(state, insert_index, .{
                .column_id = apply_request.created_column_id,
                .window_start = 0,
                .window_count = 0,
                .active_tile_idx = 0,
                .is_tabbed = 0,
                .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
                .width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                .is_full_width = 0,
                .has_saved_width = 0,
                .saved_width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                .saved_width_value = 1.0,
            });
            if (add_rc != abi.OMNI_OK) return add_rc;

            const moving_idx = findWindowIndexByIdCoherent(state, moving_window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = state.windows[moving_idx].column_index;
            if (source_column_idx >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;
            const new_column_idx = findColumnIndexByIdCoherent(state, apply_request.created_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const target_start = columnWindowStart(state, new_column_idx);
            var insert_abs = target_start;
            if (moving_idx < insert_abs and insert_abs > 0) insert_abs -= 1;

            const moved = removeWindowAt(state, moving_idx);
            if (state.columns[source_column_idx].window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;
            state.columns[source_column_idx].window_count -= 1;

            const insert_rc = insertWindowAt(state, insert_abs, moved);
            if (insert_rc != abi.OMNI_OK) return insert_rc;
            state.columns[new_column_idx].window_count += 1;
            mutated = true;
            requires_refresh = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS => {
            const lhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_column_id = preColumnId(pre_column_ids, pre_column_count, edit.related_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const lhs_idx = findColumnIndexById(state, lhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const rhs_idx = findColumnIndexById(state, rhs_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (lhs_idx == rhs_idx) {
                // no-op
            } else {
                const old = state.*;
                const temp = state.columns[lhs_idx];
                state.columns[lhs_idx] = state.columns[rhs_idx];
                state.columns[rhs_idx] = temp;

                var dst_cursor: usize = 0;
                for (0..state.column_count) |column_idx| {
                    const column_id = state.columns[column_idx].column_id;

                    var old_index_opt: ?usize = null;
                    for (0..old.column_count) |old_idx| {
                        if (uuidEqual(old.columns[old_idx].column_id, column_id)) {
                            old_index_opt = old_idx;
                            break;
                        }
                    }
                    const old_index = old_index_opt orelse return abi.OMNI_ERR_INVALID_ARGS;
                    const old_column = old.columns[old_index];

                    for (0..old_column.window_count) |row_idx| {
                        state.windows[dst_cursor + row_idx] = old.windows[old_column.window_start + row_idx];
                    }
                    dst_cursor += old_column.window_count;
                }

                mutated = true;
                requires_refresh = true;
            }
        },
        abi.OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR => {
            if (edit.scalar_a <= 0) return abi.OMNI_ERR_INVALID_ARGS;
            for (0..state.column_count) |idx| {
                state.columns[idx].size_value = clampSizeValue(state.columns[idx].size_value * edit.scalar_a);
                state.columns[idx].width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION;
            }
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR => {
            if (edit.scalar_a <= 0) return abi.OMNI_ERR_INVALID_ARGS;
            const column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column_idx = findColumnIndexById(state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const column = state.columns[column_idx];

            for (0..column.window_count) |row_idx| {
                const window_idx = column.window_start + row_idx;
                state.windows[window_idx].size_value = clampSizeValue(state.windows[window_idx].size_value * edit.scalar_a);
                state.windows[window_idx].height_kind = abi.OMNI_NIRI_HEIGHT_KIND_AUTO;
                state.windows[window_idx].height_value = state.windows[window_idx].size_value;
            }
            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS => {
            if (edit.scalar_a <= 0) return abi.OMNI_ERR_INVALID_ARGS;

            for (0..state.column_count) |col_idx| {
                state.columns[col_idx].size_value = edit.scalar_a;
                state.columns[col_idx].width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION;
                state.columns[col_idx].is_full_width = 0;
                state.columns[col_idx].has_saved_width = 0;
                state.columns[col_idx].saved_width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION;
                state.columns[col_idx].saved_width_value = 1.0;
                const column = state.columns[col_idx];
                for (0..column.window_count) |row_idx| {
                    const window_idx = column.window_start + row_idx;
                    state.windows[window_idx].size_value = 1.0;
                    state.windows[window_idx].height_kind = abi.OMNI_NIRI_HEIGHT_KIND_AUTO;
                    state.windows[window_idx].height_value = 1.0;
                }
            }

            mutated = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN => {
            if (apply_request.has_incoming_window_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            const unique_rc = ensureUniqueWindowId(state, apply_request.incoming_window_id);
            if (unique_rc != abi.OMNI_OK) return unique_rc;

            const target_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column_idx = findColumnIndexById(state, target_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column = state.columns[target_column_idx];
            const visible_i32 = proportionalSizeForVisibleCount(edit.value_a);
            if (visible_i32 < 0) return visible_i32;
            const visible_count: usize = @intCast(visible_i32);
            state.columns[target_column_idx].size_value = 1.0 / @as(f64, @floatFromInt(visible_count));
            state.columns[target_column_idx].width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION;

            const insert_abs = target_column.window_start + target_column.window_count;
            const insert_rc = insertWindowAt(state, insert_abs, .{
                .window_id = apply_request.incoming_window_id,
                .column_id = target_column.column_id,
                .column_index = target_column_idx,
                .size_value = 1.0,
                .height_kind = abi.OMNI_NIRI_HEIGHT_KIND_AUTO,
                .height_value = 1.0,
            });
            if (insert_rc != abi.OMNI_OK) return insert_rc;

            state.columns[target_column_idx].window_count += 1;
            mutated = true;
            requires_refresh = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN => {
            if (apply_request.has_incoming_window_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
            if (apply_request.has_created_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;

            const unique_window_rc = ensureUniqueWindowId(state, apply_request.incoming_window_id);
            if (unique_window_rc != abi.OMNI_OK) return unique_window_rc;
            const unique_column_rc = ensureUniqueColumnId(state, apply_request.created_column_id);
            if (unique_column_rc != abi.OMNI_OK) return unique_column_rc;

            const visible_i32 = proportionalSizeForVisibleCount(edit.value_a);
            if (visible_i32 < 0) return visible_i32;
            const visible_count: usize = @intCast(visible_i32);

            var insert_index = state.column_count;
            if (edit.subject_index >= 0) {
                const reference_column_id = preColumnId(pre_column_ids, pre_column_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                const reference_index = findColumnIndexById(state, reference_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                insert_index = reference_index + 1;
            }

            const add_rc = insertColumnAt(state, insert_index, .{
                .column_id = apply_request.created_column_id,
                .window_start = 0,
                .window_count = 0,
                .active_tile_idx = 0,
                .is_tabbed = 0,
                .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
                .width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                .is_full_width = 0,
                .has_saved_width = 0,
                .saved_width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                .saved_width_value = 1.0,
            });
            if (add_rc != abi.OMNI_OK) return add_rc;
            const cache_rc = refreshRuntimeState(state);
            if (cache_rc != abi.OMNI_OK) return cache_rc;

            const target_idx = findColumnIndexById(state, apply_request.created_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const target_column = state.columns[target_idx];
            const insert_abs = target_column.window_start + target_column.window_count;

            const insert_window_rc = insertWindowAt(state, insert_abs, .{
                .window_id = apply_request.incoming_window_id,
                .column_id = target_column.column_id,
                .column_index = target_idx,
                .size_value = 1.0,
                .height_kind = abi.OMNI_NIRI_HEIGHT_KIND_AUTO,
                .height_value = 1.0,
            });
            if (insert_window_rc != abi.OMNI_OK) return insert_window_rc;

            state.columns[target_idx].window_count += 1;
            mutated = true;
            requires_refresh = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX => {
            const window_id = preWindowId(pre_window_ids, pre_window_count, edit.subject_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const window_idx = findWindowIndexById(state, window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const source_column_idx = state.windows[window_idx].column_index;
            if (source_column_idx >= state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;
            if (state.columns[source_column_idx].window_count == 0) return abi.OMNI_ERR_OUT_OF_RANGE;

            _ = removeWindowAt(state, window_idx);
            state.columns[source_column_idx].window_count -= 1;
            mutated = true;
            requires_refresh = true;
        },
        abi.OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS => {
            hints.reset_all_column_cached_widths = true;
        },
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }

    if (mutated and requires_refresh) return refreshRuntimeStateFast(state);

    return abi.OMNI_OK;
}

fn updateInteractionContextFromLayout(
    ctx: *OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriWindowInput,
    window_count: usize,
    out_windows: [*c]const abi.OmniNiriWindowOutput,
) i32 {
    if (column_count > abi.MAX_WINDOWS or window_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (column_count > 0 and columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and out_windows == null) return abi.OMNI_ERR_INVALID_ARGS;

    ctx.interaction_window_count = window_count;
    ctx.column_count = column_count;

    for (0..column_count) |idx| {
        ctx.column_dropzones[idx] = .{
            .is_valid = 0,
            .min_y = 0,
            .max_y = 0,
            .post_insertion_count = 0,
        };
    }

    for (0..column_count) |column_idx| {
        const column = columns[column_idx];
        if (!geometry.isSubrangeWithinTotal(window_count, column.window_start, column.window_count)) {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }

        if (column.window_count == 0) continue;

        const first_window_idx = column.window_start;
        const last_window_idx = column.window_start + column.window_count - 1;
        const first_window = out_windows[first_window_idx];
        const last_window = out_windows[last_window_idx];

        ctx.column_dropzones[column_idx] = .{
            .is_valid = 1,
            .min_y = first_window.frame_y,
            .max_y = last_window.frame_y + last_window.frame_height,
            .post_insertion_count = column.window_count + 1,
        };

        for (0..column.window_count) |local_window_idx| {
            const global_window_idx = column.window_start + local_window_idx;
            const window_output = out_windows[global_window_idx];
            const window_input = windows[global_window_idx];
            ctx.interaction_windows[global_window_idx] = .{
                .window_index = global_window_idx,
                .column_index = column_idx,
                .frame_x = window_output.frame_x,
                .frame_y = window_output.frame_y,
                .frame_width = window_output.frame_width,
                .frame_height = window_output.frame_height,
                .is_fullscreen = @intFromBool(window_input.sizing_mode == abi.OMNI_NIRI_SIZING_FULLSCREEN),
            };
        }
    }

    return abi.OMNI_OK;
}

pub fn omni_niri_layout_context_create_impl() [*c]OmniNiriLayoutContext {
    const ctx = std.heap.c_allocator.create(OmniNiriLayoutContext) catch return null;
    ctx.* = undefined;
    resetContext(ctx);
    return @ptrCast(ctx);
}

pub fn omni_niri_layout_context_destroy_impl(context: [*c]OmniNiriLayoutContext) void {
    const ctx = asMutableContext(context) orelse return;
    std.heap.c_allocator.destroy(ctx);
}

pub fn omni_niri_layout_context_set_interaction_impl(
    context: [*c]OmniNiriLayoutContext,
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    column_dropzones: [*c]const abi.OmniNiriColumnDropzoneMeta,
    column_count: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > abi.MAX_WINDOWS or column_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (column_count > 0 and column_dropzones == null) return abi.OMNI_ERR_INVALID_ARGS;

    ctx.interaction_window_count = window_count;
    ctx.column_count = column_count;

    for (0..window_count) |idx| {
        ctx.interaction_windows[idx] = windows[idx];
    }
    for (0..column_count) |idx| {
        ctx.column_dropzones[idx] = column_dropzones[idx];
    }

    return abi.OMNI_OK;
}

pub fn omni_niri_layout_pass_v3_impl(
    context: [*c]OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriWindowInput,
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
    out_windows: [*c]abi.OmniNiriWindowOutput,
    out_window_count: usize,
    out_columns: [*c]abi.OmniNiriColumnOutput,
    out_column_count: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;

    const rc = layout_pass.omni_niri_layout_pass_v2_impl(
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
        out_columns,
        out_column_count,
    );
    if (rc != abi.OMNI_OK) return rc;

    return updateInteractionContextFromLayout(
        ctx,
        columns,
        column_count,
        windows,
        window_count,
        out_windows,
    );
}

pub fn omni_niri_ctx_hit_test_tiled_impl(
    context: [*c]const OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    out_window_index: [*c]i64,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return interaction.omni_niri_hit_test_tiled_impl(
        contextHitWindowsPtr(ctx),
        ctx.interaction_window_count,
        point_x,
        point_y,
        out_window_index,
    );
}

pub fn omni_niri_ctx_hit_test_resize_impl(
    context: [*c]const OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    threshold: f64,
    out_result: [*c]abi.OmniNiriResizeHitResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return interaction.omni_niri_hit_test_resize_impl(
        contextHitWindowsPtr(ctx),
        ctx.interaction_window_count,
        point_x,
        point_y,
        threshold,
        out_result,
    );
}

pub fn omni_niri_ctx_hit_test_move_target_impl(
    context: [*c]const OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    excluding_window_index: i64,
    is_insert_mode: u8,
    out_result: [*c]abi.OmniNiriMoveTargetResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    return interaction.omni_niri_hit_test_move_target_impl(
        contextHitWindowsPtr(ctx),
        ctx.interaction_window_count,
        point_x,
        point_y,
        excluding_window_index,
        is_insert_mode,
        out_result,
    );
}

pub fn omni_niri_ctx_insertion_dropzone_impl(
    context: [*c]const OmniNiriLayoutContext,
    target_window_index: i64,
    gap: f64,
    insert_position: u8,
    out_result: [*c]abi.OmniNiriDropzoneResult,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (out_result == null) return abi.OMNI_ERR_INVALID_ARGS;

    out_result[0] = .{
        .frame_x = 0,
        .frame_y = 0,
        .frame_width = 0,
        .frame_height = 0,
        .is_valid = 0,
    };

    const target_idx = std.math.cast(usize, target_window_index) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (target_idx >= ctx.interaction_window_count) return abi.OMNI_ERR_INVALID_ARGS;

    const target = ctx.interaction_windows[target_idx];
    if (target.column_index >= ctx.column_count) return abi.OMNI_ERR_INVALID_ARGS;

    const column_meta = ctx.column_dropzones[target.column_index];
    if (column_meta.is_valid == 0) return abi.OMNI_OK;

    var input = abi.OmniNiriDropzoneInput{
        .target_frame_x = target.frame_x,
        .target_frame_y = target.frame_y,
        .target_frame_width = target.frame_width,
        .target_frame_height = target.frame_height,
        .column_min_y = column_meta.min_y,
        .column_max_y = column_meta.max_y,
        .gap = gap,
        .insert_position = insert_position,
        .post_insertion_count = column_meta.post_insertion_count,
    };
    return interaction.omni_niri_insertion_dropzone_impl(&input, out_result);
}

pub fn omni_niri_ctx_seed_runtime_state_impl(
    context: [*c]OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriRuntimeColumnState,
    column_count: usize,
    windows: [*c]const abi.OmniNiriRuntimeWindowState,
    window_count: usize,
) i32 {
    const ctx = asMutableContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (column_count > abi.MAX_WINDOWS or window_count > abi.MAX_WINDOWS) {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }
    if (column_count > 0 and columns == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (window_count > 0 and windows == null) return abi.OMNI_ERR_INVALID_ARGS;

    var runtime_state: RuntimeState = undefined;
    runtime_state.column_count = column_count;
    runtime_state.window_count = window_count;
    clearSlots(&runtime_state.column_id_slots);
    clearSlots(&runtime_state.window_id_slots);

    for (0..column_count) |idx| {
        runtime_state.columns[idx] = columns[idx];
    }
    for (0..window_count) |idx| {
        runtime_state.windows[idx] = windows[idx];
    }

    const refresh_rc = refreshRuntimeState(&runtime_state);
    if (refresh_rc != abi.OMNI_OK) return refresh_rc;

    commitRuntimeState(ctx, &runtime_state);
    const meta = initTxnDeltaMeta();
    const delta_rc = storeTxnDeltaForContext(ctx, null, &meta);
    if (delta_rc != abi.OMNI_OK) return delta_rc;
    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_export_runtime_state_impl(
    context: [*c]const OmniNiriLayoutContext,
    out_export: [*c]abi.OmniNiriRuntimeStateExport,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (out_export == null) return abi.OMNI_ERR_INVALID_ARGS;

    out_export[0] = .{
        .columns = if (ctx.runtime_column_count > 0) @ptrCast(&ctx.runtime_columns[0]) else null,
        .column_count = ctx.runtime_column_count,
        .windows = if (ctx.runtime_window_count > 0) @ptrCast(&ctx.runtime_windows[0]) else null,
        .window_count = ctx.runtime_window_count,
    };

    return abi.OMNI_OK;
}

fn appendRefreshColumnMeta(meta: *TxnDeltaMeta, column_id: abi.OmniUuid128) void {
    var idx: usize = 0;
    while (idx < meta.refresh_count) : (idx += 1) {
        if (uuidEqual(meta.refresh_column_ids[idx], column_id)) return;
    }
    if (meta.refresh_count >= abi.OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS) return;
    meta.refresh_column_ids[meta.refresh_count] = column_id;
    meta.refresh_count += 1;
}

fn resolveOptionalWindowIndexById(
    state: *const RuntimeState,
    has_window_id: u8,
    window_id: abi.OmniUuid128,
    out_index: *i64,
) i32 {
    if (has_window_id == 0) {
        out_index.* = -1;
        return abi.OMNI_OK;
    }

    const idx = findWindowIndexByIdCoherent(state, window_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    out_index.* = std.math.cast(i64, idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    return abi.OMNI_OK;
}

fn resolveOptionalColumnIndexById(
    state: *const RuntimeState,
    has_column_id: u8,
    column_id: abi.OmniUuid128,
    out_index: *i64,
) i32 {
    if (has_column_id == 0) {
        out_index.* = -1;
        return abi.OMNI_OK;
    }

    const idx = findColumnIndexByIdCoherent(state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    out_index.* = std.math.cast(i64, idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    return abi.OMNI_OK;
}

fn resolveNavigationSelection(
    source_state: *const RuntimeState,
    payload: abi.OmniNiriTxnNavigationPayload,
    out_selected_window_index: *i64,
    out_selected_column_index: *i64,
    out_selected_row_index: *i64,
) i32 {
    var selected_window_index: i64 = -1;
    var selected_column_index: i64 = -1;

    var rc = resolveOptionalWindowIndexById(
        source_state,
        payload.has_source_window_id,
        payload.source_window_id,
        &selected_window_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    rc = resolveOptionalColumnIndexById(
        source_state,
        payload.has_source_column_id,
        payload.source_column_id,
        &selected_column_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    var selected_row_index: i64 = -1;
    if (selected_window_index >= 0) {
        const window_idx = std.math.cast(usize, selected_window_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (window_idx >= source_state.window_count) return abi.OMNI_ERR_OUT_OF_RANGE;

        const derived_column_idx = source_state.windows[window_idx].column_index;
        if (derived_column_idx >= source_state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;

        if (selected_column_index >= 0) {
            const selected_column_idx = std.math.cast(usize, selected_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            if (selected_column_idx != derived_column_idx) return abi.OMNI_ERR_OUT_OF_RANGE;
        } else {
            selected_column_index = std.math.cast(i64, derived_column_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        }

        const column = source_state.columns[derived_column_idx];
        if (window_idx < column.window_start or window_idx >= column.window_start + column.window_count) {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }

        selected_row_index = std.math.cast(i64, window_idx - column.window_start) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    } else if (selected_column_index >= 0) {
        const selected_column_idx = std.math.cast(usize, selected_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (selected_column_idx >= source_state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;

        const column = source_state.columns[selected_column_idx];
        if (column.window_count > 0) {
            selected_window_index = std.math.cast(i64, column.window_start) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            selected_row_index = 0;
        }
    }

    out_selected_window_index.* = selected_window_index;
    out_selected_column_index.* = selected_column_index;
    out_selected_row_index.* = selected_row_index;
    return abi.OMNI_OK;
}

fn resolveMutationSelectedNode(
    runtime_state: *const RuntimeState,
    has_selected_node_id: u8,
    selected_node_id: abi.OmniUuid128,
    out_kind: *u8,
    out_index: *i64,
) i32 {
    out_kind.* = abi.OMNI_NIRI_MUTATION_NODE_NONE;
    out_index.* = -1;

    if (has_selected_node_id == 0) return abi.OMNI_OK;

    if (findWindowIndexByIdCoherent(runtime_state, selected_node_id)) |window_idx| {
        out_kind.* = abi.OMNI_NIRI_MUTATION_NODE_WINDOW;
        out_index.* = std.math.cast(i64, window_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        return abi.OMNI_OK;
    }

    if (findColumnIndexByIdCoherent(runtime_state, selected_node_id)) |column_idx| {
        out_kind.* = abi.OMNI_NIRI_MUTATION_NODE_COLUMN;
        out_index.* = std.math.cast(i64, column_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        return abi.OMNI_OK;
    }

    return abi.OMNI_OK;
}

fn navigationOpRequiresSelection(op: u8) bool {
    return switch (op) {
        abi.OMNI_NIRI_NAV_OP_MOVE_BY_COLUMNS,
        abi.OMNI_NIRI_NAV_OP_MOVE_VERTICAL,
        abi.OMNI_NIRI_NAV_OP_FOCUS_TARGET,
        abi.OMNI_NIRI_NAV_OP_FOCUS_DOWN_OR_LEFT,
        abi.OMNI_NIRI_NAV_OP_FOCUS_UP_OR_RIGHT,
        abi.OMNI_NIRI_NAV_OP_FOCUS_WINDOW_INDEX,
        abi.OMNI_NIRI_NAV_OP_FOCUS_WINDOW_TOP,
        abi.OMNI_NIRI_NAV_OP_FOCUS_WINDOW_BOTTOM,
        => true,
        else => false,
    };
}

fn mutationOpRequiresSourceWindow(op: u8) bool {
    return switch (op) {
        abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL,
        abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL,
        abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL,
        abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL,
        abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE,
        abi.OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE,
        abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN,
        abi.OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE,
        abi.OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN,
        abi.OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW,
        abi.OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW,
        abi.OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW,
        abi.OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL,
        => true,
        else => false,
    };
}

fn mutationOpRequiresSourceColumn(op: u8) bool {
    return switch (op) {
        abi.OMNI_NIRI_MUTATION_OP_MOVE_COLUMN,
        abi.OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN,
        abi.OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES,
        => true,
        else => false,
    };
}

fn mutationOpRequiresTargetColumn(op: u8) bool {
    return switch (op) {
        abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN => true,
        else => false,
    };
}

fn mutationOpTriggersStructuralAnimation(op: u8) bool {
    return switch (op) {
        abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL,
        abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL,
        abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL,
        abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL,
        abi.OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE,
        abi.OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE,
        abi.OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN,
        abi.OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE,
        abi.OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN,
        abi.OMNI_NIRI_MUTATION_OP_MOVE_COLUMN,
        abi.OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW,
        abi.OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW,
        abi.OMNI_NIRI_MUTATION_OP_BALANCE_SIZES,
        abi.OMNI_NIRI_MUTATION_OP_ADD_WINDOW,
        abi.OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW,
        => true,
        else => false,
    };
}

fn applyNavigationTxn(
    source_ctx: *OmniNiriLayoutContext,
    source_state: *RuntimeState,
    payload: abi.OmniNiriTxnNavigationPayload,
    out_result: [*c]abi.OmniNiriTxnResult,
    source_delta_meta: *TxnDeltaMeta,
) i32 {
    if (navigationOpRequiresSelection(payload.op) and
        payload.has_source_window_id == 0 and
        payload.has_source_column_id == 0)
    {
        return abi.OMNI_ERR_INVALID_ARGS;
    }

    var selected_window_index: i64 = -1;
    var selected_column_index: i64 = -1;
    var selected_row_index: i64 = -1;
    var rc = resolveNavigationSelection(
        source_state,
        payload,
        &selected_window_index,
        &selected_column_index,
        &selected_row_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    var target_column_index_from_id: i64 = -1;
    rc = resolveOptionalColumnIndexById(
        source_state,
        payload.has_target_column_id,
        payload.target_column_id,
        &target_column_index_from_id,
    );
    if (rc != abi.OMNI_OK) return rc;

    var target_window_index_from_id: i64 = -1;
    rc = resolveOptionalWindowIndexById(
        source_state,
        payload.has_target_window_id,
        payload.target_window_id,
        &target_window_index_from_id,
    );
    if (rc != abi.OMNI_OK) return rc;

    const target_column_index: i64 = if (target_column_index_from_id >= 0)
        target_column_index_from_id
    else
        payload.focus_column_index;

    var target_window_index: i64 = payload.focus_window_index;
    if (target_window_index_from_id >= 0) {
        if (selected_column_index < 0) return abi.OMNI_ERR_INVALID_ARGS;
        const selected_column_idx = std.math.cast(usize, selected_column_index) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (selected_column_idx >= source_state.column_count) return abi.OMNI_ERR_OUT_OF_RANGE;
        const selected_column = source_state.columns[selected_column_idx];

        const target_window_idx = std.math.cast(usize, target_window_index_from_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (target_window_idx < selected_column.window_start or
            target_window_idx >= selected_column.window_start + selected_column.window_count)
        {
            return abi.OMNI_ERR_OUT_OF_RANGE;
        }

        target_window_index = std.math.cast(
            i64,
            target_window_idx - selected_column.window_start,
        ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    const request: abi.OmniNiriNavigationRequest = .{
        .op = payload.op,
        .direction = payload.direction,
        .orientation = payload.orientation,
        .infinite_loop = payload.infinite_loop,
        .selected_window_index = selected_window_index,
        .selected_column_index = selected_column_index,
        .selected_row_index = selected_row_index,
        .step = payload.step,
        .target_row_index = payload.target_row_index,
        .target_column_index = target_column_index,
        .target_window_index = target_window_index,
    };

    var nav_result: abi.OmniNiriNavigationResult = undefined;
    const nav_rc = navigation.omni_niri_navigation_resolve_impl(
        runtimeColumnsStatePtr(source_state),
        source_state.column_count,
        runtimeWindowsStatePtr(source_state),
        source_state.window_count,
        &request,
        &nav_result,
    );
    if (nav_rc != abi.OMNI_OK) return nav_rc;

    var pre_column_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    var pre_window_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    capturePreIds(source_state, &pre_column_ids, &pre_window_ids);

    if (nav_result.has_target != 0) {
        const target_window_id = preWindowId(
            &pre_window_ids,
            source_state.window_count,
            nav_result.target_window_index,
        ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].has_target_window_id = 1;
        out_result[0].target_window_id = target_window_id;
        source_delta_meta.has_target_window_id = true;
        source_delta_meta.target_window_id = target_window_id;
    }

    var mutated = false;

    if (nav_result.update_source_active_tile != 0) {
        const column_id = preColumnId(
            &pre_column_ids,
            source_state.column_count,
            nav_result.source_column_index,
        ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

        const column_idx = findColumnIndexById(source_state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        const row_idx = std.math.cast(usize, nav_result.source_active_tile_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (source_state.columns[column_idx].active_tile_idx != row_idx) {
            source_state.columns[column_idx].active_tile_idx = row_idx;
            mutated = true;
        }
    }

    if (nav_result.update_target_active_tile != 0) {
        const column_id = preColumnId(
            &pre_column_ids,
            source_state.column_count,
            nav_result.target_column_index,
        ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

        const column_idx = findColumnIndexById(source_state, column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        const row_idx = std.math.cast(usize, nav_result.target_active_tile_idx) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        if (source_state.columns[column_idx].active_tile_idx != row_idx) {
            source_state.columns[column_idx].active_tile_idx = row_idx;
            mutated = true;
        }
    }

    if (nav_result.refresh_tabbed_visibility_source != 0) {
        const column_id = preColumnId(
            &pre_column_ids,
            source_state.column_count,
            nav_result.source_column_index,
        ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        appendRefreshColumnMeta(source_delta_meta, column_id);
    }

    if (nav_result.refresh_tabbed_visibility_target != 0) {
        const column_id = preColumnId(
            &pre_column_ids,
            source_state.column_count,
            nav_result.target_column_index,
        ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        appendRefreshColumnMeta(source_delta_meta, column_id);
    }

    if (mutated) {
        const refresh_rc = refreshRuntimeStateFast(source_state);
        if (refresh_rc != abi.OMNI_OK) return refresh_rc;

        const validation_rc = validateRuntimeState(source_state);
        if (validation_rc != abi.OMNI_OK) return validation_rc;

        commitRuntimeState(source_ctx, source_state);
        out_result[0].applied = 1;
        out_result[0].changed_source_context = 1;
    }

    return abi.OMNI_OK;
}

fn applyMutationTxn(
    source_ctx: *OmniNiriLayoutContext,
    runtime_state: *RuntimeState,
    payload: abi.OmniNiriTxnMutationPayload,
    out_result: [*c]abi.OmniNiriTxnResult,
    source_delta_meta: *TxnDeltaMeta,
) i32 {
    if (mutationOpRequiresSourceWindow(payload.op) and payload.has_source_window_id == 0) {
        return abi.OMNI_ERR_INVALID_ARGS;
    }
    if (mutationOpRequiresSourceColumn(payload.op) and payload.has_source_column_id == 0) {
        return abi.OMNI_ERR_INVALID_ARGS;
    }
    if (mutationOpRequiresTargetColumn(payload.op) and payload.has_target_column_id == 0) {
        return abi.OMNI_ERR_INVALID_ARGS;
    }

    var source_window_index: i64 = -1;
    var target_window_index: i64 = -1;
    var source_column_index: i64 = -1;
    var target_column_index: i64 = -1;
    var focused_window_index: i64 = -1;

    var rc = resolveOptionalWindowIndexById(
        runtime_state,
        payload.has_source_window_id,
        payload.source_window_id,
        &source_window_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    rc = resolveOptionalWindowIndexById(
        runtime_state,
        payload.has_target_window_id,
        payload.target_window_id,
        &target_window_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    rc = resolveOptionalColumnIndexById(
        runtime_state,
        payload.has_source_column_id,
        payload.source_column_id,
        &source_column_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    rc = resolveOptionalColumnIndexById(
        runtime_state,
        payload.has_target_column_id,
        payload.target_column_id,
        &target_column_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    rc = resolveOptionalWindowIndexById(
        runtime_state,
        payload.has_focused_window_id,
        payload.focused_window_id,
        &focused_window_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    var selected_node_kind: u8 = abi.OMNI_NIRI_MUTATION_NODE_NONE;
    var selected_node_index: i64 = -1;
    rc = resolveMutationSelectedNode(
        runtime_state,
        payload.has_selected_node_id,
        payload.selected_node_id,
        &selected_node_kind,
        &selected_node_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    const request: abi.OmniNiriMutationRequest = .{
        .op = payload.op,
        .direction = payload.direction,
        .infinite_loop = payload.infinite_loop,
        .insert_position = payload.insert_position,
        .source_window_index = source_window_index,
        .target_window_index = target_window_index,
        .max_windows_per_column = payload.max_windows_per_column,
        .source_column_index = source_column_index,
        .target_column_index = target_column_index,
        .insert_column_index = payload.insert_column_index,
        .max_visible_columns = payload.max_visible_columns,
        .selected_node_kind = selected_node_kind,
        .selected_node_index = selected_node_index,
        .focused_window_index = focused_window_index,
        .incoming_spawn_mode = payload.incoming_spawn_mode,
    };

    const apply_request: abi.OmniNiriMutationApplyRequest = .{
        .request = request,
        .has_incoming_window_id = payload.has_incoming_window_id,
        .incoming_window_id = payload.incoming_window_id,
        .has_created_column_id = payload.has_created_column_id,
        .created_column_id = payload.created_column_id,
        .has_placeholder_column_id = payload.has_placeholder_column_id,
        .placeholder_column_id = payload.placeholder_column_id,
    };

    var plan_result: abi.OmniNiriMutationResult = undefined;
    const planner_rc = mutation.omni_niri_mutation_plan_impl(
        runtimeColumnsStatePtr(runtime_state),
        runtime_state.column_count,
        runtimeWindowsStatePtr(runtime_state),
        runtime_state.window_count,
        &apply_request.request,
        &plan_result,
    );
    if (planner_rc != abi.OMNI_OK) return workspaceFail(planner_rc, "planner_rc");

    var pre_column_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    var pre_window_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    capturePreIds(runtime_state, &pre_column_ids, &pre_window_ids);

    if (plan_result.has_target_window != 0) {
        const target_window_id = preWindowId(
            &pre_window_ids,
            runtime_state.window_count,
            plan_result.target_window_index,
        ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
        out_result[0].has_target_window_id = 1;
        out_result[0].target_window_id = target_window_id;
        source_delta_meta.has_target_window_id = true;
        source_delta_meta.target_window_id = target_window_id;
    }

    if (plan_result.has_target_node != 0) {
        out_result[0].has_target_node_id = 1;
        out_result[0].target_node_kind = plan_result.target_node_kind;

        switch (plan_result.target_node_kind) {
            abi.OMNI_NIRI_MUTATION_NODE_WINDOW => {
                const target_window_id = preWindowId(
                    &pre_window_ids,
                    runtime_state.window_count,
                    plan_result.target_node_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                out_result[0].target_node_id = target_window_id;
                source_delta_meta.has_target_node_id = true;
                source_delta_meta.target_node_kind = plan_result.target_node_kind;
                source_delta_meta.target_node_id = target_window_id;
            },
            abi.OMNI_NIRI_MUTATION_NODE_COLUMN => {
                const target_column_id = preColumnId(
                    &pre_column_ids,
                    runtime_state.column_count,
                    plan_result.target_node_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                out_result[0].target_node_id = target_column_id;
                source_delta_meta.has_target_node_id = true;
                source_delta_meta.target_node_kind = plan_result.target_node_kind;
                source_delta_meta.target_node_id = target_column_id;
            },
            else => return abi.OMNI_ERR_INVALID_ARGS,
        }
    }

    if (plan_result.applied == 0) {
        out_result[0].applied = 0;
        return abi.OMNI_OK;
    }

    var hints = initMutationApplyHints();
    const max_edits = @min(plan_result.edit_count, abi.OMNI_NIRI_MUTATION_MAX_EDITS);
    for (0..max_edits) |idx| {
        const apply_rc = applyMutationEdit(
            runtime_state,
            apply_request,
            plan_result.edits[idx],
            &pre_column_ids,
            &pre_window_ids,
            runtime_state.column_count,
            runtime_state.window_count,
            &hints,
        );
        if (apply_rc != abi.OMNI_OK) return apply_rc;
    }

    const final_validation_rc = validateRuntimeState(runtime_state);
    if (final_validation_rc != abi.OMNI_OK) return final_validation_rc;

    commitRuntimeState(source_ctx, runtime_state);
    out_result[0].applied = 1;
    out_result[0].changed_source_context = 1;
    out_result[0].structural_animation_active = @intFromBool(
        mutationOpTriggersStructuralAnimation(payload.op)
    );

    source_delta_meta.refresh_count = hints.refresh_count;
    source_delta_meta.refresh_column_ids = hints.refresh_column_ids;
    source_delta_meta.reset_all_column_cached_widths = hints.reset_all_column_cached_widths;
    source_delta_meta.has_delegate_move_column = hints.has_delegate_move_column;
    source_delta_meta.delegate_move_column_id = hints.delegate_move_column_id;
    source_delta_meta.delegate_move_direction = hints.delegate_move_direction;

    return abi.OMNI_OK;
}

fn applyWorkspaceTxn(
    source_ctx: *OmniNiriLayoutContext,
    target_ctx: *OmniNiriLayoutContext,
    source_state: *RuntimeState,
    target_state: *RuntimeState,
    payload: abi.OmniNiriTxnWorkspacePayload,
    out_result: [*c]abi.OmniNiriTxnResult,
    source_meta: *TxnDeltaMeta,
    target_meta: *TxnDeltaMeta,
) i32 {
    const target_had_no_windows_before_move = target_state.window_count == 0;

    switch (payload.op) {
        abi.OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE => {
            if (payload.has_source_window_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
        },
        abi.OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE => {
            if (payload.has_source_column_id == 0) return abi.OMNI_ERR_INVALID_ARGS;
        },
        else => return abi.OMNI_ERR_INVALID_ARGS,
    }

    var source_window_index: i64 = -1;
    var source_column_index: i64 = -1;

    var rc = resolveOptionalWindowIndexById(
        source_state,
        payload.has_source_window_id,
        payload.source_window_id,
        &source_window_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    rc = resolveOptionalColumnIndexById(
        source_state,
        payload.has_source_column_id,
        payload.source_column_id,
        &source_column_index,
    );
    if (rc != abi.OMNI_OK) return rc;

    const request: abi.OmniNiriWorkspaceRequest = .{
        .op = payload.op,
        .source_window_index = source_window_index,
        .source_column_index = source_column_index,
        .max_visible_columns = payload.max_visible_columns,
    };

    const apply_request: abi.OmniNiriWorkspaceApplyRequest = .{
        .request = request,
        .has_target_created_column_id = payload.has_target_created_column_id,
        .target_created_column_id = payload.target_created_column_id,
        .has_source_placeholder_column_id = payload.has_source_placeholder_column_id,
        .source_placeholder_column_id = payload.source_placeholder_column_id,
    };

    var plan_result: abi.OmniNiriWorkspaceResult = undefined;
    const planner_rc = workspace.omni_niri_workspace_plan_impl(
        runtimeColumnsStatePtr(source_state),
        source_state.column_count,
        runtimeWindowsStatePtr(source_state),
        source_state.window_count,
        runtimeColumnsStatePtr(target_state),
        target_state.column_count,
        runtimeWindowsStatePtr(target_state),
        target_state.window_count,
        &apply_request.request,
        &plan_result,
    );
    if (planner_rc != abi.OMNI_OK) return planner_rc;

    if (plan_result.applied == 0) return abi.OMNI_OK;

    var pre_source_column_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    var pre_source_window_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    var pre_target_column_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    var pre_target_window_ids: [abi.MAX_WINDOWS]abi.OmniUuid128 = undefined;
    capturePreIds(source_state, &pre_source_column_ids, &pre_source_window_ids);
    capturePreIds(target_state, &pre_target_column_ids, &pre_target_window_ids);

    var remove_source_column_ids: [abi.OMNI_NIRI_WORKSPACE_MAX_EDITS]abi.OmniUuid128 = undefined;
    var remove_source_column_count: usize = 0;

    var has_source_selection_window_id = false;
    var source_selection_window_id = zeroUuid();
    var source_selection_cleared = false;

    var has_target_selection_moved_window = false;
    var target_selection_moved_window_id = zeroUuid();
    var has_target_selection_moved_column = false;
    var target_selection_moved_column_id = zeroUuid();

    var has_reuse_target_column = false;
    var reuse_target_column_id = zeroUuid();
    var create_target_visible_count: i64 = apply_request.request.max_visible_columns;
    var prune_target_empty_columns_if_no_windows = false;

    const max_edits = @min(plan_result.edit_count, abi.OMNI_NIRI_WORKSPACE_MAX_EDITS);
    for (0..max_edits) |idx| {
        const edit = plan_result.edits[idx];
        switch (edit.kind) {
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW => {
                source_selection_window_id = preWindowId(
                    &pre_source_window_ids,
                    source_state.window_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_source_selection_window_id = true;
                source_selection_cleared = false;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE => {
                has_source_selection_window_id = false;
                source_selection_cleared = true;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN => {
                reuse_target_column_id = preColumnId(
                    &pre_target_column_ids,
                    target_state.column_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_reuse_target_column = true;
                create_target_visible_count = edit.value_a;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND => {
                create_target_visible_count = edit.value_a;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS => {
                prune_target_empty_columns_if_no_windows = true;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY => {
                if (remove_source_column_count >= abi.OMNI_NIRI_WORKSPACE_MAX_EDITS) return abi.OMNI_ERR_OUT_OF_RANGE;
                remove_source_column_ids[remove_source_column_count] = preColumnId(
                    &pre_source_column_ids,
                    source_state.column_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                remove_source_column_count += 1;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS => {},
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW => {
                target_selection_moved_window_id = preWindowId(
                    &pre_source_window_ids,
                    source_state.window_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_target_selection_moved_window = true;
                has_target_selection_moved_column = false;
            },
            abi.OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW => {
                target_selection_moved_column_id = preColumnId(
                    &pre_source_column_ids,
                    source_state.column_count,
                    edit.subject_index,
                ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
                has_target_selection_moved_column = true;
                has_target_selection_moved_window = false;
            },
            else => return abi.OMNI_ERR_INVALID_ARGS,
        }
    }

    if (prune_target_empty_columns_if_no_windows and target_state.window_count == 0) {
        var idx: usize = 0;
        while (idx < target_state.column_count) {
            if (target_state.columns[idx].window_count == 0) {
                _ = removeColumnAt(target_state, idx);
            } else {
                idx += 1;
            }
        }
    }

    var moved_window_id_opt: ?abi.OmniUuid128 = null;

    switch (apply_request.request.op) {
        abi.OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE => {
            const moving_window_id = preWindowId(
                &pre_source_window_ids,
                source_state.window_count,
                apply_request.request.source_window_index,
            ) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "moving_window_id");

            const source_window_idx = findWindowIndexByIdCoherent(source_state, moving_window_id) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "source_window_idx");
            const source_column_idx = source_state.windows[source_window_idx].column_index;
            if (source_column_idx >= source_state.column_count) return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "source_column_idx");

            var target_column_id: abi.OmniUuid128 = undefined;
            if (has_reuse_target_column) {
                const target_column_idx = findColumnIndexByIdCoherent(target_state, reuse_target_column_id) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "reuse_target_column_idx");
                if (target_state.columns[target_column_idx].window_count != 0) return workspaceFail(abi.OMNI_ERR_INVALID_ARGS, "reuse_target_not_empty");

                const visible_count_i32 = visibleCountFromRaw(create_target_visible_count);
                if (visible_count_i32 < 0) return workspaceFail(visible_count_i32, "visible_count_i32_reuse");
                const visible_count: usize = @intCast(visible_count_i32);
                target_state.columns[target_column_idx].size_value = 1.0 / @as(f64, @floatFromInt(visible_count));
                target_state.columns[target_column_idx].width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION;
                target_column_id = reuse_target_column_id;
            } else {
                if (apply_request.has_target_created_column_id == 0) return workspaceFail(abi.OMNI_ERR_INVALID_ARGS, "missing_target_created_column_id");
                const unique_target_rc = ensureUniqueColumnId(target_state, apply_request.target_created_column_id);
                if (unique_target_rc != abi.OMNI_OK) return workspaceFail(unique_target_rc, "target_created_column_id_not_unique");

                const visible_count_i32 = visibleCountFromRaw(create_target_visible_count);
                if (visible_count_i32 < 0) return workspaceFail(visible_count_i32, "visible_count_i32");
                const visible_count: usize = @intCast(visible_count_i32);

                const add_column_rc = insertColumnAt(target_state, target_state.column_count, .{
                    .column_id = apply_request.target_created_column_id,
                    .window_start = 0,
                    .window_count = 0,
                    .active_tile_idx = 0,
                    .is_tabbed = 0,
                    .size_value = 1.0 / @as(f64, @floatFromInt(visible_count)),
                    .width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                    .is_full_width = 0,
                    .has_saved_width = 0,
                    .saved_width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
                    .saved_width_value = 1.0,
                });
                if (add_column_rc != abi.OMNI_OK) return workspaceFail(add_column_rc, "add_target_column");
                target_column_id = apply_request.target_created_column_id;
            }

            const moved_window = removeWindowAt(source_state, source_window_idx);
            if (source_state.columns[source_column_idx].window_count == 0) return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "source_window_count_zero");
            source_state.columns[source_column_idx].window_count -= 1;

            const target_column_idx = findColumnIndexByIdCoherent(target_state, target_column_id) orelse return workspaceFail(abi.OMNI_ERR_OUT_OF_RANGE, "target_column_idx_after_add");
            const target_column = target_state.columns[target_column_idx];
            const target_insert_idx = columnWindowStart(target_state, target_column_idx) + target_column.window_count;

            const insert_window_rc = insertWindowAt(target_state, target_insert_idx, moved_window);
            if (insert_window_rc != abi.OMNI_OK) return workspaceFail(insert_window_rc, "insert_window_into_target");
            target_state.columns[target_column_idx].window_count += 1;

            moved_window_id_opt = moving_window_id;
        },
        abi.OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE => {
            const moving_column_id = preColumnId(
                &pre_source_column_ids,
                source_state.column_count,
                apply_request.request.source_column_index,
            ) orelse return abi.OMNI_ERR_OUT_OF_RANGE;

            const source_column_idx = findColumnIndexByIdCoherent(source_state, moving_column_id) orelse return abi.OMNI_ERR_OUT_OF_RANGE;
            const moving_column = source_state.columns[source_column_idx];

            var moved_windows: [abi.MAX_WINDOWS]abi.OmniNiriRuntimeWindowState = undefined;
            const remove_window_rc = removeWindowRange(
                source_state,
                moving_column.window_start,
                moving_column.window_count,
                &moved_windows,
            );
            if (remove_window_rc != abi.OMNI_OK) return remove_window_rc;

            _ = removeColumnAt(source_state, source_column_idx);

            const add_column_rc = insertColumnAt(target_state, target_state.column_count, moving_column);
            if (add_column_rc != abi.OMNI_OK) return add_column_rc;

            const append_windows_rc = appendWindowBatch(target_state, &moved_windows, moving_column.window_count);
            if (append_windows_rc != abi.OMNI_OK) return append_windows_rc;

            if (moving_column.window_count > 0) {
                moved_window_id_opt = moved_windows[0].window_id;
            }
        },
        else => return workspaceFail(abi.OMNI_ERR_INVALID_ARGS, "unknown_workspace_op"),
    }

    for (0..remove_source_column_count) |idx| {
        const remove_id = remove_source_column_ids[idx];
        const remove_idx_opt = findColumnIndexByIdCoherent(source_state, remove_id);
        if (remove_idx_opt) |remove_idx| {
            if (source_state.columns[remove_idx].window_count == 0) {
                _ = removeColumnAt(source_state, remove_idx);
            }
        }
    }

    if (apply_request.request.op == abi.OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE and target_had_no_windows_before_move) {
        var idx: usize = 0;
        while (idx < target_state.column_count) {
            if (target_state.columns[idx].window_count == 0) {
                _ = removeColumnAt(target_state, idx);
            } else {
                idx += 1;
            }
        }
    }

    const should_insert_source_placeholder = source_state.column_count == 0 and apply_request.has_source_placeholder_column_id != 0;
    if (should_insert_source_placeholder) {
        const unique_placeholder_rc = ensureUniqueColumnId(source_state, apply_request.source_placeholder_column_id);
        if (unique_placeholder_rc != abi.OMNI_OK) return unique_placeholder_rc;

        const add_placeholder_rc = insertColumnAt(source_state, 0, .{
            .column_id = apply_request.source_placeholder_column_id,
            .window_start = 0,
            .window_count = 0,
            .active_tile_idx = 0,
            .is_tabbed = 0,
            .size_value = 1.0,
            .width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
            .is_full_width = 0,
            .has_saved_width = 0,
            .saved_width_kind = abi.OMNI_NIRI_SIZE_KIND_PROPORTION,
            .saved_width_value = 1.0,
        });
        if (add_placeholder_rc != abi.OMNI_OK) return add_placeholder_rc;
    }

    const source_refresh_rc = refreshRuntimeStateFast(source_state);
    if (source_refresh_rc != abi.OMNI_OK) return workspaceFail(source_refresh_rc, "source_final_refresh");

    const target_refresh_rc = refreshRuntimeStateFast(target_state);
    if (target_refresh_rc != abi.OMNI_OK) return workspaceFail(target_refresh_rc, "target_final_refresh");

    const source_validation_rc = validateRuntimeState(source_state);
    if (source_validation_rc != abi.OMNI_OK) return workspaceFail(source_validation_rc, "source_final_validation");
    const target_validation_rc = validateRuntimeState(target_state);
    if (target_validation_rc != abi.OMNI_OK) return workspaceFail(target_validation_rc, "target_final_validation");

    if (source_selection_cleared) {
        source_meta.has_source_selection_window_id = false;
    } else if (has_source_selection_window_id) {
        if (findWindowIndexByIdCoherent(source_state, source_selection_window_id) != null) {
            source_meta.has_source_selection_window_id = true;
            source_meta.source_selection_window_id = source_selection_window_id;
        }
    }

    if (has_target_selection_moved_window) {
        if (findWindowIndexByIdCoherent(target_state, target_selection_moved_window_id) != null) {
            target_meta.has_target_selection_window_id = true;
            target_meta.target_selection_window_id = target_selection_moved_window_id;
        }
    } else if (has_target_selection_moved_column) {
        if (findColumnIndexByIdCoherent(target_state, target_selection_moved_column_id)) |column_idx| {
            const column = target_state.columns[column_idx];
            if (column.window_count > 0) {
                target_meta.has_target_selection_window_id = true;
                target_meta.target_selection_window_id = target_state.windows[column.window_start].window_id;
            }
        }
    }

    if (moved_window_id_opt) |moved_window_id| {
        if (findWindowIndexByIdCoherent(target_state, moved_window_id) != null) {
            target_meta.has_moved_window_id = true;
            target_meta.moved_window_id = moved_window_id;
        }
    }

    commitRuntimeState(source_ctx, source_state);
    commitRuntimeState(target_ctx, target_state);
    out_result[0].applied = 1;
    out_result[0].changed_source_context = 1;
    out_result[0].changed_target_context = 1;
    out_result[0].structural_animation_active = 1;

    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_export_delta_impl(
    context: [*c]const OmniNiriLayoutContext,
    out_export: [*c]abi.OmniNiriTxnDeltaExport,
) i32 {
    const ctx = asConstContext(context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (out_export == null) return abi.OMNI_ERR_INVALID_ARGS;

    out_export[0] = .{
        .columns = if (ctx.last_delta_column_count > 0) @ptrCast(&ctx.last_delta_columns[0]) else null,
        .column_count = ctx.last_delta_column_count,
        .windows = if (ctx.last_delta_window_count > 0) @ptrCast(&ctx.last_delta_windows[0]) else null,
        .window_count = ctx.last_delta_window_count,
        .removed_column_ids = if (ctx.last_delta_removed_column_count > 0) @ptrCast(&ctx.last_delta_removed_column_ids[0]) else null,
        .removed_column_count = ctx.last_delta_removed_column_count,
        .removed_window_ids = if (ctx.last_delta_removed_window_count > 0) @ptrCast(&ctx.last_delta_removed_window_ids[0]) else null,
        .removed_window_count = ctx.last_delta_removed_window_count,
        .refresh_tabbed_visibility_count = ctx.last_delta_refresh_count,
        .refresh_tabbed_visibility_column_ids = ctx.last_delta_refresh_column_ids,
        .reset_all_column_cached_widths = ctx.last_delta_reset_all_column_cached_widths,
        .has_delegate_move_column = ctx.last_delta_has_delegate_move_column,
        .delegate_move_column_id = ctx.last_delta_delegate_move_column_id,
        .delegate_move_direction = ctx.last_delta_delegate_move_direction,
        .has_target_window_id = ctx.last_delta_has_target_window_id,
        .target_window_id = ctx.last_delta_target_window_id,
        .has_target_node_id = ctx.last_delta_has_target_node_id,
        .target_node_kind = ctx.last_delta_target_node_kind,
        .target_node_id = ctx.last_delta_target_node_id,
        .has_source_selection_window_id = ctx.last_delta_has_source_selection_window_id,
        .source_selection_window_id = ctx.last_delta_source_selection_window_id,
        .has_target_selection_window_id = ctx.last_delta_has_target_selection_window_id,
        .target_selection_window_id = ctx.last_delta_target_selection_window_id,
        .has_moved_window_id = ctx.last_delta_has_moved_window_id,
        .moved_window_id = ctx.last_delta_moved_window_id,
        .generation = ctx.last_delta_generation,
    };

    return abi.OMNI_OK;
}

pub fn omni_niri_ctx_apply_txn_impl(
    source_context: [*c]OmniNiriLayoutContext,
    target_context: [*c]OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriTxnRequest,
    out_result: [*c]abi.OmniNiriTxnResult,
) i32 {
    const source_ctx = asMutableContext(source_context) orelse return abi.OMNI_ERR_INVALID_ARGS;
    if (request == null or out_result == null) return abi.OMNI_ERR_INVALID_ARGS;

    initTxnResult(out_result);
    out_result[0].kind = request[0].kind;

    const pre_source_state = runtimeStateFromContext(source_ctx);
    var source_state = pre_source_state;
    var source_delta_meta = initTxnDeltaMeta();

    switch (request[0].kind) {
        abi.OMNI_NIRI_TXN_NAVIGATION => {
            const rc = applyNavigationTxn(
                source_ctx,
                &source_state,
                request[0].navigation,
                out_result,
                &source_delta_meta,
            );
            out_result[0].error_code = rc;
            if (rc != abi.OMNI_OK) return rc;

            const delta_rc = storeTxnDeltaForContext(source_ctx, &pre_source_state, &source_delta_meta);
            if (delta_rc != abi.OMNI_OK) return delta_rc;

            out_result[0].delta_column_count = source_ctx.last_delta_column_count;
            out_result[0].delta_window_count = source_ctx.last_delta_window_count;
            out_result[0].removed_column_count = source_ctx.last_delta_removed_column_count;
            out_result[0].removed_window_count = source_ctx.last_delta_removed_window_count;
            return abi.OMNI_OK;
        },
        abi.OMNI_NIRI_TXN_MUTATION => {
            const rc = applyMutationTxn(
                source_ctx,
                &source_state,
                request[0].mutation,
                out_result,
                &source_delta_meta,
            );
            out_result[0].error_code = rc;
            if (rc != abi.OMNI_OK) return rc;

            const delta_rc = storeTxnDeltaForContext(source_ctx, &pre_source_state, &source_delta_meta);
            if (delta_rc != abi.OMNI_OK) return delta_rc;

            out_result[0].delta_column_count = source_ctx.last_delta_column_count;
            out_result[0].delta_window_count = source_ctx.last_delta_window_count;
            out_result[0].removed_column_count = source_ctx.last_delta_removed_column_count;
            out_result[0].removed_window_count = source_ctx.last_delta_removed_window_count;
            return abi.OMNI_OK;
        },
        abi.OMNI_NIRI_TXN_WORKSPACE => {
            const target_ctx = asMutableContext(target_context) orelse return abi.OMNI_ERR_INVALID_ARGS;
            const pre_target_state = runtimeStateFromContext(target_ctx);
            var target_state = pre_target_state;
            var source_meta = initTxnDeltaMeta();
            var target_meta = initTxnDeltaMeta();

            const rc = applyWorkspaceTxn(
                source_ctx,
                target_ctx,
                &source_state,
                &target_state,
                request[0].workspace,
                out_result,
                &source_meta,
                &target_meta,
            );
            out_result[0].error_code = rc;
            if (rc != abi.OMNI_OK) return rc;

            const source_delta_rc = storeTxnDeltaForContext(source_ctx, &pre_source_state, &source_meta);
            if (source_delta_rc != abi.OMNI_OK) return source_delta_rc;
            const target_delta_rc = storeTxnDeltaForContext(target_ctx, &pre_target_state, &target_meta);
            if (target_delta_rc != abi.OMNI_OK) return target_delta_rc;

            out_result[0].delta_column_count = source_ctx.last_delta_column_count + target_ctx.last_delta_column_count;
            out_result[0].delta_window_count = source_ctx.last_delta_window_count + target_ctx.last_delta_window_count;
            out_result[0].removed_column_count = source_ctx.last_delta_removed_column_count + target_ctx.last_delta_removed_column_count;
            out_result[0].removed_window_count = source_ctx.last_delta_removed_window_count + target_ctx.last_delta_removed_window_count;
            return abi.OMNI_OK;
        },
        else => {
            out_result[0].error_code = abi.OMNI_ERR_INVALID_ARGS;
            return abi.OMNI_ERR_INVALID_ARGS;
        },
    }
}

test "layout pass v3 handles columns with zero windows and keeps empty interaction cache" {
    const testing = std.testing;

    const context = omni_niri_layout_context_create_impl();
    defer omni_niri_layout_context_destroy_impl(context);
    try testing.expect(context != null);

    var columns = [_]abi.OmniNiriColumnInput{
        .{
            .span = 120.0,
            .render_offset_x = 0.0,
            .render_offset_y = 0.0,
            .is_tabbed = 0,
            .tab_indicator_width = 0.0,
            .window_start = 0,
            .window_count = 0,
        },
    };
    var out_columns = [_]abi.OmniNiriColumnOutput{
        .{
            .frame_x = 0.0,
            .frame_y = 0.0,
            .frame_width = 0.0,
            .frame_height = 0.0,
            .hide_side = abi.OMNI_NIRI_HIDE_NONE,
            .is_visible = 0,
        },
    };

    const rc = omni_niri_layout_pass_v3_impl(
        context,
        &columns,
        columns.len,
        null,
        0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        0.0,
        0.0,
        1920.0,
        1080.0,
        8.0,
        8.0,
        0.0,
        1920.0,
        0.0,
        1.0,
        abi.OMNI_NIRI_ORIENTATION_HORIZONTAL,
        null,
        0,
        &out_columns,
        out_columns.len,
    );
    try testing.expectEqual(@as(i32, abi.OMNI_OK), rc);

    const resolved_ctx = asConstContext(context).?;
    try testing.expectEqual(@as(usize, 0), resolved_ctx.interaction_window_count);
}
