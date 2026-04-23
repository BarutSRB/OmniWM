// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;
const kernel_allocation_failed: i32 = 2;
const kernel_buffer_too_small: i32 = 3;
const floating_tolerance: f64 = 1.0;

const restore_event_other: u32 = 0;
const restore_event_topology_changed: u32 = 1;
const restore_event_active_space_changed: u32 = 2;
const restore_event_system_wake: u32 = 3;
const restore_event_system_sleep: u32 = 4;

const restore_note_none: u32 = 0;
const restore_note_topology: u32 = 1;
const restore_note_active_space: u32 = 2;
const restore_note_system_wake: u32 = 3;
const restore_note_system_sleep: u32 = 4;

const restore_cache_source_existing: u32 = 0;
const restore_cache_source_removed_monitor: u32 = 1;

const restore_hydration_outcome_none: u32 = 0;
const restore_hydration_outcome_matched: u32 = 1;
const restore_hydration_outcome_ambiguous: u32 = 2;
const restore_hydration_outcome_workspace_unresolved: u32 = 3;

const reconcile_window_mode_tiling: u32 = 0;
const reconcile_window_mode_floating: u32 = 1;

const RestoreSnapshot = extern struct {
    display_id: u32,
    anchor_x: f64,
    anchor_y: f64,
    frame_width: f64,
    frame_height: f64,
};

const RestoreMonitor = extern struct {
    display_id: u32,
    frame_min_x: f64,
    frame_max_y: f64,
    anchor_x: f64,
    anchor_y: f64,
    frame_width: f64,
    frame_height: f64,
};

const RestoreAssignment = extern struct {
    snapshot_index: u32,
    monitor_index: u32,
};

extern fn omniwm_restore_resolve_assignments(
    snapshots_ptr: [*c]const RestoreSnapshot,
    snapshot_count: usize,
    monitors_ptr: [*c]const RestoreMonitor,
    monitor_count: usize,
    name_penalties_ptr: [*c]const u8,
    name_penalty_count: usize,
    assignments_ptr: [*c]RestoreAssignment,
    assignment_capacity: usize,
    assignment_count_ptr: [*c]usize,
) i32;

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

const RestoreStringRef = extern struct {
    offset: usize,
    length: usize,
};

const RestoreMonitorKey = extern struct {
    display_id: u32,
    anchor_x: f64,
    anchor_y: f64,
    frame_width: f64,
    frame_height: f64,
    name: RestoreStringRef,
    has_name: u8,
};

const RestoreMonitorContext = extern struct {
    frame_min_x: f64,
    frame_max_y: f64,
    visible_frame: Rect,
    key: RestoreMonitorKey,
};

const RestoreEventInput = extern struct {
    event_kind: u32,
    sorted_monitor_ids: [*c]const u32,
    sorted_monitor_count: usize,
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
};

const RestoreEventOutput = extern struct {
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    note_code: u32,
    refresh_restore_intents: u8,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
};

const RestoreVisibleWorkspaceSnapshot = extern struct {
    workspace_id: UUID,
    monitor_key: RestoreMonitorKey,
};

const RestoreDisconnectedCacheEntry = extern struct {
    workspace_id: UUID,
    monitor_key: RestoreMonitorKey,
};

const RestoreWorkspaceMonitorFact = extern struct {
    workspace_id: UUID,
    home_monitor_id: u32,
    effective_monitor_id: u32,
    workspace_exists: u8,
    has_home_monitor_id: u8,
    has_effective_monitor_id: u8,
};

const RestoreTopologyInput = extern struct {
    previous_monitors: [*c]const RestoreMonitorContext,
    previous_monitor_count: usize,
    new_monitors: [*c]const RestoreMonitorContext,
    new_monitor_count: usize,
    visible_workspaces: [*c]const RestoreVisibleWorkspaceSnapshot,
    visible_workspace_count: usize,
    visible_workspace_name_penalties: [*c]const u8,
    visible_workspace_name_penalty_count: usize,
    disconnected_cache_entries: [*c]const RestoreDisconnectedCacheEntry,
    disconnected_cache_entry_count: usize,
    workspace_facts: [*c]const RestoreWorkspaceMonitorFact,
    workspace_fact_count: usize,
    string_bytes: [*c]const u8,
    string_byte_count: usize,
    focused_workspace_id: UUID,
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    has_focused_workspace_id: u8,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
};

const RestoreVisibleAssignment = extern struct {
    monitor_id: u32,
    workspace_id: UUID,
};

const RestoreDisconnectedCacheOutputEntry = extern struct {
    source_kind: u32,
    source_index: u32,
    workspace_id: UUID,
};

const RestoreTopologyOutput = extern struct {
    visible_assignments: [*c]RestoreVisibleAssignment,
    visible_assignment_capacity: usize,
    visible_assignment_count: usize,
    disconnected_cache_entries: [*c]RestoreDisconnectedCacheOutputEntry,
    disconnected_cache_capacity: usize,
    disconnected_cache_count: usize,
    interaction_monitor_id: u32,
    previous_interaction_monitor_id: u32,
    refresh_restore_intents: u8,
    has_interaction_monitor_id: u8,
    has_previous_interaction_monitor_id: u8,
};

const RestorePersistedKey = extern struct {
    bundle_id: RestoreStringRef,
    role: RestoreStringRef,
    subrole: RestoreStringRef,
    title: RestoreStringRef,
    window_level: i32,
    parent_window_id: u32,
    has_bundle_id: u8,
    has_role: u8,
    has_subrole: u8,
    has_title: u8,
    has_window_level: u8,
    has_parent_window_id: u8,
};

const RestorePersistedEntrySnapshot = extern struct {
    key: RestorePersistedKey,
    workspace_id: UUID,
    preferred_monitor: RestoreMonitorKey,
    floating_frame: Rect,
    normalized_floating_origin: Point,
    preferred_monitor_name_penalty_offset: usize,
    restore_to_floating: u8,
    consumed: u8,
    has_workspace_id: u8,
    has_preferred_monitor: u8,
    has_floating_frame: u8,
    has_normalized_floating_origin: u8,
};

const RestorePersistedHydrationInput = extern struct {
    metadata_key: RestorePersistedKey,
    metadata_mode: u32,
    monitors: [*c]const RestoreMonitorContext,
    monitor_count: usize,
    entries: [*c]const RestorePersistedEntrySnapshot,
    entry_count: usize,
    preferred_monitor_name_penalties: [*c]const u8,
    preferred_monitor_name_penalty_count: usize,
    string_bytes: [*c]const u8,
    string_byte_count: usize,
};

const RestorePersistedHydrationOutput = extern struct {
    outcome: u32,
    entry_index: usize,
    workspace_id: UUID,
    preferred_monitor_id: u32,
    target_mode: u32,
    floating_frame: Rect,
    has_entry_index: u8,
    has_preferred_monitor_id: u8,
    has_floating_frame: u8,
};

