// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class BorderSettings {
    private(set) var enabled: Bool
    private(set) var width: Double
    private(set) var color: SettingsColor

    init(values: SettingsExport.Borders) {
        enabled = values.enabled
        width = values.width
        color = SettingsColor(
            red: values.color.red,
            green: values.color.green,
            blue: values.color.blue,
            alpha: values.color.alpha
        )
    }

    func export() -> SettingsExport.Borders {
        SettingsExport.Borders(
            enabled: enabled,
            width: width,
            color: SettingsColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
        )
    }

    fileprivate func setEnabled(_ value: Bool, didChange: () -> Void) {
        enabled = value
        didChange()
    }

    fileprivate func setWidth(_ value: Double, didChange: () -> Void) {
        width = value
        didChange()
    }

    fileprivate func setColor(_ value: SettingsColor, didChange: () -> Void) {
        color = value
        didChange()
    }

    fileprivate func apply(_ values: SettingsExport.Borders, didChange: () -> Void) {
        setEnabled(values.enabled, didChange: didChange)
        setWidth(Self.validatedWidth(values.width), didChange: didChange)
        setColor(SettingsColor(
            red: Self.validatedColorComponent(values.color.red),
            green: Self.validatedColorComponent(values.color.green),
            blue: Self.validatedColorComponent(values.color.blue),
            alpha: Self.validatedColorComponent(values.color.alpha)
        ), didChange: didChange)
    }

    private static func validatedWidth(_ width: Double) -> Double {
        min(12.0, max(1.0, width))
    }

    private static func validatedColorComponent(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

extension SettingsStore {
    func setBordersEnabled(_ value: Bool) {
        borders.setEnabled(value, didChange: scheduleSave)
    }

    func setBorderWidth(_ value: Double) {
        borders.setWidth(value, didChange: scheduleSave)
    }

    func setBorderColor(_ value: SettingsColor) {
        borders.setColor(value, didChange: scheduleSave)
    }

    func applyBorders(_ values: SettingsExport.Borders) {
        borders.apply(values, didChange: scheduleSave)
    }
}
