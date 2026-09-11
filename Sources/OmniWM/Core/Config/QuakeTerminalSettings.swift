// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor @Observable
final class QuakeTerminalSettings {
    private(set) var enabled: Bool
    private(set) var position: QuakeTerminalPosition
    private(set) var widthPercent: Double
    private(set) var heightPercent: Double
    private(set) var animationDuration: Double
    private(set) var autoHide: Bool
    private(set) var opacity: Double
    private(set) var backgroundEffect: QuakeTerminalBackgroundEffect
    private(set) var backgroundBlurRadius: Int
    private(set) var monitorMode: QuakeTerminalMonitorMode

    init(values: SettingsExport.QuakeTerminal) {
        enabled = values.enabled
        position = values.position
        widthPercent = values.widthPercent
        heightPercent = values.heightPercent
        animationDuration = values.animationDuration
        autoHide = values.autoHide
        opacity = values.opacity ?? 1.0
        backgroundEffect = values.backgroundEffect
        backgroundBlurRadius = values.backgroundBlurRadius ?? QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        monitorMode = values.monitorMode ?? .focusedWindow
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

    fileprivate func setEnabled(_ value: Bool, didChange: () -> Void) {
        enabled = value
        didChange()
    }

    fileprivate func setPosition(_ value: QuakeTerminalPosition, didChange: () -> Void) {
        position = value
        didChange()
    }

    fileprivate func setWidthPercent(_ value: Double, didChange: () -> Void) {
        widthPercent = value
        let normalized = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(widthPercent)
        if normalized != widthPercent {
            setWidthPercent(normalized, didChange: didChange)
            return
        }
        didChange()
    }

    fileprivate func setHeightPercent(_ value: Double, didChange: () -> Void) {
        heightPercent = value
        let normalized = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(heightPercent)
        if normalized != heightPercent {
            setHeightPercent(normalized, didChange: didChange)
            return
        }
        didChange()
    }

    fileprivate func setAnimationDuration(_ value: Double, didChange: () -> Void) {
        animationDuration = value
        didChange()
    }

    fileprivate func setAutoHide(_ value: Bool, didChange: () -> Void) {
        autoHide = value
        didChange()
    }

    fileprivate func setOpacity(_ value: Double, didChange: () -> Void) {
        opacity = value
        didChange()
    }

    fileprivate func setBackgroundEffect(_ value: QuakeTerminalBackgroundEffect, didChange: () -> Void) {
        backgroundEffect = value
        didChange()
    }

    fileprivate func setBackgroundBlurRadius(_ value: Int, didChange: () -> Void) {
        backgroundBlurRadius = value
        let normalized = QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(backgroundBlurRadius)
        if normalized != backgroundBlurRadius {
            setBackgroundBlurRadius(normalized, didChange: didChange)
            return
        }
        didChange()
    }

    fileprivate func setMonitorMode(_ value: QuakeTerminalMonitorMode, didChange: () -> Void) {
        monitorMode = value
        didChange()
    }

    fileprivate func apply(
        _ values: SettingsExport.QuakeTerminal,
        baseline: SettingsExport.QuakeTerminal,
        didChange: () -> Void
    ) {
        setEnabled(values.enabled, didChange: didChange)
        setPosition(values.position, didChange: didChange)
        setWidthPercent(
            QuakeTerminalGeometryPolicy
                .normalizedDimensionPercent(values.widthPercent),
            didChange: didChange
        )
        setHeightPercent(
            QuakeTerminalGeometryPolicy
                .normalizedDimensionPercent(values.heightPercent),
            didChange: didChange
        )
        setAnimationDuration(values.animationDuration, didChange: didChange)
        setAutoHide(values.autoHide, didChange: didChange)
        setOpacity(values.opacity ?? baseline.opacity ?? 1.0, didChange: didChange)
        setBackgroundEffect(values.backgroundEffect, didChange: didChange)
        setBackgroundBlurRadius(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(
            values.backgroundBlurRadius
                ?? baseline.backgroundBlurRadius
                ?? QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        ), didChange: didChange)
        setMonitorMode(
            values.monitorMode ?? baseline
                .monitorMode ?? .focusedWindow,
            didChange: didChange
        )
    }
}

extension SettingsStore {
    func setQuakeTerminalEnabled(_ value: Bool) {
        quakeTerminal.setEnabled(value, didChange: scheduleSave)
    }

    func setQuakeTerminalPosition(_ value: QuakeTerminalPosition) {
        quakeTerminal.setPosition(value, didChange: scheduleSave)
    }

    func setQuakeTerminalWidthPercent(_ value: Double) {
        quakeTerminal.setWidthPercent(value, didChange: scheduleSave)
    }

    func setQuakeTerminalHeightPercent(_ value: Double) {
        quakeTerminal.setHeightPercent(value, didChange: scheduleSave)
    }

    func setQuakeTerminalAnimationDuration(_ value: Double) {
        quakeTerminal.setAnimationDuration(value, didChange: scheduleSave)
    }

    func setQuakeTerminalAutoHide(_ value: Bool) {
        quakeTerminal.setAutoHide(value, didChange: scheduleSave)
    }

    func setQuakeTerminalOpacity(_ value: Double) {
        quakeTerminal.setOpacity(value, didChange: scheduleSave)
    }

    func setQuakeTerminalBackgroundEffect(_ value: QuakeTerminalBackgroundEffect) {
        quakeTerminal.setBackgroundEffect(value, didChange: scheduleSave)
    }

    func setQuakeTerminalBackgroundBlurRadius(_ value: Int) {
        quakeTerminal.setBackgroundBlurRadius(value, didChange: scheduleSave)
    }

    func setQuakeTerminalMonitorMode(_ value: QuakeTerminalMonitorMode) {
        quakeTerminal.setMonitorMode(value, didChange: scheduleSave)
    }

    func applyQuakeTerminal(
        _ values: SettingsExport.QuakeTerminal,
        baseline: SettingsExport.QuakeTerminal
    ) {
        quakeTerminal.apply(values, baseline: baseline, didChange: scheduleSave)
    }
}