const RestoreFloatingRescueCandidate = extern struct {
    token: WindowToken,
    workspace_id: UUID,
    target_monitor_id: u32,
    target_monitor_visible_frame: Rect,
    current_frame: Rect,
    floating_frame: Rect,
    normalized_origin: Point,
    reference_monitor_id: u32,
    has_current_frame: u8,
    has_normalized_origin: u8,
    has_reference_monitor_id: u8,
    is_scratchpad_hidden: u8,
    is_workspace_inactive_hidden: u8,
};

const RestoreFloatingRescueOperation = extern struct {
    candidate_index: usize,
    target_frame: Rect,
};

const RestoreFloatingRescueOutput = extern struct {
    operations: [*c]RestoreFloatingRescueOperation,
    operation_capacity: usize,
    operation_count: usize,
};

const KernelError = error{
    InvalidArgument,
    BufferTooSmall,
    AllocationFailed,
};

const VisibleAssignmentRecord = struct {
    monitor_id: u32,
    workspace_id: UUID,
};

const CacheRecord = struct {
    source_kind: u32,
    source_index: usize,
    workspace_id: UUID,
    key: RestoreMonitorKey,
};

const MigrationRecord = struct {
    previous_monitor_index: usize,
    workspace_id: UUID,
};

fn statusFromError(err: KernelError) i32 {
    return switch (err) {
        error.InvalidArgument => kernel_invalid_argument,
        error.BufferTooSmall => kernel_buffer_too_small,
        error.AllocationFailed => kernel_allocation_failed,
    };
}

fn swiftMax(lhs: f64, rhs: f64) f64 {
    return if (rhs > lhs) rhs else lhs;
}

fn swiftMin(lhs: f64, rhs: f64) f64 {
    return if (rhs < lhs) rhs else lhs;
}

fn uuidEqual(lhs: UUID, rhs: UUID) bool {
    return lhs.high == rhs.high and lhs.low == rhs.low;
}

fn zeroUUID() UUID {
    return .{ .high = 0, .low = 0 };
}

fn rectApproximatelyEqual(lhs: Rect, rhs: Rect, tolerance: f64) bool {
    return @abs(lhs.x - rhs.x) < tolerance
        and @abs(lhs.y - rhs.y) < tolerance
        and @abs(lhs.width - rhs.width) < tolerance
        and @abs(lhs.height - rhs.height) < tolerance;
}

fn floatingRescueCandidateLessThan(
    lhs_index: usize,
    rhs_index: usize,
    candidates: []const RestoreFloatingRescueCandidate,
) bool {
    const lhs = candidates[lhs_index];
    const rhs = candidates[rhs_index];
    if (lhs.workspace_id.high != rhs.workspace_id.high) {
        return lhs.workspace_id.high < rhs.workspace_id.high;
    }
    if (lhs.workspace_id.low != rhs.workspace_id.low) {
        return lhs.workspace_id.low < rhs.workspace_id.low;
    }
    if (lhs.token.pid != rhs.token.pid) {
        return lhs.token.pid < rhs.token.pid;
    }
    if (lhs.token.window_id != rhs.token.window_id) {
        return lhs.token.window_id < rhs.token.window_id;
    }
    return lhs_index < rhs_index;
}

fn insertionSortCandidateIndices(
    indices: []usize,
    candidates: []const RestoreFloatingRescueCandidate,
) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const value = indices[i];
        var j = i;
        while (j > 0 and floatingRescueCandidateLessThan(value, indices[j - 1], candidates)) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = value;
    }
}

fn floatingOrigin(normalized_origin: Point, window_size: Rect, visible_frame: Rect) Point {
    const available_width = swiftMax(0, visible_frame.width - window_size.width);
    const available_height = swiftMax(0, visible_frame.height - window_size.height);
    return .{
        .x = visible_frame.x + clamp01(normalized_origin.x) * available_width,
        .y = visible_frame.y + clamp01(normalized_origin.y) * available_height,
    };
}

fn clamp01(value: f64) f64 {
    return swiftMin(1, swiftMax(0, value));
}

fn clampedFloatingFrame(frame: Rect, visible_frame: Rect) Rect {
    const max_x = visible_frame.x + visible_frame.width - frame.width;
    const max_y = visible_frame.y + visible_frame.height - frame.height;
    const clamped_x = swiftMin(
        swiftMax(frame.x, visible_frame.x),
        if (max_x >= visible_frame.x) max_x else visible_frame.x
    );
    const clamped_y = swiftMin(
        swiftMax(frame.y, visible_frame.y),
        if (max_y >= visible_frame.y) max_y else visible_frame.y
    );
    return .{
        .x = clamped_x,
        .y = clamped_y,
        .width = frame.width,
        .height = frame.height,
    };
}

fn resolveFloatingFrame(
    floating_frame: Rect,
    normalized_origin: ?Point,
    reference_monitor_id: ?u32,
    target_monitor_id: u32,
    visible_frame: Rect,
) Rect {
    if (normalized_origin) |origin| {
        if (reference_monitor_id == null or reference_monitor_id.? != target_monitor_id) {
            const resolved_origin = floatingOrigin(origin, floating_frame, visible_frame);
            return clampedFloatingFrame(.{
                .x = resolved_origin.x,
                .y = resolved_origin.y,
                .width = floating_frame.width,
                .height = floating_frame.height,
            }, visible_frame);
        }
    }

    return clampedFloatingFrame(floating_frame, visible_frame);
}

fn bytesSlice(ptr: [*c]const u8, count: usize) KernelError![]const u8 {
    if (count == 0) {
        return &[_]u8{};
    }
    if (ptr == null) {
        return error.InvalidArgument;
    }
    return @as([*]const u8, @ptrCast(ptr))[0..count];
}

fn sliceFromOptionalPtr(comptime T: type, ptr: [*c]const T, count: usize) KernelError![]const T {
    if (count == 0) {
        return &[_]T{};
    }
    if (ptr == null) {
        return error.InvalidArgument;
    }
    return @as([*]const T, @ptrCast(ptr))[0..count];
}

fn sliceFromOptionalMutablePtr(comptime T: type, ptr: [*c]T, count: usize) KernelError![]T {
    if (count == 0) {
        return &[_]T{};
    }
    if (ptr == null) {
        return error.InvalidArgument;
    }
    return @as([*]T, @ptrCast(ptr))[0..count];
}

fn validateOutputBuffer(comptime T: type, ptr: [*c]T, capacity: usize) KernelError!void {
    if (capacity > 0 and ptr == null) {
        return error.InvalidArgument;
    }
}

fn stringForRef(
    bytes: []const u8,
    ref: RestoreStringRef,
    has_value: bool,
) KernelError!?[]const u8 {
    if (!has_value) {
        return null;
    }
    if (ref.offset > bytes.len or ref.length > bytes.len - ref.offset) {
        return error.InvalidArgument;
    }
    return bytes[ref.offset .. ref.offset + ref.length];
}

