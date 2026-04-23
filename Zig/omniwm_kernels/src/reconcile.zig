// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;

const event_window_admitted: u32 = 0;
const event_window_rekeyed: u32 = 1;
const event_window_removed: u32 = 2;
const event_workspace_assigned: u32 = 3;
const event_window_mode_changed: u32 = 4;
const event_floating_geometry_updated: u32 = 5;
const event_hidden_state_changed: u32 = 6;
const event_native_fullscreen_transition: u32 = 7;
const event_managed_replacement_metadata_changed: u32 = 8;
const event_topology_changed: u32 = 9;
const event_active_space_changed: u32 = 10;
const event_focus_lease_changed: u32 = 11;
const event_managed_focus_requested: u32 = 12;
const event_managed_focus_confirmed: u32 = 13;
const event_managed_focus_cancelled: u32 = 14;
const event_non_managed_focus_changed: u32 = 15;
const event_system_sleep: u32 = 16;
const event_system_wake: u32 = 17;

const mode_tiling: u32 = 0;
const mode_floating: u32 = 1;

const lifecycle_tiled: u32 = 2;
const lifecycle_floating: u32 = 3;
const lifecycle_hidden: u32 = 4;
const lifecycle_offscreen: u32 = 5;
const lifecycle_replacing: u32 = 7;
const lifecycle_native_fullscreen: u32 = 8;
const lifecycle_destroyed: u32 = 9;

const replacement_managed_replacement: u32 = 0;

const hidden_state_visible: u32 = 0;
const hidden_state_hidden: u32 = 1;

const note_none: u32 = 0;
const note_managed_replacement_metadata_changed: u32 = 1;
const note_topology_changed: u32 = 2;
const note_active_space_changed: u32 = 3;
const note_focus_lease_set: u32 = 4;
const note_focus_lease_cleared: u32 = 5;
const note_system_sleep: u32 = 6;
const note_system_wake: u32 = 7;

const focus_lease_action_keep_existing: u32 = 0;
const focus_lease_action_clear: u32 = 1;
const focus_lease_action_set_from_event: u32 = 2;

const UUID = extern struct {
    high: u64,
    low: u64,
};

const WindowToken = extern struct {
    pid: i32,
    window_id: i64,
};

const Point = extern struct {
    x: f64,
    y: f64,
};

const Rect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const ObservedState = extern struct {
    frame: Rect,
    workspace_id: UUID,
    monitor_id: u32,
    has_frame: u8,
    has_workspace_id: u8,
    has_monitor_id: u8,
    is_visible: u8,
    is_focused: u8,
    has_ax_reference: u8,
    is_native_fullscreen: u8,
};

const DesiredState = extern struct {
    workspace_id: UUID,
    monitor_id: u32,
    disposition: u32,
    floating_frame: Rect,
    has_workspace_id: u8,
    has_monitor_id: u8,
    has_disposition: u8,
    has_floating_frame: u8,
    rescue_eligible: u8,
};

const FloatingState = extern struct {
    last_frame: Rect,
    normalized_origin: Point,
    reference_monitor_id: u32,
    has_normalized_origin: u8,
    has_reference_monitor_id: u8,
    restore_to_floating: u8,
};

const Entry = extern struct {
    workspace_id: UUID,
    mode: u32,
    observed_state: ObservedState,
    desired_state: DesiredState,
    floating_state: FloatingState,
    has_floating_state: u8,
};

const Monitor = extern struct {
    display_id: u32,
    visible_frame: Rect,
};

const PendingFocus = extern struct {
    token: WindowToken,
    workspace_id: UUID,
    monitor_id: u32,
    has_token: u8,
    has_workspace_id: u8,
    has_monitor_id: u8,
};

const FocusSession = extern struct {
    focused_token: WindowToken,
    pending_managed_focus: PendingFocus,
    has_focused_token: u8,
    is_non_managed_focus_active: u8,
    is_app_fullscreen_active: u8,
};

const PersistedHydration = extern struct {
    workspace_id: UUID,
    monitor_id: u32,
    target_mode: u32,
    floating_frame: Rect,
    has_monitor_id: u8,
    has_floating_frame: u8,
};

const Event = extern struct {
    kind: u32,
    token: WindowToken,
    secondary_token: WindowToken,
    workspace_id: UUID,
    secondary_workspace_id: UUID,
    monitor_id: u32,
    mode: u32,
    frame: Rect,
    hidden_state: u32,
    replacement_reason: u32,
    has_secondary_token: u8,
    has_workspace_id: u8,
    has_secondary_workspace_id: u8,
    has_monitor_id: u8,
    has_mode: u8,
    has_frame: u8,
    restore_to_floating: u8,
    is_active: u8,
    app_fullscreen: u8,
    preserve_focused_token: u8,
    has_focus_lease: u8,
};

const RestoreIntentOutput = extern struct {
    workspace_id: UUID,
    preferred_monitor_index: i32,
    floating_frame: Rect,
    normalized_floating_origin: Point,
    has_floating_frame: u8,
    has_normalized_floating_origin: u8,
    restore_to_floating: u8,
    rescue_eligible: u8,
};

const ReplacementCorrelation = extern struct {
    previous_token: WindowToken,
    next_token: WindowToken,
    reason: u32,
};

