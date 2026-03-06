const std = @import("std");
const abi = @import("abi_types.zig");
const layout_context = @import("layout_context.zig");

pub const OmniNiriRuntime = layout_context.OmniNiriLayoutContext;

pub fn omni_niri_runtime_create_impl() [*c]OmniNiriRuntime {
    return @ptrCast(layout_context.omni_niri_layout_context_create_impl());
}

pub fn omni_niri_runtime_destroy_impl(runtime: [*c]OmniNiriRuntime) void {
    layout_context.omni_niri_layout_context_destroy_impl(@ptrCast(runtime));
}

pub fn omni_niri_runtime_seed_impl(
    runtime: [*c]OmniNiriRuntime,
    request: [*c]const abi.OmniNiriRuntimeSeedRequest,
) i32 {
    if (request == null) return abi.OMNI_ERR_INVALID_ARGS;
    return layout_context.omni_niri_ctx_seed_runtime_state_impl(
        @ptrCast(runtime),
        request[0].columns,
        request[0].column_count,
        request[0].windows,
        request[0].window_count,
    );
}

pub fn omni_niri_runtime_apply_command_impl(
    source_runtime: [*c]OmniNiriRuntime,
    target_runtime: [*c]OmniNiriRuntime,
    request: [*c]const abi.OmniNiriRuntimeCommandRequest,
    out_result: [*c]abi.OmniNiriRuntimeCommandResult,
) i32 {
    if (request == null or out_result == null) return abi.OMNI_ERR_INVALID_ARGS;
    if (source_runtime == null) {
        var invalid_txn = std.mem.zeroes(abi.OmniNiriTxnResult);
        invalid_txn.kind = request[0].txn.kind;
        invalid_txn.error_code = abi.OMNI_ERR_INVALID_ARGS;
        out_result[0] = .{ .txn = invalid_txn };
        return abi.OMNI_ERR_INVALID_ARGS;
    }

    var txn_result = std.mem.zeroes(abi.OmniNiriTxnResult);
    txn_result.kind = request[0].txn.kind;
    const rc = layout_context.omni_niri_ctx_apply_txn_impl(
        @ptrCast(source_runtime),
        @ptrCast(target_runtime),
        &request[0].txn,
        &txn_result,
    );
    if (rc != abi.OMNI_OK) {
        txn_result.error_code = rc;
    } else if (txn_result.structural_animation_active != 0) {
        layout_context.startRuntimeAnimation(
            @ptrCast(&source_runtime[0]),
            layout_context.RUNTIME_ANIMATION_MUTATION,
            request[0].sample_time,
            layout_context.NIRI_MUTATION_ANIMATION_DURATION,
        );
    }
    out_result[0] = .{ .txn = txn_result };
    return rc;
}

pub fn omni_niri_runtime_render_impl(
    runtime: [*c]OmniNiriRuntime,
    layout: [*c]layout_context.OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriRuntimeRenderRequest,
    out_output: [*c]abi.OmniNiriRuntimeRenderOutput,
) i32 {
    if (runtime == null or request == null or out_output == null) return abi.OMNI_ERR_INVALID_ARGS;

    const runtime_ctx: *OmniNiriRuntime = @ptrCast(&runtime[0]);
    const render_ctx: [*c]layout_context.OmniNiriLayoutContext = if (layout != null) layout else @ptrCast(runtime);

    if (request[0].column_count != runtime_ctx.runtime_column_count or
        request[0].window_count != runtime_ctx.runtime_window_count)
    {
        return abi.OMNI_ERR_OUT_OF_RANGE;
    }

    out_output[0].animation_active = 0;

    const rc = layout_context.omni_niri_layout_pass_v3_impl(
        render_ctx,
        request[0].columns,
        request[0].column_count,
        request[0].windows,
        request[0].window_count,
        request[0].working_x,
        request[0].working_y,
        request[0].working_width,
        request[0].working_height,
        request[0].view_x,
        request[0].view_y,
        request[0].view_width,
        request[0].view_height,
        request[0].fullscreen_x,
        request[0].fullscreen_y,
        request[0].fullscreen_width,
        request[0].fullscreen_height,
        request[0].primary_gap,
        request[0].secondary_gap,
        request[0].view_start,
        request[0].viewport_span,
        request[0].workspace_offset,
        request[0].scale,
        request[0].orientation,
        out_output[0].windows,
        out_output[0].window_count,
        out_output[0].columns,
        out_output[0].column_count,
    );
    if (rc != abi.OMNI_OK) return rc;

    out_output[0].animation_active = layout_context.applyRuntimeAnimationToOutputs(
        runtime_ctx,
        request[0].sample_time,
        request[0].orientation,
        request[0].scale,
        out_output[0].windows,
        out_output[0].window_count,
    );
    return abi.OMNI_OK;
}

