#ifndef OMNIWM_KERNELS_H
#define OMNIWM_KERNELS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    OMNIWM_KERNELS_STATUS_OK = 0,
    OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT = 1,
    OMNIWM_KERNELS_STATUS_ALLOCATION_FAILED = 2,
};

enum {
    OMNIWM_CENTER_FOCUSED_COLUMN_NEVER = 0,
    OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS = 1,
    OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW = 2,
};

enum {
    OMNIWM_DWINDLE_NODE_KIND_SPLIT = 0,
    OMNIWM_DWINDLE_NODE_KIND_LEAF = 1,
};

enum {
    OMNIWM_DWINDLE_ORIENTATION_HORIZONTAL = 0,
    OMNIWM_DWINDLE_ORIENTATION_VERTICAL = 1,
};

enum {
    OMNIWM_NIRI_ORIENTATION_HORIZONTAL = 0,
    OMNIWM_NIRI_ORIENTATION_VERTICAL = 1,
};

enum {
    OMNIWM_NIRI_WINDOW_SIZING_NORMAL = 0,
    OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN = 1,
};

enum {
    OMNIWM_NIRI_HIDDEN_EDGE_NONE = 0,
    OMNIWM_NIRI_HIDDEN_EDGE_MINIMUM = 1,
    OMNIWM_NIRI_HIDDEN_EDGE_MAXIMUM = 2,
};

typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    double fixed_value;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
} omniwm_axis_input;

typedef struct {
    double value;
    uint8_t was_constrained;
} omniwm_axis_output;

typedef struct {
    int32_t root_index;
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
    double minimum_dimension;
    double gap_sticks_tolerance;
    double split_ratio_min;
    double split_ratio_max;
    double split_fraction_divisor;
    double split_fraction_min;
    double split_fraction_max;
} omniwm_dwindle_layout_input;

typedef struct {
    int32_t first_child_index;
    int32_t second_child_index;
    double split_ratio;
    double min_width;
    double min_height;
    uint32_t kind;
    uint32_t orientation;
    uint8_t has_window;
    uint8_t fullscreen;
} omniwm_dwindle_node_input;

typedef struct {
    double x;
    double y;
    double width;
    double height;
    uint8_t has_frame;
} omniwm_dwindle_node_frame;

typedef struct {
    double working_x;
    double working_y;
    double working_width;
    double working_height;
    double view_x;
    double view_y;
    double view_width;
    double view_height;
    double scale;
    double primary_gap;
    double secondary_gap;
    double tab_indicator_width;
    double view_offset;
    double workspace_offset;
    double single_window_aspect_ratio;
    double single_window_aspect_tolerance;
    int32_t active_container_index;
    int32_t hidden_placement_monitor_index;
    uint32_t orientation;
    uint8_t single_window_mode;
} omniwm_niri_layout_input;

typedef struct {
    double span;
    double render_offset_x;
    double render_offset_y;
    uint32_t window_start_index;
    uint32_t window_count;
    uint8_t is_tabbed;
    uint8_t has_manual_single_window_width_override;
} omniwm_niri_container_input;

typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    double fixed_value;
    double render_offset_x;
    double render_offset_y;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
    uint8_t sizing_mode;
} omniwm_niri_window_input;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    double visible_x;
    double visible_y;
    double visible_width;
    double visible_height;
} omniwm_niri_hidden_placement_monitor;

typedef struct {
    double canonical_x;
    double canonical_y;
    double canonical_width;
    double canonical_height;
    double rendered_x;
    double rendered_y;
    double rendered_width;
    double rendered_height;
} omniwm_niri_container_output;

typedef struct {
    double canonical_x;
    double canonical_y;
    double canonical_width;
    double canonical_height;
    double rendered_x;
    double rendered_y;
    double rendered_width;
    double rendered_height;
    double resolved_span;
    uint8_t hidden_edge;
} omniwm_niri_window_output;

int32_t omniwm_axis_solve(
    const omniwm_axis_input *inputs,
    size_t count,
    double available_space,
    double gap_size,
    uint8_t is_tabbed,
    omniwm_axis_output *outputs
);

int32_t omniwm_dwindle_solve(
    const omniwm_dwindle_layout_input *input,
    const omniwm_dwindle_node_input *nodes,
    size_t node_count,
    omniwm_dwindle_node_frame *outputs,
    size_t output_count
);

int32_t omniwm_niri_layout_solve(
    const omniwm_niri_layout_input *input,
    const omniwm_niri_container_input *containers,
    size_t container_count,
    const omniwm_niri_window_input *windows,
    size_t window_count,
    const omniwm_niri_hidden_placement_monitor *monitors,
    size_t monitor_count,
    omniwm_niri_container_output *container_outputs,
    size_t container_output_count,
    omniwm_niri_window_output *window_outputs,
    size_t window_output_count
);

