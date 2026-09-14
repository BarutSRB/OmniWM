// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct TrackpadGestureConflict: Error, Equatable, LocalizedError {
    let fingerCount: Int
    let otherGesture: TrackpadGestureMode

    var errorDescription: String? {
        let otherName = switch otherGesture {
        case .columnScroll: "Niri column scrolling"
        case .workspaceSwitch: "workspace switching"
        case .overview: "Overview"
        }
        return "Overview and \(otherName) both use a \(fingerCount)-finger upward swipe. "
            + "Choose different fingers or disable one gesture."
    }
}

enum GestureSettingsValidation {
    static func validate(_ export: SettingsExport, monitorProvider: () -> [Monitor]) throws {
        guard export.gestures.overviewGestureEnabled == true else { return }
        if let conflict = conflict(
            gestures: export.gestures,
            orientationOverrides: export.monitorOrientationSettings,
            monitors: monitorProvider()
        ) {
            throw conflict
        }
    }

    static func conflict(
        gestures: SettingsExport.Gestures,
        orientationOverrides: [MonitorOrientationSettings],
        monitors: [Monitor]
    ) -> TrackpadGestureConflict? {
        guard gestures.overviewGestureEnabled == true else { return nil }
        let config = TrackpadGestureIntent.Config(
            columnScrollEnabled: gestures.scrollEnabled,
            columnScrollFingerCount: gestures.fingerCount.rawValue,
            workspaceSwipeEnabled: gestures.workspaceSwipeEnabled,
            workspaceSwipeFingerCount: gestures.workspaceSwipeFingerCount.rawValue,
            workspaceSwipeAxis: gestures.workspaceSwipeAxis,
            overviewEnabled: true,
            overviewFingerCount: (gestures.overviewGestureFingerCount ?? .four).rawValue
        )
        if let other = TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: nil) {
            return TrackpadGestureConflict(fingerCount: config.overviewFingerCount, otherGesture: other)
        }
        for monitor in monitors {
            let orientation = MonitorSettingsStore.get(for: monitor, in: orientationOverrides)?.orientation
                ?? monitor.autoOrientation
            if let other = TrackpadGestureIntent.overviewConflict(
                config,
                columnScrollAxis: orientation == .horizontal ? .horizontal : .vertical
            ) {
                return TrackpadGestureConflict(fingerCount: config.overviewFingerCount, otherGesture: other)
            }
        }
        return nil
    }
}