fn optionalBytesEqual(
    bytes: []const u8,
    lhs_ref: RestoreStringRef,
    lhs_has: bool,
    rhs_ref: RestoreStringRef,
    rhs_has: bool,
) KernelError!bool {
    if (lhs_has != rhs_has) {
        return false;
    }
    if (!lhs_has) {
        return true;
    }

    const lhs = (try stringForRef(bytes, lhs_ref, lhs_has)).?;
    const rhs = (try stringForRef(bytes, rhs_ref, rhs_has)).?;
    return std.mem.eql(u8, lhs, rhs);
}

fn monitorKeyEqual(bytes: []const u8, lhs: RestoreMonitorKey, rhs: RestoreMonitorKey) KernelError!bool {
    if (lhs.display_id != rhs.display_id
        or lhs.anchor_x != rhs.anchor_x
        or lhs.anchor_y != rhs.anchor_y
        or lhs.frame_width != rhs.frame_width
        or lhs.frame_height != rhs.frame_height)
    {
        return false;
    }

    return try optionalBytesEqual(
        bytes,
        lhs.name,
        lhs.has_name != 0,
        rhs.name,
        rhs.has_name != 0,
    );
}

fn monitorKeyLessThan(lhs: RestoreMonitorKey, rhs: RestoreMonitorKey) bool {
    if (lhs.anchor_x != rhs.anchor_x) {
        return lhs.anchor_x < rhs.anchor_x;
    }
    if (lhs.anchor_y != rhs.anchor_y) {
        return lhs.anchor_y > rhs.anchor_y;
    }
    return lhs.display_id < rhs.display_id;
}

fn monitorContextLessThan(lhs: RestoreMonitorContext, rhs: RestoreMonitorContext) bool {
    if (lhs.frame_min_x != rhs.frame_min_x) {
        return lhs.frame_min_x < rhs.frame_min_x;
    }
    if (lhs.frame_max_y != rhs.frame_max_y) {
        return lhs.frame_max_y > rhs.frame_max_y;
    }
    return lhs.key.display_id < rhs.key.display_id;
}

fn insertionSortContexts(contexts: []RestoreMonitorContext) void {
    var i: usize = 1;
    while (i < contexts.len) : (i += 1) {
        const value = contexts[i];
        var j = i;
        while (j > 0 and monitorContextLessThan(value, contexts[j - 1])) : (j -= 1) {
            contexts[j] = contexts[j - 1];
        }
        contexts[j] = value;
    }
}

fn insertionSortCache(cache: []CacheRecord) void {
    var i: usize = 1;
    while (i < cache.len) : (i += 1) {
        const value = cache[i];
        var j = i;
        while (j > 0 and monitorKeyLessThan(value.key, cache[j - 1].key)) : (j -= 1) {
            cache[j] = cache[j - 1];
        }
        cache[j] = value;
    }
}

fn insertionSortMigrations(migrations: []MigrationRecord, previous_monitors: []const RestoreMonitorContext) void {
    var i: usize = 1;
    while (i < migrations.len) : (i += 1) {
        const value = migrations[i];
        var j = i;
        while (j > 0 and monitorContextLessThan(
            previous_monitors[value.previous_monitor_index],
            previous_monitors[migrations[j - 1].previous_monitor_index],
        )) : (j -= 1) {
            migrations[j] = migrations[j - 1];
        }
        migrations[j] = value;
    }
}

fn workspaceFactFor(
    workspace_id: UUID,
    facts: []const RestoreWorkspaceMonitorFact,
) ?RestoreWorkspaceMonitorFact {
    for (facts) |fact| {
        if (uuidEqual(fact.workspace_id, workspace_id)) {
            return fact;
        }
    }
    return null;
}

fn workspaceExists(workspace_id: UUID, facts: []const RestoreWorkspaceMonitorFact) bool {
    return if (workspaceFactFor(workspace_id, facts)) |fact| fact.workspace_exists != 0 else false;
}

fn homeMonitorId(workspace_id: UUID, facts: []const RestoreWorkspaceMonitorFact) ?u32 {
    if (workspaceFactFor(workspace_id, facts)) |fact| {
        if (fact.workspace_exists != 0 and fact.has_home_monitor_id != 0) {
            return fact.home_monitor_id;
        }
    }
    return null;
}

fn effectiveMonitorId(workspace_id: UUID, facts: []const RestoreWorkspaceMonitorFact) ?u32 {
    if (workspaceFactFor(workspace_id, facts)) |fact| {
        if (fact.workspace_exists != 0 and fact.has_effective_monitor_id != 0) {
            return fact.effective_monitor_id;
        }
    }
    return null;
}

fn validMonitorId(monitor_id: u32, sorted_monitor_ids: []const u32) bool {
    for (sorted_monitor_ids) |candidate| {
        if (candidate == monitor_id) {
            return true;
        }
    }
    return false;
}

fn visibleAssignmentIndexForMonitor(
    assignments: []const VisibleAssignmentRecord,
    monitor_id: u32,
) ?usize {
    for (assignments, 0..) |assignment, index| {
        if (assignment.monitor_id == monitor_id) {
            return index;
        }
    }
    return null;
}

fn visibleAssignmentMonitorForWorkspace(
    assignments: []const VisibleAssignmentRecord,
    workspace_id: UUID,
) ?u32 {
    for (assignments) |assignment| {
        if (uuidEqual(assignment.workspace_id, workspace_id)) {
            return assignment.monitor_id;
        }
    }
    return null;
}

fn upsertVisibleAssignment(
    allocator: std.mem.Allocator,
    assignments: *std.ArrayListUnmanaged(VisibleAssignmentRecord),
    monitor_id: u32,
    workspace_id: UUID,
) KernelError!void {
    if (visibleAssignmentIndexForMonitor(assignments.items, monitor_id)) |index| {
        assignments.items[index].workspace_id = workspace_id;
        return;
    }
    assignments.append(allocator, .{
        .monitor_id = monitor_id,
        .workspace_id = workspace_id,
    }) catch return error.AllocationFailed;
}

fn cacheIndexForKey(
    bytes: []const u8,
    cache: []const CacheRecord,
    key: RestoreMonitorKey,
) KernelError!?usize {
    for (cache, 0..) |entry, index| {
        if (try monitorKeyEqual(bytes, entry.key, key)) {
            return index;
        }
    }
    return null;
}

fn visibleWorkspaceForMonitor(
    monitor_id: u32,
    visible_workspaces: []const RestoreVisibleWorkspaceSnapshot,
) ?UUID {
    for (visible_workspaces) |visible| {
        if (visible.monitor_key.display_id == monitor_id) {
            return visible.workspace_id;
        }
    }
    return null;
}

