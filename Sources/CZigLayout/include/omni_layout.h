#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct OmniNiriLayoutContext OmniNiriLayoutContext;
typedef struct OmniNiriRuntime OmniNiriRuntime;
typedef struct OmniDwindleLayoutContext OmniDwindleLayoutContext;

/// Input descriptor for one window on a single axis.
/// Zig struct OmniAxisInput must match this layout exactly.
typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
    double fixed_value; // ignored when has_fixed_value == 0
} OmniAxisInput;

/// Result for one window on a single axis.
typedef struct {
    double value;
    uint8_t was_constrained;
} OmniAxisOutput;

typedef enum {
    OMNI_CENTER_NEVER = 0,
    OMNI_CENTER_ALWAYS = 1,
    OMNI_CENTER_ON_OVERFLOW = 2
} OmniCenterMode;

typedef struct {
    double view_pos;
    size_t column_index;
} OmniSnapResult;

enum {
    OMNI_VIEWPORT_GESTURE_HISTORY_CAP = 64
};

typedef struct {
    uint8_t is_trackpad;
    size_t history_count;
    size_t history_head;
    double tracker_position;
    double current_view_offset;
    double stationary_view_offset;
    double delta_from_tracker;
    double history_deltas[OMNI_VIEWPORT_GESTURE_HISTORY_CAP];
    double history_timestamps[OMNI_VIEWPORT_GESTURE_HISTORY_CAP];
} OmniViewportGestureState;

typedef struct {
    size_t resolved_column_index;
    double offset_delta;
    double adjusted_target_offset;
    double target_offset;
    double snap_delta;
    uint8_t snap_to_target_immediately;
} OmniViewportTransitionResult;

typedef struct {
    double target_offset;
    double offset_delta;
    uint8_t is_noop;
} OmniViewportEnsureVisibleResult;

typedef struct {
    uint8_t applied;
    double new_offset;
    double selection_progress;
    uint8_t has_selection_steps;
    int64_t selection_steps;
} OmniViewportScrollResult;

typedef struct {
    double current_view_offset;
    double selection_progress;
    uint8_t has_selection_steps;
    int64_t selection_steps;
} OmniViewportGestureUpdateResult;

typedef struct {
    size_t resolved_column_index;
    double spring_from;
    double spring_to;
    double initial_velocity;
} OmniViewportGestureEndResult;

typedef struct {
    double current_offset;
    double target_offset;
    int64_t active_column_index;
    double selection_progress;
    uint8_t is_gesture;
    uint8_t is_animating;
} OmniNiriRuntimeViewportStatus;

typedef enum {
    OMNI_NIRI_ORIENTATION_HORIZONTAL = 0,
    OMNI_NIRI_ORIENTATION_VERTICAL = 1
} OmniNiriOrientation;

typedef enum {
    OMNI_NIRI_SIZING_NORMAL = 0,
    OMNI_NIRI_SIZING_FULLSCREEN = 1
} OmniNiriSizingMode;

typedef enum {
    OMNI_NIRI_HIDE_NONE = 0,
    OMNI_NIRI_HIDE_LEFT = 1,
    OMNI_NIRI_HIDE_RIGHT = 2
} OmniNiriHideSide;

typedef struct {
    double span;
    double render_offset_x;
    double render_offset_y;
    uint8_t is_tabbed;
    double tab_indicator_width;
    size_t window_start;
    size_t window_count;
} OmniNiriColumnInput;

typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
    double fixed_value;
    uint8_t sizing_mode;
    double render_offset_x;
    double render_offset_y;
} OmniNiriWindowInput;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    double animated_x;
    double animated_y;
    double animated_width;
    double animated_height;
    double resolved_span;
    uint8_t was_constrained;
    uint8_t hide_side;
    size_t column_index;
} OmniNiriWindowOutput;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint8_t hide_side;
    uint8_t is_visible;
} OmniNiriColumnOutput;

typedef enum {
    OMNI_NIRI_RESIZE_EDGE_TOP = 0b0001,
    OMNI_NIRI_RESIZE_EDGE_BOTTOM = 0b0010,
    OMNI_NIRI_RESIZE_EDGE_LEFT = 0b0100,
    OMNI_NIRI_RESIZE_EDGE_RIGHT = 0b1000
} OmniNiriResizeEdge;

typedef struct {
    size_t window_index;
    size_t column_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint8_t is_fullscreen;
} OmniNiriHitTestWindow;

typedef struct {
    uint8_t is_valid;
    double min_y;
    double max_y;
    size_t post_insertion_count;
} OmniNiriColumnDropzoneMeta;

typedef struct {
    int64_t window_index;
    uint8_t edges;
} OmniNiriResizeHitResult;

typedef enum {
    OMNI_NIRI_INSERT_BEFORE = 0,
    OMNI_NIRI_INSERT_AFTER = 1,
    OMNI_NIRI_INSERT_SWAP = 2
} OmniNiriInsertPosition;

typedef enum {
    OMNI_NIRI_SPAWN_NEW_COLUMN = 0,
    OMNI_NIRI_SPAWN_FOCUSED_COLUMN = 1
} OmniNiriIncomingSpawnMode;

typedef struct {
    int64_t window_index;
    uint8_t insert_position;
} OmniNiriMoveTargetResult;

typedef struct {
    double target_frame_x;
    double target_frame_y;
    double target_frame_width;
    double target_frame_height;
    double column_min_y;
    double column_max_y;
    double gap;
    uint8_t insert_position;
    size_t post_insertion_count;
} OmniNiriDropzoneInput;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint8_t is_valid;
} OmniNiriDropzoneResult;

typedef struct {
    uint8_t edges;
    double start_x;
    double start_y;
    double current_x;
    double current_y;
    double original_column_width;
    double min_column_width;
    double max_column_width;
    double original_window_weight;
    double min_window_weight;
    double max_window_weight;
    double pixels_per_weight;
    uint8_t has_original_view_offset;
    double original_view_offset;
} OmniNiriResizeInput;