pub fn omni_niri_runtime_snapshot_impl(
    runtime: [*c]const OmniNiriRuntime,
    out_export: [*c]abi.OmniNiriRuntimeStateExport,
) i32 {
    return layout_context.omni_niri_ctx_export_runtime_state_impl(
        @ptrCast(runtime),
        out_export,
    );
}

pub fn omni_niri_runtime_start_workspace_switch_animation_impl(
    runtime: [*c]OmniNiriRuntime,
    sample_time: f64,
) i32 {
    return layout_context.omni_niri_ctx_start_workspace_switch_animation_impl(
        @ptrCast(runtime),
        sample_time,
    );
}

pub fn omni_niri_runtime_start_mutation_animation_impl(
    runtime: [*c]OmniNiriRuntime,
    sample_time: f64,
) i32 {
    if (runtime == null) return abi.OMNI_ERR_INVALID_ARGS;
    layout_context.startRuntimeAnimation(
        @ptrCast(&runtime[0]),
        layout_context.RUNTIME_ANIMATION_MUTATION,
        sample_time,
        layout_context.NIRI_MUTATION_ANIMATION_DURATION,
    );
    return abi.OMNI_OK;
}

pub fn omni_niri_runtime_cancel_animation_impl(runtime: [*c]OmniNiriRuntime) i32 {
    return layout_context.omni_niri_ctx_cancel_animation_impl(@ptrCast(runtime));
}

pub fn omni_niri_runtime_animation_active_impl(
    runtime: [*c]OmniNiriRuntime,
    sample_time: f64,
    out_active: [*c]u8,
) i32 {
    return layout_context.omni_niri_ctx_animation_active_impl(
        @ptrCast(runtime),
        sample_time,
        out_active,
    );
}

pub fn omni_niri_runtime_viewport_status_impl(
    runtime: [*c]OmniNiriRuntime,
    sample_time: f64,
    out_status: [*c]abi.OmniNiriRuntimeViewportStatus,
) i32 {
    return layout_context.omni_niri_ctx_viewport_status_impl(
        @ptrCast(runtime),
        sample_time,
        out_status,
    );
}

pub fn omni_niri_runtime_viewport_begin_gesture_impl(
    runtime: [*c]OmniNiriRuntime,
    sample_time: f64,
    is_trackpad: u8,
) i32 {
    return layout_context.omni_niri_ctx_viewport_begin_gesture_impl(
        @ptrCast(runtime),
        sample_time,
        is_trackpad,
    );
}

pub fn omni_niri_runtime_viewport_update_gesture_impl(
    runtime: [*c]OmniNiriRuntime,
    spans: [*c]const f64,
    span_count: usize,
    delta_pixels: f64,
    timestamp: f64,
    gap: f64,
    viewport_span: f64,
    out_result: [*c]abi.OmniViewportGestureUpdateResult,
) i32 {
    return layout_context.omni_niri_ctx_viewport_update_gesture_impl(
        @ptrCast(runtime),
        spans,
        span_count,
        delta_pixels,
        timestamp,
        gap,
        viewport_span,
        out_result,
    );
}

