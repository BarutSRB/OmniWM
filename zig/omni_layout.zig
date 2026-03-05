/// omni_layout.zig
///
/// ABI facade for the OmniWM Zig kernel.
/// Internal logic lives in `zig/omni/` modules:
/// - `abi_types.zig`: C ABI structs/constants
/// - `state_validation.zig`: snapshot validation
/// - `interaction.zig`: hit-testing/dropzone/resize math
/// - `viewport.zig`: viewport offset/snap math
/// - `layout_context.zig`: context-based Niri layout and state ops
/// - `dwindle.zig`: Dwindle context ABI scaffolding

const abi = @import("omni/abi_types.zig");
const state_validation = @import("omni/state_validation.zig");
const interaction = @import("omni/interaction.zig");
const layout_context = @import("omni/layout_context.zig");
const viewport = @import("omni/viewport.zig");
const dwindle = @import("omni/dwindle.zig");

/// Validate a Niri state snapshot for bounds, ownership, and assignment consistency.
///
/// Populates `out_result` and returns `OMNI_OK` when valid, otherwise an error code.
export fn omni_niri_validate_state_snapshot(
    columns: [*c]const abi.OmniNiriStateColumnInput,
    column_count: usize,
    windows: [*c]const abi.OmniNiriStateWindowInput,
    window_count: usize,
    out_result: [*c]abi.OmniNiriStateValidationResult,
) i32 {
    return state_validation.omni_niri_validate_state_snapshot_impl(
        columns,
        column_count,
        windows,
        window_count,
        out_result,
    );
}

/// Create a reusable Niri layout context.
export fn omni_niri_layout_context_create() [*c]layout_context.OmniNiriLayoutContext {
    return layout_context.omni_niri_layout_context_create_impl();
}

/// Destroy a reusable Niri layout context.
export fn omni_niri_layout_context_destroy(context: [*c]layout_context.OmniNiriLayoutContext) void {
    layout_context.omni_niri_layout_context_destroy_impl(context);
}

/// Seed context interaction buffers directly (primarily for tests and parity harnesses).
export fn omni_niri_layout_context_set_interaction(
    context: [*c]layout_context.OmniNiriLayoutContext,
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    column_dropzones: [*c]const abi.OmniNiriColumnDropzoneMeta,
    column_count: usize,
) i32 {
    return layout_context.omni_niri_layout_context_set_interaction_impl(
        context,
        windows,
        window_count,
        column_dropzones,
        column_count,
    );
}