const FocusSessionOutput = extern struct {
    focused_token: WindowToken,
    pending_managed_focus: PendingFocus,
    focus_lease_action: u32,
    has_focused_token: u8,
    is_non_managed_focus_active: u8,
    is_app_fullscreen_active: u8,
};

const PlanOutput = extern struct {
    lifecycle_phase: u32,
    observed_state: ObservedState,
    desired_state: DesiredState,
    restore_intent: RestoreIntentOutput,
    replacement_correlation: ReplacementCorrelation,
    focus_session: FocusSessionOutput,
    has_lifecycle_phase: u8,
    has_observed_state: u8,
    has_desired_state: u8,
    has_restore_intent: u8,
    has_replacement_correlation: u8,
    has_focus_session: u8,
    note_code: u32,
};

const SimulatedEntry = struct {
    workspace_id: UUID,
    mode: u32,
    observed_state: ObservedState,
    desired_state: DesiredState,
    floating_state: FloatingState,
    has_floating_state: bool,
};

fn windowTokenEqual(lhs: WindowToken, rhs: WindowToken) bool {
    return lhs.pid == rhs.pid and lhs.window_id == rhs.window_id;
}

fn lifecycleForMode(mode: u32) u32 {
    return if (mode == mode_floating) lifecycle_floating else lifecycle_tiled;
}

fn initialObserved(workspace_id: UUID, has_monitor_id: bool, monitor_id: u32) ObservedState {
    var state = std.mem.zeroes(ObservedState);
    state.workspace_id = workspace_id;
    state.has_workspace_id = 1;
    if (has_monitor_id) {
        state.monitor_id = monitor_id;
        state.has_monitor_id = 1;
    }
    state.is_visible = 1;
    state.has_ax_reference = 1;
    return state;
}

fn initialDesired(workspace_id: UUID, has_monitor_id: bool, monitor_id: u32, mode: u32) DesiredState {
    var state = std.mem.zeroes(DesiredState);
    state.workspace_id = workspace_id;
    state.has_workspace_id = 1;
    if (has_monitor_id) {
        state.monitor_id = monitor_id;
        state.has_monitor_id = 1;
    }
    state.disposition = mode;
    state.has_disposition = 1;
    state.rescue_eligible = @intFromBool(mode == mode_floating);
    return state;
}

fn baseObserved(entry: ?*const Entry, workspace_id: UUID, has_monitor_id: bool, monitor_id: u32) ObservedState {
    var state = if (entry) |resolved| resolved.observed_state else initialObserved(workspace_id, has_monitor_id, monitor_id);
    state.workspace_id = workspace_id;
    state.has_workspace_id = 1;
    if (has_monitor_id) {
        state.monitor_id = monitor_id;
        state.has_monitor_id = 1;
    }
    state.has_ax_reference = 1;
    return state;
}

fn baseDesired(entry: ?*const Entry, workspace_id: UUID, has_monitor_id: bool, monitor_id: u32, mode: u32) DesiredState {
    var state = if (entry) |resolved| resolved.desired_state else initialDesired(workspace_id, has_monitor_id, monitor_id, mode);
    state.workspace_id = workspace_id;
    state.has_workspace_id = 1;
    if (has_monitor_id) {
        state.monitor_id = monitor_id;
        state.has_monitor_id = 1;
    }
    state.disposition = mode;
    state.has_disposition = 1;
    state.rescue_eligible = @intFromBool(mode == mode_floating or state.rescue_eligible != 0);
    return state;
}

fn emptyPendingFocus() PendingFocus {
    return std.mem.zeroes(PendingFocus);
}

fn focusSessionFromInput(input: *const FocusSession) FocusSessionOutput {
    var output = std.mem.zeroes(FocusSessionOutput);
    output.has_focused_token = input.has_focused_token;
    output.focused_token = input.focused_token;
    output.pending_managed_focus = input.pending_managed_focus;
    output.is_non_managed_focus_active = input.is_non_managed_focus_active;
    output.is_app_fullscreen_active = input.is_app_fullscreen_active;
    output.focus_lease_action = focus_lease_action_keep_existing;
    return output;
}

fn effectiveMode(entry: ?*const Entry) u32 {
    return if (entry) |resolved| resolved.mode else mode_tiling;
}

fn findMonitorIndex(monitors: []const Monitor, display_id: u32) ?usize {
    for (monitors, 0..) |monitor, index| {
        if (monitor.display_id == display_id) {
            return index;
        }
    }
    return null;
}

fn normalizedFloatingOrigin(frame: Rect, visible_frame: Rect) Point {
    const available_width = @max(@as(f64, 1), visible_frame.width - frame.width);
    const available_height = @max(@as(f64, 1), visible_frame.height - frame.height);
    const normalized_x = (frame.x - visible_frame.x) / available_width;
    const normalized_y = (frame.y - visible_frame.y) / available_height;
    return .{
        .x = std.math.clamp(normalized_x, 0, 1),
        .y = std.math.clamp(normalized_y, 0, 1),
    };
}

fn visibleFrameForHydration(monitors: []const Monitor, hydration: *const PersistedHydration) Rect {
    if (hydration.has_monitor_id != 0) {
        if (findMonitorIndex(monitors, hydration.monitor_id)) |index| {
            return monitors[index].visible_frame;
        }
    }
    return hydration.floating_frame;
}