fn geometryDelta(fingerprint: RestoreMonitorKey, monitor: RestoreMonitorContext) f64 {
    const dx = fingerprint.anchor_x - monitor.key.anchor_x;
    const dy = fingerprint.anchor_y - monitor.key.anchor_y;
    return (dx * dx)
        + (dy * dy)
        + @abs(fingerprint.frame_width - monitor.key.frame_width)
        + @abs(fingerprint.frame_height - monitor.key.frame_height);
}

fn preferredMonitorIndex(
    bytes: []const u8,
    monitors: []const RestoreMonitorContext,
    penalties: []const u8,
    entry: RestorePersistedEntrySnapshot,
) KernelError!?usize {
    if (monitors.len == 0) {
        return null;
    }

    if (entry.has_preferred_monitor == 0) {
        return 0;
    }

    for (monitors, 0..) |monitor, index| {
        if (try monitorKeyEqual(bytes, monitor.key, entry.preferred_monitor)) {
            return index;
        }
    }

    for (monitors, 0..) |monitor, index| {
        if (monitor.key.display_id == entry.preferred_monitor.display_id) {
            return index;
        }
    }

    if (entry.preferred_monitor_name_penalty_offset > penalties.len
        or monitors.len > penalties.len - entry.preferred_monitor_name_penalty_offset)
    {
        return error.InvalidArgument;
    }

    var best_index: usize = 0;
    var best_penalty = penalties[entry.preferred_monitor_name_penalty_offset];
    var best_delta = geometryDelta(entry.preferred_monitor, monitors[0]);
    var index: usize = 1;
    while (index < monitors.len) : (index += 1) {
        const penalty = penalties[entry.preferred_monitor_name_penalty_offset + index];
        const delta = geometryDelta(entry.preferred_monitor, monitors[index]);
        const lhs = monitors[index];
        const rhs = monitors[best_index];
        if (penalty < best_penalty
            or (penalty == best_penalty and (delta < best_delta
            or (delta == best_delta and monitorContextLessThan(lhs, rhs)))))
        {
            best_index = index;
            best_penalty = penalty;
            best_delta = delta;
        }
    }

    return best_index;
}

fn persistedKeyMatches(
    bytes: []const u8,
    metadata: RestorePersistedKey,
    entry: RestorePersistedKey,
) KernelError!bool {
    if (metadata.has_bundle_id == 0 or entry.has_bundle_id == 0) {
        return false;
    }

    if (!(try optionalBytesEqual(bytes, metadata.bundle_id, metadata.has_bundle_id != 0, entry.bundle_id, entry.has_bundle_id != 0))
        or !(try optionalBytesEqual(bytes, metadata.role, metadata.has_role != 0, entry.role, entry.has_role != 0))
        or !(try optionalBytesEqual(bytes, metadata.subrole, metadata.has_subrole != 0, entry.subrole, entry.has_subrole != 0)))
    {
        return false;
    }

    if (metadata.has_window_level != entry.has_window_level) {
        return false;
    }
    if (metadata.has_window_level != 0 and metadata.window_level != entry.window_level) {
        return false;
    }

    if (metadata.has_parent_window_id != entry.has_parent_window_id) {
        return false;
    }
    if (metadata.has_parent_window_id != 0 and metadata.parent_window_id != entry.parent_window_id) {
        return false;
    }

    if (entry.has_title == 0) {
        return true;
    }

    return try optionalBytesEqual(
        bytes,
        metadata.title,
        metadata.has_title != 0,
        entry.title,
        entry.has_title != 0,
    );
}

pub export fn omniwm_restore_plan_event(
    input_ptr: ?*const RestoreEventInput,
    output_ptr: ?*RestoreEventOutput,
) i32 {
    const input = input_ptr orelse return kernel_invalid_argument;
    const output = output_ptr orelse return kernel_invalid_argument;
    output.* = .{
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .note_code = 0,
        .refresh_restore_intents = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
    };

    const sorted_monitor_ids = sliceFromOptionalPtr(
        u32,
        input.sorted_monitor_ids,
        input.sorted_monitor_count,
    ) catch return kernel_invalid_argument;

    switch (input.event_kind) {
        restore_event_other,
        restore_event_topology_changed,
        restore_event_active_space_changed,
        restore_event_system_wake,
        restore_event_system_sleep,
        => {},
        else => return kernel_invalid_argument,
    }

    if (input.has_interaction_monitor_id != 0
        and validMonitorId(input.interaction_monitor_id, sorted_monitor_ids))
    {
        output.interaction_monitor_id = input.interaction_monitor_id;
        output.has_interaction_monitor_id = 1;
    } else if (sorted_monitor_ids.len > 0) {
        output.interaction_monitor_id = sorted_monitor_ids[0];
        output.has_interaction_monitor_id = 1;
    }

    if (input.has_previous_interaction_monitor_id != 0
        and validMonitorId(input.previous_interaction_monitor_id, sorted_monitor_ids))
    {
        output.previous_interaction_monitor_id = input.previous_interaction_monitor_id;
        output.has_previous_interaction_monitor_id = 1;
    }

    switch (input.event_kind) {
    restore_event_topology_changed => {
        output.refresh_restore_intents = 1;
        output.note_code = restore_note_topology;
    },
    restore_event_active_space_changed => {
        output.refresh_restore_intents = 1;
        output.note_code = restore_note_active_space;
    },
    restore_event_system_wake => {
        output.refresh_restore_intents = 1;
        output.note_code = restore_note_system_wake;
    },
    restore_event_system_sleep => {
        output.note_code = restore_note_system_sleep;
    },
    else => {
        output.note_code = restore_note_none;
    },
    }

    return kernel_ok;
}

pub export fn omniwm_restore_plan_topology(
    input_ptr: ?*const RestoreTopologyInput,
    output_ptr: ?*RestoreTopologyOutput,
) i32 {
    const input = input_ptr orelse return kernel_invalid_argument;
    const output = output_ptr orelse return kernel_invalid_argument;
    output.* = .{
        .visible_assignments = output.visible_assignments,
        .visible_assignment_capacity = output.visible_assignment_capacity,
        .visible_assignment_count = 0,
        .disconnected_cache_entries = output.disconnected_cache_entries,
        .disconnected_cache_capacity = output.disconnected_cache_capacity,
        .disconnected_cache_count = 0,
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .refresh_restore_intents = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
    };

    planTopologyInternal(input, output) catch |err| return statusFromError(err);
    return kernel_ok;
}