typedef struct {
    uint8_t changed_width;
    double new_column_width;
    uint8_t changed_weight;
    double new_window_weight;
    uint8_t adjust_view_offset;
    double new_view_offset;
} OmniNiriResizeResult;

enum {
    OMNI_OK = 0,
    OMNI_ERR_INVALID_ARGS = -1,
    OMNI_ERR_OUT_OF_RANGE = -2
};

/// Compute viewport offset needed to reveal a target container index.
/// Returns 0 on success, -1 for invalid args, -2 when index/range is invalid.
int32_t omni_viewport_compute_visible_offset(
    const double *spans,
    size_t span_count,
    size_t container_index,
    double gap,
    double viewport_span,
    double current_view_start,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    int64_t from_container_index,
    double *out_target_offset);

/// Compute transition plan values for switching active container to requested index.
/// Returns 0 on success, -1 for invalid args, -2 for range errors.
int32_t omni_viewport_transition_to_column(
    const double *spans,
    size_t span_count,
    size_t current_active_index,
    size_t requested_index,
    double gap,
    double viewport_span,
    double current_target_offset,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    int64_t from_container_index,
    double scale,
    OmniViewportTransitionResult *out_result);

/// Compute offset plan to ensure a target container is visible.
/// Returns 0 on success, -1 for invalid args, -2 for range errors.
int32_t omni_viewport_ensure_visible(
    const double *spans,
    size_t span_count,
    size_t active_container_index,
    size_t target_container_index,
    double gap,
    double viewport_span,
    double current_offset,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    int64_t from_container_index,
    double epsilon,
    OmniViewportEnsureVisibleResult *out_result);

/// Apply one viewport scroll delta and report clamped offset/selection-step effects.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_viewport_scroll_step(
    const double *spans,
    size_t span_count,
    double delta_pixels,
    double viewport_span,
    double gap,
    double current_offset,
    double selection_progress,
    uint8_t change_selection,
    OmniViewportScrollResult *out_result);

/// Initialize gesture tracker/kernel state for a new gesture sequence.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_viewport_gesture_begin(
    double current_view_offset,
    uint8_t is_trackpad,
    OmniViewportGestureState *out_state);

/// Compute current gesture velocity from tracker history.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_viewport_gesture_velocity(
    const OmniViewportGestureState *gesture_state,
    double *out_velocity);

/// Advance gesture tracker state with one delta event.
/// Returns 0 on success, -1 for invalid args, -2 for range errors.
int32_t omni_viewport_gesture_update(
    OmniViewportGestureState *gesture_state,
    const double *spans,
    size_t span_count,
    size_t active_container_index,
    double delta_pixels,
    double timestamp,
    double gap,
    double viewport_span,
    double selection_progress,
    OmniViewportGestureUpdateResult *out_result);

/// Resolve gesture end target and spring endpoints from the current gesture state.
/// Returns 0 on success, -1 for invalid args, -2 for range errors.
int32_t omni_viewport_gesture_end(
    const OmniViewportGestureState *gesture_state,
    const double *spans,
    size_t span_count,
    size_t active_container_index,
    double gap,
    double viewport_span,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    OmniViewportGestureEndResult *out_result);

/// Create a reusable Niri layout context.
/// Returns NULL on allocation failure.
OmniNiriLayoutContext *omni_niri_layout_context_create(void);

/// Destroy a reusable Niri layout context.
void omni_niri_layout_context_destroy(OmniNiriLayoutContext *context);

/// Seed context interaction buffers directly (primarily for tests/parity harnesses).
/// Returns 0 on success, -1 for invalid args, -2 for capacity errors.
int32_t omni_niri_layout_context_set_interaction(
    OmniNiriLayoutContext *context,
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    const OmniNiriColumnDropzoneMeta *column_dropzones,
    size_t column_count);

/// Layout-pass v3 emits the same outputs as v2 and updates interaction feed in context.
/// `out_windows` may be NULL only when `window_count == 0` and `out_window_count == 0`.
/// Returns 0 on success, -1 for invalid args, -2 for range/assignment/capacity errors.
int32_t omni_niri_layout_pass_v3(
    OmniNiriLayoutContext *context,
    const OmniNiriColumnInput *columns,
    size_t column_count,
    const OmniNiriWindowInput *windows,
    size_t window_count,
    double working_x,
    double working_y,
    double working_width,
    double working_height,
    double view_x,
    double view_y,
    double view_width,
    double view_height,
    double fullscreen_x,
    double fullscreen_y,
    double fullscreen_width,
    double fullscreen_height,
    double primary_gap,
    double secondary_gap,
    double view_start,
    double viewport_span,
    double workspace_offset,
    double scale,
    uint8_t orientation,
    OmniNiriWindowOutput *out_windows,
    size_t out_window_count,
    OmniNiriColumnOutput *out_columns,
    size_t out_column_count);

/// Hit-test tiled windows and return first containing window index.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_hit_test_tiled(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    int64_t *out_window_index);

/// Hit-test tiled windows from reusable context feed.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_ctx_hit_test_tiled(
    const OmniNiriLayoutContext *context,
    double point_x,
    double point_y,
    int64_t *out_window_index);

/// Hit-test resize edges around tiled windows.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_hit_test_resize(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    double threshold,
    OmniNiriResizeHitResult *out_result);

/// Hit-test resize edges from reusable context feed.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_ctx_hit_test_resize(
    const OmniNiriLayoutContext *context,
    double point_x,
    double point_y,
    double threshold,
    OmniNiriResizeHitResult *out_result);

/// Resolve move target under cursor, with swap or insert semantics.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_hit_test_move_target(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    int64_t excluding_window_index,
    uint8_t is_insert_mode,
    OmniNiriMoveTargetResult *out_result);

