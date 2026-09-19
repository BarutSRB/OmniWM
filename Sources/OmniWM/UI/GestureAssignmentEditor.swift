// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

enum GestureAssignmentAction: String, CaseIterable, Identifiable {
    case columns, workspaces, overview, move, resize

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .columns: "Scroll columns"
        case .workspaces: "Switch workspaces"
        case .overview: "Overview"
        case .move: "Move windows"
        case .resize: "Resize windows"
        }
    }

    var supportedFingerCounts: [Int] {
        self == .overview ? [3, 4] : [2, 3, 4]
    }

    func isEnabled(in gestures: SettingsExport.Gestures) -> Bool {
        switch self {
        case .columns: gestures.scrollEnabled
        case .workspaces: gestures.workspaceSwipeEnabled
        case .overview: gestures.overviewGestureEnabled ?? false
        case .move: gestures.windowMoveEnabled ?? false
        case .resize: gestures.windowResizeEnabled ?? false
        }
    }

    func fingerCount(in gestures: SettingsExport.Gestures) -> Int {
        switch self {
        case .columns: gestures.fingerCount.rawValue
        case .workspaces: gestures.workspaceSwipeFingerCount.rawValue
        case .overview: (gestures.overviewGestureFingerCount ?? .four).rawValue
        case .move: (gestures.windowMoveFingerCount ?? .four).rawValue
        case .resize: (gestures.windowResizeFingerCount ?? .three).rawValue
        }
    }
}

struct GestureAssignmentEdit: Equatable {
    enum Change: Equatable {
        case enabled(Bool)
        case fingers(Int)
        case workspaceAxis(WorkspaceSwipeAxis)
    }

    let action: GestureAssignmentAction
    let change: Change

    var summary: String {
        switch change {
        case let .enabled(enabled): "\(enabled ? "Enable" : "Disable") \(action.title)"
        case let .fingers(count): "Set \(action.title) to \(count) fingers"
        case let .workspaceAxis(axis): "Set \(action.title) to \(axis.displayName.lowercased()) swipes"
        }
    }

    func applying(to gestures: SettingsExport.Gestures) -> SettingsExport.Gestures {
        var candidate = gestures
        switch change {
        case let .enabled(enabled):
            switch action {
            case .columns: candidate.scrollEnabled = enabled
            case .workspaces: candidate.workspaceSwipeEnabled = enabled
            case .overview: candidate.overviewGestureEnabled = enabled
            case .move: candidate.windowMoveEnabled = enabled
            case .resize: candidate.windowResizeEnabled = enabled
            }
        case let .fingers(count):
            precondition(action.supportedFingerCounts.contains(count))
            guard let fingers = GestureFingerCount(rawValue: count) else {
                preconditionFailure("Unsupported gesture finger count")
            }
            switch action {
            case .columns: candidate.fingerCount = fingers
            case .workspaces: candidate.workspaceSwipeFingerCount = fingers
            case .overview: candidate.overviewGestureFingerCount = OverviewGestureFingerCount(rawValue: count)
            case .move: candidate.windowMoveFingerCount = fingers
            case .resize: candidate.windowResizeFingerCount = fingers
            }
        case let .workspaceAxis(axis):
            precondition(action == .workspaces)
            candidate.workspaceSwipeAxis = axis
        }
        return candidate
    }
}

struct GestureAssignmentResolution: Equatable, Identifiable {
    let disabledActions: [GestureAssignmentAction]

    var id: String {
        disabledActions.map(\.rawValue).joined(separator: ",")
    }

    var disablesMouseWheelScrolling: Bool {
        disabledActions.contains(.columns)
    }

    func title(for edit: GestureAssignmentEdit) -> String {
        guard !disabledActions.isEmpty else { return edit.summary }
        let names = disabledActions.map(\.title)
        let joinedNames = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            : names[0]
        let request = edit.summary.prefix(1).lowercased() + edit.summary.dropFirst()
        return "Turn off \(joinedNames) and \(request)"
    }

    func applying(to gestures: SettingsExport.Gestures) -> SettingsExport.Gestures {
        disabledActions.reduce(gestures) { candidate, action in
            GestureAssignmentEdit(action: action, change: .enabled(false)).applying(to: candidate)
        }
    }
}