pub fn omni_niri_runtime_viewport_end_gesture_impl(
    runtime: [*c]OmniNiriRuntime,
    spans: [*c]const f64,
    span_count: usize,
    gap: f64,
    viewport_span: f64,
    center_mode: u8,
    always_center_single_column: u8,
    sample_time: f64,
    display_refresh_rate: f64,
    reduce_motion: u8,
    out_result: [*c]abi.OmniViewportGestureEndResult,
) i32 {
    return layout_context.omni_niri_ctx_viewport_end_gesture_impl(
        @ptrCast(runtime),
        spans,
        span_count,
        gap,
        viewport_span,
        center_mode,
        always_center_single_column,
        sample_time,
        display_refresh_rate,
        reduce_motion,
        out_result,
    );
}

pub fn omni_niri_runtime_viewport_transition_to_column_impl(
    runtime: [*c]OmniNiriRuntime,
    spans: [*c]const f64,
    span_count: usize,
    requested_index: usize,
    gap: f64,
    viewport_span: f64,
    center_mode: u8,
    always_center_single_column: u8,
    animate: u8,
    scale: f64,
    sample_time: f64,
    display_refresh_rate: f64,
    reduce_motion: u8,
    out_result: [*c]abi.OmniViewportTransitionResult,
) i32 {
    return layout_context.omni_niri_ctx_viewport_transition_to_column_impl(
        @ptrCast(runtime),
        spans,
        span_count,
        requested_index,
        gap,
        viewport_span,
        center_mode,
        always_center_single_column,
        animate,
        scale,
        sample_time,
        display_refresh_rate,
        reduce_motion,
        out_result,
    );
}

pub fn omni_niri_runtime_viewport_set_offset_impl(
    runtime: [*c]OmniNiriRuntime,
    offset: f64,
) i32 {
    return layout_context.omni_niri_ctx_viewport_set_offset_impl(
        @ptrCast(runtime),
        offset,
    );
}

pub fn omni_niri_runtime_viewport_cancel_impl(
    runtime: [*c]OmniNiriRuntime,
    sample_time: f64,
) i32 {
    return layout_context.omni_niri_ctx_viewport_cancel_impl(
        @ptrCast(runtime),
        sample_time,
    );
}

test "runtime apply command returns deterministic txn output when source runtime is null" {
    const testing = std.testing;

    const request = abi.OmniNiriRuntimeCommandRequest{
        .txn = .{
            .kind = abi.OMNI_NIRI_TXN_MUTATION,
            .navigation = std.mem.zeroes(abi.OmniNiriTxnNavigationPayload),
            .mutation = std.mem.zeroes(abi.OmniNiriTxnMutationPayload),
            .workspace = std.mem.zeroes(abi.OmniNiriTxnWorkspacePayload),
            .max_delta_columns = 0,
            .max_delta_windows = 0,
            .max_removed_ids = 0,
        },
        .sample_time = 123.0,
    };
    var result = std.mem.zeroes(abi.OmniNiriRuntimeCommandResult);

    const rc = omni_niri_runtime_apply_command_impl(
        null,
        null,
        &request,
        &result,
    );

    try testing.expectEqual(@as(i32, abi.OMNI_ERR_INVALID_ARGS), rc);
    try testing.expectEqual(@as(u8, abi.OMNI_NIRI_TXN_MUTATION), result.txn.kind);
    try testing.expectEqual(@as(i32, abi.OMNI_ERR_INVALID_ARGS), result.txn.error_code);
    try testing.expectEqual(@as(u8, 0), result.txn.applied);
    try testing.expectEqual(@as(u8, 0), result.txn.structural_animation_active);
    try testing.expectEqual(@as(usize, 0), result.txn.delta_column_count);
    try testing.expectEqual(@as(usize, 0), result.txn.delta_window_count);
}