/// Hit-test move targets from reusable context feed.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_ctx_hit_test_move_target(
    const OmniNiriLayoutContext *context,
    double point_x,
    double point_y,
    int64_t excluding_window_index,
    uint8_t is_insert_mode,
    OmniNiriMoveTargetResult *out_result);

/// Compute insertion dropzone frame for before/after/swap placement.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_insertion_dropzone(
    const OmniNiriDropzoneInput *input,
    OmniNiriDropzoneResult *out_result);

/// Compute insertion dropzone using context metadata and target window index.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_ctx_insertion_dropzone(
    const OmniNiriLayoutContext *context,
    int64_t target_window_index,
    double gap,
    uint8_t insert_position,
    OmniNiriDropzoneResult *out_result);

/// Compute interactive resize updates for column width/window weight.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_resize_compute(
    const OmniNiriResizeInput *input,
    OmniNiriResizeResult *out_result);

typedef struct {
    uint8_t bytes[16];
} OmniUuid128;

typedef struct {
    OmniUuid128 column_id;
    size_t window_start;
    size_t window_count;
    size_t active_tile_idx;
    uint8_t is_tabbed;
    double size_value;
    uint8_t width_kind;
    uint8_t is_full_width;
    uint8_t has_saved_width;
    uint8_t saved_width_kind;
    double saved_width_value;
} OmniNiriStateColumnInput;

typedef struct {
    OmniUuid128 window_id;
    OmniUuid128 column_id;
    size_t column_index;
    double size_value;
    uint8_t height_kind;
    double height_value;
} OmniNiriStateWindowInput;

typedef struct {
    OmniUuid128 column_id;
    size_t window_start;
    size_t window_count;
    size_t active_tile_idx;
    uint8_t is_tabbed;
    double size_value;
    uint8_t width_kind;
    uint8_t is_full_width;
    uint8_t has_saved_width;
    uint8_t saved_width_kind;
    double saved_width_value;
} OmniNiriRuntimeColumnState;

typedef struct {
    OmniUuid128 window_id;
    OmniUuid128 column_id;
    size_t column_index;
    double size_value;
    uint8_t height_kind;
    double height_value;
} OmniNiriRuntimeWindowState;

typedef struct {
    const OmniNiriRuntimeColumnState *columns;
    size_t column_count;
    const OmniNiriRuntimeWindowState *windows;
    size_t window_count;
} OmniNiriRuntimeStateExport;

typedef enum {
    OMNI_NIRI_TXN_LAYOUT = 0,
    OMNI_NIRI_TXN_NAVIGATION = 1,
    OMNI_NIRI_TXN_MUTATION = 2,
    OMNI_NIRI_TXN_WORKSPACE = 3
} OmniNiriTxnKind;

enum {
    OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS = 2
};

typedef struct {
    OmniUuid128 column_id;
    size_t order_index;
    size_t window_start;
    size_t window_count;
    size_t active_tile_idx;
    uint8_t is_tabbed;
    double size_value;
    uint8_t width_kind;
    uint8_t is_full_width;
    uint8_t has_saved_width;
    uint8_t saved_width_kind;
    double saved_width_value;
} OmniNiriDeltaColumnRecord;

typedef struct {
    OmniUuid128 window_id;
    OmniUuid128 column_id;
    size_t column_order_index;
    size_t row_index;
    double size_value;
    uint8_t height_kind;
    double height_value;
} OmniNiriDeltaWindowRecord;

typedef struct {
    const OmniNiriDeltaColumnRecord *columns;
    size_t column_count;
    const OmniNiriDeltaWindowRecord *windows;
    size_t window_count;
    const OmniUuid128 *removed_column_ids;
    size_t removed_column_count;
    const OmniUuid128 *removed_window_ids;
    size_t removed_window_count;
    uint8_t refresh_tabbed_visibility_count;
    OmniUuid128 refresh_tabbed_visibility_column_ids[OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS];
    uint8_t reset_all_column_cached_widths;
    uint8_t has_delegate_move_column;
    OmniUuid128 delegate_move_column_id;
    uint8_t delegate_move_direction;
    uint8_t has_target_window_id;
    OmniUuid128 target_window_id;
    uint8_t has_target_node_id;
    uint8_t target_node_kind;
    OmniUuid128 target_node_id;
    uint8_t has_source_selection_window_id;
    OmniUuid128 source_selection_window_id;
    uint8_t has_target_selection_window_id;
    OmniUuid128 target_selection_window_id;
    uint8_t has_moved_window_id;
    OmniUuid128 moved_window_id;
    uint64_t generation;
} OmniNiriTxnDeltaExport;

typedef struct {
    size_t column_count;
    size_t window_count;
    int64_t first_invalid_column_index;
    int64_t first_invalid_window_index;
    int32_t first_error_code;
} OmniNiriStateValidationResult;

/// Validate snapshot bounds, ownership, and assignment consistency.
/// Returns 0 when valid, otherwise -1/-2 and fills first_invalid_* fields.
int32_t omni_niri_validate_state_snapshot(
    const OmniNiriStateColumnInput *columns,
    size_t column_count,
    const OmniNiriStateWindowInput *windows,
    size_t window_count,
    OmniNiriStateValidationResult *out_result);

/// Seed authoritative runtime state into a reusable context.
/// Returns 0 on success, -1 for invalid args, -2 for capacity/range failures.
int32_t omni_niri_ctx_seed_runtime_state(
    OmniNiriLayoutContext *context,
    const OmniNiriRuntimeColumnState *columns,
    size_t column_count,
    const OmniNiriRuntimeWindowState *windows,
    size_t window_count);