/// Run Niri tiled layout pass and update a reusable context with hit-test/dropzone feed data.
export fn omni_niri_layout_pass_v3(
    context: [*c]layout_context.OmniNiriLayoutContext,
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
    return layout_context.omni_niri_layout_pass_v3_impl(
        context,
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
}

/// Hit-test tiled windows and return the first window index containing the point.
export fn omni_niri_hit_test_tiled(
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    out_window_index: [*c]i64,
) i32 {
    return interaction.omni_niri_hit_test_tiled_impl(
        windows,
        window_count,
        point_x,
        point_y,
        out_window_index,
    );
}

/// Hit-test tiled windows from a reusable context.
export fn omni_niri_ctx_hit_test_tiled(
    context: [*c]const layout_context.OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    out_window_index: [*c]i64,
) i32 {
    return layout_context.omni_niri_ctx_hit_test_tiled_impl(
        context,
        point_x,
        point_y,
        out_window_index,
    );
}

/// Hit-test resize edges for tiled windows.
export fn omni_niri_hit_test_resize(
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    threshold: f64,
    out_result: [*c]abi.OmniNiriResizeHitResult,
) i32 {
    return interaction.omni_niri_hit_test_resize_impl(
        windows,
        window_count,
        point_x,
        point_y,
        threshold,
        out_result,
    );
}

/// Hit-test resize edges from a reusable context.
export fn omni_niri_ctx_hit_test_resize(
    context: [*c]const layout_context.OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    threshold: f64,
    out_result: [*c]abi.OmniNiriResizeHitResult,
) i32 {
    return layout_context.omni_niri_ctx_hit_test_resize_impl(
        context,
        point_x,
        point_y,
        threshold,
        out_result,
    );
}

/// Hit-test a move target and insertion position for a drag point.
export fn omni_niri_hit_test_move_target(
    windows: [*c]const abi.OmniNiriHitTestWindow,
    window_count: usize,
    point_x: f64,
    point_y: f64,
    excluding_window_index: i64,
    is_insert_mode: u8,
    out_result: [*c]abi.OmniNiriMoveTargetResult,
) i32 {
    return interaction.omni_niri_hit_test_move_target_impl(
        windows,
        window_count,
        point_x,
        point_y,
        excluding_window_index,
        is_insert_mode,
        out_result,
    );
}

/// Hit-test move target from a reusable context.
export fn omni_niri_ctx_hit_test_move_target(
    context: [*c]const layout_context.OmniNiriLayoutContext,
    point_x: f64,
    point_y: f64,
    excluding_window_index: i64,
    is_insert_mode: u8,
    out_result: [*c]abi.OmniNiriMoveTargetResult,
) i32 {
    return layout_context.omni_niri_ctx_hit_test_move_target_impl(
        context,
        point_x,
        point_y,
        excluding_window_index,
        is_insert_mode,
        out_result,
    );
}

/// Compute insertion dropzone frame for before/after/swap placement.
export fn omni_niri_insertion_dropzone(
    input: [*c]const abi.OmniNiriDropzoneInput,
    out_result: [*c]abi.OmniNiriDropzoneResult,
) i32 {
    return interaction.omni_niri_insertion_dropzone_impl(input, out_result);
}

/// Compute insertion dropzone from a reusable context by target window index.
export fn omni_niri_ctx_insertion_dropzone(
    context: [*c]const layout_context.OmniNiriLayoutContext,
    target_window_index: i64,
    gap: f64,
    insert_position: u8,
    out_result: [*c]abi.OmniNiriDropzoneResult,
) i32 {
    return layout_context.omni_niri_ctx_insertion_dropzone_impl(
        context,
        target_window_index,
        gap,
        insert_position,
        out_result,
    );
}

/// Seed authoritative runtime state into a reusable context.
export fn omni_niri_ctx_seed_runtime_state(
    context: [*c]layout_context.OmniNiriLayoutContext,
    columns: [*c]const abi.OmniNiriRuntimeColumnState,
    column_count: usize,
    windows: [*c]const abi.OmniNiriRuntimeWindowState,
    window_count: usize,
) i32 {
    return layout_context.omni_niri_ctx_seed_runtime_state_impl(
        context,
        columns,
        column_count,
        windows,
        window_count,
    );
}

/// Apply one Niri transaction against source/target authoritative runtime contexts.
export fn omni_niri_ctx_apply_txn(
    source_context: [*c]layout_context.OmniNiriLayoutContext,
    target_context: [*c]layout_context.OmniNiriLayoutContext,
    request: [*c]const abi.OmniNiriTxnRequest,
    out_result: [*c]abi.OmniNiriTxnResult,
) i32 {
    return layout_context.omni_niri_ctx_apply_txn_impl(
        source_context,
        target_context,
        request,
        out_result,
    );
}

/// Export context-owned transaction delta pointers/counts from last apply.
export fn omni_niri_ctx_export_delta(
    context: [*c]const layout_context.OmniNiriLayoutContext,
    out_export: [*c]abi.OmniNiriTxnDeltaExport,
) i32 {
    return layout_context.omni_niri_ctx_export_delta_impl(
        context,
        out_export,
    );
}

/// Create a reusable Dwindle layout context.
export fn omni_dwindle_layout_context_create() [*c]dwindle.OmniDwindleLayoutContext {
    return dwindle.omni_dwindle_layout_context_create_impl();
}

/// Destroy a reusable Dwindle layout context.
export fn omni_dwindle_layout_context_destroy(context: [*c]dwindle.OmniDwindleLayoutContext) void {
    dwindle.omni_dwindle_layout_context_destroy_impl(context);
}

/// Seed deterministic Dwindle state topology into a context.
export fn omni_dwindle_ctx_seed_state(
    context: [*c]dwindle.OmniDwindleLayoutContext,
    nodes: [*c]const abi.OmniDwindleSeedNode,
    node_count: usize,
    seed_state: [*c]const abi.OmniDwindleSeedState,
) i32 {
    return dwindle.omni_dwindle_ctx_seed_state_impl(
        context,
        nodes,
        node_count,
        seed_state,
    );
}

/// Apply a single Dwindle operation to context state.
export fn omni_dwindle_ctx_apply_op(
    context: [*c]dwindle.OmniDwindleLayoutContext,
    request: [*c]const abi.OmniDwindleOpRequest,
    out_result: [*c]abi.OmniDwindleOpResult,
    out_removed_window_ids: [*c]abi.OmniUuid128,
    out_removed_window_capacity: usize,
) i32 {
    return dwindle.omni_dwindle_ctx_apply_op_impl(
        context,
        request,
        out_result,
        out_removed_window_ids,
        out_removed_window_capacity,
    );
}

/// Calculate Dwindle output frames for current context state.
export fn omni_dwindle_ctx_calculate_layout(
    context: [*c]dwindle.OmniDwindleLayoutContext,
    request: [*c]const abi.OmniDwindleLayoutRequest,
    constraints: [*c]const abi.OmniDwindleWindowConstraint,
    constraint_count: usize,
    out_frames: [*c]abi.OmniDwindleWindowFrame,
    out_frame_capacity: usize,
    out_frame_count: [*c]usize,
) i32 {
    return dwindle.omni_dwindle_ctx_calculate_layout_impl(
        context,
        request,
        constraints,
        constraint_count,
        out_frames,
        out_frame_capacity,
        out_frame_count,
    );
}

/// Resolve directional Dwindle neighbor from cached context state.
export fn omni_dwindle_ctx_find_neighbor(
    context: [*c]const dwindle.OmniDwindleLayoutContext,
    window_id: abi.OmniUuid128,
    direction: u8,
    inner_gap: f64,
    out_has_neighbor: [*c]u8,
    out_neighbor_window_id: [*c]abi.OmniUuid128,
) i32 {
    return dwindle.omni_dwindle_ctx_find_neighbor_impl(
        context,
        window_id,
        direction,
        inner_gap,
        out_has_neighbor,
        out_neighbor_window_id,
    );
}

/// Compute interactive resize result for column width/window weight.
export fn omni_niri_resize_compute(
    input: [*c]const abi.OmniNiriResizeInput,
    out_result: [*c]abi.OmniNiriResizeResult,
) i32 {
    return interaction.omni_niri_resize_compute_impl(input, out_result);
}

/// Compute the viewport offset needed to reveal a target container.
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
    return viewport.omni_viewport_compute_visible_offset_impl(
        spans,
        span_count,
        container_index,
        gap,
        viewport_span,
        current_view_start,
        center_mode,
        always_center_single_column,
        from_container_index,
        out_target_offset,
    );
}

