pub const OmniAxisInput = extern struct {
    weight: f64,
    min_constraint: f64,
    max_constraint: f64,
    has_max_constraint: u8,
    is_constraint_fixed: u8,
    has_fixed_value: u8,
    fixed_value: f64,
};

pub const OmniAxisOutput = extern struct {
    value: f64,
    was_constrained: u8,
};

pub const OmniSnapResult = extern struct {
    view_pos: f64,
    column_index: usize,
};

pub const OmniViewportGestureState = extern struct {
    is_trackpad: u8,
    history_count: usize,
    history_head: usize,
    tracker_position: f64,
    current_view_offset: f64,
    stationary_view_offset: f64,
    delta_from_tracker: f64,
    history_deltas: [OMNI_VIEWPORT_GESTURE_HISTORY_CAP]f64,
    history_timestamps: [OMNI_VIEWPORT_GESTURE_HISTORY_CAP]f64,
};

pub const OmniViewportTransitionResult = extern struct {
    resolved_column_index: usize,
    offset_delta: f64,
    adjusted_target_offset: f64,
    target_offset: f64,
    snap_delta: f64,
    snap_to_target_immediately: u8,
};

pub const OmniViewportEnsureVisibleResult = extern struct {
    target_offset: f64,
    offset_delta: f64,
    is_noop: u8,
};

pub const OmniViewportScrollResult = extern struct {
    applied: u8,
    new_offset: f64,
    selection_progress: f64,
    has_selection_steps: u8,
    selection_steps: i64,
};

pub const OmniViewportGestureUpdateResult = extern struct {
    current_view_offset: f64,
    selection_progress: f64,
    has_selection_steps: u8,
    selection_steps: i64,
};

