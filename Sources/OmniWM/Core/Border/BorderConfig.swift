// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

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
        return BorderConfig(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth),
            color: settings.borderColor,
            gradient: settings.borderGradient,
            glow: settings.borderGlow
        )
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