fn planTopologyInternal(
    input: *const RestoreTopologyInput,
    output: *RestoreTopologyOutput,
) KernelError!void {
    const allocator = std.heap.page_allocator;
    const previous_monitors = try sliceFromOptionalPtr(
        RestoreMonitorContext,
        input.previous_monitors,
        input.previous_monitor_count,
    );
    const new_monitors = try sliceFromOptionalPtr(
        RestoreMonitorContext,
        input.new_monitors,
        input.new_monitor_count,
    );
    const visible_workspaces = try sliceFromOptionalPtr(
        RestoreVisibleWorkspaceSnapshot,
        input.visible_workspaces,
        input.visible_workspace_count,
    );
    const cache_entries = try sliceFromOptionalPtr(
        RestoreDisconnectedCacheEntry,
        input.disconnected_cache_entries,
        input.disconnected_cache_entry_count,
    );
    const workspace_facts = try sliceFromOptionalPtr(
        RestoreWorkspaceMonitorFact,
        input.workspace_facts,
        input.workspace_fact_count,
    );
    const string_bytes = try bytesSlice(input.string_bytes, input.string_byte_count);

    if (visible_workspaces.len > 0 and new_monitors.len > 0) {
        if (visible_workspaces.len > std.math.maxInt(usize) / new_monitors.len) {
            return error.InvalidArgument;
        }
        if (input.visible_workspace_name_penalty_count != visible_workspaces.len * new_monitors.len) {
            return error.InvalidArgument;
        }
    } else if (input.visible_workspace_name_penalty_count != 0) {
        return error.InvalidArgument;
    }

    const visible_penalties = try bytesSlice(
        input.visible_workspace_name_penalties,
        input.visible_workspace_name_penalty_count,
    );

    try validateOutputBuffer(
        RestoreVisibleAssignment,
        output.visible_assignments,
        output.visible_assignment_capacity,
    );
    try validateOutputBuffer(
        RestoreDisconnectedCacheOutputEntry,
        output.disconnected_cache_entries,
        output.disconnected_cache_capacity,
    );

    var visible_assignments = std.ArrayListUnmanaged(VisibleAssignmentRecord).empty;
    defer visible_assignments.deinit(allocator);

    var filtered_snapshots = std.ArrayListUnmanaged(RestoreSnapshot).empty;
    defer filtered_snapshots.deinit(allocator);
    var filtered_workspace_ids = std.ArrayListUnmanaged(UUID).empty;
    defer filtered_workspace_ids.deinit(allocator);
    var filtered_penalties = std.ArrayListUnmanaged(u8).empty;
    defer filtered_penalties.deinit(allocator);
    var seen_workspace_ids = std.ArrayListUnmanaged(UUID).empty;
    defer seen_workspace_ids.deinit(allocator);

    for (visible_workspaces, 0..) |visible, visible_index| {
        if (!workspaceExists(visible.workspace_id, workspace_facts)) {
            continue;
        }

        var already_seen = false;
        for (seen_workspace_ids.items) |seen| {
            if (uuidEqual(seen, visible.workspace_id)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) {
            continue;
        }

        seen_workspace_ids.append(allocator, visible.workspace_id) catch return error.AllocationFailed;
        filtered_snapshots.append(allocator, .{
            .display_id = visible.monitor_key.display_id,
            .anchor_x = visible.monitor_key.anchor_x,
            .anchor_y = visible.monitor_key.anchor_y,
            .frame_width = visible.monitor_key.frame_width,
            .frame_height = visible.monitor_key.frame_height,
        }) catch return error.AllocationFailed;
        filtered_workspace_ids.append(allocator, visible.workspace_id) catch return error.AllocationFailed;

        var new_monitor_index: usize = 0;
        while (new_monitor_index < new_monitors.len) : (new_monitor_index += 1) {
            filtered_penalties.append(
                allocator,
                visible_penalties[(visible_index * new_monitors.len) + new_monitor_index],
            ) catch return error.AllocationFailed;
        }
    }

    if (filtered_snapshots.items.len > 0 and new_monitors.len > 0) {
        var raw_monitors = std.ArrayListUnmanaged(RestoreMonitor).empty;
        defer raw_monitors.deinit(allocator);
        raw_monitors.ensureTotalCapacity(allocator, new_monitors.len) catch {
            return error.AllocationFailed;
        };
        for (new_monitors) |monitor| {
            raw_monitors.appendAssumeCapacity(.{
                .display_id = monitor.key.display_id,
                .frame_min_x = monitor.frame_min_x,
                .frame_max_y = monitor.frame_max_y,
                .anchor_x = monitor.key.anchor_x,
                .anchor_y = monitor.key.anchor_y,
                .frame_width = monitor.key.frame_width,
                .frame_height = monitor.key.frame_height,
            });
        }

        var raw_assignments = allocator.alloc(
            RestoreAssignment,
            @min(filtered_snapshots.items.len, raw_monitors.items.len),
        ) catch return error.AllocationFailed;
        defer allocator.free(raw_assignments);
        var raw_assignment_count: usize = 0;

        const assignment_status = omniwm_restore_resolve_assignments(
            filtered_snapshots.items.ptr,
            filtered_snapshots.items.len,
            raw_monitors.items.ptr,
            raw_monitors.items.len,
            filtered_penalties.items.ptr,
            filtered_penalties.items.len,
            raw_assignments.ptr,
            raw_assignments.len,
            &raw_assignment_count,
        );

        switch (assignment_status) {
        kernel_ok => {},
        kernel_invalid_argument => return error.InvalidArgument,
        kernel_allocation_failed => return error.AllocationFailed,
        else => return error.InvalidArgument,
        }

        for (raw_assignments[0..raw_assignment_count]) |assignment| {
            const workspace_id = filtered_workspace_ids.items[assignment.snapshot_index];
            const monitor_id = new_monitors[assignment.monitor_index].key.display_id;
            if (effectiveMonitorId(workspace_id, workspace_facts)) |effective_monitor_id| {
                if (effective_monitor_id == monitor_id) {
                    try upsertVisibleAssignment(
                        allocator,
                        &visible_assignments,
                        monitor_id,
                        workspace_id,
                    );
                }
            }
        }
    }

    var disconnected_cache = std.ArrayListUnmanaged(CacheRecord).empty;
    defer disconnected_cache.deinit(allocator);
    disconnected_cache.ensureTotalCapacity(allocator, cache_entries.len) catch return error.AllocationFailed;
    for (cache_entries, 0..) |entry, index| {
        disconnected_cache.appendAssumeCapacity(.{
            .source_kind = restore_cache_source_existing,
            .source_index = index,
            .workspace_id = entry.workspace_id,
            .key = entry.monitor_key,
        });
    }

    var migrations = std.ArrayListUnmanaged(MigrationRecord).empty;
    defer migrations.deinit(allocator);
    for (previous_monitors, 0..) |previous_monitor, previous_index| {
        var survives = false;
        for (new_monitors) |new_monitor| {
            if (new_monitor.key.display_id == previous_monitor.key.display_id) {
                survives = true;
                break;
            }
        }
        if (survives) {
            continue;
        }

        const workspace_id = visibleWorkspaceForMonitor(
            previous_monitor.key.display_id,
            visible_workspaces,
        ) orelse continue;
        if (!workspaceExists(workspace_id, workspace_facts)) {
            continue;
        }

        if (try cacheIndexForKey(string_bytes, disconnected_cache.items, previous_monitor.key)) |cache_index| {
            disconnected_cache.items[cache_index] = .{
                .source_kind = restore_cache_source_removed_monitor,
                .source_index = previous_index,
                .workspace_id = workspace_id,
                .key = previous_monitor.key,
            };
        } else {
            disconnected_cache.append(allocator, .{
                .source_kind = restore_cache_source_removed_monitor,
                .source_index = previous_index,
                .workspace_id = workspace_id,
                .key = previous_monitor.key,
            }) catch return error.AllocationFailed;
        }

        migrations.append(allocator, .{
            .previous_monitor_index = previous_index,
            .workspace_id = workspace_id,
        }) catch return error.AllocationFailed;
    }

    insertionSortMigrations(migrations.items, previous_monitors);

    var has_new_monitor = false;
    for (new_monitors) |new_monitor| {
        var existed = false;
        for (previous_monitors) |previous_monitor| {
            if (previous_monitor.key.display_id == new_monitor.key.display_id) {
                existed = true;
                break;
            }
        }
        if (!existed) {
            has_new_monitor = true;
            break;
        }
    }

    if (has_new_monitor and disconnected_cache.items.len > 0) {
        insertionSortCache(disconnected_cache.items);
        for (disconnected_cache.items) |entry| {
            if (!workspaceExists(entry.workspace_id, workspace_facts)) {
                continue;
            }
            if (homeMonitorId(entry.workspace_id, workspace_facts)) |home_monitor_id| {
                if (visibleAssignmentIndexForMonitor(visible_assignments.items, home_monitor_id) == null) {
                    try upsertVisibleAssignment(
                        allocator,
                        &visible_assignments,
                        home_monitor_id,
                        entry.workspace_id,
                    );
                }
            }
        }
    }

    var winner_by_fallback = std.AutoHashMap(u32, UUID).init(allocator);
    defer winner_by_fallback.deinit();
    for (migrations.items) |migration| {
        if (!workspaceExists(migration.workspace_id, workspace_facts)) {
            continue;
        }
        if (effectiveMonitorId(migration.workspace_id, workspace_facts)) |fallback_monitor_id| {
            if (!winner_by_fallback.contains(fallback_monitor_id)) {
                winner_by_fallback.put(fallback_monitor_id, migration.workspace_id) catch {
                    return error.AllocationFailed;
                };
            }
        }
    }

    const sorted_new_monitors = allocator.dupe(RestoreMonitorContext, new_monitors) catch {
        return error.AllocationFailed;
    };
    defer allocator.free(sorted_new_monitors);
    insertionSortContexts(sorted_new_monitors);
    for (sorted_new_monitors) |monitor| {
        if (winner_by_fallback.get(monitor.key.display_id)) |workspace_id| {
            try upsertVisibleAssignment(
                allocator,
                &visible_assignments,
                monitor.key.display_id,
                workspace_id,
            );
        }
    }

    var filtered_cache = std.ArrayListUnmanaged(CacheRecord).empty;
    defer filtered_cache.deinit(allocator);
    for (disconnected_cache.items) |entry| {
        if (!workspaceExists(entry.workspace_id, workspace_facts)) {
            continue;
        }
        if (homeMonitorId(entry.workspace_id, workspace_facts)) |home_monitor_id| {
            if (visibleAssignmentMonitorForWorkspace(visible_assignments.items, entry.workspace_id)) |assigned_monitor_id| {
                if (assigned_monitor_id == home_monitor_id) {
                    continue;
                }
            }
        }
        filtered_cache.append(allocator, entry) catch return error.AllocationFailed;
    }

    output.visible_assignment_count = visible_assignments.items.len;
    output.disconnected_cache_count = filtered_cache.items.len;
    if (output.visible_assignment_capacity < visible_assignments.items.len
        or output.disconnected_cache_capacity < filtered_cache.items.len)
    {
        return error.BufferTooSmall;
    }

    var interaction_monitor_id: ?u32 = null;
    if (input.has_interaction_monitor_id != 0) {
        for (sorted_new_monitors) |monitor| {
            if (monitor.key.display_id == input.interaction_monitor_id) {
                interaction_monitor_id = input.interaction_monitor_id;
                break;
            }
        }
    }

    if (interaction_monitor_id == null) {
        if (input.has_focused_workspace_id != 0) {
            interaction_monitor_id = visibleAssignmentMonitorForWorkspace(
                visible_assignments.items,
                input.focused_workspace_id,
            ) orelse if (sorted_new_monitors.len > 0) sorted_new_monitors[0].key.display_id else null;
        } else if (sorted_new_monitors.len > 0) {
            interaction_monitor_id = sorted_new_monitors[0].key.display_id;
        }
    }

    var previous_interaction_monitor_id: ?u32 = null;
    if (input.has_previous_interaction_monitor_id != 0) {
        for (sorted_new_monitors) |monitor| {
            if (monitor.key.display_id == input.previous_interaction_monitor_id) {
                previous_interaction_monitor_id = input.previous_interaction_monitor_id;
                break;
            }
        }
    }

    if (interaction_monitor_id) |resolved| {
        output.interaction_monitor_id = resolved;
        output.has_interaction_monitor_id = 1;
    }
    if (previous_interaction_monitor_id) |resolved| {
        output.previous_interaction_monitor_id = resolved;
        output.has_previous_interaction_monitor_id = 1;
    }
    output.refresh_restore_intents = 1;

    if (visible_assignments.items.len > 0) {
        const output_assignments = try sliceFromOptionalMutablePtr(
            RestoreVisibleAssignment,
            output.visible_assignments,
            output.visible_assignment_capacity,
        );
        var written: usize = 0;
        for (sorted_new_monitors) |monitor| {
            if (visibleAssignmentIndexForMonitor(visible_assignments.items, monitor.key.display_id)) |assignment_index| {
                output_assignments[written] = .{
                    .monitor_id = monitor.key.display_id,
                    .workspace_id = visible_assignments.items[assignment_index].workspace_id,
                };
                written += 1;
            }
        }
    }

    if (filtered_cache.items.len > 0) {
        const output_cache = try sliceFromOptionalMutablePtr(
            RestoreDisconnectedCacheOutputEntry,
            output.disconnected_cache_entries,
            output.disconnected_cache_capacity,
        );
        for (filtered_cache.items, 0..) |entry, index| {
            output_cache[index] = .{
                .source_kind = entry.source_kind,
                .source_index = @intCast(entry.source_index),
                .workspace_id = entry.workspace_id,
            };
        }
    }
}

pub export fn omniwm_restore_plan_persisted_hydration(
    input_ptr: ?*const RestorePersistedHydrationInput,
    output_ptr: ?*RestorePersistedHydrationOutput,
) i32 {
    const input = input_ptr orelse return kernel_invalid_argument;
    const output = output_ptr orelse return kernel_invalid_argument;
    output.* = .{
        .outcome = 0,
        .entry_index = 0,
        .workspace_id = zeroUUID(),
        .preferred_monitor_id = 0,
        .target_mode = 0,
        .floating_frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .has_entry_index = 0,
        .has_preferred_monitor_id = 0,
        .has_floating_frame = 0,
    };

    planPersistedHydrationInternal(input, output) catch |err| return statusFromError(err);
    return kernel_ok;
}

fn planPersistedHydrationInternal(
    input: *const RestorePersistedHydrationInput,
    output: *RestorePersistedHydrationOutput,
) KernelError!void {
    const monitors = try sliceFromOptionalPtr(
        RestoreMonitorContext,
        input.monitors,
        input.monitor_count,
    );
    const entries = try sliceFromOptionalPtr(
        RestorePersistedEntrySnapshot,
        input.entries,
        input.entry_count,
    );
    const penalties = try bytesSlice(
        input.preferred_monitor_name_penalties,
        input.preferred_monitor_name_penalty_count,
    );
    const string_bytes = try bytesSlice(input.string_bytes, input.string_byte_count);

    switch (input.metadata_mode) {
    reconcile_window_mode_tiling,
    reconcile_window_mode_floating,
    => {},
    else => return error.InvalidArgument,
    }

    var matched_index: ?usize = null;
    var match_count: usize = 0;
    for (entries, 0..) |entry, index| {
        if (entry.consumed != 0) {
            continue;
        }
        if (try persistedKeyMatches(string_bytes, input.metadata_key, entry.key)) {
            matched_index = index;
            match_count += 1;
        }
    }

    if (match_count == 0) {
        output.outcome = restore_hydration_outcome_none;
        return;
    }
    if (match_count > 1) {
        output.outcome = restore_hydration_outcome_ambiguous;
        return;
    }

    const entry_index = matched_index.?;
    const entry = entries[entry_index];
    if (entry.has_workspace_id == 0) {
        output.outcome = restore_hydration_outcome_workspace_unresolved;
        return;
    }

    output.outcome = restore_hydration_outcome_matched;
    output.entry_index = entry_index;
    output.workspace_id = entry.workspace_id;
    output.has_entry_index = 1;

    const preferred_index = try preferredMonitorIndex(string_bytes, monitors, penalties, entry);
    if (preferred_index) |index| {
        output.preferred_monitor_id = monitors[index].key.display_id;
        output.has_preferred_monitor_id = 1;
    }

    output.target_mode = if (entry.restore_to_floating != 0)
        reconcile_window_mode_floating
    else
        input.metadata_mode;

    if (entry.restore_to_floating == 0 or entry.has_floating_frame == 0) {
        return;
    }

    const selected_monitor = if (preferred_index) |index| &monitors[index] else null;
    if (selected_monitor) |monitor| {
        const should_use_normalized_origin = entry.has_normalized_floating_origin != 0
            and (entry.has_preferred_monitor == 0
            or !(try monitorKeyEqual(string_bytes, entry.preferred_monitor, monitor.key)));
        output.floating_frame = if (should_use_normalized_origin)
            resolveFloatingFrame(
                entry.floating_frame,
                entry.normalized_floating_origin,
                null,
                monitor.key.display_id,
                monitor.visible_frame,
            )
        else
            clampedFloatingFrame(entry.floating_frame, monitor.visible_frame);
        output.has_floating_frame = 1;
    } else {
        output.floating_frame = entry.floating_frame;
        output.has_floating_frame = 1;
    }
}

pub export fn omniwm_restore_plan_floating_rescue(
    candidates_ptr: [*c]const RestoreFloatingRescueCandidate,
    candidate_count: usize,
    output_ptr: ?*RestoreFloatingRescueOutput,
) i32 {
    const output = output_ptr orelse return kernel_invalid_argument;
    output.* = .{
        .operations = output.operations,
        .operation_capacity = output.operation_capacity,
        .operation_count = 0,
    };

    planFloatingRescueInternal(
        candidates_ptr,
        candidate_count,
        output,
    ) catch |err| return statusFromError(err);
    return kernel_ok;
}

fn planFloatingRescueInternal(
    candidates_ptr: [*c]const RestoreFloatingRescueCandidate,
    candidate_count: usize,
    output: *RestoreFloatingRescueOutput,
) KernelError!void {
    const allocator = std.heap.page_allocator;
    const candidates = try sliceFromOptionalPtr(
        RestoreFloatingRescueCandidate,
        candidates_ptr,
        candidate_count,
    );
    try validateOutputBuffer(
        RestoreFloatingRescueOperation,
        output.operations,
        output.operation_capacity,
    );

    var rescue_count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.is_scratchpad_hidden != 0 or candidate.is_workspace_inactive_hidden != 0) {
            continue;
        }

        const resolved_target = resolveFloatingFrame(
            candidate.floating_frame,
            if (candidate.has_normalized_origin != 0) candidate.normalized_origin else null,
            if (candidate.has_reference_monitor_id != 0) candidate.reference_monitor_id else null,
            candidate.target_monitor_id,
            candidate.target_monitor_visible_frame,
        );

        const needs_rescue = if (candidate.has_current_frame != 0)
            !rectApproximatelyEqual(candidate.current_frame, resolved_target, floating_tolerance)
        else
            true;
        if (needs_rescue) {
            rescue_count += 1;
        }
    }

    output.operation_count = rescue_count;
    if (output.operation_capacity < rescue_count) {
        return error.BufferTooSmall;
    }

    if (rescue_count == 0) {
        return;
    }

    var rescue_indices = allocator.alloc(usize, rescue_count) catch return error.AllocationFailed;
    defer allocator.free(rescue_indices);

    var rescue_index: usize = 0;
    for (candidates, 0..) |candidate, candidate_index| {
        if (candidate.is_scratchpad_hidden != 0 or candidate.is_workspace_inactive_hidden != 0) {
            continue;
        }

        const resolved_target = resolveFloatingFrame(
            candidate.floating_frame,
            if (candidate.has_normalized_origin != 0) candidate.normalized_origin else null,
            if (candidate.has_reference_monitor_id != 0) candidate.reference_monitor_id else null,
            candidate.target_monitor_id,
            candidate.target_monitor_visible_frame,
        );

        const needs_rescue = if (candidate.has_current_frame != 0)
            !rectApproximatelyEqual(candidate.current_frame, resolved_target, floating_tolerance)
        else
            true;
        if (!needs_rescue) {
            continue;
        }

        rescue_indices[rescue_index] = candidate_index;
        rescue_index += 1;
    }

    insertionSortCandidateIndices(rescue_indices, candidates);

    const operations = try sliceFromOptionalMutablePtr(
        RestoreFloatingRescueOperation,
        output.operations,
        output.operation_capacity,
    );
    var write_index: usize = 0;
    for (rescue_indices) |candidate_index| {
        const candidate = candidates[candidate_index];
        const resolved_target = resolveFloatingFrame(
            candidate.floating_frame,
            if (candidate.has_normalized_origin != 0) candidate.normalized_origin else null,
            if (candidate.has_reference_monitor_id != 0) candidate.reference_monitor_id else null,
            candidate.target_monitor_id,
            candidate.target_monitor_visible_frame,
        );

        operations[write_index] = .{
            .candidate_index = candidate_index,
            .target_frame = resolved_target,
        };
        write_index += 1;
    }
}