typedef enum {
    OMNI_NIRI_DIRECTION_LEFT = 0,
    OMNI_NIRI_DIRECTION_RIGHT = 1,
    OMNI_NIRI_DIRECTION_UP = 2,
    OMNI_NIRI_DIRECTION_DOWN = 3
} OmniNiriDirection;

typedef enum {
    OMNI_NIRI_NAV_OP_MOVE_BY_COLUMNS = 0,
    OMNI_NIRI_NAV_OP_MOVE_VERTICAL = 1,
    OMNI_NIRI_NAV_OP_FOCUS_TARGET = 2,
    OMNI_NIRI_NAV_OP_FOCUS_DOWN_OR_LEFT = 3,
    OMNI_NIRI_NAV_OP_FOCUS_UP_OR_RIGHT = 4,
    OMNI_NIRI_NAV_OP_FOCUS_COLUMN_FIRST = 5,
    OMNI_NIRI_NAV_OP_FOCUS_COLUMN_LAST = 6,
    OMNI_NIRI_NAV_OP_FOCUS_COLUMN_INDEX = 7,
    OMNI_NIRI_NAV_OP_FOCUS_WINDOW_INDEX = 8,
    OMNI_NIRI_NAV_OP_FOCUS_WINDOW_TOP = 9,
    OMNI_NIRI_NAV_OP_FOCUS_WINDOW_BOTTOM = 10
} OmniNiriNavigationOp;

typedef struct {
    uint8_t op;
    uint8_t direction;
    uint8_t orientation;
    uint8_t infinite_loop;
    int64_t selected_window_index;
    int64_t selected_column_index;
    int64_t selected_row_index;
    int64_t step;
    int64_t target_row_index;
    int64_t target_column_index;
    int64_t target_window_index;
} OmniNiriNavigationRequest;

typedef struct {
    uint8_t has_target;
    int64_t target_window_index;
    uint8_t update_source_active_tile;
    int64_t source_column_index;
    int64_t source_active_tile_idx;
    uint8_t update_target_active_tile;
    int64_t target_column_index;
    int64_t target_active_tile_idx;
    uint8_t refresh_tabbed_visibility_source;
    uint8_t refresh_tabbed_visibility_target;
} OmniNiriNavigationResult;

typedef struct {
    OmniNiriNavigationRequest request;
} OmniNiriNavigationApplyRequest;

typedef struct {
    uint8_t applied;
    uint8_t has_target_window_id;
    OmniUuid128 target_window_id;
    uint8_t update_source_active_tile;
    OmniUuid128 source_column_id;
    int64_t source_active_tile_idx;
    uint8_t update_target_active_tile;
    OmniUuid128 target_column_id;
    int64_t target_active_tile_idx;
    uint8_t refresh_tabbed_visibility_source;
    OmniUuid128 refresh_source_column_id;
    uint8_t refresh_tabbed_visibility_target;
    OmniUuid128 refresh_target_column_id;
} OmniNiriNavigationApplyResult;

typedef enum {
    OMNI_NIRI_SIZE_KIND_PROPORTION = 0,
    OMNI_NIRI_SIZE_KIND_FIXED = 1
} OmniNiriSizeKind;

typedef enum {
    OMNI_NIRI_HEIGHT_KIND_AUTO = 0,
    OMNI_NIRI_HEIGHT_KIND_FIXED = 1
} OmniNiriHeightKind;

typedef enum {
    OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL = 0,
    OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL = 1,
    OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL = 2,
    OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL = 3,
    OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE = 4,
    OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE = 5,
    OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN = 6,
    OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE = 7,
    OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN = 8,
    OMNI_NIRI_MUTATION_OP_MOVE_COLUMN = 9,
    OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW = 10,
    OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW = 11,
    OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN = 12,
    OMNI_NIRI_MUTATION_OP_NORMALIZE_COLUMN_SIZES = 13,
    OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES = 14,
    OMNI_NIRI_MUTATION_OP_BALANCE_SIZES = 15,
    OMNI_NIRI_MUTATION_OP_ADD_WINDOW = 16,
    OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW = 17,
    OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION = 18,
    OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL = 19
} OmniNiriMutationOp;

typedef enum {
    OMNI_NIRI_MUTATION_EDIT_SET_ACTIVE_TILE = 0,
    OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOWS = 1,
    OMNI_NIRI_MUTATION_EDIT_MOVE_WINDOW_TO_COLUMN_INDEX = 2,
    OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMN_WIDTH_STATE = 3,
    OMNI_NIRI_MUTATION_EDIT_SWAP_WINDOW_SIZE_HEIGHT = 4,
    OMNI_NIRI_MUTATION_EDIT_RESET_WINDOW_SIZE_HEIGHT = 5,
    OMNI_NIRI_MUTATION_EDIT_REMOVE_COLUMN_IF_EMPTY = 6,
    OMNI_NIRI_MUTATION_EDIT_REFRESH_TABBED_VISIBILITY = 7,
    OMNI_NIRI_MUTATION_EDIT_DELEGATE_MOVE_COLUMN = 8,
    OMNI_NIRI_MUTATION_EDIT_CREATE_COLUMN_ADJACENT_AND_MOVE_WINDOW = 9,
    OMNI_NIRI_MUTATION_EDIT_INSERT_NEW_COLUMN_AT_INDEX_AND_MOVE_WINDOW = 10,
    OMNI_NIRI_MUTATION_EDIT_SWAP_COLUMNS = 11,
    OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMNS_BY_FACTOR = 12,
    OMNI_NIRI_MUTATION_EDIT_NORMALIZE_COLUMN_WINDOWS_BY_FACTOR = 13,
    OMNI_NIRI_MUTATION_EDIT_BALANCE_COLUMNS = 14,
    OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_INTO_COLUMN = 15,
    OMNI_NIRI_MUTATION_EDIT_INSERT_INCOMING_WINDOW_IN_NEW_COLUMN = 16,
    OMNI_NIRI_MUTATION_EDIT_REMOVE_WINDOW_BY_INDEX = 17,
    OMNI_NIRI_MUTATION_EDIT_RESET_ALL_COLUMN_CACHED_WIDTHS = 18
} OmniNiriMutationEditKind;