fn applyHydration(output: *PlanOutput, existing_entry: ?*const Entry, hydration: *const PersistedHydration) void {
    var observed = if (output.has_observed_state != 0)
        output.observed_state
    else if (existing_entry) |resolved|
        resolved.observed_state
    else
        initialObserved(hydration.workspace_id, hydration.has_monitor_id != 0, hydration.monitor_id);
    observed.workspace_id = hydration.workspace_id;
    observed.has_workspace_id = 1;
    if (hydration.has_monitor_id != 0) {
        observed.monitor_id = hydration.monitor_id;
        observed.has_monitor_id = 1;
    }
    observed.has_ax_reference = 1;
    output.observed_state = observed;
    output.has_observed_state = 1;

    var desired = if (output.has_desired_state != 0)
        output.desired_state
    else if (existing_entry) |resolved|
        resolved.desired_state
    else
        initialDesired(hydration.workspace_id, hydration.has_monitor_id != 0, hydration.monitor_id, hydration.target_mode);
    desired.workspace_id = hydration.workspace_id;
    desired.has_workspace_id = 1;
    if (hydration.has_monitor_id != 0) {
        desired.monitor_id = hydration.monitor_id;
        desired.has_monitor_id = 1;
    }
    desired.disposition = hydration.target_mode;
    desired.has_disposition = 1;
    if (hydration.has_floating_frame != 0) {
        desired.floating_frame = hydration.floating_frame;
        desired.has_floating_frame = 1;
        desired.rescue_eligible = 1;
    } else if (hydration.target_mode == mode_floating) {
        desired.rescue_eligible = 1;
    }
    output.desired_state = desired;
    output.has_desired_state = 1;
    output.lifecycle_phase = lifecycleForMode(hydration.target_mode);
    output.has_lifecycle_phase = 1;
}

fn simulatedEntry(existing_entry: *const Entry, output: *const PlanOutput, monitors: []const Monitor, hydration: ?*const PersistedHydration) SimulatedEntry {
    var state = SimulatedEntry{
        .workspace_id = existing_entry.workspace_id,
        .mode = existing_entry.mode,
        .observed_state = if (output.has_observed_state != 0) output.observed_state else existing_entry.observed_state,
        .desired_state = if (output.has_desired_state != 0) output.desired_state else existing_entry.desired_state,
        .floating_state = existing_entry.floating_state,
        .has_floating_state = existing_entry.has_floating_state != 0,
    };

    if (hydration) |resolved| {
        state.workspace_id = resolved.workspace_id;
        state.mode = resolved.target_mode;
        if (resolved.has_floating_frame != 0) {
            state.has_floating_state = true;
            state.floating_state.last_frame = resolved.floating_frame;
            state.floating_state.normalized_origin = normalizedFloatingOrigin(resolved.floating_frame, visibleFrameForHydration(monitors, resolved));
            state.floating_state.has_normalized_origin = 1;
            state.floating_state.reference_monitor_id = resolved.monitor_id;
            state.floating_state.has_reference_monitor_id = resolved.has_monitor_id;
            state.floating_state.restore_to_floating = 1;
        }
    }

    return state;
}

fn deriveRestoreIntent(state: SimulatedEntry, monitors: []const Monitor) RestoreIntentOutput {
    var output = std.mem.zeroes(RestoreIntentOutput);
    output.workspace_id = state.workspace_id;
    output.preferred_monitor_index = -1;

    var preferred_index: ?usize = null;
    if (state.desired_state.has_monitor_id != 0) {
        preferred_index = findMonitorIndex(monitors, state.desired_state.monitor_id);
    }
    if (preferred_index == null and state.observed_state.has_monitor_id != 0) {
        preferred_index = findMonitorIndex(monitors, state.observed_state.monitor_id);
    }
    if (preferred_index == null and state.has_floating_state and state.floating_state.has_reference_monitor_id != 0) {
        preferred_index = findMonitorIndex(monitors, state.floating_state.reference_monitor_id);
    }
    if (preferred_index) |resolved| {
        output.preferred_monitor_index = @intCast(resolved);
    }

    if (state.desired_state.has_floating_frame != 0) {
        output.floating_frame = state.desired_state.floating_frame;
        output.has_floating_frame = 1;
    } else if (state.has_floating_state) {
        output.floating_frame = state.floating_state.last_frame;
        output.has_floating_frame = 1;
    }

    if (state.has_floating_state and state.floating_state.has_normalized_origin != 0) {
        output.normalized_floating_origin = state.floating_state.normalized_origin;
        output.has_normalized_floating_origin = 1;
    }

    output.restore_to_floating = if (state.has_floating_state) state.floating_state.restore_to_floating else @intFromBool(state.mode == mode_floating);
    output.rescue_eligible = @intFromBool(
        state.desired_state.rescue_eligible != 0 or (state.has_floating_state and state.floating_state.restore_to_floating != 0)
    );
    return output;
}

