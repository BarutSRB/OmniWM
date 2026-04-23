// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import COmniWMKernels
import Foundation

enum WindowDecisionBuiltInSourceKind {
    case defaultFloatingApp
    case browserPictureInPicture
    case cleanShotRecordingOverlay

    fileprivate var kernelRawValue: UInt32 {
        switch self {
        case .defaultFloatingApp:
            UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_DEFAULT_FLOATING_APP)
        case .browserPictureInPicture:
            UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_BROWSER_PICTURE_IN_PICTURE)
        case .cleanShotRecordingOverlay:
            UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_CLEAN_SHOT_RECORDING_OVERLAY)
        }
    }

    fileprivate init?(kernelRawValue: UInt32) {
        switch kernelRawValue {
        case UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_NONE):
            return nil
        case UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_DEFAULT_FLOATING_APP):
            self = .defaultFloatingApp
        case UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_BROWSER_PICTURE_IN_PICTURE):
            self = .browserPictureInPicture
        case UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_CLEAN_SHOT_RECORDING_OVERLAY):
            self = .cleanShotRecordingOverlay
        default:
            preconditionFailure("Unknown window decision built-in source \(kernelRawValue)")
        }
    }
}

enum WindowDecisionSpecialCaseKind {
    case none
    case cleanShotRecordingOverlay

    fileprivate var kernelRawValue: UInt32 {
        switch self {
        case .none:
            UInt32(OMNIWM_WINDOW_DECISION_SPECIAL_CASE_NONE)
        case .cleanShotRecordingOverlay:
            UInt32(OMNIWM_WINDOW_DECISION_SPECIAL_CASE_CLEAN_SHOT_RECORDING_OVERLAY)
        }
    }
}

enum WindowDecisionKernelSourceKind {
    case userRule
    case builtInRule
    case heuristic

    fileprivate init(kernelRawValue: UInt32) {
        switch kernelRawValue {
        case UInt32(OMNIWM_WINDOW_DECISION_SOURCE_USER_RULE):
            self = .userRule
        case UInt32(OMNIWM_WINDOW_DECISION_SOURCE_BUILT_IN_RULE):
            self = .builtInRule
        case UInt32(OMNIWM_WINDOW_DECISION_SOURCE_HEURISTIC):
            self = .heuristic
        default:
            preconditionFailure("Unknown window decision source \(kernelRawValue)")
        }
    }
}

struct WindowDecisionKernelOutput {
    let disposition: WindowDecisionDisposition
    let sourceKind: WindowDecisionKernelSourceKind
    let builtInSourceKind: WindowDecisionBuiltInSourceKind?
    let layoutDecisionKind: WindowDecisionLayoutKind
    let deferredReason: WindowDecisionDeferredReason?
    let heuristicReasons: [AXWindowHeuristicReason]

    var heuristicDisposition: AXWindowHeuristicDisposition {
        AXWindowHeuristicDisposition(
            disposition: disposition,
            reasons: heuristicReasons
        )
    }
}

private extension WindowRuleLayoutAction {
    var windowDecisionKernelRawValue: UInt32 {
        switch self {
        case .auto:
            UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_AUTO)
        case .tile:
            UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_TILE)
        case .float:
            UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_FLOAT)
        }
    }
}

private extension WindowDecisionDisposition {
    init(windowDecisionKernelRawValue: UInt32) {
        switch windowDecisionKernelRawValue {
        case UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_MANAGED):
            self = .managed
        case UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_FLOATING):
            self = .floating
        case UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_UNMANAGED):
            self = .unmanaged
        case UInt32(OMNIWM_WINDOW_DECISION_DISPOSITION_UNDECIDED):
            self = .undecided
        default:
            preconditionFailure("Unknown window decision disposition \(windowDecisionKernelRawValue)")
        }
    }
}

private extension WindowDecisionLayoutKind {
    init(windowDecisionKernelRawValue: UInt32) {
        switch windowDecisionKernelRawValue {
        case UInt32(OMNIWM_WINDOW_DECISION_LAYOUT_KIND_EXPLICIT):
            self = .explicitLayout
        case UInt32(OMNIWM_WINDOW_DECISION_LAYOUT_KIND_FALLBACK):
            self = .fallbackLayout
        default:
            preconditionFailure("Unknown window decision layout kind \(windowDecisionKernelRawValue)")
        }
    }
}

private extension Optional where Wrapped == WindowDecisionDeferredReason {
    init(windowDecisionKernelRawValue: UInt32) {
        switch windowDecisionKernelRawValue {
        case UInt32(OMNIWM_WINDOW_DECISION_DEFERRED_REASON_NONE):
            self = nil
        case UInt32(OMNIWM_WINDOW_DECISION_DEFERRED_REASON_ATTRIBUTE_FETCH_FAILED):
            self = .attributeFetchFailed
        case UInt32(OMNIWM_WINDOW_DECISION_DEFERRED_REASON_REQUIRED_TITLE_MISSING):
            self = .requiredTitleMissing
        default:
            preconditionFailure("Unknown window decision deferred reason \(windowDecisionKernelRawValue)")
        }
    }
}

private extension NSApplication.ActivationPolicy? {
    var windowDecisionKernelRawValue: UInt32 {
        switch self {
        case .regular:
            UInt32(OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_REGULAR)
        case .accessory:
            UInt32(OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_ACCESSORY)
        case .prohibited:
            UInt32(OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_PROHIBITED)
        case nil:
            UInt32(OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_UNKNOWN)
        @unknown default:
            UInt32(OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_UNKNOWN)
        }
    }
}