typedef enum {
    OMNI_NIRI_MUTATION_NODE_NONE = 0,
    OMNI_NIRI_MUTATION_NODE_WINDOW = 1,
    OMNI_NIRI_MUTATION_NODE_COLUMN = 2
} OmniNiriMutationNodeKind;

typedef struct {
    uint8_t op;
    uint8_t direction;
    uint8_t infinite_loop;
    uint8_t insert_position;
    int64_t source_window_index;
    int64_t target_window_index;
    int64_t max_windows_per_column;
    int64_t source_column_index;
    int64_t target_column_index;
    int64_t insert_column_index;
    int64_t max_visible_columns;
    uint8_t selected_node_kind;
    int64_t selected_node_index;
    int64_t focused_window_index;
    uint8_t incoming_spawn_mode;
} OmniNiriMutationRequest;

typedef struct {
    uint8_t kind;
    int64_t subject_index;
    int64_t related_index;
    int64_t value_a;
    int64_t value_b;
    double scalar_a;
    double scalar_b;
} OmniNiriMutationEdit;

enum {
    OMNI_NIRI_MUTATION_MAX_EDITS = 32
};

typedef struct {
    uint8_t applied;
    uint8_t has_target_window;
    int64_t target_window_index;
    uint8_t has_target_node;
    uint8_t target_node_kind;
    int64_t target_node_index;
    size_t edit_count;
    OmniNiriMutationEdit edits[OMNI_NIRI_MUTATION_MAX_EDITS];
} OmniNiriMutationResult;

typedef struct {
    OmniNiriMutationRequest request;
    uint8_t has_incoming_window_id;
    OmniUuid128 incoming_window_id;
    uint8_t has_created_column_id;
    OmniUuid128 created_column_id;
    uint8_t has_placeholder_column_id;
    OmniUuid128 placeholder_column_id;
} OmniNiriMutationApplyRequest;

typedef struct {
    uint8_t applied;
    uint8_t has_target_window_id;
    OmniUuid128 target_window_id;
    uint8_t has_target_node_id;
    uint8_t target_node_kind;
    OmniUuid128 target_node_id;
    uint8_t refresh_tabbed_visibility_count;
    OmniUuid128 refresh_tabbed_visibility_column_ids[OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS];
    uint8_t reset_all_column_cached_widths;
    uint8_t has_delegate_move_column;
    OmniUuid128 delegate_move_column_id;
    uint8_t delegate_move_direction;
} OmniNiriMutationApplyResult;

typedef enum {
    OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE = 0,
    OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE = 1
} OmniNiriWorkspaceOp;

typedef enum {
    OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_WINDOW = 0,
    OMNI_NIRI_WORKSPACE_EDIT_SET_SOURCE_SELECTION_NONE = 1,
    OMNI_NIRI_WORKSPACE_EDIT_REUSE_TARGET_EMPTY_COLUMN = 2,
    OMNI_NIRI_WORKSPACE_EDIT_CREATE_TARGET_COLUMN_APPEND = 3,
    OMNI_NIRI_WORKSPACE_EDIT_PRUNE_TARGET_EMPTY_COLUMNS_IF_NO_WINDOWS = 4,
    OMNI_NIRI_WORKSPACE_EDIT_REMOVE_SOURCE_COLUMN_IF_EMPTY = 5,
    OMNI_NIRI_WORKSPACE_EDIT_ENSURE_SOURCE_PLACEHOLDER_IF_NO_COLUMNS = 6,
    OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_WINDOW = 7,
    OMNI_NIRI_WORKSPACE_EDIT_SET_TARGET_SELECTION_MOVED_COLUMN_FIRST_WINDOW = 8
} OmniNiriWorkspaceEditKind;

typedef struct {
    uint8_t op;
    int64_t source_window_index;
    int64_t source_column_index;
    int64_t max_visible_columns;
} OmniNiriWorkspaceRequest;

typedef struct {
    uint8_t kind;
    int64_t subject_index;
    int64_t related_index;
    int64_t value_a;
    int64_t value_b;
} OmniNiriWorkspaceEdit;

enum {
    OMNI_NIRI_WORKSPACE_MAX_EDITS = 16
};

typedef struct {
    uint8_t applied;
    size_t edit_count;
    OmniNiriWorkspaceEdit edits[OMNI_NIRI_WORKSPACE_MAX_EDITS];
} OmniNiriWorkspaceResult;

typedef struct {
    OmniNiriWorkspaceRequest request;
    uint8_t has_target_created_column_id;
    OmniUuid128 target_created_column_id;
    uint8_t has_source_placeholder_column_id;
    OmniUuid128 source_placeholder_column_id;
} OmniNiriWorkspaceApplyRequest;

typedef struct {
    uint8_t applied;
    uint8_t has_source_selection_window_id;
    OmniUuid128 source_selection_window_id;
    uint8_t has_target_selection_window_id;
    OmniUuid128 target_selection_window_id;
    uint8_t has_moved_window_id;
    OmniUuid128 moved_window_id;
} OmniNiriWorkspaceApplyResult;

typedef struct {
    uint8_t op;
    uint8_t direction;
    uint8_t orientation;
    uint8_t infinite_loop;
    uint8_t has_source_window_id;
    OmniUuid128 source_window_id;
    uint8_t has_source_column_id;
    OmniUuid128 source_column_id;
    uint8_t has_target_window_id;
    OmniUuid128 target_window_id;
    uint8_t has_target_column_id;
    OmniUuid128 target_column_id;
    int64_t step;
    int64_t target_row_index;
    int64_t focus_column_index;
    int64_t focus_window_index;
} OmniNiriTxnNavigationPayload;