pub export fn omniwm_reconcile_plan(
    event_ptr: [*c]const Event,
    existing_entry_ptr: [*c]const Entry,
    focus_session_ptr: [*c]const FocusSession,
    monitors_ptr: [*c]const Monitor,
    monitor_count: usize,
    persisted_hydration_ptr: [*c]const PersistedHydration,
    output_ptr: [*c]PlanOutput,
) i32 {
    if (event_ptr == null or focus_session_ptr == null or output_ptr == null) {
        return kernel_invalid_argument;
    }
    if (monitor_count > 0 and monitors_ptr == null) {
        return kernel_invalid_argument;
    }

    const event: *const Event = @ptrCast(event_ptr);
    const focus_session: *const FocusSession = @ptrCast(focus_session_ptr);
    const existing_entry: ?*const Entry = if (existing_entry_ptr == null) null else @ptrCast(existing_entry_ptr);
    const persisted_hydration: ?*const PersistedHydration = if (persisted_hydration_ptr == null) null else @ptrCast(persisted_hydration_ptr);
    const monitors = if (monitor_count == 0) &[_]Monitor{} else @as([*]const Monitor, @ptrCast(monitors_ptr))[0..monitor_count];

    var output = std.mem.zeroes(PlanOutput);

    switch (event.kind) {
        event_window_admitted => {
            output.lifecycle_phase = lifecycleForMode(event.mode);
            output.has_lifecycle_phase = 1;
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.has_observed_state = 1;
            output.desired_state = baseDesired(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id, event.mode);
            output.has_desired_state = 1;
        },
        event_window_rekeyed => {
            output.lifecycle_phase = lifecycle_replacing;
            output.has_lifecycle_phase = 1;
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.has_observed_state = 1;
            output.desired_state = baseDesired(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id, effectiveMode(existing_entry));
            output.has_desired_state = 1;
            output.replacement_correlation = .{
                .previous_token = event.secondary_token,
                .next_token = event.token,
                .reason = event.replacement_reason,
            };
            output.has_replacement_correlation = 1;

            var next_focus = focusSessionFromInput(focus_session);
            if (next_focus.has_focused_token != 0 and windowTokenEqual(next_focus.focused_token, event.secondary_token)) {
                next_focus.focused_token = event.token;
            }
            if (next_focus.pending_managed_focus.has_token != 0 and windowTokenEqual(next_focus.pending_managed_focus.token, event.secondary_token)) {
                next_focus.pending_managed_focus.token = event.token;
            }
            output.focus_session = next_focus;
            output.has_focus_session = 1;
        },
        event_window_removed => {
            output.lifecycle_phase = lifecycle_destroyed;
            output.has_lifecycle_phase = 1;

            var next_focus = focusSessionFromInput(focus_session);
            if (next_focus.has_focused_token != 0 and windowTokenEqual(next_focus.focused_token, event.token)) {
                next_focus.has_focused_token = 0;
                next_focus.is_app_fullscreen_active = 0;
            }
            if (next_focus.pending_managed_focus.has_token != 0 and windowTokenEqual(next_focus.pending_managed_focus.token, event.token)) {
                next_focus.pending_managed_focus = emptyPendingFocus();
            }
            output.focus_session = next_focus;
            output.has_focus_session = 1;
        },
        event_workspace_assigned => {
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.has_observed_state = 1;
            output.desired_state = baseDesired(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id, effectiveMode(existing_entry));
            output.has_desired_state = 1;
        },
        event_window_mode_changed => {
            output.lifecycle_phase = lifecycleForMode(event.mode);
            output.has_lifecycle_phase = 1;
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.has_observed_state = 1;
            output.desired_state = baseDesired(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id, event.mode);
            output.has_desired_state = 1;
        },
        event_floating_geometry_updated => {
            output.lifecycle_phase = lifecycle_floating;
            output.has_lifecycle_phase = 1;
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.observed_state.frame = event.frame;
            output.observed_state.has_frame = 1;
            output.has_observed_state = 1;
            output.desired_state = baseDesired(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id, mode_floating);
            output.desired_state.floating_frame = event.frame;
            output.desired_state.has_floating_frame = 1;
            output.desired_state.rescue_eligible = event.restore_to_floating;
            output.has_desired_state = 1;
        },
        event_hidden_state_changed => {
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.observed_state.is_visible = @intFromBool(event.hidden_state == hidden_state_visible);
            output.has_observed_state = 1;
            output.lifecycle_phase = switch (event.hidden_state) {
                hidden_state_visible => lifecycleForMode(effectiveMode(existing_entry)),
                hidden_state_hidden => lifecycle_hidden,
                else => lifecycle_offscreen,
            };
            output.has_lifecycle_phase = 1;
        },
        event_native_fullscreen_transition => {
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.observed_state.is_native_fullscreen = event.is_active;
            output.has_observed_state = 1;
            output.lifecycle_phase = if (event.is_active != 0) lifecycle_native_fullscreen else lifecycleForMode(effectiveMode(existing_entry));
            output.has_lifecycle_phase = 1;
        },
        event_managed_replacement_metadata_changed => {
            output.observed_state = baseObserved(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id);
            output.has_observed_state = 1;
            output.desired_state = baseDesired(existing_entry, event.workspace_id, event.has_monitor_id != 0, event.monitor_id, effectiveMode(existing_entry));
            output.has_desired_state = 1;
            output.note_code = note_managed_replacement_metadata_changed;
        },
        event_topology_changed => {
            output.note_code = note_topology_changed;
        },
        event_active_space_changed => {
            output.note_code = note_active_space_changed;
        },
        event_focus_lease_changed => {
            var next_focus = focusSessionFromInput(focus_session);
            next_focus.focus_lease_action = if (event.has_focus_lease != 0) focus_lease_action_set_from_event else focus_lease_action_clear;
            output.focus_session = next_focus;
            output.has_focus_session = 1;
            output.note_code = if (event.has_focus_lease != 0) note_focus_lease_set else note_focus_lease_cleared;
        },
        event_managed_focus_requested => {
            var next_focus = focusSessionFromInput(focus_session);
            next_focus.pending_managed_focus = .{
                .token = event.token,
                .workspace_id = event.workspace_id,
                .monitor_id = event.monitor_id,
                .has_token = 1,
                .has_workspace_id = 1,
                .has_monitor_id = event.has_monitor_id,
            };
            output.focus_session = next_focus;
            output.has_focus_session = 1;
        },
        event_managed_focus_confirmed => {
            var next_focus = focusSessionFromInput(focus_session);
            next_focus.has_focused_token = 1;
            next_focus.focused_token = event.token;
            next_focus.pending_managed_focus = emptyPendingFocus();
            next_focus.is_non_managed_focus_active = 0;
            next_focus.is_app_fullscreen_active = event.app_fullscreen;
            output.focus_session = next_focus;
            output.has_focus_session = 1;
        },
        event_managed_focus_cancelled => {
            var next_focus = focusSessionFromInput(focus_session);
            const matches_token = if (event.has_secondary_token != 0)
                next_focus.pending_managed_focus.has_token != 0 and windowTokenEqual(next_focus.pending_managed_focus.token, event.secondary_token)
            else
                true;
            const matches_workspace = if (event.has_workspace_id != 0)
                next_focus.pending_managed_focus.has_workspace_id != 0 and
                    next_focus.pending_managed_focus.workspace_id.high == event.workspace_id.high and
                    next_focus.pending_managed_focus.workspace_id.low == event.workspace_id.low
            else
                true;
            if (matches_token and matches_workspace) {
                next_focus.pending_managed_focus = emptyPendingFocus();
            }
            output.focus_session = next_focus;
            output.has_focus_session = 1;
        },
        event_non_managed_focus_changed => {
            var next_focus = focusSessionFromInput(focus_session);
            if (event.is_active != 0 and event.preserve_focused_token == 0) {
                next_focus.has_focused_token = 0;
            }
            next_focus.pending_managed_focus = emptyPendingFocus();
            next_focus.is_non_managed_focus_active = event.is_active;
            next_focus.is_app_fullscreen_active = event.app_fullscreen;
            output.focus_session = next_focus;
            output.has_focus_session = 1;
        },
        event_system_sleep => {
            output.note_code = note_system_sleep;
        },
        event_system_wake => {
            output.note_code = note_system_wake;
        },
        else => return kernel_invalid_argument,
    }

    if (persisted_hydration) |resolved| {
        applyHydration(&output, existing_entry, resolved);
    }

    if (existing_entry) |resolved_entry| {
        output.restore_intent = deriveRestoreIntent(simulatedEntry(resolved_entry, &output, monitors, persisted_hydration), monitors);
        output.has_restore_intent = 1;
    }

    output_ptr[0] = output;
    return kernel_ok;
}