test "restore event planner keeps sleep as note-only and refreshes on wake" {
    const monitor_ids = [_]u32{ 10, 20 };
    var output = RestoreEventOutput{
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .note_code = 0,
        .refresh_restore_intents = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
    };
    var input = RestoreEventInput{
        .event_kind = restore_event_system_sleep,
        .sorted_monitor_ids = &monitor_ids,
        .sorted_monitor_count = monitor_ids.len,
        .interaction_monitor_id = 999,
        .previous_interaction_monitor_id = 20,
        .has_interaction_monitor_id = 1,
        .has_previous_interaction_monitor_id = 1,
    };

    try std.testing.expectEqual(kernel_ok, omniwm_restore_plan_event(&input, &output));
    try std.testing.expectEqual(@as(u8, 0), output.refresh_restore_intents);
    try std.testing.expectEqual(restore_note_system_sleep, output.note_code);
    try std.testing.expectEqual(@as(u8, 1), output.has_interaction_monitor_id);
    try std.testing.expectEqual(@as(u32, 10), output.interaction_monitor_id);
    try std.testing.expectEqual(@as(u8, 1), output.has_previous_interaction_monitor_id);
    try std.testing.expectEqual(@as(u32, 20), output.previous_interaction_monitor_id);

    input.event_kind = restore_event_system_wake;
    output = .{
        .interaction_monitor_id = 0,
        .previous_interaction_monitor_id = 0,
        .note_code = 0,
        .refresh_restore_intents = 0,
        .has_interaction_monitor_id = 0,
        .has_previous_interaction_monitor_id = 0,
    };
    try std.testing.expectEqual(kernel_ok, omniwm_restore_plan_event(&input, &output));
    try std.testing.expectEqual(@as(u8, 1), output.refresh_restore_intents);
    try std.testing.expectEqual(restore_note_system_wake, output.note_code);
}