pub const OmniViewportGestureEndResult = extern struct {
    resolved_column_index: usize,
    spring_from: f64,
    spring_to: f64,
    initial_velocity: f64,
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

pub const OmniNiriColumnDropzoneMeta = extern struct {
    is_valid: u8,
    min_y: f64,
    max_y: f64,
    post_insertion_count: usize,
};

pub const OmniNiriResizeHitResult = extern struct {
    window_index: i64,
    edges: u8,
};

pub const OmniNiriMoveTargetResult = extern struct {
    window_index: i64,
    insert_position: u8,
};

pub const OmniNiriDropzoneInput = extern struct {
    target_frame_x: f64,
    target_frame_y: f64,
    target_frame_width: f64,
    target_frame_height: f64,
    column_min_y: f64,
    column_max_y: f64,
    gap: f64,
    insert_position: u8,
    post_insertion_count: usize,
};

pub const OmniNiriDropzoneResult = extern struct {
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
    is_valid: u8,
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

pub const OmniUuid128 = extern struct {
    bytes: [16]u8,
};

pub const OmniNiriStateColumnInput = extern struct {
    column_id: OmniUuid128,
    window_start: usize,
    window_count: usize,
    active_tile_idx: usize,
    is_tabbed: u8,
    size_value: f64,
    width_kind: u8,
    is_full_width: u8,
    has_saved_width: u8,
    saved_width_kind: u8,
    saved_width_value: f64,
};

pub const OmniNiriStateWindowInput = extern struct {
    window_id: OmniUuid128,
    column_id: OmniUuid128,
    column_index: usize,
    size_value: f64,
    height_kind: u8,
    height_value: f64,
};

pub const OmniNiriRuntimeColumnState = extern struct {
    column_id: OmniUuid128,
    window_start: usize,
    window_count: usize,
    active_tile_idx: usize,
    is_tabbed: u8,
    size_value: f64,
    width_kind: u8,
    is_full_width: u8,
    has_saved_width: u8,
    saved_width_kind: u8,
    saved_width_value: f64,
};

pub const OmniNiriRuntimeWindowState = extern struct {
    window_id: OmniUuid128,
    column_id: OmniUuid128,
    column_index: usize,
    size_value: f64,
    height_kind: u8,
    height_value: f64,
};

pub const OmniNiriRuntimeStateExport = extern struct {
    columns: [*c]const OmniNiriRuntimeColumnState,
    column_count: usize,
    windows: [*c]const OmniNiriRuntimeWindowState,
    window_count: usize,
};

pub const OmniNiriDeltaColumnRecord = extern struct {
    column_id: OmniUuid128,
    order_index: usize,
    window_start: usize,
    window_count: usize,
    active_tile_idx: usize,
    is_tabbed: u8,
    size_value: f64,
    width_kind: u8,
    is_full_width: u8,
    has_saved_width: u8,
    saved_width_kind: u8,
    saved_width_value: f64,
};

pub const OmniNiriDeltaWindowRecord = extern struct {
    window_id: OmniUuid128,
    column_id: OmniUuid128,
    column_order_index: usize,
    row_index: usize,
    size_value: f64,
    height_kind: u8,
    height_value: f64,
};

pub const OmniNiriTxnDeltaExport = extern struct {
    columns: [*c]const OmniNiriDeltaColumnRecord,
    column_count: usize,
    windows: [*c]const OmniNiriDeltaWindowRecord,
    window_count: usize,
    removed_column_ids: [*c]const OmniUuid128,
    removed_column_count: usize,
    removed_window_ids: [*c]const OmniUuid128,
    removed_window_count: usize,
    refresh_tabbed_visibility_count: u8,
    refresh_tabbed_visibility_column_ids: [OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS]OmniUuid128,
    reset_all_column_cached_widths: u8,
    has_delegate_move_column: u8,
    delegate_move_column_id: OmniUuid128,
    delegate_move_direction: u8,
    has_target_window_id: u8,
    target_window_id: OmniUuid128,
    has_target_node_id: u8,
    target_node_kind: u8,
    target_node_id: OmniUuid128,
    has_source_selection_window_id: u8,
    source_selection_window_id: OmniUuid128,
    has_target_selection_window_id: u8,
    target_selection_window_id: OmniUuid128,
    has_moved_window_id: u8,
    moved_window_id: OmniUuid128,
    generation: u64,
};

pub const OmniNiriStateValidationResult = extern struct {
    column_count: usize,
    window_count: usize,
    first_invalid_column_index: i64,
    first_invalid_window_index: i64,
    first_error_code: i32,
};

pub const OmniNiriNavigationRequest = extern struct {
    op: u8,
    direction: u8,
    orientation: u8,
    infinite_loop: u8,
    selected_window_index: i64,
    selected_column_index: i64,
    selected_row_index: i64,
    step: i64,
    target_row_index: i64,
    target_column_index: i64,
    target_window_index: i64,
};

pub const OmniNiriNavigationResult = extern struct {
    has_target: u8,
    target_window_index: i64,
    update_source_active_tile: u8,
    source_column_index: i64,
    source_active_tile_idx: i64,
    update_target_active_tile: u8,
    target_column_index: i64,
    target_active_tile_idx: i64,
    refresh_tabbed_visibility_source: u8,
    refresh_tabbed_visibility_target: u8,
};

pub const OmniNiriNavigationApplyRequest = extern struct {
    request: OmniNiriNavigationRequest,
};

pub const OmniNiriNavigationApplyResult = extern struct {
    applied: u8,
    has_target_window_id: u8,
    target_window_id: OmniUuid128,
    update_source_active_tile: u8,
    source_column_id: OmniUuid128,
    source_active_tile_idx: i64,
    update_target_active_tile: u8,
    target_column_id: OmniUuid128,
    target_active_tile_idx: i64,
    refresh_tabbed_visibility_source: u8,
    refresh_source_column_id: OmniUuid128,
    refresh_tabbed_visibility_target: u8,
    refresh_target_column_id: OmniUuid128,
};

pub const OmniNiriMutationRequest = extern struct {
    op: u8,
    direction: u8,
    infinite_loop: u8,
    insert_position: u8,
    source_window_index: i64,
    target_window_index: i64,
    max_windows_per_column: i64,
    source_column_index: i64,
    target_column_index: i64,
    insert_column_index: i64,
    max_visible_columns: i64,
    selected_node_kind: u8,
    selected_node_index: i64,
    focused_window_index: i64,
    incoming_spawn_mode: u8,
};

pub const OmniNiriMutationEdit = extern struct {
    kind: u8,
    subject_index: i64,
    related_index: i64,
    value_a: i64,
    value_b: i64,
    scalar_a: f64,
    scalar_b: f64,
};

pub const OmniNiriMutationResult = extern struct {
    applied: u8,
    has_target_window: u8,
    target_window_index: i64,
    has_target_node: u8,
    target_node_kind: u8,
    target_node_index: i64,
    edit_count: usize,
    edits: [OMNI_NIRI_MUTATION_MAX_EDITS]OmniNiriMutationEdit,
};

pub const OmniNiriMutationApplyRequest = extern struct {
    request: OmniNiriMutationRequest,
    has_incoming_window_id: u8,
    incoming_window_id: OmniUuid128,
    has_created_column_id: u8,
    created_column_id: OmniUuid128,
    has_placeholder_column_id: u8,
    placeholder_column_id: OmniUuid128,
};

pub const OmniNiriMutationApplyResult = extern struct {
    applied: u8,
    has_target_window_id: u8,
    target_window_id: OmniUuid128,
    has_target_node_id: u8,
    target_node_kind: u8,
    target_node_id: OmniUuid128,
    refresh_tabbed_visibility_count: u8,
    refresh_tabbed_visibility_column_ids: [OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS]OmniUuid128,
    reset_all_column_cached_widths: u8,
    has_delegate_move_column: u8,
    delegate_move_column_id: OmniUuid128,
    delegate_move_direction: u8,
};

pub const OmniNiriWorkspaceRequest = extern struct {
    op: u8,
    source_window_index: i64,
    source_column_index: i64,
    max_visible_columns: i64,
};

pub const OmniNiriWorkspaceEdit = extern struct {
    kind: u8,
    subject_index: i64,
    related_index: i64,
    value_a: i64,
    value_b: i64,
};

pub const OmniNiriWorkspaceResult = extern struct {
    applied: u8,
    edit_count: usize,
    edits: [OMNI_NIRI_WORKSPACE_MAX_EDITS]OmniNiriWorkspaceEdit,
};

pub const OmniNiriWorkspaceApplyRequest = extern struct {
    request: OmniNiriWorkspaceRequest,
    has_target_created_column_id: u8,
    target_created_column_id: OmniUuid128,
    has_source_placeholder_column_id: u8,
    source_placeholder_column_id: OmniUuid128,
};

pub const OmniNiriWorkspaceApplyResult = extern struct {
    applied: u8,
    has_source_selection_window_id: u8,
    source_selection_window_id: OmniUuid128,
    has_target_selection_window_id: u8,
    target_selection_window_id: OmniUuid128,
    has_moved_window_id: u8,
    moved_window_id: OmniUuid128,
};

pub const OmniNiriTxnNavigationPayload = extern struct {
    op: u8,
    direction: u8,
    orientation: u8,
    infinite_loop: u8,
    has_source_window_id: u8,
    source_window_id: OmniUuid128,
    has_source_column_id: u8,
    source_column_id: OmniUuid128,
    has_target_window_id: u8,
    target_window_id: OmniUuid128,
    has_target_column_id: u8,
    target_column_id: OmniUuid128,
    step: i64,
    target_row_index: i64,
    focus_column_index: i64,
    focus_window_index: i64,
};

pub const OmniNiriTxnMutationPayload = extern struct {
    op: u8,
    direction: u8,
    infinite_loop: u8,
    insert_position: u8,
    has_source_window_id: u8,
    source_window_id: OmniUuid128,
    has_target_window_id: u8,
    target_window_id: OmniUuid128,
    max_windows_per_column: i64,
    has_source_column_id: u8,
    source_column_id: OmniUuid128,
    has_target_column_id: u8,
    target_column_id: OmniUuid128,
    insert_column_index: i64,
    max_visible_columns: i64,
    has_selected_node_id: u8,
    selected_node_id: OmniUuid128,
    has_focused_window_id: u8,
    focused_window_id: OmniUuid128,
    incoming_spawn_mode: u8,
    has_incoming_window_id: u8,
    incoming_window_id: OmniUuid128,
    has_created_column_id: u8,
    created_column_id: OmniUuid128,
    has_placeholder_column_id: u8,
    placeholder_column_id: OmniUuid128,
};

pub const OmniNiriTxnWorkspacePayload = extern struct {
    op: u8,
    has_source_window_id: u8,
    source_window_id: OmniUuid128,
    has_source_column_id: u8,
    source_column_id: OmniUuid128,
    max_visible_columns: i64,
    has_target_created_column_id: u8,
    target_created_column_id: OmniUuid128,
    has_source_placeholder_column_id: u8,
    source_placeholder_column_id: OmniUuid128,
};

pub const OmniNiriTxnRequest = extern struct {
    kind: u8,
    navigation: OmniNiriTxnNavigationPayload,
    mutation: OmniNiriTxnMutationPayload,
    workspace: OmniNiriTxnWorkspacePayload,
    max_delta_columns: usize,
    max_delta_windows: usize,
    max_removed_ids: usize,
};

pub const OmniNiriTxnResult = extern struct {
    applied: u8,
    kind: u8,
    structural_animation_active: u8,
    has_target_window_id: u8,
    target_window_id: OmniUuid128,
    has_target_node_id: u8,
    target_node_kind: u8,
    target_node_id: OmniUuid128,
    changed_source_context: u8,
    changed_target_context: u8,
    error_code: i32,
    delta_column_count: usize,
    delta_window_count: usize,
    removed_column_count: usize,
    removed_window_count: usize,
};

pub const OmniNiriRuntimeSeedRequest = extern struct {
    columns: [*c]const OmniNiriRuntimeColumnState,
    column_count: usize,
    windows: [*c]const OmniNiriRuntimeWindowState,
    window_count: usize,
};

pub const OmniNiriRuntimeCommandRequest = extern struct {
    txn: OmniNiriTxnRequest,
};

pub const OmniNiriRuntimeCommandResult = extern struct {
    txn: OmniNiriTxnResult,
};

pub const OmniNiriRuntimeRenderRequest = extern struct {
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
};

pub const OmniNiriRuntimeRenderOutput = extern struct {
    windows: [*c]OmniNiriWindowOutput,
    window_count: usize,
    columns: [*c]OmniNiriColumnOutput,
    column_count: usize,
};

pub const OmniDwindleSeedNode = extern struct {
    node_id: OmniUuid128,
    parent_index: i64,
    first_child_index: i64,
    second_child_index: i64,
    kind: u8,
    orientation: u8,
    ratio: f64,
    has_window_id: u8,
    window_id: OmniUuid128,
    is_fullscreen: u8,
};

pub const OmniDwindleSeedState = extern struct {
    root_node_index: i64,
    selected_node_index: i64,
    has_preselection: u8,
    preselection_direction: u8,
};

pub const OmniDwindleRuntimeSettings = extern struct {
    smart_split: u8,
    default_split_ratio: f64,
    split_width_multiplier: f64,
    inner_gap: f64,
};

pub const OmniDwindleRect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const OmniDwindleLayoutRequest = extern struct {
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
    runtime_settings: OmniDwindleRuntimeSettings,
};

pub const OmniDwindleWindowConstraint = extern struct {
    window_id: OmniUuid128,
    min_width: f64,
    min_height: f64,
    max_width: f64,
    max_height: f64,
    has_max_width: u8,
    has_max_height: u8,
    is_fixed: u8,
};

pub const OmniDwindleWindowFrame = extern struct {
    window_id: OmniUuid128,
    frame_x: f64,
    frame_y: f64,
    frame_width: f64,
    frame_height: f64,
};

pub const OmniDwindleAddWindowPayload = extern struct {
    window_id: OmniUuid128,
    has_active_window_frame: u8,
    active_window_frame: OmniDwindleRect,
};

pub const OmniDwindleRemoveWindowPayload = extern struct {
    window_id: OmniUuid128,
};

pub const OmniDwindleSyncWindowsPayload = extern struct {
    window_ids: [*c]const OmniUuid128,
    window_count: usize,
};

pub const OmniDwindleMoveFocusPayload = extern struct {
    direction: u8,
};

pub const OmniDwindleSwapWindowsPayload = extern struct {
    direction: u8,
};

pub const OmniDwindleToggleFullscreenPayload = extern struct {
    unused: u8,
};

pub const OmniDwindleToggleOrientationPayload = extern struct {
    unused: u8,
};

pub const OmniDwindleResizeSelectedPayload = extern struct {
    delta: f64,
    direction: u8,
};

pub const OmniDwindleBalanceSizesPayload = extern struct {
    unused: u8,
};

pub const OmniDwindleCycleSplitRatioPayload = extern struct {
    forward: u8,
};

pub const OmniDwindleMoveSelectionToRootPayload = extern struct {
    stable: u8,
};

pub const OmniDwindleSwapSplitPayload = extern struct {
    unused: u8,
};

pub const OmniDwindleSetPreselectionPayload = extern struct {
    direction: u8,
};

pub const OmniDwindleClearPreselectionPayload = extern struct {
    unused: u8,
};

pub const OmniDwindleValidateSelectionPayload = extern struct {
    unused: u8,
};

pub const OmniDwindleOpPayload = extern union {
    add_window: OmniDwindleAddWindowPayload,
    remove_window: OmniDwindleRemoveWindowPayload,
    sync_windows: OmniDwindleSyncWindowsPayload,
    move_focus: OmniDwindleMoveFocusPayload,
    swap_windows: OmniDwindleSwapWindowsPayload,
    toggle_fullscreen: OmniDwindleToggleFullscreenPayload,
    toggle_orientation: OmniDwindleToggleOrientationPayload,
    resize_selected: OmniDwindleResizeSelectedPayload,
    balance_sizes: OmniDwindleBalanceSizesPayload,
    cycle_split_ratio: OmniDwindleCycleSplitRatioPayload,
    move_selection_to_root: OmniDwindleMoveSelectionToRootPayload,
    swap_split: OmniDwindleSwapSplitPayload,
    set_preselection: OmniDwindleSetPreselectionPayload,
    clear_preselection: OmniDwindleClearPreselectionPayload,
    validate_selection: OmniDwindleValidateSelectionPayload,
};

pub const OmniDwindleOpRequest = extern struct {
    op: u8,
    payload: OmniDwindleOpPayload,
    runtime_settings: OmniDwindleRuntimeSettings,
};

pub const OmniDwindleOpResult = extern struct {
    applied: u8,
    has_selected_window_id: u8,
    selected_window_id: OmniUuid128,
    has_focused_window_id: u8,
    focused_window_id: OmniUuid128,
    has_preselection: u8,
    preselection_direction: u8,
    removed_window_count: usize,
};

pub const MAX_WINDOWS: usize = 512;

pub const OMNI_OK: i32 = 0;
pub const OMNI_ERR_INVALID_ARGS: i32 = -1;
pub const OMNI_ERR_OUT_OF_RANGE: i32 = -2;

pub const OMNI_CENTER_NEVER: u8 = 0;
pub const OMNI_CENTER_ALWAYS: u8 = 1;
pub const OMNI_CENTER_ON_OVERFLOW: u8 = 2;

pub const OMNI_VIEWPORT_GESTURE_HISTORY_CAP: usize = 64;

pub const OMNI_NIRI_ORIENTATION_HORIZONTAL: u8 = 0;
pub const OMNI_NIRI_ORIENTATION_VERTICAL: u8 = 1;

pub const OMNI_NIRI_SIZING_NORMAL: u8 = 0;
pub const OMNI_NIRI_SIZING_FULLSCREEN: u8 = 1;

pub const OMNI_NIRI_HIDE_NONE: u8 = 0;
pub const OMNI_NIRI_HIDE_LEFT: u8 = 1;
pub const OMNI_NIRI_HIDE_RIGHT: u8 = 2;

pub const OMNI_NIRI_RESIZE_EDGE_TOP: u8 = 0b0001;
pub const OMNI_NIRI_RESIZE_EDGE_BOTTOM: u8 = 0b0010;
pub const OMNI_NIRI_RESIZE_EDGE_LEFT: u8 = 0b0100;
pub const OMNI_NIRI_RESIZE_EDGE_RIGHT: u8 = 0b1000;

pub const OMNI_NIRI_INSERT_BEFORE: u8 = 0;
pub const OMNI_NIRI_INSERT_AFTER: u8 = 1;
pub const OMNI_NIRI_INSERT_SWAP: u8 = 2;

pub const OMNI_NIRI_SPAWN_NEW_COLUMN: u8 = 0;
pub const OMNI_NIRI_SPAWN_FOCUSED_COLUMN: u8 = 1;

pub const OMNI_NIRI_DIRECTION_LEFT: u8 = 0;
pub const OMNI_NIRI_DIRECTION_RIGHT: u8 = 1;
pub const OMNI_NIRI_DIRECTION_UP: u8 = 2;
pub const OMNI_NIRI_DIRECTION_DOWN: u8 = 3;

pub const OMNI_NIRI_TXN_LAYOUT: u8 = 0;
pub const OMNI_NIRI_TXN_NAVIGATION: u8 = 1;
pub const OMNI_NIRI_TXN_MUTATION: u8 = 2;
pub const OMNI_NIRI_TXN_WORKSPACE: u8 = 3;

pub const OMNI_NIRI_NAV_OP_MOVE_BY_COLUMNS: u8 = 0;
pub const OMNI_NIRI_NAV_OP_MOVE_VERTICAL: u8 = 1;
pub const OMNI_NIRI_NAV_OP_FOCUS_TARGET: u8 = 2;
pub const OMNI_NIRI_NAV_OP_FOCUS_DOWN_OR_LEFT: u8 = 3;
pub const OMNI_NIRI_NAV_OP_FOCUS_UP_OR_RIGHT: u8 = 4;
pub const OMNI_NIRI_NAV_OP_FOCUS_COLUMN_FIRST: u8 = 5;
pub const OMNI_NIRI_NAV_OP_FOCUS_COLUMN_LAST: u8 = 6;
pub const OMNI_NIRI_NAV_OP_FOCUS_COLUMN_INDEX: u8 = 7;
pub const OMNI_NIRI_NAV_OP_FOCUS_WINDOW_INDEX: u8 = 8;
pub const OMNI_NIRI_NAV_OP_FOCUS_WINDOW_TOP: u8 = 9;
pub const OMNI_NIRI_NAV_OP_FOCUS_WINDOW_BOTTOM: u8 = 10;

pub const OMNI_NIRI_SIZE_KIND_PROPORTION: u8 = 0;
pub const OMNI_NIRI_SIZE_KIND_FIXED: u8 = 1;

pub const OMNI_NIRI_HEIGHT_KIND_AUTO: u8 = 0;
pub const OMNI_NIRI_HEIGHT_KIND_FIXED: u8 = 1;

pub const OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL: u8 = 0;
pub const OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL: u8 = 1;
pub const OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL: u8 = 2;
pub const OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL: u8 = 3;
pub const OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE: u8 = 4;
pub const OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE: u8 = 5;
pub const OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN: u8 = 6;
pub const OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE: u8 = 7;
pub const OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN: u8 = 8;
pub const OMNI_NIRI_MUTATION_OP_MOVE_COLUMN: u8 = 9;
pub const OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW: u8 = 10;
pub const OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW: u8 = 11;
pub const OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN: u8 = 12;
pub const OMNI_NIRI_MUTATION_OP_NORMALIZE_COLUMN_SIZES: u8 = 13;
pub const OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES: u8 = 14;
pub const OMNI_NIRI_MUTATION_OP_BALANCE_SIZES: u8 = 15;
pub const OMNI_NIRI_MUTATION_OP_ADD_WINDOW: u8 = 16;
pub const OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW: u8 = 17;
pub const OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION: u8 = 18;
pub const OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL: u8 = 19;

pub const OMNI_NIRI_MUTATION_NODE_NONE: u8 = 0;
pub const OMNI_NIRI_MUTATION_NODE_WINDOW: u8 = 1;
pub const OMNI_NIRI_MUTATION_NODE_COLUMN: u8 = 2;

pub const OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE: u8 = 0;
pub const OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS: u8 = 1;
pub const OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX: u8 = 2;
pub const OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE: u8 = 3;
pub const OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT: u8 = 4;
pub const OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT: u8 = 5;
pub const OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY: u8 = 6;
pub const OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY: u8 = 7;
pub const OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN: u8 = 8;
pub const OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW: u8 = 9;
pub const OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW: u8 = 10;
pub const OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS: u8 = 11;
pub const OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR: u8 = 12;
pub const OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR: u8 = 13;
pub const OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS: u8 = 14;
pub const OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN: u8 = 15;
pub const OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN: u8 = 16;
pub const OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX: u8 = 17;
pub const OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS: u8 = 18;

pub const OMNI_NIRI_MUTATION_MAX_EDITS: usize = 32;
pub const OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS: usize = 2;

pub const OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE: u8 = 0;
pub const OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE: u8 = 1;

pub const OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW: u8 = 0;
pub const OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE: u8 = 1;
pub const OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN: u8 = 2;
pub const OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND: u8 = 3;
pub const OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS: u8 = 4;
pub const OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY: u8 = 5;
pub const OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS: u8 = 6;
pub const OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW: u8 = 7;
pub const OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW: u8 = 8;

pub const OMNI_NIRI_WORKSPACE_MAX_EDITS: usize = 16;

pub const OMNI_DWINDLE_MAX_NODES: usize = (MAX_WINDOWS * 2) - 1;

pub const OMNI_DWINDLE_NODE_SPLIT: u8 = 0;
pub const OMNI_DWINDLE_NODE_LEAF: u8 = 1;

pub const OMNI_DWINDLE_ORIENTATION_HORIZONTAL: u8 = 0;
pub const OMNI_DWINDLE_ORIENTATION_VERTICAL: u8 = 1;

pub const OMNI_DWINDLE_DIRECTION_LEFT: u8 = 0;
pub const OMNI_DWINDLE_DIRECTION_RIGHT: u8 = 1;
pub const OMNI_DWINDLE_DIRECTION_UP: u8 = 2;
pub const OMNI_DWINDLE_DIRECTION_DOWN: u8 = 3;

pub const OMNI_DWINDLE_OP_ADD_WINDOW: u8 = 0;
pub const OMNI_DWINDLE_OP_REMOVE_WINDOW: u8 = 1;
pub const OMNI_DWINDLE_OP_SYNC_WINDOWS: u8 = 2;
pub const OMNI_DWINDLE_OP_MOVE_FOCUS: u8 = 3;
pub const OMNI_DWINDLE_OP_SWAP_WINDOWS: u8 = 4;
pub const OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN: u8 = 5;
pub const OMNI_DWINDLE_OP_TOGGLE_ORIENTATION: u8 = 6;
pub const OMNI_DWINDLE_OP_RESIZE_SELECTED: u8 = 7;
pub const OMNI_DWINDLE_OP_BALANCE_SIZES: u8 = 8;
pub const OMNI_DWINDLE_OP_CYCLE_SPLIT_RATIO: u8 = 9;
pub const OMNI_DWINDLE_OP_MOVE_SELECTION_TO_ROOT: u8 = 10;
pub const OMNI_DWINDLE_OP_SWAP_SPLIT: u8 = 11;
pub const OMNI_DWINDLE_OP_SET_PRESELECTION: u8 = 12;
pub const OMNI_DWINDLE_OP_CLEAR_PRESELECTION: u8 = 13;
pub const OMNI_DWINDLE_OP_VALIDATE_SELECTION: u8 = 14;