pub export fn omniwm_reconcile_restore_intent(
    entry_ptr: [*c]const Entry,
    monitors_ptr: [*c]const Monitor,
    monitor_count: usize,
    output_ptr: [*c]RestoreIntentOutput,
) i32 {
    if (entry_ptr == null or output_ptr == null) {
        return kernel_invalid_argument;
    }
    if (monitor_count > 0 and monitors_ptr == null) {
        return kernel_invalid_argument;
    }

    const monitors = if (monitor_count == 0) &[_]Monitor{} else @as([*]const Monitor, @ptrCast(monitors_ptr))[0..monitor_count];
    const entry = &entry_ptr[0];
    output_ptr[0] = deriveRestoreIntent(.{
        .workspace_id = entry.workspace_id,
        .mode = entry.mode,
        .observed_state = entry.observed_state,
        .desired_state = entry.desired_state,
        .floating_state = entry.floating_state,
        .has_floating_state = entry.has_floating_state != 0,
    }, monitors);
    return kernel_ok;
}

test "reconcile plan rekeys focused and pending tokens" {
    var output = std.mem.zeroes(PlanOutput);
    const event = Event{
        .kind = event_window_rekeyed,
        .token = .{ .pid = 7, .window_id = 8 },
        .secondary_token = .{ .pid = 7, .window_id = 6 },
        .workspace_id = .{ .high = 1, .low = 2 },
        .secondary_workspace_id = .{ .high = 0, .low = 0 },
        .monitor_id = 9,
        .mode = mode_tiling,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_visible,
        .replacement_reason = replacement_managed_replacement,
        .has_secondary_token = 1,
        .has_workspace_id = 1,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 1,
        .has_mode = 0,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 0,
    };
    const entry = Entry{
        .workspace_id = .{ .high = 1, .low = 2 },
        .mode = mode_tiling,
        .observed_state = initialObserved(.{ .high = 1, .low = 2 }, true, 9),
        .desired_state = initialDesired(.{ .high = 1, .low = 2 }, true, 9, mode_tiling),
        .floating_state = std.mem.zeroes(FloatingState),
        .has_floating_state = 0,
    };
    const focus = FocusSession{
        .focused_token = .{ .pid = 7, .window_id = 6 },
        .pending_managed_focus = .{
            .token = .{ .pid = 7, .window_id = 6 },
            .workspace_id = .{ .high = 1, .low = 2 },
            .monitor_id = 9,
            .has_token = 1,
            .has_workspace_id = 1,
            .has_monitor_id = 1,
        },
        .has_focused_token = 1,
        .is_non_managed_focus_active = 0,
        .is_app_fullscreen_active = 0,
    };
    const status = omniwm_reconcile_plan(&event, &entry, &focus, null, 0, null, &output);
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(@as(u8, 1), output.has_focus_session);
    try std.testing.expectEqual(@as(i64, 8), output.focus_session.focused_token.window_id);
    try std.testing.expectEqual(@as(i64, 8), output.focus_session.pending_managed_focus.token.window_id);
    try std.testing.expectEqual(@as(u8, 1), output.has_replacement_correlation);
}

