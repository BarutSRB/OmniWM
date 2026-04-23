// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Foundation
import Testing

private func makeWindowDecisionRuleSummary(
    action: UInt32 = UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_NONE),
    hasMatch: Bool = false
) -> omniwm_window_decision_rule_summary {
    omniwm_window_decision_rule_summary(
        action: action,
        has_match: hasMatch ? 1 : 0
    )
}

private func makeWindowDecisionBuiltInRuleSummary(
    action: UInt32 = UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_NONE),
    sourceKind: UInt32 = UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_NONE),
    hasMatch: Bool = false
) -> omniwm_window_decision_built_in_rule_summary {
    omniwm_window_decision_built_in_rule_summary(
        action: action,
        source_kind: sourceKind,
        has_match: hasMatch ? 1 : 0
    )
}

private func makeWindowDecisionInput(
    matchedUserRule: omniwm_window_decision_rule_summary = makeWindowDecisionRuleSummary(),
    matchedBuiltInRule: omniwm_window_decision_built_in_rule_summary = makeWindowDecisionBuiltInRuleSummary(),
    specialCaseKind: UInt32 = UInt32(OMNIWM_WINDOW_DECISION_SPECIAL_CASE_NONE),
    activationPolicy: UInt32 = UInt32(OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_REGULAR),
    subroleKind: UInt32 = UInt32(OMNIWM_WINDOW_DECISION_SUBROLE_KIND_STANDARD),
    fullscreenButtonState: UInt32 = UInt32(OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_ENABLED),
    titleRequired: Bool = false,
    titlePresent: Bool = true,
    attributeFetchSucceeded: Bool = true,
    appFullscreen: Bool = false,
    hasCloseButton: Bool = true,
    hasFullscreenButton: Bool = true,
    hasZoomButton: Bool = true,
    hasMinimizeButton: Bool = true
) -> omniwm_window_decision_input {
    omniwm_window_decision_input(
        matched_user_rule: matchedUserRule,
        matched_built_in_rule: matchedBuiltInRule,
        special_case_kind: specialCaseKind,
        activation_policy: activationPolicy,
        subrole_kind: subroleKind,
        fullscreen_button_state: fullscreenButtonState,
        title_required: titleRequired ? 1 : 0,
        title_present: titlePresent ? 1 : 0,
        attribute_fetch_succeeded: attributeFetchSucceeded ? 1 : 0,
        app_fullscreen: appFullscreen ? 1 : 0,
        has_close_button: hasCloseButton ? 1 : 0,
        has_fullscreen_button: hasFullscreenButton ? 1 : 0,
        has_zoom_button: hasZoomButton ? 1 : 0,
        has_minimize_button: hasMinimizeButton ? 1 : 0
    )
}

