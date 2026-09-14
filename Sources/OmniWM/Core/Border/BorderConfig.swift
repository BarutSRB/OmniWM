// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics

struct BorderConfig: Equatable {
    struct ResolvedGeometry {
        let targetFrame: CGRect
        let ringFrame: CGRect
        let surfaceFrame: CGRect
        let width: CGFloat
        let surfacePadding: CGFloat
    }

    var enabled: Bool
    var width: CGFloat
    var color: SettingsColor
    var gradient: BorderGradient?
    var glow: BorderGlow?

    /// Creates border geometry and optional appearance effects.
    init(
        enabled: Bool = true,
        width: CGFloat = 5.0,
        color: SettingsColor = SettingsColor(
            red: 0.084585202284378935,
            green: 1.0,
            blue: 0.97930003794467602,
            alpha: 1.0
        ),
        gradient: BorderGradient? = nil,
        glow: BorderGlow? = nil
    ) {
        self.enabled = enabled
        self.width = width
        self.color = color
        self.gradient = gradient
        self.glow = glow
    }

    /// Builds the render configuration from the live settings store.
    @MainActor static func from(settings: SettingsStore) -> BorderConfig {
        from(settings: settings, isDark: systemAppearanceUsesDarkAqua)
    }

    /// Builds the render configuration with colors resolved for an appearance.
    @MainActor static func from(settings: SettingsStore, isDark: Bool) -> BorderConfig {
        BorderConfig(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth),
            color: resolvedColor(settings.borderColor, dark: settings.borderColorDark, isDark: isDark),
            gradient: settings.borderGradient.map { resolvedGradient($0, isDark: isDark) },
            glow: settings.borderGlow
        )
    }

    /// Reports whether the system appearance currently resolves to dark Aqua.
    @MainActor static var systemAppearanceUsesDarkAqua: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Returns the appearance-resolved color, falling back to the base color.
    static func resolvedColor(
        _ base: SettingsColor,
        dark: SettingsColor?,
        isDark: Bool
    ) -> SettingsColor {
        isDark ? (dark ?? base) : base
    }

    /// Returns a gradient whose endpoint colors are resolved for an appearance.
    static func resolvedGradient(_ gradient: BorderGradient, isDark: Bool) -> BorderGradient {
        var resolved = gradient
        resolved.start = resolvedColor(gradient.start, dark: gradient.dark?.start, isDark: isDark)
        resolved.end = resolvedColor(gradient.end, dark: gradient.dark?.end, isDark: isDark)
        resolved.dark = nil
        return resolved
    }

    /// Returns width-based layout clearance without glow padding.
    static func layoutClearance(enabled: Bool, width: CGFloat, scale: CGFloat) -> CGFloat {
        guard enabled else { return 0 }
        let effectiveScale = max(scale, 1)
        return ceil(max(0, width) * effectiveScale) / effectiveScale
    }

    /// Resolves physical-pixel target, ring, and private overlay frames.
    func resolvedGeometry(
        for targetFrame: CGRect,
        scale: CGFloat
    ) -> ResolvedGeometry {
        let targetFrame = targetFrame.roundedToPhysicalPixels(scale: scale)
        let width = Self.layoutClearance(enabled: enabled, width: width, scale: scale)
        let surfacePadding = Self.renderPadding(glow: glow, scale: scale)
        let ringFrame = targetFrame.insetBy(dx: -width, dy: -width)
        return ResolvedGeometry(
            targetFrame: targetFrame,
            ringFrame: ringFrame,
            surfaceFrame: ringFrame.insetBy(dx: -surfacePadding, dy: -surfacePadding),
            width: width,
            surfacePadding: surfacePadding
        )
    }

    /// Returns the physical-pixel-aligned overlay padding for a glow.
    static func renderPadding(glow: BorderGlow?, scale: CGFloat) -> CGFloat {
        guard glow?.enabled == true else { return 0 }
        let effectiveScale = max(scale, 1)
        let radius = min(max(glow?.radius ?? 0, 0), 32)
        // The 1.5× falloff budget leaves the band glow fully inside the
        // overlay surface while preserving a zero-alpha outer edge.
        return ceil(CGFloat(radius) * 1.5 * effectiveScale) / effectiveScale
    }
}
