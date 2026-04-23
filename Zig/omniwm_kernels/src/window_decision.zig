// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");

const kernel_ok: i32 = 0;
const kernel_invalid_argument: i32 = 1;

const rule_action_none: u32 = 0;
const rule_action_auto: u32 = 1;
const rule_action_tile: u32 = 2;
const rule_action_float: u32 = 3;

const disposition_managed: u32 = 0;
const disposition_floating: u32 = 1;
const disposition_unmanaged: u32 = 2;
const disposition_undecided: u32 = 3;

const source_user_rule: u32 = 0;
const source_built_in_rule: u32 = 1;
const source_heuristic: u32 = 2;

const built_in_source_none: u32 = 0;
const built_in_source_default_floating_app: u32 = 1;
const built_in_source_browser_picture_in_picture: u32 = 2;
const built_in_source_clean_shot_recording_overlay: u32 = 3;

const layout_kind_explicit: u32 = 0;
const layout_kind_fallback: u32 = 1;

const deferred_reason_none: u32 = 0;
const deferred_reason_attribute_fetch_failed: u32 = 1;
const deferred_reason_required_title_missing: u32 = 2;

const special_case_none: u32 = 0;
const special_case_clean_shot_recording_overlay: u32 = 1;

const activation_policy_unknown: u32 = 0;
const activation_policy_regular: u32 = 1;
const activation_policy_accessory: u32 = 2;
const activation_policy_prohibited: u32 = 3;

const subrole_kind_unknown: u32 = 0;
const subrole_kind_standard: u32 = 1;
const subrole_kind_nonstandard: u32 = 2;

const fullscreen_button_state_unknown: u32 = 0;
const fullscreen_button_state_enabled: u32 = 1;
const fullscreen_button_state_disabled: u32 = 2;

const heuristic_reason_attribute_fetch_failed: u32 = 1 << 0;
const heuristic_reason_browser_picture_in_picture: u32 = 1 << 1;
const heuristic_reason_accessory_without_close: u32 = 1 << 2;
const heuristic_reason_trusted_floating_subrole: u32 = 1 << 3;
const heuristic_reason_no_buttons_on_nonstandard_subrole: u32 = 1 << 4;
const heuristic_reason_nonstandard_subrole: u32 = 1 << 5;
const heuristic_reason_missing_fullscreen_button: u32 = 1 << 6;
const heuristic_reason_disabled_fullscreen_button: u32 = 1 << 7;
const heuristic_reason_fixed_size_window: u32 = 1 << 8;

const RuleSummary = extern struct {
    action: u32,
    has_match: u8,
};

const BuiltInRuleSummary = extern struct {
    action: u32,
    source_kind: u32,
    has_match: u8,
};

const WindowDecisionInput = extern struct {
    matched_user_rule: RuleSummary,
    matched_built_in_rule: BuiltInRuleSummary,
    special_case_kind: u32,
    activation_policy: u32,
    subrole_kind: u32,
    fullscreen_button_state: u32,
    title_required: u8,
    title_present: u8,
    attribute_fetch_succeeded: u8,
    app_fullscreen: u8,
    has_close_button: u8,
    has_fullscreen_button: u8,
    has_zoom_button: u8,
    has_minimize_button: u8,
};

const WindowDecisionOutput = extern struct {
    disposition: u32,
    source_kind: u32,
    built_in_source_kind: u32,
    layout_kind: u32,
    deferred_reason: u32,
    heuristic_reason_bits: u32,
};

const SourceSelection = struct {
    source_kind: u32,
    built_in_source_kind: u32,
};

const HeuristicClassification = struct {
    disposition: u32,
    reasons: u32,
};

fn sanitizeRuleAction(raw_value: u32) u32 {
    return switch (raw_value) {
        rule_action_none,
        rule_action_auto,
        rule_action_tile,
        rule_action_float,
        => raw_value,
        else => rule_action_none,
    };
}

fn sanitizeBuiltInSourceKind(raw_value: u32) u32 {
    return switch (raw_value) {
        built_in_source_none,
        built_in_source_default_floating_app,
        built_in_source_browser_picture_in_picture,
        built_in_source_clean_shot_recording_overlay,
        => raw_value,
        else => built_in_source_none,
    };
}

