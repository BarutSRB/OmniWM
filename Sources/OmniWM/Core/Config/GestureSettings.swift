// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class GestureSettings {
    private nonisolated static let defaults = SettingsExport.Gestures.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored var onAvailabilityChanged: ((Bool) -> Void)?

    private nonisolated static let scrollSensitivityRange = 0.1 ... 100.0

    private nonisolated static func normalizedScrollSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return defaults.scrollSensitivity }
        return min(max(value, scrollSensitivityRange.lowerBound), scrollSensitivityRange.upperBound)
    }

    var scrollEnabled = GestureSettings.defaults.scrollEnabled {
        didSet {
            guard oldValue != scrollEnabled else { return }
            if (oldValue || workspaceSwipeEnabled) != (scrollEnabled || workspaceSwipeEnabled) {
                onAvailabilityChanged?(scrollEnabled || workspaceSwipeEnabled)
            }
            onChange?()
        }
    }

    var scrollSensitivity = GestureSettings.defaults.scrollSensitivity {
        didSet {
            let normalized = GestureSettings.normalizedScrollSensitivity(scrollSensitivity)
            guard normalized == scrollSensitivity else {
                scrollSensitivity = normalized
                return
            }
            onChange?()
        }
    }

    var scrollModifierKey = GestureSettings.defaults.scrollModifierKey {
        didSet { onChange?() }
    }

    var mouseMoveModifierKey = GestureSettings.defaults.mouseMoveModifierKey {
        didSet { onChange?() }
    }

    var mouseResizeModifierKey = GestureSettings.defaults.mouseResizeModifierKey {
        didSet { onChange?() }
    }

    var fingerCount = GestureSettings.defaults.fingerCount {
        didSet { onChange?() }
    }

    var invertDirection = GestureSettings.defaults.invertDirection {
        didSet { onChange?() }
    }

    var trackpadScrollStyle = GestureSettings.defaults.trackpadScrollStyle {
        didSet { onChange?() }
    }

    var workspaceSwipeEnabled = GestureSettings.defaults.workspaceSwipeEnabled {
        didSet {
            guard oldValue != workspaceSwipeEnabled else { return }
            if (scrollEnabled || oldValue) != (scrollEnabled || workspaceSwipeEnabled) {
                onAvailabilityChanged?(scrollEnabled || workspaceSwipeEnabled)
            }
            onChange?()
        }
    }

    var workspaceSwipeFingerCount = GestureSettings.defaults.workspaceSwipeFingerCount {
        didSet { onChange?() }
    }

    var workspaceSwipeAxis = GestureSettings.defaults.workspaceSwipeAxis {
        didSet { onChange?() }
    }

    var workspaceSwipeAxisLockedToVertical: Bool {
        scrollEnabled && workspaceSwipeFingerCount == fingerCount
    }

    var effectiveWorkspaceSwipeAxis: WorkspaceSwipeAxis {
        workspaceSwipeAxisLockedToVertical ? .vertical : workspaceSwipeAxis
    }

    func export() -> SettingsExport.Gestures {
        SettingsExport.Gestures(
            scrollEnabled: scrollEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey,
            mouseMoveModifierKey: mouseMoveModifierKey,
            mouseResizeModifierKey: mouseResizeModifierKey,
            fingerCount: fingerCount,
            invertDirection: invertDirection,
            trackpadScrollStyle: trackpadScrollStyle,
            workspaceSwipeEnabled: workspaceSwipeEnabled,
            workspaceSwipeFingerCount: workspaceSwipeFingerCount,
            workspaceSwipeAxis: workspaceSwipeAxis
        )
    }

    func apply(_ gestures: SettingsExport.Gestures) {
        scrollEnabled = gestures.scrollEnabled
        scrollSensitivity = gestures.scrollSensitivity
        scrollModifierKey = gestures.scrollModifierKey
        mouseMoveModifierKey = gestures.mouseMoveModifierKey
        mouseResizeModifierKey = gestures.mouseResizeModifierKey
        fingerCount = gestures.fingerCount
        invertDirection = gestures.invertDirection
        trackpadScrollStyle = gestures.trackpadScrollStyle
        workspaceSwipeEnabled = gestures.workspaceSwipeEnabled
        workspaceSwipeFingerCount = gestures.workspaceSwipeFingerCount
        workspaceSwipeAxis = gestures.workspaceSwipeAxis
    }
}