double omniwm_geometry_container_position(
    const double *spans,
    size_t count,
    double gap,
    size_t index
);

double omniwm_geometry_total_span(
    const double *spans,
    size_t count,
    double gap
);

double omniwm_geometry_centered_offset(
    const double *spans,
    size_t count,
    double gap,
    double viewport_span,
    size_t index
);

double omniwm_geometry_visible_offset(
    const double *spans,
    size_t count,
    double gap,
    double viewport_span,
    int32_t index,
    double current_view_start,
    uint32_t center_mode,
    uint8_t always_center_single_column,
    int32_t from_index,
    double scale
);

typedef struct {
    double screen_x;
    double screen_y;
    double screen_width;
    double screen_height;
    double metrics_scale;
    double available_width;
    double scaled_window_padding;
    double scaled_workspace_label_height;
    double scaled_workspace_section_padding;
    double scaled_window_spacing;
    double thumbnail_width;
    double initial_content_y;
    double content_bottom_padding;
    double total_content_height_override;
    uint8_t has_total_content_height_override;
} omniwm_overview_context;

typedef struct {
    uint32_t generic_window_start_index;
    uint32_t generic_window_count;
    uint32_t niri_column_start_index;
    uint32_t niri_column_count;
} omniwm_overview_workspace_input;

typedef struct {
    uint32_t workspace_index;
    double source_x;
    double source_y;
    double source_width;
    double source_height;
    uint32_t title_sort_rank;
} omniwm_overview_generic_window_input;

typedef struct {
    double preferred_height;
} omniwm_overview_niri_tile_input;

typedef struct {
    uint32_t workspace_index;
    int32_t column_index;
    double width_weight;
    double preferred_width;
    uint32_t tile_start_index;
    uint32_t tile_count;
    uint8_t has_preferred_width;
} omniwm_overview_niri_column_input;

typedef struct {
    uint32_t workspace_index;
    double section_x;
    double section_y;
    double section_width;
    double section_height;
    double label_x;
    double label_y;
    double label_width;
    double label_height;
    double grid_x;
    double grid_y;
    double grid_width;
    double grid_height;
    uint32_t generic_window_output_start_index;
    uint32_t generic_window_output_count;
    uint32_t niri_column_output_start_index;
    uint32_t niri_column_output_count;
    uint32_t niri_tile_output_start_index;
    uint32_t niri_tile_output_count;
    uint32_t drop_zone_output_start_index;
    uint32_t drop_zone_output_count;
} omniwm_overview_section_output;

typedef struct {
    uint32_t input_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
} omniwm_overview_generic_window_output;

typedef struct {
    uint32_t input_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
} omniwm_overview_niri_tile_output;

typedef struct {
    uint32_t input_index;
    int32_t column_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint32_t tile_output_start_index;
    uint32_t tile_output_count;
} omniwm_overview_niri_column_output;

typedef struct {
    uint32_t workspace_index;
    uint32_t insert_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
} omniwm_overview_drop_zone_output;

typedef struct {
    double total_content_height;
    double min_scroll_offset;
    double max_scroll_offset;
    size_t section_count;
    size_t generic_window_output_count;
    size_t niri_column_output_count;
    size_t niri_tile_output_count;
    size_t drop_zone_output_count;
} omniwm_overview_result;

int32_t omniwm_overview_projection_solve(
    const omniwm_overview_context *context,
    const omniwm_overview_workspace_input *workspaces,
    size_t workspace_count,
    const omniwm_overview_generic_window_input *generic_windows,
    size_t generic_window_count,
    const omniwm_overview_niri_column_input *niri_columns,
    size_t niri_column_count,
    const omniwm_overview_niri_tile_input *niri_tiles,
    size_t niri_tile_count,
    omniwm_overview_section_output *section_outputs,
    size_t section_output_capacity,
    omniwm_overview_generic_window_output *generic_window_outputs,
    size_t generic_window_output_capacity,
    omniwm_overview_niri_column_output *niri_column_outputs,
    size_t niri_column_output_capacity,
    omniwm_overview_niri_tile_output *niri_tile_outputs,
    size_t niri_tile_output_capacity,
    omniwm_overview_drop_zone_output *drop_zone_outputs,
    size_t drop_zone_output_capacity,
    omniwm_overview_result *result
);

typedef struct {
    uint32_t display_id;
    double anchor_x;
    double anchor_y;
    double frame_width;
    double frame_height;
} omniwm_restore_snapshot;

typedef struct {
    uint32_t display_id;
    double frame_min_x;
    double frame_max_y;
    double anchor_x;
    double anchor_y;
    double frame_width;
    double frame_height;
} omniwm_restore_monitor;

typedef struct {
    uint32_t snapshot_index;
    uint32_t monitor_index;
} omniwm_restore_assignment;