typedef struct {
    uint8_t op;
    uint8_t direction;
    uint8_t infinite_loop;
    uint8_t insert_position;
    uint8_t has_source_window_id;
    OmniUuid128 source_window_id;
    uint8_t has_target_window_id;
    OmniUuid128 target_window_id;
    int64_t max_windows_per_column;
    uint8_t has_source_column_id;
    OmniUuid128 source_column_id;
    uint8_t has_target_column_id;
    OmniUuid128 target_column_id;
    int64_t insert_column_index;
    int64_t max_visible_columns;
    uint8_t has_selected_node_id;
    OmniUuid128 selected_node_id;
    uint8_t has_focused_window_id;
    OmniUuid128 focused_window_id;
    uint8_t incoming_spawn_mode;
    uint8_t has_incoming_window_id;
    OmniUuid128 incoming_window_id;
    uint8_t has_created_column_id;
    OmniUuid128 created_column_id;
    uint8_t has_placeholder_column_id;
    OmniUuid128 placeholder_column_id;
} OmniNiriTxnMutationPayload;

typedef struct {
    uint8_t op;
    uint8_t has_source_window_id;
    OmniUuid128 source_window_id;
    uint8_t has_source_column_id;
    OmniUuid128 source_column_id;
    int64_t max_visible_columns;
    uint8_t has_target_created_column_id;
    OmniUuid128 target_created_column_id;
    uint8_t has_source_placeholder_column_id;
    OmniUuid128 source_placeholder_column_id;
} OmniNiriTxnWorkspacePayload;

typedef struct {
    uint8_t kind;
    OmniNiriTxnNavigationPayload navigation;
    OmniNiriTxnMutationPayload mutation;
    OmniNiriTxnWorkspacePayload workspace;
    size_t max_delta_columns;
    size_t max_delta_windows;
    size_t max_removed_ids;
} OmniNiriTxnRequest;

typedef struct {
    uint8_t applied;
    uint8_t kind;
    uint8_t structural_animation_active;
    uint8_t has_target_window_id;
    OmniUuid128 target_window_id;
    uint8_t has_target_node_id;
    uint8_t target_node_kind;
    OmniUuid128 target_node_id;
    uint8_t changed_source_context;
    uint8_t changed_target_context;
    int32_t error_code;
    size_t delta_column_count;
    size_t delta_window_count;
    size_t removed_column_count;
    size_t removed_window_count;
} OmniNiriTxnResult;

typedef struct {
    const OmniNiriRuntimeColumnState *columns;
    size_t column_count;
    const OmniNiriRuntimeWindowState *windows;
    size_t window_count;
} OmniNiriRuntimeSeedRequest;

typedef struct {
    OmniNiriTxnRequest txn;
    double sample_time;
} OmniNiriRuntimeCommandRequest;

typedef struct {
    OmniNiriTxnResult txn;
} OmniNiriRuntimeCommandResult;

typedef struct {
    const OmniNiriColumnInput *columns;
    size_t column_count;
    const OmniNiriWindowInput *windows;
    size_t window_count;
    double working_x;
    double working_y;
    double working_width;
    double working_height;
    double view_x;
    double view_y;
    double view_width;
    double view_height;
    double fullscreen_x;
    double fullscreen_y;
    double fullscreen_width;
    double fullscreen_height;
    double primary_gap;
    double secondary_gap;
    double view_start;
    double viewport_span;
    double workspace_offset;
    double scale;
    uint8_t orientation;
    double sample_time;
} OmniNiriRuntimeRenderRequest;

typedef struct {
    OmniNiriWindowOutput *windows;
    size_t window_count;
    OmniNiriColumnOutput *columns;
    size_t column_count;
    uint8_t animation_active;
} OmniNiriRuntimeRenderOutput;

/// Apply one Niri runtime transaction and update context-owned delta buffers.
/// Returns 0 on success, -1 for invalid args, -2 for range/capacity failures.
int32_t omni_niri_ctx_apply_txn(
    OmniNiriLayoutContext *source_context,
    OmniNiriLayoutContext *target_context,
    const OmniNiriTxnRequest *request,
    OmniNiriTxnResult *out_result);

/// Export context-owned transaction delta pointers/counts from last apply.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_ctx_export_delta(
    const OmniNiriLayoutContext *context,
    OmniNiriTxnDeltaExport *out_export);

/// Create a Niri runtime owner for authoritative state.
/// Returns NULL on allocation failure.
OmniNiriRuntime *omni_niri_runtime_create(void);

/// Destroy a runtime owner.
void omni_niri_runtime_destroy(OmniNiriRuntime *runtime);

/// Seed authoritative runtime state.
/// Returns 0 on success, -1 for invalid args, -2 for capacity/range failures.
int32_t omni_niri_runtime_seed(
    OmniNiriRuntime *runtime,
    const OmniNiriRuntimeSeedRequest *request);

/// Apply one runtime command (navigation/mutation/workspace transaction).
/// Returns 0 on success, -1 for invalid args, -2 for range/capacity failures.
int32_t omni_niri_runtime_apply_command(
    OmniNiriRuntime *source_runtime,
    OmniNiriRuntime *target_runtime,
    const OmniNiriRuntimeCommandRequest *request,
    OmniNiriRuntimeCommandResult *out_result);

/// Render current runtime state into frame outputs.
/// Returns 0 on success, -1 for invalid args, -2 for range/capacity failures.
int32_t omni_niri_runtime_render(
    OmniNiriRuntime *runtime,
    OmniNiriLayoutContext *layout_context,
    const OmniNiriRuntimeRenderRequest *request,
    OmniNiriRuntimeRenderOutput *out_output);

/// Start the workspace-switch structural animation track for a runtime.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_start_workspace_switch_animation(
    OmniNiriRuntime *runtime,
    double sample_time);