test "reconcile plan admits window without existing entry or monitors" {
    var output = std.mem.zeroes(PlanOutput);
    const event = Event{
        .kind = event_window_admitted,
        .token = .{ .pid = 12, .window_id = 13 },
        .secondary_token = std.mem.zeroes(WindowToken),
        .workspace_id = .{ .high = 6, .low = 7 },
        .secondary_workspace_id = std.mem.zeroes(UUID),
        .monitor_id = 0,
        .mode = mode_floating,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_visible,
        .replacement_reason = 0,
        .has_secondary_token = 0,
        .has_workspace_id = 1,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 0,
        .has_mode = 1,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 0,
    };
    const focus = FocusSession{
        .focused_token = std.mem.zeroes(WindowToken),
        .pending_managed_focus = emptyPendingFocus(),
        .has_focused_token = 0,
        .is_non_managed_focus_active = 0,
        .is_app_fullscreen_active = 0,
    };
    const status = omniwm_reconcile_plan(&event, null, &focus, null, 0, null, &output);
    try std.testing.expectEqual(kernel_ok, status);
    try std.testing.expectEqual(@as(u8, 1), output.has_lifecycle_phase);
    try std.testing.expectEqual(lifecycle_floating, output.lifecycle_phase);
    try std.testing.expectEqual(@as(u8, 1), output.has_observed_state);
    try std.testing.expectEqual(@as(u8, 1), output.has_desired_state);
    try std.testing.expectEqual(@as(u8, 0), output.has_restore_intent);
    try std.testing.expectEqual(@as(u8, 1), output.observed_state.has_workspace_id);
    try std.testing.expectEqual(@as(u8, 0), output.observed_state.has_monitor_id);
    try std.testing.expectEqual(mode_floating, output.desired_state.disposition);
    try std.testing.expectEqual(@as(u8, 1), output.desired_state.rescue_eligible);
}

test "reconcile plan maps hidden lifecycle and clears focus lease" {
    var hidden_output = std.mem.zeroes(PlanOutput);
    const hidden_event = Event{
        .kind = event_hidden_state_changed,
        .token = .{ .pid = 14, .window_id = 15 },
        .secondary_token = std.mem.zeroes(WindowToken),
        .workspace_id = .{ .high = 8, .low = 9 },
        .secondary_workspace_id = std.mem.zeroes(UUID),
        .monitor_id = 44,
        .mode = 0,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_hidden,
        .replacement_reason = 0,
        .has_secondary_token = 0,
        .has_workspace_id = 1,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 1,
        .has_mode = 0,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 0,
    };
    const entry = Entry{
        .workspace_id = .{ .high = 8, .low = 9 },
        .mode = mode_floating,
        .observed_state = initialObserved(.{ .high = 8, .low = 9 }, true, 44),
        .desired_state = initialDesired(.{ .high = 8, .low = 9 }, true, 44, mode_floating),
        .floating_state = std.mem.zeroes(FloatingState),
        .has_floating_state = 0,
    };
    const focus = FocusSession{
        .focused_token = std.mem.zeroes(WindowToken),
        .pending_managed_focus = emptyPendingFocus(),
        .has_focused_token = 0,
        .is_non_managed_focus_active = 0,
        .is_app_fullscreen_active = 0,
    };
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&hidden_event, &entry, &focus, null, 0, null, &hidden_output));
    try std.testing.expectEqual(lifecycle_hidden, hidden_output.lifecycle_phase);
    try std.testing.expectEqual(@as(u8, 0), hidden_output.observed_state.is_visible);

    var lease_output = std.mem.zeroes(PlanOutput);
    const lease_event = Event{
        .kind = event_focus_lease_changed,
        .token = std.mem.zeroes(WindowToken),
        .secondary_token = std.mem.zeroes(WindowToken),
        .workspace_id = std.mem.zeroes(UUID),
        .secondary_workspace_id = std.mem.zeroes(UUID),
        .monitor_id = 0,
        .mode = 0,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_visible,
        .replacement_reason = 0,
        .has_secondary_token = 0,
        .has_workspace_id = 0,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 0,
        .has_mode = 0,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 0,
    };
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&lease_event, null, &focus, null, 0, null, &lease_output));
    try std.testing.expectEqual(@as(u8, 1), lease_output.has_focus_session);
    try std.testing.expectEqual(focus_lease_action_clear, lease_output.focus_session.focus_lease_action);
    try std.testing.expectEqual(note_focus_lease_cleared, lease_output.note_code);
}