private extension AXWindowFacts {
    var windowDecisionSubroleKernelRawValue: UInt32 {
        guard let subrole else {
            return UInt32(OMNIWM_WINDOW_DECISION_SUBROLE_KIND_UNKNOWN)
        }
        if subrole == (kAXStandardWindowSubrole as String) {
            return UInt32(OMNIWM_WINDOW_DECISION_SUBROLE_KIND_STANDARD)
        }
        return UInt32(OMNIWM_WINDOW_DECISION_SUBROLE_KIND_NONSTANDARD)
    }

    var windowDecisionFullscreenButtonStateKernelRawValue: UInt32 {
        switch fullscreenButtonEnabled {
        case true:
            UInt32(OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_ENABLED)
        case false:
            UInt32(OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_DISABLED)
        case nil:
            UInt32(OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_UNKNOWN)
        }
    }
}

private extension AXWindowHeuristicReason {
    var windowDecisionKernelBit: UInt32 {
        switch self {
        case .attributeFetchFailed:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_ATTRIBUTE_FETCH_FAILED)
        case .browserPictureInPicture:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_BROWSER_PICTURE_IN_PICTURE)
        case .accessoryWithoutClose:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_ACCESSORY_WITHOUT_CLOSE)
        case .trustedFloatingSubrole:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_TRUSTED_FLOATING_SUBROLE)
        case .noButtonsOnNonStandardSubrole:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_NO_BUTTONS_ON_NONSTANDARD_SUBROLE)
        case .nonStandardSubrole:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_NONSTANDARD_SUBROLE)
        case .missingFullscreenButton:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_MISSING_FULLSCREEN_BUTTON)
        case .disabledFullscreenButton:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_DISABLED_FULLSCREEN_BUTTON)
        case .fixedSizeWindow:
            UInt32(OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_FIXED_SIZE_WINDOW)
        }
    }
}

private let orderedWindowDecisionHeuristicReasons: [AXWindowHeuristicReason] = [
    .attributeFetchFailed,
    .browserPictureInPicture,
    .accessoryWithoutClose,
    .trustedFloatingSubrole,
    .noButtonsOnNonStandardSubrole,
    .nonStandardSubrole,
    .missingFullscreenButton,
    .disabledFullscreenButton,
    .fixedSizeWindow,
]

func solveWindowDecisionKernel(
    matchedUserAction: WindowRuleLayoutAction?,
    matchedBuiltInAction: WindowRuleLayoutAction?,
    matchedBuiltInSourceKind: WindowDecisionBuiltInSourceKind?,
    specialCaseKind: WindowDecisionSpecialCaseKind,
    facts: AXWindowFacts,
    titleRequired: Bool,
    appFullscreen: Bool
) -> WindowDecisionKernelOutput {
    var input = omniwm_window_decision_input(
        matched_user_rule: omniwm_window_decision_rule_summary(
            action: matchedUserAction?.windowDecisionKernelRawValue
                ?? UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_NONE),
            has_match: matchedUserAction == nil ? 0 : 1
        ),
        matched_built_in_rule: omniwm_window_decision_built_in_rule_summary(
            action: matchedBuiltInAction?.windowDecisionKernelRawValue
                ?? UInt32(OMNIWM_WINDOW_DECISION_RULE_ACTION_NONE),
            source_kind: matchedBuiltInSourceKind?.kernelRawValue
                ?? UInt32(OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_NONE),
            has_match: matchedBuiltInAction == nil ? 0 : 1
        ),
        special_case_kind: specialCaseKind.kernelRawValue,
        activation_policy: facts.appPolicy.windowDecisionKernelRawValue,
        subrole_kind: facts.windowDecisionSubroleKernelRawValue,
        fullscreen_button_state: facts.windowDecisionFullscreenButtonStateKernelRawValue,
        title_required: titleRequired ? 1 : 0,
        title_present: facts.title == nil ? 0 : 1,
        attribute_fetch_succeeded: facts.attributeFetchSucceeded ? 1 : 0,
        app_fullscreen: appFullscreen ? 1 : 0,
        has_close_button: facts.hasCloseButton ? 1 : 0,
        has_fullscreen_button: facts.hasFullscreenButton ? 1 : 0,
        has_zoom_button: facts.hasZoomButton ? 1 : 0,
        has_minimize_button: facts.hasMinimizeButton ? 1 : 0
    )
    var output = omniwm_window_decision_output()

    let status = withUnsafePointer(to: &input) { inputPointer in
        withUnsafeMutablePointer(to: &output) { outputPointer in
            omniwm_window_decision_solve(inputPointer, outputPointer)
        }
    }

    precondition(
        status == OMNIWM_KERNELS_STATUS_OK,
        "omniwm_window_decision_solve returned \(status)"
    )

    return WindowDecisionKernelOutput(
        disposition: WindowDecisionDisposition(windowDecisionKernelRawValue: output.disposition),
        sourceKind: WindowDecisionKernelSourceKind(kernelRawValue: output.source_kind),
        builtInSourceKind: WindowDecisionBuiltInSourceKind(kernelRawValue: output.built_in_source_kind),
        layoutDecisionKind: WindowDecisionLayoutKind(windowDecisionKernelRawValue: output.layout_kind),
        deferredReason: Optional(windowDecisionKernelRawValue: output.deferred_reason),
        heuristicReasons: orderedWindowDecisionHeuristicReasons.filter {
            output.heuristic_reason_bits & $0.windowDecisionKernelBit != 0
        }
    )
}
