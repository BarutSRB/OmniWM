// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct BorderConfig: Equatable {
    struct ResolvedGeometry {
        let targetFrame: CGRect
        let surfaceFrame: CGRect
        let width: CGFloat
        let surfacePadding: CGFloat

        func localized() -> Self {
            let localSurfaceFrame = CGRect(origin: .zero, size: surfaceFrame.size)
            let inset = width + surfacePadding
            return Self(
                targetFrame: CGRect(
                    origin: CGPoint(x: inset, y: inset),
                    size: targetFrame.size
                ),
                surfaceFrame: localSurfaceFrame,
                width: width,
                surfacePadding: surfacePadding
            )
        }
    }

    var enabled: Bool
    var width: CGFloat
    var color: SettingsColor
    var gradient: BorderGradient?
    var glow: BorderGlow?

    init(
        enabled: Bool = false,
        width: CGFloat = 4.0,
        color: SettingsColor = SettingsColor(red: 0, green: 0.478_431_372_5, blue: 1, alpha: 1),
        gradient: BorderGradient? = nil,
        glow: BorderGlow? = nil
    ) {
        self.enabled = enabled
        self.width = width
        self.color = color
        self.gradient = gradient
        self.glow = glow
    }

    @MainActor static func from(settings: SettingsStore, isDark: Bool) -> BorderConfig {
        BorderConfig(
            enabled: settings.borders.enabled,
            width: CGFloat(settings.borders.width),
            color: resolvedColor(settings.borders.color, dark: settings.borders.darkColor, isDark: isDark),
            gradient: settings.borders.gradient.map { resolvedGradient($0, isDark: isDark) },
            glow: settings.borders.glow.map { resolvedGlow($0, isDark: isDark) }
        )
    }

    static func resolvedColor(
        _ base: SettingsColor,
        dark: SettingsColor?,
        isDark: Bool
    ) -> SettingsColor {
        isDark ? (dark ?? base) : base
    }

    static func resolvedGradient(_ gradient: BorderGradient, isDark: Bool) -> BorderGradient {
        var resolved = gradient
        resolved.start = resolvedColor(gradient.start, dark: gradient.dark?.start, isDark: isDark)
        resolved.end = resolvedColor(gradient.end, dark: gradient.dark?.end, isDark: isDark)
        resolved.dark = nil
        return resolved
    }

    static func resolvedGlow(_ glow: BorderGlow, isDark: Bool) -> BorderGlow {
        var resolved = glow
        resolved.color = resolvedOptionalColor(glow.color, dark: glow.darkColor, isDark: isDark)
        resolved.darkColor = nil
        return resolved
    }

    private static func resolvedOptionalColor(
        _ base: SettingsColor?,
        dark: SettingsColor?,
        isDark: Bool
    ) -> SettingsColor? {
        isDark ? (dark ?? base) : base
    }

    static func layoutClearance(enabled: Bool, width: CGFloat, scale: CGFloat) -> CGFloat {
        guard enabled else { return 0 }
        let effectiveScale = max(scale, 1)
        return ceil(max(0, width) * effectiveScale) / effectiveScale
    }

    static func renderPadding(glow: BorderGlow?, scale: CGFloat) -> CGFloat {
        guard glow?.enabled == true else { return 0 }
        let effectiveScale = max(scale, 1)
        let radius = min(max(glow?.radius ?? 0, 0), 32)
        return ceil(CGFloat(radius) * 1.5 * effectiveScale) / effectiveScale
    }

    func resolvedGeometry(
        for targetFrame: CGRect,
        scale: CGFloat
    ) -> ResolvedGeometry {
        let targetFrame = targetFrame.roundedToPhysicalPixels(scale: scale)
        let width = Self.layoutClearance(enabled: enabled, width: width, scale: scale)
        let surfacePadding = Self.renderPadding(glow: glow, scale: scale)
        return ResolvedGeometry(
            targetFrame: targetFrame,
            surfaceFrame: targetFrame.insetBy(dx: -(width + surfacePadding), dy: -(width + surfacePadding)),
            width: width,
            surfacePadding: surfacePadding
        )
    }
}
