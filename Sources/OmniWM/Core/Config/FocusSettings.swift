// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class FocusSettings {
    private nonisolated static let defaults = SettingsExport.Focus.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var followsMouse = FocusSettings.defaults.followsMouse {
        didSet { onChange?() }
    }

    var raiseOnMouseFocus = FocusSettings.defaults.raiseOnMouseFocus {
        didSet { onChange?() }
    }

    var lockModifier = FocusSettings.defaults.lockModifier {
        didSet { onChange?() }
    }

    var moveMouseToFocusedWindow = FocusSettings.defaults.moveMouseToFocusedWindow {
        didSet { onChange?() }
    }

    var followsWindowToMonitor = FocusSettings.defaults.followsWindowToMonitor {
        didSet { onChange?() }
    }

    var crossesMonitorAtEdge = FocusSettings.defaults.crossesMonitorAtEdge {
        didSet { onChange?() }
    }

    var moveCrossesMonitorAtEdge = FocusSettings.defaults.moveCrossesMonitorAtEdge {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Focus {
        SettingsExport.Focus(
            followsMouse: followsMouse,
            raiseOnMouseFocus: raiseOnMouseFocus,
            lockModifier: lockModifier,
            moveMouseToFocusedWindow: moveMouseToFocusedWindow,
            followsWindowToMonitor: followsWindowToMonitor,
            crossesMonitorAtEdge: crossesMonitorAtEdge,
            moveCrossesMonitorAtEdge: moveCrossesMonitorAtEdge
        )
    }

    func apply(_ focus: SettingsExport.Focus) {
        followsMouse = focus.followsMouse
        raiseOnMouseFocus = focus.raiseOnMouseFocus
        lockModifier = focus.lockModifier
        moveMouseToFocusedWindow = focus.moveMouseToFocusedWindow
        followsWindowToMonitor = focus.followsWindowToMonitor
        crossesMonitorAtEdge = focus.crossesMonitorAtEdge
        moveCrossesMonitorAtEdge = focus.moveCrossesMonitorAtEdge
    }
}
