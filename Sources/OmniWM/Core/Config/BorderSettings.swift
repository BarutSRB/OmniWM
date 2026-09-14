// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class BorderSettings {
    private nonisolated static let defaults = SettingsExport.Borders.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = BorderSettings.defaults.enabled {
        didSet { onChange?() }
    }

    var width = BorderSettings.defaults.width {
        didSet { onChange?() }
    }

    var color = BorderSettings.defaults.color {
        didSet { onChange?() }
    }

    var darkColor = BorderSettings.defaults.darkColor {
        didSet { onChange?() }
    }

    var gradient = BorderSettings.defaults.gradient {
        didSet { onChange?() }
    }

    var glow = BorderSettings.defaults.glow {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Borders {
        SettingsExport.Borders(
            enabled: enabled,
            width: width,
            color: color,
            darkColor: darkColor,
            gradient: gradient,
            glow: glow
        )
    }

    func apply(_ values: SettingsExport.Borders) {
        enabled = values.enabled
        width = Self.validatedWidth(values.width)
        color = Self.validatedColor(values.color)
        darkColor = values.darkColor.map(Self.validatedColor)
        gradient = Self.validatedGradient(values.gradient, fallback: gradient)
        glow = Self.validatedGlow(values.glow, fallback: glow)
    }

    private static func validatedWidth(_ width: Double) -> Double {
        min(12.0, max(1.0, width))
    }

    private static func validatedColorComponent(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    /// Clamps every component of a settings color into the unit interval.
    private static func validatedColor(_ color: SettingsColor) -> SettingsColor {
        SettingsColor(
            red: validatedColorComponent(color.red),
            green: validatedColorComponent(color.green),
            blue: validatedColorComponent(color.blue),
            alpha: validatedColorComponent(color.alpha)
        )
    }

    /// Reports whether every component of a settings color is finite.
    private static func isFinite(_ color: SettingsColor) -> Bool {
        color.red.isFinite && color.green.isFinite && color.blue.isFinite && color.alpha.isFinite
    }

    /// Validates gradient structure and clamps its finite color components.
    private static func validatedGradient(
        _ gradient: BorderGradient?,
        fallback: BorderGradient?
    ) -> BorderGradient? {
        guard var gradient else { return nil }
        guard isFinite(gradient.start),
              isFinite(gradient.end),
              gradient.dark.map({ isFinite($0.start) && isFinite($0.end) }) ?? true
        else {
            return fallback
        }
        gradient.start = validatedColor(gradient.start)
        gradient.end = validatedColor(gradient.end)
        if var dark = gradient.dark {
            dark.start = validatedColor(dark.start)
            dark.end = validatedColor(dark.end)
            gradient.dark = dark
        }
        return gradient
    }

    /// Validates the supported glow radius and opacity ranges.
    private static func validatedGlow(
        _ glow: BorderGlow?,
        fallback: BorderGlow?
    ) -> BorderGlow? {
        guard var glow else { return nil }
        guard glow.radius.isFinite, glow.opacity.isFinite,
              glow.radius >= 0, glow.radius <= 32,
              glow.opacity >= 0, glow.opacity <= 1
        else {
            return fallback
        }
        glow.radius = min(32, max(0, glow.radius))
        glow.opacity = min(1, max(0, glow.opacity))
        return glow
    }
}