@Suite struct WindowDecisionKernelABITests {
    @Test func nullPointersReturnInvalidArgument() {
        var input = makeWindowDecisionInput()
        var output = omniwm_window_decision_output()

        #expect(
            omniwm_window_decision_solve(nil, &output) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
        #expect(
            omniwm_window_decision_solve(&input, nil) == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT
        )
    }

    @Test func zeroedInputRemainsStableAndDeferred() {
        var input = omniwm_window_decision_input()
        var output = omniwm_window_decision_output()

        let status = omniwm_window_decision_solve(&input, &output)

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.disposition == UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_UNDECIDED))
        #expect(output.source_kind == UInt32(OMNIWM_WINDOW_DECISION_SOURCE_HEURISTIC))
        #expect(output.built_in_source_kind == UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_NONE))
        #expect(output.layout_kind == UInt32(OMNIWM_WINDOW_DECISION_LAYOUT_KIND_FALLBACK))
        #expect(output.deferred_reason == UInt32(OMNIWM_WINDOW_DECISION_DEFERRED_REASON_ATTRIBUTE_FETCH_FAILED))
        #expect(
            output.heuristic_reason_bits
                == UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_ATTRIBUTE_FETCH_FAILED)
        )
    }

    @Test func standardManagedFallbackDecodesToHeuristicManaged() {
        var input = makeWindowDecisionInput()
        var output = omniwm_window_decision_output()

        let status = omniwm_window_decision_solve(&input, &output)

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.disposition == UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_MANAGED))
        #expect(output.source_kind == UInt32(OMNIWM_WINDOW_DECISION_SOURCE_HEURISTIC))
        #expect(output.built_in_source_kind == UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_NONE))
        #expect(output.layout_kind == UInt32(OMNIWM_WINDOW_DECISION_LAYOUT_KIND_FALLBACK))
        #expect(output.deferred_reason == UInt32(OMNIWM_WINDOW_DECISION_DEFERRED_REASON_NONE))
        #expect(output.heuristic_reason_bits == 0)
    }

    @Test func explicitUserRuleReturnsExplicitUserSource() {
        var input = makeWindowDecisionInput(
            matchedUserRule: makeWindowDecisionRuleSummary(
                action: UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_TILE),
                hasMatch: true
            )
        )
        var output = omniwm_window_decision_output()

        let status = omniwm_window_decision_solve(&input, &output)

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.disposition == UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_MANAGED))
        #expect(output.source_kind == UInt32(OMNIWM_WINDOW_DECISION_SOURCE_USER_RULE))
        #expect(output.built_in_source_kind == UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_NONE))
        #expect(output.layout_kind == UInt32(OMNIWM_WINDOW_DECISION_LAYOUT_KIND_EXPLICIT))
        #expect(output.deferred_reason == UInt32(OMNIWM_WINDOW_DECISION_DEFERRED_REASON_NONE))
    }

    @Test func explicitBuiltInRuleReturnsStableBuiltInSourceKind() {
        var input = makeWindowDecisionInput(
            matchedBuiltInRule: makeWindowDecisionBuiltInRuleSummary(
                action: UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_FLOAT),
                sourceKind: UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_DEFAULT_FLOATING_APP),
                hasMatch: true
            )
        )
        var output = omniwm_window_decision_output()

        let status = omniwm_window_decision_solve(&input, &output)

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.disposition == UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_FLOATING))
        #expect(output.source_kind == UInt32(OMNIWM_WINDOW_DECISION_SOURCE_BUILT_IN_RULE))
        #expect(
            output.built_in_source_kind
                == UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_DEFAULT_FLOATING_APP)
        )
        #expect(output.layout_kind == UInt32(OMNIWM_WINDOW_DECISION_LAYOUT_KIND_EXPLICIT))
    }

    @Test func titleDeferralCanReturnBuiltInFallbackSource() {
        var input = makeWindowDecisionInput(
            matchedBuiltInRule: makeWindowDecisionBuiltInRuleSummary(
                action: UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_AUTO),
                sourceKind: UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_BROWSER_PICTURE_IN_PICTURE),
                hasMatch: true
            ),
            titleRequired: true,
            titlePresent: false
        )
        var output = omniwm_window_decision_output()

        let status = omniwm_window_decision_solve(&input, &output)

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.disposition == UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_UNDECIDED))
        #expect(output.source_kind == UInt32(OMNIWM_WINDOW_DECISION_SOURCE_BUILT_IN_RULE))
        #expect(
            output.built_in_source_kind
                == UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_BROWSER_PICTURE_IN_PICTURE)
        )
        #expect(
            output.deferred_reason
                == UInt32(OMNIWM_WINDOW_DECISION_DEFERRED_REASON_REQUIRED_TITLE_MISSING)
        )
    }

    @Test func heuristicReasonBitsetIsStableForMissingFullscreenButton() {
        var input = makeWindowDecisionInput(
            fullscreenButtonState: UInt32(OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_UNKNOWN),
            hasFullscreenButton: false
        )
        var output = omniwm_window_decision_output()

        let status = omniwm_window_decision_solve(&input, &output)

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.disposition == UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_FLOATING))
        #expect(
            output.heuristic_reason_bits
                == UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_MISSING_FULLSCREEN_BUTTON)
        )
    }
}