struct GestureAssignmentProposal {
    let edit: GestureAssignmentEdit
    let conflict: TrackpadGestureConflict?
    let resolutions: [GestureAssignmentResolution]
    let refreshed: Bool
    fileprivate let baseline: GestureAssignmentContext

    fileprivate init(edit: GestureAssignmentEdit, baseline: GestureAssignmentContext, refreshed: Bool = false) {
        self.edit = edit
        self.baseline = baseline
        self.refreshed = refreshed
        let candidate = edit.applying(to: baseline.gestures)
        conflict = baseline.conflict(in: candidate)
        let otherActions = GestureAssignmentAction.allCases.filter {
            $0 != edit.action && $0.isEnabled(in: candidate)
        }
        let validMasks = (0 ..< (1 << otherActions.count)).filter { mask in
            let resolution = Self.resolution(mask: mask, actions: otherActions)
            return baseline.conflict(in: resolution.applying(to: candidate)) == nil
        }
        resolutions = validMasks.filter { mask in
            !validMasks.contains { other in other != mask && other & mask == other }
        }.map { Self.resolution(mask: $0, actions: otherActions) }
    }

    private static func resolution(mask: Int, actions: [GestureAssignmentAction]) -> GestureAssignmentResolution {
        GestureAssignmentResolution(disabledActions: actions.enumerated().compactMap { index, action in
            mask & (1 << index) == 0 ? nil : action
        })
    }
}

private struct GestureAssignmentContext: Equatable {
    let gestures: SettingsExport.Gestures
    let orientationOverrides: [MonitorOrientationSettings]
    let monitors: [Monitor]

    @MainActor
    init(settings: SettingsStore, monitors: [Monitor]) {
        gestures = settings.gestures.export()
        orientationOverrides = settings.monitors.orientationOverrides
        self.monitors = monitors
    }

    func conflict(in candidate: SettingsExport.Gestures) -> TrackpadGestureConflict? {
        GestureSettingsValidation.conflict(
            gestures: candidate,
            orientationOverrides: orientationOverrides,
            monitors: monitors
        )
    }
}

@MainActor @Observable
final class GestureAssignmentEditor {
    var proposal: GestureAssignmentProposal?

    func submit(_ edit: GestureAssignmentEdit, settings: SettingsStore, monitors: [Monitor]) {
        let context = GestureAssignmentContext(settings: settings, monitors: monitors)
        if settings.updateGestureSettings(edit.applying(to: context.gestures), monitors: monitors) == nil {
            proposal = nil
        } else {
            proposal = GestureAssignmentProposal(edit: edit, baseline: context)
        }
    }

    func confirm(_ resolution: GestureAssignmentResolution, settings: SettingsStore, monitors: [Monitor]) {
        guard let proposal else { return }
        let context = GestureAssignmentContext(settings: settings, monitors: monitors)
        guard context == proposal.baseline else {
            self.proposal = GestureAssignmentProposal(edit: proposal.edit, baseline: context, refreshed: true)
            return
        }
        guard proposal.resolutions.contains(resolution) else { return }
        let candidate = resolution.applying(to: proposal.edit.applying(to: context.gestures))
        if settings.updateGestureSettings(candidate, monitors: monitors) == nil {
            self.proposal = nil
        } else {
            self.proposal = GestureAssignmentProposal(edit: proposal.edit, baseline: context, refreshed: true)
        }
    }

    func cancel() {
        proposal = nil
    }

    func refresh(settings: SettingsStore, monitors: [Monitor]) {
        guard let proposal else { return }
        let context = GestureAssignmentContext(settings: settings, monitors: monitors)
        guard context != proposal.baseline else { return }
        self.proposal = GestureAssignmentProposal(edit: proposal.edit, baseline: context, refreshed: true)
    }

    static func conflict(
        enabling action: GestureAssignmentAction,
        settings: SettingsStore,
        monitors: [Monitor]
    ) -> TrackpadGestureConflict? {
        let context = GestureAssignmentContext(settings: settings, monitors: monitors)
        return context.conflict(in: GestureAssignmentEdit(action: action, change: .enabled(true))
            .applying(to: context.gestures))
    }
}
