// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class OverviewSettings {
    private nonisolated static let defaults = SettingsExport.Overview.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var zoom = OverviewSettings.defaults.zoom {
        didSet { onChange?() }
    }

    var backdropColor = OverviewSettings.defaults.backdrop {
        didSet { onChange?() }
    }

    var normalBorderColor = OverviewSettings.defaults.windowBorders.normal {
        didSet { onChange?() }
    }

    var hoveredBorderColor = OverviewSettings.defaults.windowBorders.hovered {
        didSet { onChange?() }
    }

    var selectedBorderColor = OverviewSettings.defaults.windowBorders.selected {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Overview {
        SettingsExport.Overview(
            zoom: zoom,
            backdrop: backdropColor,
            windowBorders: SettingsExport.OverviewWindowBorders(
                normal: normalBorderColor,
                hovered: hoveredBorderColor,
                selected: selectedBorderColor
            )
        )
    }

    func apply(_ values: SettingsExport.Overview, baseline: SettingsExport.Overview) {
        zoom = Self.validatedZoom(values.zoom)
        backdropColor = Self.validatedColor(values.backdrop, default: baseline.backdrop)
        normalBorderColor = Self.validatedColor(
            values.windowBorders.normal,
            default: baseline.windowBorders.normal
        )
        hoveredBorderColor = Self.validatedColor(
            values.windowBorders.hovered,
            default: baseline.windowBorders.hovered
        )
        selectedBorderColor = Self.validatedColor(
            values.windowBorders.selected,
            default: baseline.windowBorders.selected
        )
    }

    private static func validatedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return defaults.zoom }
        return min(1.5, max(0.5, value))
    }

    private static func validatedColor(_ color: SettingsColor, default defaultColor: SettingsColor) -> SettingsColor {
        SettingsColor(
            red: validatedColorComponent(color.red, default: defaultColor.red),
            green: validatedColorComponent(color.green, default: defaultColor.green),
            blue: validatedColorComponent(color.blue, default: defaultColor.blue),
            alpha: validatedColorComponent(color.alpha, default: defaultColor.alpha)
        )
    }

    private static func validatedColorComponent(_ value: Double, default defaultValue: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(1.0, max(0.0, value))
    }
}
