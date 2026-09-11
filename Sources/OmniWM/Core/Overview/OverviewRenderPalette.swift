// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

struct OverviewRenderPalette {
    private struct Components: Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private static let backdropDefault = Components(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
    private static let normalBorderDefault = Components(red: 0.3, green: 0.3, blue: 0.35, alpha: 0.5)
    private static let hoveredBorderDefault = Components(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
    private static let selectedBorderDefault = Components(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)

    static let `default` = OverviewRenderPalette(
        backdrop: cgColor(backdropDefault),
        normalBorder: cgColor(normalBorderDefault),
        hoveredBorder: cgColor(hoveredBorderDefault),
        selectedBorder: cgColor(selectedBorderDefault)
    )

    let backdrop: CGColor
    let normalBorder: CGColor
    let hoveredBorder: CGColor
    let selectedBorder: CGColor

    init(
        backdropColor: SettingsColor,
        normalBorderColor: SettingsColor,
        hoveredBorderColor: SettingsColor,
        selectedBorderColor: SettingsColor
    ) {
        backdrop = Self.cgColor(backdropColor, fallback: Self.backdropDefault)
        normalBorder = Self.cgColor(normalBorderColor, fallback: Self.normalBorderDefault)
        hoveredBorder = Self.cgColor(hoveredBorderColor, fallback: Self.hoveredBorderDefault)
        selectedBorder = Self.cgColor(selectedBorderColor, fallback: Self.selectedBorderDefault)
    }

    private init(
        backdrop: CGColor,
        normalBorder: CGColor,
        hoveredBorder: CGColor,
        selectedBorder: CGColor
    ) {
        self.backdrop = backdrop
        self.normalBorder = normalBorder
        self.hoveredBorder = hoveredBorder
        self.selectedBorder = selectedBorder
    }

    private static func cgColor(_ color: SettingsColor, fallback: Components) -> CGColor {
        CGColor(
            red: component(color.red, fallback: fallback.red),
            green: component(color.green, fallback: fallback.green),
            blue: component(color.blue, fallback: fallback.blue),
            alpha: component(color.alpha, fallback: fallback.alpha)
        )
    }

    private static func cgColor(_ components: Components) -> CGColor {
        CGColor(
            red: CGFloat(components.red),
            green: CGFloat(components.green),
            blue: CGFloat(components.blue),
            alpha: CGFloat(components.alpha)
        )
    }

    private static func component(_ value: Double, fallback: Double) -> CGFloat {
        guard value.isFinite else { return CGFloat(fallback) }
        return CGFloat(min(max(value, 0), 1))
    }
}