int32_t omniwm_restore_resolve_assignments(
    const omniwm_restore_snapshot *snapshots,
    size_t snapshot_count,
    const omniwm_restore_monitor *monitors,
    size_t monitor_count,
    const uint8_t *name_penalties,
    size_t name_penalty_count,
    omniwm_restore_assignment *assignments,
    size_t assignment_capacity,
    size_t *assignment_count
);

enum {
    OMNIWM_RECONCILE_EVENT_WINDOW_ADMITTED = 0,
    OMNIWM_RECONCILE_EVENT_WINDOW_REKEYED = 1,
    OMNIWM_RECONCILE_EVENT_WINDOW_REMOVED = 2,
    OMNIWM_RECONCILE_EVENT_WORKSPACE_ASSIGNED = 3,
    OMNIWM_RECONCILE_EVENT_WINDOW_MODE_CHANGED = 4,
    OMNIWM_RECONCILE_EVENT_FLOATING_GEOMETRY_UPDATED = 5,
    OMNIWM_RECONCILE_EVENT_HIDDEN_STATE_CHANGED = 6,
    OMNIWM_RECONCILE_EVENT_NATIVE_FULLSCREEN_TRANSITION = 7,
    OMNIWM_RECONCILE_EVENT_MANAGED_REPLACEMENT_METADATA_CHANGED = 8,
    OMNIWM_RECONCILE_EVENT_TOPOLOGY_CHANGED = 9,
    OMNIWM_RECONCILE_EVENT_ACTIVE_SPACE_CHANGED = 10,
    OMNIWM_RECONCILE_EVENT_FOCUS_LEASE_CHANGED = 11,
    OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_REQUESTED = 12,
    OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_CONFIRMED = 13,
    OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_CANCELLED = 14,
    OMNIWM_RECONCILE_EVENT_NON_MANAGED_FOCUS_CHANGED = 15,
    OMNIWM_RECONCILE_EVENT_SYSTEM_SLEEP = 16,
    OMNIWM_RECONCILE_EVENT_SYSTEM_WAKE = 17,
};

enum {
    OMNIWM_RECONCILE_WINDOW_MODE_TILING = 0,
    OMNIWM_RECONCILE_WINDOW_MODE_FLOATING = 1,
};

enum {
    OMNIWM_RECONCILE_LIFECYCLE_DISCOVERED = 0,
    OMNIWM_RECONCILE_LIFECYCLE_ADMITTED = 1,
    OMNIWM_RECONCILE_LIFECYCLE_TILED = 2,
    OMNIWM_RECONCILE_LIFECYCLE_FLOATING = 3,
    OMNIWM_RECONCILE_LIFECYCLE_HIDDEN = 4,
    OMNIWM_RECONCILE_LIFECYCLE_OFFSCREEN = 5,
    OMNIWM_RECONCILE_LIFECYCLE_RESTORING = 6,
    OMNIWM_RECONCILE_LIFECYCLE_REPLACING = 7,
    OMNIWM_RECONCILE_LIFECYCLE_NATIVE_FULLSCREEN = 8,
    OMNIWM_RECONCILE_LIFECYCLE_DESTROYED = 9,
};

enum {
    OMNIWM_RECONCILE_REPLACEMENT_REASON_MANAGED_REPLACEMENT = 0,
    OMNIWM_RECONCILE_REPLACEMENT_REASON_NATIVE_FULLSCREEN = 1,
    OMNIWM_RECONCILE_REPLACEMENT_REASON_MANUAL_REKEY = 2,
};

enum {
    OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE = 0,
    OMNIWM_RECONCILE_HIDDEN_STATE_HIDDEN = 1,
    OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_LEFT = 2,
    OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_RIGHT = 3,
};

enum {
    OMNIWM_RECONCILE_NOTE_NONE = 0,
    OMNIWM_RECONCILE_NOTE_MANAGED_REPLACEMENT_METADATA_CHANGED = 1,
    OMNIWM_RECONCILE_NOTE_TOPOLOGY_CHANGED = 2,
    OMNIWM_RECONCILE_NOTE_ACTIVE_SPACE_CHANGED = 3,
    OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_SET = 4,
    OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_CLEARED = 5,
    OMNIWM_RECONCILE_NOTE_SYSTEM_SLEEP = 6,
    OMNIWM_RECONCILE_NOTE_SYSTEM_WAKE = 7,
};

enum {
    OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_KEEP_EXISTING = 0,
    OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_CLEAR = 1,
    OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_SET_FROM_EVENT = 2,
};

typedef struct {
    uint64_t high;
    uint64_t low;
} omniwm_uuid;

typedef struct {
    int32_t pid;
    int64_t window_id;
} omniwm_window_token;

typedef struct {
    double x;
    double y;
} omniwm_point;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} omniwm_rect;