test "floating rescue resolves normalized origin and skips approximate frames" {
    const candidates = [_]RestoreFloatingRescueCandidate{
        .{
            .token = .{ .pid = 1, .window_id = 1 },
            .workspace_id = zeroUUID(),
            .target_monitor_id = 11,
            .target_monitor_visible_frame = .{ .x = 1920, .y = 0, .width = 1440, .height = 900 },
            .current_frame = .{ .x = 2775.4, .y = 350.2, .width = 300, .height = 200 },
            .floating_frame = .{ .x = 120, .y = 100, .width = 300, .height = 200 },
            .normalized_origin = .{ .x = 0.75, .y = 0.5 },
            .reference_monitor_id = 10,
            .has_current_frame = 1,
            .has_normalized_origin = 1,
            .has_reference_monitor_id = 1,
            .is_scratchpad_hidden = 0,
            .is_workspace_inactive_hidden = 0,
        },
        .{
            .token = .{ .pid = 2, .window_id = 2 },
            .workspace_id = zeroUUID(),
            .target_monitor_id = 11,
            .target_monitor_visible_frame = .{ .x = 1920, .y = 0, .width = 1440, .height = 900 },
            .current_frame = .{ .x = 0, .y = 0, .width = 300, .height = 200 },
            .floating_frame = .{ .x = 120, .y = 100, .width = 300, .height = 200 },
            .normalized_origin = .{ .x = 0.75, .y = 0.5 },
            .reference_monitor_id = 10,
            .has_current_frame = 1,
            .has_normalized_origin = 1,
            .has_reference_monitor_id = 1,
            .is_scratchpad_hidden = 0,
            .is_workspace_inactive_hidden = 0,
        },
    };
    var operations = [_]RestoreFloatingRescueOperation{.{
        .candidate_index = 0,
        .target_frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    }} ** 2;
    var output = RestoreFloatingRescueOutput{
        .operations = &operations,
        .operation_capacity = operations.len,
        .operation_count = 0,
    };

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_restore_plan_floating_rescue(&candidates, candidates.len, &output),
    );
    try std.testing.expectEqual(@as(usize, 1), output.operation_count);
    try std.testing.expectEqual(@as(usize, 1), operations[0].candidate_index);
    try std.testing.expectEqual(@as(f64, 2775), operations[0].target_frame.x);
    try std.testing.expectEqual(@as(f64, 350), operations[0].target_frame.y);
}