/// Start the mutation structural animation track for a runtime.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_start_mutation_animation(
    OmniNiriRuntime *runtime,
    double sample_time);

/// Cancel any active runtime animation track.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_cancel_animation(
    OmniNiriRuntime *runtime);

/// Query whether the runtime still has an active animation track at `sample_time`.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_animation_active(
    OmniNiriRuntime *runtime,
    double sample_time,
    uint8_t *out_active);

/// Query the current Niri runtime viewport motion state at `sample_time`.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_viewport_status(
    OmniNiriRuntime *runtime,
    double sample_time,
    OmniNiriRuntimeViewportStatus *out_status);

/// Begin a runtime-owned viewport gesture sequence.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_viewport_begin_gesture(
    OmniNiriRuntime *runtime,
    double sample_time,
    uint8_t is_trackpad);

/// Advance a runtime-owned viewport gesture sequence.
/// Returns 0 on success, -1 for invalid args, -2 for range/capacity failures.
int32_t omni_niri_runtime_viewport_update_gesture(
    OmniNiriRuntime *runtime,
    const double *spans,
    size_t span_count,
    double delta_pixels,
    double timestamp,
    double gap,
    double viewport_span,
    OmniViewportGestureUpdateResult *out_result);

/// Finish a runtime-owned viewport gesture sequence and start the snap spring.
/// Returns 0 on success, -1 for invalid args, -2 for range/capacity failures.
int32_t omni_niri_runtime_viewport_end_gesture(
    OmniNiriRuntime *runtime,
    const double *spans,
    size_t span_count,
    double gap,
    double viewport_span,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    double sample_time,
    double display_refresh_rate,
    uint8_t reduce_motion,
    OmniViewportGestureEndResult *out_result);

/// Transition the runtime-owned viewport toward a selected column.
/// Returns 0 on success, -1 for invalid args, -2 for range/capacity failures.
int32_t omni_niri_runtime_viewport_transition_to_column(
    OmniNiriRuntime *runtime,
    const double *spans,
    size_t span_count,
    size_t requested_index,
    double gap,
    double viewport_span,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    uint8_t animate,
    double scale,
    double sample_time,
    double display_refresh_rate,
    uint8_t reduce_motion,
    OmniViewportTransitionResult *out_result);

/// Force the runtime-owned viewport offset to a static value.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_viewport_set_offset(
    OmniNiriRuntime *runtime,
    double offset);

/// Cancel runtime-owned viewport gesture/spring motion at `sample_time`.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_viewport_cancel(
    OmniNiriRuntime *runtime,
    double sample_time);

/// Export full runtime snapshot pointers/counts.
/// Returns 0 on success, -1 for invalid args.
int32_t omni_niri_runtime_snapshot(
    const OmniNiriRuntime *runtime,
    OmniNiriRuntimeStateExport *out_export);

typedef enum {
    OMNI_DWINDLE_NODE_SPLIT = 0,
    OMNI_DWINDLE_NODE_LEAF = 1
} OmniDwindleNodeKind;

typedef enum {
    OMNI_DWINDLE_ORIENTATION_HORIZONTAL = 0,
    OMNI_DWINDLE_ORIENTATION_VERTICAL = 1
} OmniDwindleOrientation;

typedef enum {
    OMNI_DWINDLE_DIRECTION_LEFT = 0,
    OMNI_DWINDLE_DIRECTION_RIGHT = 1,
    OMNI_DWINDLE_DIRECTION_UP = 2,
    OMNI_DWINDLE_DIRECTION_DOWN = 3
} OmniDwindleDirection;

typedef enum {
    OMNI_DWINDLE_OP_ADD_WINDOW = 0,
    OMNI_DWINDLE_OP_REMOVE_WINDOW = 1,
    OMNI_DWINDLE_OP_SYNC_WINDOWS = 2,
    OMNI_DWINDLE_OP_MOVE_FOCUS = 3,
    OMNI_DWINDLE_OP_SWAP_WINDOWS = 4,
    OMNI_DWINDLE_OP_TOGGLE_FULLSCREEN = 5,
    OMNI_DWINDLE_OP_TOGGLE_ORIENTATION = 6,
    OMNI_DWINDLE_OP_RESIZE_SELECTED = 7,
    OMNI_DWINDLE_OP_BALANCE_SIZES = 8,
    OMNI_DWINDLE_OP_CYCLE_SPLIT_RATIO = 9,
    OMNI_DWINDLE_OP_MOVE_SELECTION_TO_ROOT = 10,
    OMNI_DWINDLE_OP_SWAP_SPLIT = 11,
    OMNI_DWINDLE_OP_SET_PRESELECTION = 12,
    OMNI_DWINDLE_OP_CLEAR_PRESELECTION = 13,
    OMNI_DWINDLE_OP_VALIDATE_SELECTION = 14
} OmniDwindleOp;

enum {
    /// Equivalent to (MAX_WINDOWS * 2) - 1 where MAX_WINDOWS is 512 in Zig ABI.
    OMNI_DWINDLE_MAX_NODES = 1023
};

typedef struct {
    OmniUuid128 node_id;
    int64_t parent_index;
    int64_t first_child_index;
    int64_t second_child_index;
    uint8_t kind;
    uint8_t orientation;
    double ratio;
    uint8_t has_window_id;
    OmniUuid128 window_id;
    uint8_t is_fullscreen;
} OmniDwindleSeedNode;

typedef struct {
    int64_t root_node_index;
    int64_t selected_node_index;
    uint8_t has_preselection;
    uint8_t preselection_direction;
} OmniDwindleSeedState;

typedef struct {
    uint8_t smart_split;
    double default_split_ratio;
    double split_width_multiplier;
    double inner_gap;
} OmniDwindleRuntimeSettings;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} OmniDwindleRect;