test "reconcile restore intent prefers desired then observed then floating monitor" {
    const monitors = [_]Monitor{
        .{ .display_id = 101, .visible_frame = .{ .x = 0, .y = 0, .width = 1600, .height = 900 } },
        .{ .display_id = 202, .visible_frame = .{ .x = 1600, .y = 0, .width = 1600, .height = 900 } },
        .{ .display_id = 303, .visible_frame = .{ .x = 3200, .y = 0, .width = 1600, .height = 900 } },
    };
    var entry = Entry{
        .workspace_id = .{ .high = 4, .low = 5 },
        .mode = mode_floating,
        .observed_state = initialObserved(.{ .high = 4, .low = 5 }, true, 202),
        .desired_state = initialDesired(.{ .high = 4, .low = 5 }, true, 101, mode_floating),
        .floating_state = .{
            .last_frame = .{ .x = 10, .y = 20, .width = 300, .height = 200 },
            .normalized_origin = .{ .x = 0.25, .y = 0.5 },
            .reference_monitor_id = 303,
            .has_normalized_origin = 1,
            .has_reference_monitor_id = 1,
            .restore_to_floating = 1,
        },
        .has_floating_state = 1,
    };
    var output = std.mem.zeroes(RestoreIntentOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_restore_intent(&entry, &monitors, monitors.len, &output));
    try std.testing.expectEqual(@as(i32, 0), output.preferred_monitor_index);

    entry.desired_state.has_monitor_id = 0;
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_restore_intent(&entry, &monitors, monitors.len, &output));
    try std.testing.expectEqual(@as(i32, 1), output.preferred_monitor_index);

    entry.observed_state.has_monitor_id = 0;
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_restore_intent(&entry, &monitors, monitors.len, &output));
    try std.testing.expectEqual(@as(i32, 2), output.preferred_monitor_index);
    try std.testing.expectEqual(@as(u8, 1), output.restore_to_floating);
    try std.testing.expectEqual(@as(u8, 1), output.rescue_eligible);
}

test "reconcile plan hydration overrides desired state and restore intent" {
    const monitors = [_]Monitor{
        .{ .display_id = 404, .visible_frame = .{ .x = 0, .y = 0, .width = 1440, .height = 900 } },
    };
    const event = Event{
        .kind = event_managed_replacement_metadata_changed,
        .token = .{ .pid = 10, .window_id = 11 },
        .secondary_token = .{ .pid = 0, .window_id = 0 },
        .workspace_id = .{ .high = 7, .low = 8 },
        .secondary_workspace_id = .{ .high = 0, .low = 0 },
        .monitor_id = 404,
        .mode = mode_tiling,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_visible,
        .replacement_reason = 0,
        .has_secondary_token = 0,
        .has_workspace_id = 1,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 1,
        .has_mode = 0,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 0,
    };
    const entry = Entry{
        .workspace_id = .{ .high = 7, .low = 8 },
        .mode = mode_tiling,
        .observed_state = initialObserved(.{ .high = 7, .low = 8 }, true, 404),
        .desired_state = initialDesired(.{ .high = 7, .low = 8 }, true, 404, mode_tiling),
        .floating_state = std.mem.zeroes(FloatingState),
        .has_floating_state = 0,
    };
    const focus = FocusSession{
        .focused_token = .{ .pid = 0, .window_id = 0 },
        .pending_managed_focus = emptyPendingFocus(),
        .has_focused_token = 0,
        .is_non_managed_focus_active = 0,
        .is_app_fullscreen_active = 0,
    };
    const hydration = PersistedHydration{
        .workspace_id = .{ .high = 9, .low = 10 },
        .monitor_id = 404,
        .target_mode = mode_floating,
        .floating_frame = .{ .x = 120, .y = 140, .width = 500, .height = 320 },
        .has_monitor_id = 1,
        .has_floating_frame = 1,
    };
    var output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&event, &entry, &focus, &monitors, monitors.len, &hydration, &output));
    try std.testing.expectEqual(@as(u8, 1), output.has_desired_state);
    try std.testing.expectEqual(mode_floating, output.desired_state.disposition);
    try std.testing.expectEqual(@as(u8, 1), output.desired_state.rescue_eligible);
    try std.testing.expectEqual(@as(u8, 1), output.has_restore_intent);
    try std.testing.expectEqual(@as(i32, 0), output.restore_intent.preferred_monitor_index);
    try std.testing.expectEqual(@as(u8, 1), output.restore_intent.has_normalized_floating_origin);
}