fn sanitizeSpecialCaseKind(raw_value: u32) u32 {
    return switch (raw_value) {
        special_case_none,
        special_case_clean_shot_recording_overlay,
        => raw_value,
        else => special_case_none,
    };
}

fn sanitizeActivationPolicy(raw_value: u32) u32 {
    return switch (raw_value) {
        activation_policy_unknown,
        activation_policy_regular,
        activation_policy_accessory,
        activation_policy_prohibited,
        => raw_value,
        else => activation_policy_unknown,
    };
}

fn sanitizeSubroleKind(raw_value: u32) u32 {
    return switch (raw_value) {
        subrole_kind_unknown,
        subrole_kind_standard,
        subrole_kind_nonstandard,
        => raw_value,
        else => subrole_kind_unknown,
    };
}

fn sanitizeFullscreenButtonState(raw_value: u32) u32 {
    return switch (raw_value) {
        fullscreen_button_state_unknown,
        fullscreen_button_state_enabled,
        fullscreen_button_state_disabled,
        => raw_value,
        else => fullscreen_button_state_unknown,
    };
}

fn hasMatch(summary: RuleSummary) bool {
    return summary.has_match != 0;
}

fn hasBuiltInMatch(summary: BuiltInRuleSummary) bool {
    return summary.has_match != 0;
}

fn explicitDispositionForAction(raw_action: u32) ?u32 {
    return switch (sanitizeRuleAction(raw_action)) {
        rule_action_tile => disposition_managed,
        rule_action_float => disposition_floating,
        else => null,
    };
}

fn explicitUserSource() SourceSelection {
    return .{
        .source_kind = source_user_rule,
        .built_in_source_kind = built_in_source_none,
    };
}

fn explicitBuiltInSource(summary: BuiltInRuleSummary) SourceSelection {
    return .{
        .source_kind = source_built_in_rule,
        .built_in_source_kind = sanitizeBuiltInSourceKind(summary.source_kind),
    };
}

fn heuristicSource() SourceSelection {
    return .{
        .source_kind = source_heuristic,
        .built_in_source_kind = built_in_source_none,
    };
}

fn fallbackSourceForTitleOrFullscreen(input: WindowDecisionInput) SourceSelection {
    if (hasMatch(input.matched_user_rule)) {
        return explicitUserSource();
    }

    if (hasBuiltInMatch(input.matched_built_in_rule)) {
        return explicitBuiltInSource(input.matched_built_in_rule);
    }

    return heuristicSource();
}

fn fallbackSourceForHeuristicPath(input: WindowDecisionInput) SourceSelection {
    if (hasMatch(input.matched_user_rule)) {
        return explicitUserSource();
    }

    return heuristicSource();
}

fn makeOutput(
    disposition: u32,
    source: SourceSelection,
    layout_kind: u32,
    deferred_reason: u32,
    heuristic_reason_bits: u32,
) WindowDecisionOutput {
    return .{
        .disposition = disposition,
        .source_kind = source.source_kind,
        .built_in_source_kind = source.built_in_source_kind,
        .layout_kind = layout_kind,
        .deferred_reason = deferred_reason,
        .heuristic_reason_bits = heuristic_reason_bits,
    };
}

fn classifyHeuristics(input: WindowDecisionInput) HeuristicClassification {
    if (input.attribute_fetch_succeeded == 0) {
        return .{
            .disposition = disposition_undecided,
            .reasons = heuristic_reason_attribute_fetch_failed,
        };
    }

    const has_any_button =
        input.has_close_button != 0 or
        input.has_fullscreen_button != 0 or
        input.has_zoom_button != 0 or
        input.has_minimize_button != 0;
    const activation_policy = sanitizeActivationPolicy(input.activation_policy);
    const subrole_kind = sanitizeSubroleKind(input.subrole_kind);
    const fullscreen_button_state = sanitizeFullscreenButtonState(input.fullscreen_button_state);

    if (activation_policy == activation_policy_accessory and input.has_close_button == 0) {
        return .{
            .disposition = disposition_floating,
            .reasons = heuristic_reason_accessory_without_close,
        };
    }

    if (!has_any_button and subrole_kind != subrole_kind_standard) {
        return .{
            .disposition = disposition_floating,
            .reasons = heuristic_reason_no_buttons_on_nonstandard_subrole,
        };
    }

    if (subrole_kind == subrole_kind_nonstandard) {
        return .{
            .disposition = disposition_floating,
            .reasons = heuristic_reason_nonstandard_subrole,
        };
    }

    if (input.has_fullscreen_button == 0) {
        return .{
            .disposition = disposition_floating,
            .reasons = heuristic_reason_missing_fullscreen_button,
        };
    }

    if (fullscreen_button_state != fullscreen_button_state_enabled) {
        return .{
            .disposition = disposition_floating,
            .reasons = heuristic_reason_disabled_fullscreen_button,
        };
    }

    return .{
        .disposition = disposition_managed,
        .reasons = 0,
    };
}