/// Build transition plan values for switching active viewport container.
export fn omni_viewport_transition_to_column(
    spans: [*c]const f64,
    span_count: usize,
    current_active_index: usize,
    requested_index: usize,
    gap: f64,
    viewport_span: f64,
    current_target_offset: f64,
    center_mode: u8,
    always_center_single_column: u8,
    from_container_index: i64,
    scale: f64,
    out_result: [*c]abi.OmniViewportTransitionResult,
) i32 {
    return viewport.omni_viewport_transition_to_column_impl(
        spans,
        span_count,
        current_active_index,
        requested_index,
        gap,
        viewport_span,
        current_target_offset,
        center_mode,
        always_center_single_column,
        from_container_index,
        scale,
        out_result,
    );
}

/// Build ensure-visible plan for a viewport container target.
export fn omni_viewport_ensure_visible(
    spans: [*c]const f64,
    span_count: usize,
    active_container_index: usize,
    target_container_index: usize,
    gap: f64,
    viewport_span: f64,
    current_offset: f64,
    center_mode: u8,
    always_center_single_column: u8,
    from_container_index: i64,
    epsilon: f64,
    out_result: [*c]abi.OmniViewportEnsureVisibleResult,
) i32 {
    return viewport.omni_viewport_ensure_visible_impl(
        spans,
        span_count,
        active_container_index,
        target_container_index,
        gap,
        viewport_span,
        current_offset,
        center_mode,
        always_center_single_column,
        from_container_index,
        epsilon,
        out_result,
    );
}

/// Apply one scroll delta in viewport space.
export fn omni_viewport_scroll_step(
    spans: [*c]const f64,
    span_count: usize,
    delta_pixels: f64,
    viewport_span: f64,
    gap: f64,
    current_offset: f64,
    selection_progress: f64,
    change_selection: u8,
    out_result: [*c]abi.OmniViewportScrollResult,
) i32 {
    return viewport.omni_viewport_scroll_step_impl(
        spans,
        span_count,
        delta_pixels,
        viewport_span,
        gap,
        current_offset,
        selection_progress,
        change_selection,
        out_result,
    );
}

/// Initialize viewport gesture tracking state.
export fn omni_viewport_gesture_begin(
    current_view_offset: f64,
    is_trackpad: u8,
    out_state: [*c]abi.OmniViewportGestureState,
) i32 {
    return viewport.omni_viewport_gesture_begin_impl(
        current_view_offset,
        is_trackpad,
        out_state,
    );
}

/// Compute current gesture velocity from tracker history.
export fn omni_viewport_gesture_velocity(
    gesture_state: [*c]const abi.OmniViewportGestureState,
    out_velocity: [*c]f64,
) i32 {
    return viewport.omni_viewport_gesture_velocity_impl(
        gesture_state,
        out_velocity,
    );
}

/// Update viewport gesture tracking state with one delta sample.
export fn omni_viewport_gesture_update(
    gesture_state: [*c]abi.OmniViewportGestureState,
    spans: [*c]const f64,
    span_count: usize,
    active_container_index: usize,
    delta_pixels: f64,
    timestamp: f64,
    gap: f64,
    viewport_span: f64,
    selection_progress: f64,
    out_result: [*c]abi.OmniViewportGestureUpdateResult,
) i32 {
    return viewport.omni_viewport_gesture_update_impl(
        gesture_state,
        spans,
        span_count,
        active_container_index,
        delta_pixels,
        timestamp,
        gap,
        viewport_span,
        selection_progress,
        out_result,
    );
}

/// Resolve viewport gesture end snap target and spring endpoints.
export fn omni_viewport_gesture_end(
    gesture_state: [*c]const abi.OmniViewportGestureState,
    spans: [*c]const f64,
    span_count: usize,
    active_container_index: usize,
    gap: f64,
    viewport_span: f64,
    center_mode: u8,
    always_center_single_column: u8,
    out_result: [*c]abi.OmniViewportGestureEndResult,
) i32 {
    return viewport.omni_viewport_gesture_end_impl(
        gesture_state,
        spans,
        span_count,
        active_container_index,
        gap,
        viewport_span,
        center_mode,
        always_center_single_column,
        out_result,
    );
}
