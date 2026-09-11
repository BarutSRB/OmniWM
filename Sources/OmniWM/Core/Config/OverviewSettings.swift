// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class OverviewSettings {
    private static let defaultZoom = SettingsExport.Overview.defaults().zoom

    private(set) var zoom: Double
    private(set) var backdropColor: SettingsColor
    private(set) var normalBorderColor: SettingsColor
    private(set) var hoveredBorderColor: SettingsColor
    private(set) var selectedBorderColor: SettingsColor

    init(values: SettingsExport.Overview) {
        zoom = values.zoom
        backdropColor = values.backdrop
        normalBorderColor = values.windowBorders.normal
        hoveredBorderColor = values.windowBorders.hovered
        selectedBorderColor = values.windowBorders.selected
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

    fileprivate func setZoom(_ value: Double, didChange: () -> Void) {
        zoom = value
        didChange()
    }

    fileprivate func setBackdropColor(_ value: SettingsColor, didChange: () -> Void) {
        backdropColor = value
        didChange()
    }

    fileprivate func setNormalBorderColor(_ value: SettingsColor, didChange: () -> Void) {
        normalBorderColor = value
        didChange()
    }

    fileprivate func setHoveredBorderColor(_ value: SettingsColor, didChange: () -> Void) {
        hoveredBorderColor = value
        didChange()
    }

    fileprivate func setSelectedBorderColor(_ value: SettingsColor, didChange: () -> Void) {
        selectedBorderColor = value
        didChange()
    }

    fileprivate func apply(
        _ values: SettingsExport.Overview,
        baseline: SettingsExport.Overview,
        didChange: () -> Void
    ) {
        setZoom(Self.validatedZoom(values.zoom), didChange: didChange)
        setBackdropColor(Self.validatedColor(
            values.backdrop,
            default: baseline.backdrop
        ), didChange: didChange)
        setNormalBorderColor(Self.validatedColor(
            values.windowBorders.normal,
            default: baseline.windowBorders.normal
        ), didChange: didChange)
        setHoveredBorderColor(Self.validatedColor(
            values.windowBorders.hovered,
            default: baseline.windowBorders.hovered
        ), didChange: didChange)
        setSelectedBorderColor(Self.validatedColor(
            values.windowBorders.selected,
            default: baseline.windowBorders.selected
        ), didChange: didChange)
    }

    private static func validatedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return defaultZoom }
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

extension SettingsStore {
    func setOverviewZoom(_ value: Double) {
        overview.setZoom(value, didChange: scheduleSave)
    }

    func setOverviewBackdropColor(_ value: SettingsColor) {
        overview.setBackdropColor(value, didChange: scheduleSave)
    }

    func setOverviewNormalBorderColor(_ value: SettingsColor) {
        overview.setNormalBorderColor(value, didChange: scheduleSave)
    }

    func setOverviewHoveredBorderColor(_ value: SettingsColor) {
        overview.setHoveredBorderColor(value, didChange: scheduleSave)
    }

    func setOverviewSelectedBorderColor(_ value: SettingsColor) {
        overview.setSelectedBorderColor(value, didChange: scheduleSave)
    }

    func applyOverview(_ values: SettingsExport.Overview, baseline: SettingsExport.Overview) {
        overview.apply(values, baseline: baseline, didChange: scheduleSave)
    }
}
