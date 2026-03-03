#pragma once
#include <stddef.h>
#include <stdint.h>

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
    int64_t window_index;
    uint8_t edges;
} OmniNiriResizeHitResult;

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

/// Solve axis layout for window_count windows.
///
/// is_tabbed: 0 = normal (weighted) layout, 1 = tabbed (all windows share one span).
///
/// Returns 0 on success.
/// Returns -1 if out_count < window_count or window_count exceeds the internal limit.
int32_t omni_axis_solve(
    const OmniAxisInput *windows,
    size_t window_count,
    double available_space,
    double gap_size,
    uint8_t is_tabbed,
    OmniAxisOutput *out,
    size_t out_count);

/// Tabbed variant (all windows get the same span, gaps are ignored).
/// Equivalent to calling omni_axis_solve with is_tabbed = 1.
int32_t omni_axis_solve_tabbed(
    const OmniAxisInput *windows,
    size_t window_count,
    double available_space,
    double gap_size,
    OmniAxisOutput *out,
    size_t out_count);

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

int32_t omni_viewport_find_snap_target(
    const double *spans,
    size_t span_count,
    double gap,
    double viewport_span,
    double projected_view_pos,
    double current_view_pos,
    uint8_t center_mode,
    uint8_t always_center_single_column,
    OmniSnapResult *out_result);

int32_t omni_niri_layout_pass(
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
    size_t out_window_count);

int32_t omni_niri_layout_pass_v2(
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

int32_t omni_niri_hit_test_tiled(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    int64_t *out_window_index);

int32_t omni_niri_hit_test_resize(
    const OmniNiriHitTestWindow *windows,
    size_t window_count,
    double point_x,
    double point_y,
    double threshold,
    OmniNiriResizeHitResult *out_result);

int32_t omni_niri_resize_compute(
    const OmniNiriResizeInput *input,
    OmniNiriResizeResult *out_result);
