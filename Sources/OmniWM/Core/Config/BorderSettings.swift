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

    func export() -> SettingsExport.Borders {
        SettingsExport.Borders(enabled: enabled, width: width, color: color)
    }

    func apply(_ values: SettingsExport.Borders) {
        enabled = values.enabled
        width = Self.validatedWidth(values.width)
        color = SettingsColor(
            red: Self.validatedColorComponent(values.color.red),
            green: Self.validatedColorComponent(values.color.green),
            blue: Self.validatedColorComponent(values.color.blue),
            alpha: Self.validatedColorComponent(values.color.alpha)
        )
    }

    private static func validatedWidth(_ width: Double) -> Double {
        min(12.0, max(1.0, width))
    }

    private static func validatedColorComponent(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
