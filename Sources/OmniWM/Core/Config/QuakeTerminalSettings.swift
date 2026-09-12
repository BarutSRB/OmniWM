// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class QuakeTerminalSettings {
    private nonisolated static let defaults = SettingsExport.QuakeTerminal.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = QuakeTerminalSettings.defaults.enabled {
        didSet { onChange?() }
    }

    var position = QuakeTerminalSettings.defaults.position {
        didSet { onChange?() }
    }

    var widthPercent = QuakeTerminalSettings.defaults.widthPercent {
        didSet {
            let normalized = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(widthPercent)
            if normalized != widthPercent {
                widthPercent = normalized
                return
            }
            onChange?()
        }
    }

    var heightPercent = QuakeTerminalSettings.defaults.heightPercent {
        didSet {
            let normalized = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(heightPercent)
            if normalized != heightPercent {
                heightPercent = normalized
                return
            }
            onChange?()
        }
    }

    var animationDuration = QuakeTerminalSettings.defaults.animationDuration {
        didSet { onChange?() }
    }

    var autoHide = QuakeTerminalSettings.defaults.autoHide {
        didSet { onChange?() }
    }

    var opacity = QuakeTerminalSettings.defaults.opacity ?? 1.0 {
        didSet { onChange?() }
    }

    var backgroundEffect = QuakeTerminalSettings.defaults.backgroundEffect {
        didSet { onChange?() }
    }

    var backgroundBlurRadius = QuakeTerminalSettings.defaults.backgroundBlurRadius
        ?? QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
    {
        didSet {
            let normalized = QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(backgroundBlurRadius)
            if normalized != backgroundBlurRadius {
                backgroundBlurRadius = normalized
                return
            }
            onChange?()
        }
    }

    var monitorMode = QuakeTerminalSettings.defaults.monitorMode ?? .focusedWindow {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.QuakeTerminal {
        SettingsExport.QuakeTerminal(
            enabled: enabled,
            position: position,
            widthPercent: widthPercent,
            heightPercent: heightPercent,
            animationDuration: animationDuration,
            autoHide: autoHide,
            opacity: opacity,
            backgroundEffect: backgroundEffect,
            backgroundBlurRadius: backgroundBlurRadius,
            monitorMode: monitorMode
        )
    }

    func apply(_ values: SettingsExport.QuakeTerminal, baseline: SettingsExport.QuakeTerminal) {
        enabled = values.enabled
        position = values.position
        widthPercent = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(values.widthPercent)
        heightPercent = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(values.heightPercent)
        animationDuration = values.animationDuration
        autoHide = values.autoHide
        opacity = values.opacity ?? baseline.opacity ?? 1.0
        backgroundEffect = values.backgroundEffect
        backgroundBlurRadius = QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(
            values.backgroundBlurRadius
                ?? baseline.backgroundBlurRadius
                ?? QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        )
        monitorMode = values.monitorMode ?? baseline.monitorMode ?? .focusedWindow
    }
}