test "floating rescue orders operations by stable window identity" {
    const candidates = [_]RestoreFloatingRescueCandidate{
        .{
            .token = .{ .pid = 4, .window_id = 400 },
            .workspace_id = .{ .high = 2, .low = 0 },
            .target_monitor_id = 10,
            .target_monitor_visible_frame = .{ .x = 0, .y = 0, .width = 1600, .height = 900 },
            .current_frame = .{ .x = 0, .y = 0, .width = 300, .height = 200 },
            .floating_frame = .{ .x = 500, .y = 300, .width = 300, .height = 200 },
            .normalized_origin = .{ .x = 0, .y = 0 },
            .reference_monitor_id = 0,
            .has_current_frame = 1,
            .has_normalized_origin = 0,
            .has_reference_monitor_id = 0,
            .is_scratchpad_hidden = 0,
            .is_workspace_inactive_hidden = 0,
        },
        .{
            .token = .{ .pid = 1, .window_id = 100 },
            .workspace_id = .{ .high = 1, .low = 0 },
            .target_monitor_id = 10,
            .target_monitor_visible_frame = .{ .x = 0, .y = 0, .width = 1600, .height = 900 },
            .current_frame = .{ .x = 0, .y = 0, .width = 300, .height = 200 },
            .floating_frame = .{ .x = 450, .y = 260, .width = 300, .height = 200 },
            .normalized_origin = .{ .x = 0, .y = 0 },
            .reference_monitor_id = 0,
            .has_current_frame = 1,
            .has_normalized_origin = 0,
            .has_reference_monitor_id = 0,
            .is_scratchpad_hidden = 0,
            .is_workspace_inactive_hidden = 0,
        },
    };
    var operations = [_]RestoreFloatingRescueOperation{.{
        .candidate_index = 0,
        .target_frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    }} ** 2;
    var output = RestoreFloatingRescueOutput{
        .operations = &operations,
        .operation_capacity = operations.len,
        .operation_count = 0,
    };

    try std.testing.expectEqual(
        kernel_ok,
        omniwm_restore_plan_floating_rescue(&candidates, candidates.len, &output),
    );
    try std.testing.expectEqual(@as(usize, 2), output.operation_count);
    try std.testing.expectEqual(@as(usize, 1), operations[0].candidate_index);
    try std.testing.expectEqual(@as(usize, 0), operations[1].candidate_index);
}