typedef struct {
    double screen_x;
    double screen_y;
    double screen_width;
    double screen_height;
    double inner_gap;
    double outer_gap_top;
    double outer_gap_bottom;
    double outer_gap_left;
    double outer_gap_right;
    double single_window_aspect_width;
    double single_window_aspect_height;
    double single_window_aspect_tolerance;
    OmniDwindleRuntimeSettings runtime_settings;
} OmniDwindleLayoutRequest;

typedef struct {
    OmniUuid128 window_id;
    double min_width;
    double min_height;
    double max_width;
    double max_height;
    uint8_t has_max_width;
    uint8_t has_max_height;
    uint8_t is_fixed;
} OmniDwindleWindowConstraint;

typedef struct {
    OmniUuid128 window_id;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
} OmniDwindleWindowFrame;

typedef struct {
    OmniUuid128 window_id;
    uint8_t has_active_window_frame;
    OmniDwindleRect active_window_frame;
} OmniDwindleAddWindowPayload;

typedef struct {
    OmniUuid128 window_id;
} OmniDwindleRemoveWindowPayload;

typedef struct {
    const OmniUuid128 *window_ids;
    size_t window_count;
} OmniDwindleSyncWindowsPayload;

typedef struct {
    uint8_t direction;
} OmniDwindleMoveFocusPayload;

typedef struct {
    uint8_t direction;
} OmniDwindleSwapWindowsPayload;

typedef struct {
    uint8_t unused;
} OmniDwindleToggleFullscreenPayload;

typedef struct {
    uint8_t unused;
} OmniDwindleToggleOrientationPayload;

typedef struct {
    double delta;
    uint8_t direction;
} OmniDwindleResizeSelectedPayload;

typedef struct {
    uint8_t unused;
} OmniDwindleBalanceSizesPayload;

typedef struct {
    uint8_t forward;
} OmniDwindleCycleSplitRatioPayload;

typedef struct {
    uint8_t stable;
} OmniDwindleMoveSelectionToRootPayload;

typedef struct {
    uint8_t unused;
} OmniDwindleSwapSplitPayload;

typedef struct {
    uint8_t direction;
} OmniDwindleSetPreselectionPayload;

typedef struct {
    uint8_t unused;
} OmniDwindleClearPreselectionPayload;

typedef struct {
    uint8_t unused;
} OmniDwindleValidateSelectionPayload;

typedef union {
    OmniDwindleAddWindowPayload add_window;
    OmniDwindleRemoveWindowPayload remove_window;
    OmniDwindleSyncWindowsPayload sync_windows;
    OmniDwindleMoveFocusPayload move_focus;
    OmniDwindleSwapWindowsPayload swap_windows;
    OmniDwindleToggleFullscreenPayload toggle_fullscreen;
    OmniDwindleToggleOrientationPayload toggle_orientation;
    OmniDwindleResizeSelectedPayload resize_selected;
    OmniDwindleBalanceSizesPayload balance_sizes;
    OmniDwindleCycleSplitRatioPayload cycle_split_ratio;
    OmniDwindleMoveSelectionToRootPayload move_selection_to_root;
    OmniDwindleSwapSplitPayload swap_split;
    OmniDwindleSetPreselectionPayload set_preselection;
    OmniDwindleClearPreselectionPayload clear_preselection;
    OmniDwindleValidateSelectionPayload validate_selection;
} OmniDwindleOpPayload;

typedef struct {
    uint8_t op;
    OmniDwindleOpPayload payload;
    OmniDwindleRuntimeSettings runtime_settings;
} OmniDwindleOpRequest;

typedef struct {
    uint8_t applied;
    uint8_t has_selected_window_id;
    OmniUuid128 selected_window_id;
    uint8_t has_focused_window_id;
    OmniUuid128 focused_window_id;
    uint8_t has_preselection;
    uint8_t preselection_direction;
    size_t removed_window_count;
} OmniDwindleOpResult;

/// Create a reusable Dwindle layout context.
/// Returns NULL on allocation failure.
OmniDwindleLayoutContext *omni_dwindle_layout_context_create(void);

/// Destroy a reusable Dwindle layout context.
void omni_dwindle_layout_context_destroy(OmniDwindleLayoutContext *context);

/// Seed deterministic Dwindle state topology into context.
/// Returns 0 on success, -1 for invalid args, -2 for range/topology failures.
int32_t omni_dwindle_ctx_seed_state(
    OmniDwindleLayoutContext *context,
    const OmniDwindleSeedNode *nodes,
    size_t node_count,
    const OmniDwindleSeedState *seed_state);

/// Apply one deterministic Dwindle operation request.
/// Returns 0 on success, -1 for invalid args, -2 for range failures.
int32_t omni_dwindle_ctx_apply_op(
    OmniDwindleLayoutContext *context,
    const OmniDwindleOpRequest *request,
    OmniDwindleOpResult *out_result,
    OmniUuid128 *out_removed_window_ids,
    size_t out_removed_window_capacity);

/// Calculate Dwindle layout outputs for current deterministic context state.
/// Returns 0 on success, -1 for invalid args, -2 for range failures.
int32_t omni_dwindle_ctx_calculate_layout(
    OmniDwindleLayoutContext *context,
    const OmniDwindleLayoutRequest *request,
    const OmniDwindleWindowConstraint *constraints,
    size_t constraint_count,
    OmniDwindleWindowFrame *out_frames,
    size_t out_frame_capacity,
    size_t *out_frame_count);

/// Find directional geometric neighbor for a window in current context state.
/// Returns 0 on success, -1 for invalid args, -2 for range failures.
int32_t omni_dwindle_ctx_find_neighbor(
    const OmniDwindleLayoutContext *context,
    OmniUuid128 window_id,
    uint8_t direction,
    double inner_gap,
    uint8_t *out_has_neighbor,
    OmniUuid128 *out_neighbor_window_id);