fn solveWindowDecision(input: WindowDecisionInput) WindowDecisionOutput {
    if (explicitDispositionForAction(input.matched_user_rule.action)) |disposition| {
        if (hasMatch(input.matched_user_rule)) {
            return makeOutput(
                disposition,
                explicitUserSource(),
                layout_kind_explicit,
                deferred_reason_none,
                0,
            );
        }
    }

    if (explicitDispositionForAction(input.matched_built_in_rule.action)) |disposition| {
        if (hasBuiltInMatch(input.matched_built_in_rule)) {
            return makeOutput(
                disposition,
                explicitBuiltInSource(input.matched_built_in_rule),
                layout_kind_explicit,
                deferred_reason_none,
                0,
            );
        }
    }

    if (sanitizeSpecialCaseKind(input.special_case_kind) == special_case_clean_shot_recording_overlay) {
        return makeOutput(
            disposition_floating,
            .{
                .source_kind = source_built_in_rule,
                .built_in_source_kind = built_in_source_clean_shot_recording_overlay,
            },
            layout_kind_explicit,
            deferred_reason_none,
            0,
        );
    }

    if (input.title_required != 0 and input.title_present == 0) {
        return makeOutput(
            disposition_undecided,
            fallbackSourceForTitleOrFullscreen(input),
            layout_kind_fallback,
            deferred_reason_required_title_missing,
            0,
        );
    }

    if (input.app_fullscreen != 0) {
        return makeOutput(
            disposition_managed,
            fallbackSourceForTitleOrFullscreen(input),
            layout_kind_fallback,
            deferred_reason_none,
            0,
        );
    }

    if (input.attribute_fetch_succeeded == 0) {
        if (hasMatch(input.matched_user_rule) and sanitizeRuleAction(input.matched_user_rule.action) == rule_action_float) {
            return makeOutput(
                disposition_floating,
                explicitUserSource(),
                layout_kind_fallback,
                deferred_reason_none,
                heuristic_reason_attribute_fetch_failed,
            );
        }

        return makeOutput(
            disposition_undecided,
            fallbackSourceForHeuristicPath(input),
            layout_kind_fallback,
            deferred_reason_attribute_fetch_failed,
            heuristic_reason_attribute_fetch_failed,
        );
    }

    const heuristic = classifyHeuristics(input);
    return makeOutput(
        heuristic.disposition,
        fallbackSourceForHeuristicPath(input),
        layout_kind_fallback,
        if (heuristic.disposition == disposition_undecided) deferred_reason_attribute_fetch_failed else deferred_reason_none,
        heuristic.reasons,
    );
}

pub export fn omniwm_window_decision_solve(
    input_ptr: ?*const WindowDecisionInput,
    output_ptr: ?*WindowDecisionOutput,
) i32 {
    const input = input_ptr orelse return kernel_invalid_argument;
    const output = output_ptr orelse return kernel_invalid_argument;

    output.* = solveWindowDecision(input.*);
    return kernel_ok;
}

fn baseInput() WindowDecisionInput {
    var input = std.mem.zeroes(WindowDecisionInput);
    input.attribute_fetch_succeeded = 1;
    input.activation_policy = activation_policy_regular;
    input.subrole_kind = subrole_kind_standard;
    input.has_close_button = 1;
    input.has_fullscreen_button = 1;
    input.fullscreen_button_state = fullscreen_button_state_enabled;
    input.has_zoom_button = 1;
    input.has_minimize_button = 1;
    return input;
}

fn expectSolved(input: WindowDecisionInput) !WindowDecisionOutput {
    var output = std.mem.zeroes(WindowDecisionOutput);
    try std.testing.expectEqual(
        kernel_ok,
        omniwm_window_decision_solve(&input, &output),
    );
    return output;
}