typedef struct {
    omniwm_rect frame;
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint8_t has_frame;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
    uint8_t is_visible;
    uint8_t is_focused;
    uint8_t has_ax_reference;
    uint8_t is_native_fullscreen;
} omniwm_reconcile_observed_state;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint32_t disposition;
    omniwm_rect floating_frame;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
    uint8_t has_disposition;
    uint8_t has_floating_frame;
    uint8_t rescue_eligible;
} omniwm_reconcile_desired_state;

typedef struct {
    omniwm_rect last_frame;
    omniwm_point normalized_origin;
    uint32_t reference_monitor_id;
    uint8_t has_normalized_origin;
    uint8_t has_reference_monitor_id;
    uint8_t restore_to_floating;
} omniwm_reconcile_floating_state;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t mode;
    omniwm_reconcile_observed_state observed_state;
    omniwm_reconcile_desired_state desired_state;
    omniwm_reconcile_floating_state floating_state;
    uint8_t has_floating_state;
} omniwm_reconcile_entry;

typedef struct {
    uint32_t display_id;
    omniwm_rect visible_frame;
} omniwm_reconcile_monitor;

typedef struct {
    omniwm_window_token token;
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint8_t has_token;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
} omniwm_reconcile_pending_focus;

typedef struct {
    omniwm_window_token focused_token;
    omniwm_reconcile_pending_focus pending_managed_focus;
    uint8_t has_focused_token;
    uint8_t is_non_managed_focus_active;
    uint8_t is_app_fullscreen_active;
} omniwm_reconcile_focus_session;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint32_t target_mode;
    omniwm_rect floating_frame;
    uint8_t has_monitor_id;
    uint8_t has_floating_frame;
} omniwm_reconcile_persisted_hydration;

typedef struct {
    uint32_t kind;
    omniwm_window_token token;
    omniwm_window_token secondary_token;
    omniwm_uuid workspace_id;
    omniwm_uuid secondary_workspace_id;
    uint32_t monitor_id;
    uint32_t mode;
    omniwm_rect frame;
    uint32_t hidden_state;
    uint32_t replacement_reason;
    uint8_t has_secondary_token;
    uint8_t has_workspace_id;
    uint8_t has_secondary_workspace_id;
    uint8_t has_monitor_id;
    uint8_t has_mode;
    uint8_t has_frame;
    uint8_t restore_to_floating;
    uint8_t is_active;
    uint8_t app_fullscreen;
    uint8_t preserve_focused_token;
    uint8_t has_focus_lease;
} omniwm_reconcile_event;

typedef struct {
    omniwm_uuid workspace_id;
    int32_t preferred_monitor_index;
    omniwm_rect floating_frame;
    omniwm_point normalized_floating_origin;
    uint8_t has_floating_frame;
    uint8_t has_normalized_floating_origin;
    uint8_t restore_to_floating;
    uint8_t rescue_eligible;
} omniwm_reconcile_restore_intent_output;

typedef struct {
    omniwm_window_token previous_token;
    omniwm_window_token next_token;
    uint32_t reason;
} omniwm_reconcile_replacement_correlation;

typedef struct {
    omniwm_window_token focused_token;
    omniwm_reconcile_pending_focus pending_managed_focus;
    uint32_t focus_lease_action;
    uint8_t has_focused_token;
    uint8_t is_non_managed_focus_active;
    uint8_t is_app_fullscreen_active;
} omniwm_reconcile_focus_session_output;

typedef struct {
    uint32_t lifecycle_phase;
    omniwm_reconcile_observed_state observed_state;
    omniwm_reconcile_desired_state desired_state;
    omniwm_reconcile_restore_intent_output restore_intent;
    omniwm_reconcile_replacement_correlation replacement_correlation;
    omniwm_reconcile_focus_session_output focus_session;
    uint8_t has_lifecycle_phase;
    uint8_t has_observed_state;
    uint8_t has_desired_state;
    uint8_t has_restore_intent;
    uint8_t has_replacement_correlation;
    uint8_t has_focus_session;
    uint32_t note_code;
} omniwm_reconcile_plan_output;

int32_t omniwm_reconcile_plan(
    const omniwm_reconcile_event *event,
    const omniwm_reconcile_entry *existing_entry,
    const omniwm_reconcile_focus_session *focus_session,
    const omniwm_reconcile_monitor *monitors,
    size_t monitor_count,
    const omniwm_reconcile_persisted_hydration *persisted_hydration,
    omniwm_reconcile_plan_output *output
);

int32_t omniwm_reconcile_restore_intent(
    const omniwm_reconcile_entry *entry,
    const omniwm_reconcile_monitor *monitors,
    size_t monitor_count,
    omniwm_reconcile_restore_intent_output *output
);

#ifdef __cplusplus
}
#endif

#endif
