// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct TrackpadGestureConflict: Error, Equatable, LocalizedError {
    let fingerCount: Int
    let gesture: TrackpadGestureMode
    let otherGesture: TrackpadGestureMode

    var errorDescription: String? {
        let assignment = gesture == .overview(.open) ? "upward swipe" : "gesture"
        return "\(Self.name(for: gesture)) and \(Self.name(for: otherGesture)) both use a \(fingerCount)-finger \(assignment). "
            + "Choose different fingers or disable one gesture."
    }

    private static func name(for gesture: TrackpadGestureMode) -> String {
        switch gesture {
        case .columnScroll: "Niri column scrolling"
        case .workspaceSwitch: "workspace switching"
        case .overview: "Overview"
        case .windowMove: "window moving"
        case .windowResize: "window resizing"
        }
    }
}

enum GestureSettingsValidation {
    static func validate(_ export: SettingsExport, monitorProvider: () -> [Monitor]) throws {
        guard export.gestures.overviewGestureEnabled == true || export.gestures.windowMoveEnabled == true
            || export.gestures.windowResizeEnabled == true else { return }
        if let conflict = conflict(
            gestures: export.gestures,
            orientationOverrides: export.monitorOrientationSettings,
            monitors: export.gestures.overviewGestureEnabled == true ? monitorProvider() : []
        ) {
            throw conflict
        }
    }

    static func conflict(
        gestures: SettingsExport.Gestures,
        orientationOverrides: [MonitorOrientationSettings],
        monitors: [Monitor]
    ) -> TrackpadGestureConflict? {
        let config = TrackpadGestureIntent.Config(
            columnScrollEnabled: gestures.scrollEnabled,
            columnScrollFingerCount: gestures.fingerCount.rawValue,
            workspaceSwipeEnabled: gestures.workspaceSwipeEnabled,
            workspaceSwipeFingerCount: gestures.workspaceSwipeFingerCount.rawValue,
            workspaceSwipeAxis: gestures.workspaceSwipeAxis,
            overviewAction: gestures.overviewGestureEnabled == true ? .open : nil,
            overviewFingerCount: (gestures.overviewGestureFingerCount ?? .four).rawValue,
            windowMoveEnabled: gestures.windowMoveEnabled ?? false,
            windowMoveFingerCount: (gestures.windowMoveFingerCount ?? .four).rawValue,
            windowResizeEnabled: gestures.windowResizeEnabled ?? false,
            windowResizeFingerCount: (gestures.windowResizeFingerCount ?? .three).rawValue
        )
        for (enabled, mode, fingers) in [
            (config.windowMoveEnabled, TrackpadGestureMode.windowMove, config.windowMoveFingerCount),
            (config.windowResizeEnabled, .windowResize, config.windowResizeFingerCount)
        ] where enabled {
            if let other = TrackpadGestureIntent.windowGestureConflict(config, mode: mode) {
                return TrackpadGestureConflict(fingerCount: fingers, gesture: mode, otherGesture: other)
            }
        }
        guard gestures.overviewGestureEnabled == true else { return nil }
        if let other = TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: nil) {
            return TrackpadGestureConflict(
                fingerCount: config.overviewFingerCount,
                gesture: .overview(.open),
                otherGesture: other
            )
        }
        for monitor in monitors {
            let orientation = MonitorSettingsStore.get(for: monitor, in: orientationOverrides)?.orientation
                ?? monitor.autoOrientation
            if let other = TrackpadGestureIntent.overviewConflict(
                config,
                columnScrollAxis: orientation == .horizontal ? .horizontal : .vertical
            ) {
                return TrackpadGestureConflict(
                    fingerCount: config.overviewFingerCount,
                    gesture: .overview(.open),
                    otherGesture: other
                )
            }
        }
        return nil
    }
}
