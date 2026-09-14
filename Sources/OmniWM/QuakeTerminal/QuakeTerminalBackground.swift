// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
final class QuakeTerminalBackground {
    private var glassEffectView: QuakeTerminalGlassView?
    private var ghosttyAppearance: QuakeGhosttyAppearance?
    private var appliedBackgroundBlurRadius: Int?
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func updateAppearance(_ appearance: QuakeGhosttyAppearance?) -> Bool {
        guard ghosttyAppearance != appearance else { return false }
        ghosttyAppearance = appearance
        return true
    }

    func reconcile(in containerView: NSView?, window: NSWindow?) {
        if let appearance = ghosttyAppearance,
           let glassStyle = appearance.glassStyle,
           let containerView
        {
            let effectView = makeGlassEffectView(in: containerView)
            let style: NSGlassEffectView.Style = switch glassStyle {
            case .regular:
                .regular
            case .clear:
                .clear
            }
            let color = ghosttyBackgroundColor(for: appearance)
            effectView.configure(
                style: style,
                backgroundColor: color,
                backgroundOpacity: appearance.opacity,
                isKeyWindow: window?.isKeyWindow == true
            )
        } else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
        }

        applyBackgroundBlur(to: window)
    }

    private func ghosttyBackgroundColor(for appearance: QuakeGhosttyAppearance) -> NSColor {
        guard let backgroundColor = appearance.backgroundColor else {
            return .windowBackgroundColor
        }
        return NSColor(
            srgbRed: CGFloat(backgroundColor.red) / 255,
            green: CGFloat(backgroundColor.green) / 255,
            blue: CGFloat(backgroundColor.blue) / 255,
            alpha: 1
        )
    }

    func updateKeyStatus(_ isKeyWindow: Bool) {
        guard let ghosttyAppearance else { return }
        glassEffectView?.updateKeyStatus(
            isKeyWindow,
            backgroundColor: ghosttyBackgroundColor(for: ghosttyAppearance)
        )
    }

    private func makeGlassEffectView(in containerView: NSView) -> QuakeTerminalGlassView {
        if let glassEffectView {
            return glassEffectView
        }

        let effectView = QuakeTerminalGlassView(frame: containerView.bounds)
        effectView.autoresizingMask = [.width, .height]
        if let bottomSubview = containerView.subviews.first {
            containerView.addSubview(effectView, positioned: .below, relativeTo: bottomSubview)
        } else {
            containerView.addSubview(effectView)
        }
        glassEffectView = effectView
        return effectView
    }

    private func applyBackgroundBlur(to window: NSWindow?) {
        let radius = QuakeTerminalAppearancePolicy.effectiveBackgroundBlurRadius(
            settings.quakeTerminal.backgroundBlurRadius,
            glassEffectActive: ghosttyAppearance?.glassStyle != nil
        )
        applyBlurRadius(radius, to: window)
    }

    func applyBlurRadius(_ radius: Int, to window: NSWindow?) {
        guard let window, window.isVisible else { return }
        let windowNumber = window.windowNumber
        guard windowNumber > 0 else { return }
        guard appliedBackgroundBlurRadius != radius else { return }
        guard SkyLight.shared.setWindowBackgroundBlurRadius(UInt32(windowNumber), radius: radius) else { return }
        appliedBackgroundBlurRadius = radius
    }

    func reset() {
        appliedBackgroundBlurRadius = nil
        glassEffectView = nil
        ghosttyAppearance = nil
    }
}