test "reconcile hidden state changes preserve visibility and lifecycle mapping" {
    const workspace = UUID{ .high = 11, .low = 12 };
    const event_template = Event{
        .kind = event_hidden_state_changed,
        .token = .{ .pid = 12, .window_id = 13 },
        .secondary_token = .{ .pid = 0, .window_id = 0 },
        .workspace_id = workspace,
        .secondary_workspace_id = .{ .high = 0, .low = 0 },
        .monitor_id = 41,
        .mode = mode_floating,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_hidden,
        .replacement_reason = 0,
        .has_secondary_token = 0,
        .has_workspace_id = 1,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 1,
        .has_mode = 0,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 0,
    };
    const entry = Entry{
        .workspace_id = workspace,
        .mode = mode_floating,
        .observed_state = initialObserved(workspace, true, 41),
        .desired_state = initialDesired(workspace, true, 41, mode_floating),
        .floating_state = std.mem.zeroes(FloatingState),
        .has_floating_state = 0,
    };
    const focus = FocusSession{
        .focused_token = .{ .pid = 0, .window_id = 0 },
        .pending_managed_focus = emptyPendingFocus(),
        .has_focused_token = 0,
        .is_non_managed_focus_active = 0,
        .is_app_fullscreen_active = 0,
    };

    var hidden_event = event_template;
    var output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&hidden_event, &entry, &focus, null, 0, null, &output));
    try std.testing.expectEqual(@as(u8, 1), output.has_observed_state);
    try std.testing.expectEqual(@as(u8, 0), output.observed_state.is_visible);
    try std.testing.expectEqual(lifecycle_hidden, output.lifecycle_phase);

    var offscreen_event = event_template;
    offscreen_event.hidden_state = 2;
    output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&offscreen_event, &entry, &focus, null, 0, null, &output));
    try std.testing.expectEqual(@as(u8, 0), output.observed_state.is_visible);
    try std.testing.expectEqual(lifecycle_offscreen, output.lifecycle_phase);

    var visible_event = event_template;
    visible_event.hidden_state = hidden_state_visible;
    output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&visible_event, &entry, &focus, null, 0, null, &output));
    try std.testing.expectEqual(@as(u8, 1), output.observed_state.is_visible);
    try std.testing.expectEqual(lifecycle_floating, output.lifecycle_phase);
}

test "reconcile focus lease and managed focus cancellation return stable boundary actions" {
    const workspace = UUID{ .high = 13, .low = 14 };
    const pending_token = WindowToken{ .pid = 88, .window_id = 99 };
    const pending_focus = PendingFocus{
        .token = pending_token,
        .workspace_id = workspace,
        .monitor_id = 55,
        .has_token = 1,
        .has_workspace_id = 1,
        .has_monitor_id = 1,
    };
    const focus = FocusSession{
        .focused_token = .{ .pid = 0, .window_id = 0 },
        .pending_managed_focus = pending_focus,
        .has_focused_token = 0,
        .is_non_managed_focus_active = 0,
        .is_app_fullscreen_active = 0,
    };

    var lease_event = Event{
        .kind = event_focus_lease_changed,
        .token = .{ .pid = 0, .window_id = 0 },
        .secondary_token = .{ .pid = 0, .window_id = 0 },
        .workspace_id = .{ .high = 0, .low = 0 },
        .secondary_workspace_id = .{ .high = 0, .low = 0 },
        .monitor_id = 0,
        .mode = 0,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_visible,
        .replacement_reason = 0,
        .has_secondary_token = 0,
        .has_workspace_id = 0,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 0,
        .has_mode = 0,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 1,
    };
    var output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&lease_event, null, &focus, null, 0, null, &output));
    try std.testing.expectEqual(@as(u8, 1), output.has_focus_session);
    try std.testing.expectEqual(focus_lease_action_set_from_event, output.focus_session.focus_lease_action);
    try std.testing.expectEqual(note_focus_lease_set, output.note_code);

    lease_event.has_focus_lease = 0;
    output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&lease_event, null, &focus, null, 0, null, &output));
    try std.testing.expectEqual(focus_lease_action_clear, output.focus_session.focus_lease_action);
    try std.testing.expectEqual(note_focus_lease_cleared, output.note_code);

    var cancel_event = Event{
        .kind = event_managed_focus_cancelled,
        .token = .{ .pid = 0, .window_id = 0 },
        .secondary_token = .{ .pid = 77, .window_id = 100 },
        .workspace_id = workspace,
        .secondary_workspace_id = .{ .high = 0, .low = 0 },
        .monitor_id = 0,
        .mode = 0,
        .frame = std.mem.zeroes(Rect),
        .hidden_state = hidden_state_visible,
        .replacement_reason = 0,
        .has_secondary_token = 1,
        .has_workspace_id = 1,
        .has_secondary_workspace_id = 0,
        .has_monitor_id = 0,
        .has_mode = 0,
        .has_frame = 0,
        .restore_to_floating = 0,
        .is_active = 0,
        .app_fullscreen = 0,
        .preserve_focused_token = 0,
        .has_focus_lease = 0,
    };
    output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&cancel_event, null, &focus, null, 0, null, &output));
    try std.testing.expectEqual(@as(u8, 1), output.focus_session.pending_managed_focus.has_token);

    cancel_event.secondary_token = pending_token;
    output = std.mem.zeroes(PlanOutput);
    try std.testing.expectEqual(kernel_ok, omniwm_reconcile_plan(&cancel_event, null, &focus, null, 0, null, &output));
    try std.testing.expectEqual(@as(u8, 0), output.focus_session.pending_managed_focus.has_token);
    try std.testing.expectEqual(@as(u8, 0), output.focus_session.pending_managed_focus.has_workspace_id);
}