test "window decision explicit user rule beats built-in and special case" {
    var input = baseInput();
    input.matched_user_rule = .{
        .action = rule_action_tile,
        .has_match = 1,
    };
    input.matched_built_in_rule = .{
        .action = rule_action_float,
        .source_kind = built_in_source_default_floating_app,
        .has_match = 1,
    };
    input.special_case_kind = special_case_clean_shot_recording_overlay;
    input.title_required = 1;
    input.app_fullscreen = 1;

    const output = try expectSolved(input);
    try std.testing.expectEqual(disposition_managed, output.disposition);
    try std.testing.expectEqual(source_user_rule, output.source_kind);
    try std.testing.expectEqual(layout_kind_explicit, output.layout_kind);
}

test "window decision explicit built-in rule wins before fullscreen fallback" {
    var input = baseInput();
    input.matched_built_in_rule = .{
        .action = rule_action_float,
        .source_kind = built_in_source_default_floating_app,
        .has_match = 1,
    };
    input.app_fullscreen = 1;

    const output = try expectSolved(input);
    try std.testing.expectEqual(disposition_floating, output.disposition);
    try std.testing.expectEqual(source_built_in_rule, output.source_kind);
    try std.testing.expectEqual(built_in_source_default_floating_app, output.built_in_source_kind);
    try std.testing.expectEqual(layout_kind_explicit, output.layout_kind);
}

test "window decision special case wins before title deferral" {
    var input = baseInput();
    input.special_case_kind = special_case_clean_shot_recording_overlay;
    input.title_required = 1;
    input.title_present = 0;

    const output = try expectSolved(input);
    try std.testing.expectEqual(disposition_floating, output.disposition);
    try std.testing.expectEqual(source_built_in_rule, output.source_kind);
    try std.testing.expectEqual(built_in_source_clean_shot_recording_overlay, output.built_in_source_kind);
    try std.testing.expectEqual(layout_kind_explicit, output.layout_kind);
}

test "window decision title deferral keeps fallback source and no heuristic reasons" {
    var input = baseInput();
    input.matched_user_rule = .{
        .action = rule_action_auto,
        .has_match = 1,
    };
    input.title_required = 1;
    input.title_present = 0;

    const output = try expectSolved(input);
    try std.testing.expectEqual(disposition_undecided, output.disposition);
    try std.testing.expectEqual(source_user_rule, output.source_kind);
    try std.testing.expectEqual(layout_kind_fallback, output.layout_kind);
    try std.testing.expectEqual(deferred_reason_required_title_missing, output.deferred_reason);
    try std.testing.expectEqual(@as(u32, 0), output.heuristic_reason_bits);
}

test "window decision degraded ax keeps explicit float user rule" {
    var input = baseInput();
    input.attribute_fetch_succeeded = 0;
    input.matched_user_rule = .{
        .action = rule_action_float,
        .has_match = 1,
    };

    const output = try expectSolved(input);
    try std.testing.expectEqual(disposition_floating, output.disposition);
    try std.testing.expectEqual(source_user_rule, output.source_kind);
    try std.testing.expectEqual(layout_kind_explicit, output.layout_kind);
    try std.testing.expectEqual(deferred_reason_none, output.deferred_reason);
    try std.testing.expectEqual(@as(u32, 0), output.heuristic_reason_bits);
}

test "window decision heuristic fallback uses accessory floating classification" {
    var input = baseInput();
    input.activation_policy = activation_policy_accessory;
    input.has_close_button = 0;

    const output = try expectSolved(input);
    try std.testing.expectEqual(disposition_floating, output.disposition);
    try std.testing.expectEqual(source_heuristic, output.source_kind);
    try std.testing.expectEqual(layout_kind_fallback, output.layout_kind);
    try std.testing.expectEqual(heuristic_reason_accessory_without_close, output.heuristic_reason_bits);
}

test "window decision heuristic fallback returns managed for standard window" {
    const input = baseInput();
    const output = try expectSolved(input);
    try std.testing.expectEqual(disposition_managed, output.disposition);
    try std.testing.expectEqual(source_heuristic, output.source_kind);
    try std.testing.expectEqual(@as(u32, 0), output.heuristic_reason_bits);
}
