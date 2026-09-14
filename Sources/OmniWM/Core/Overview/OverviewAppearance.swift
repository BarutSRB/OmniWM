// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

struct OverviewAppearance: Equatable {
    let backdrop: SettingsColor
    let normalBorder: SettingsColor
    let hoveredBorder: SettingsColor
    let selectedBorder: SettingsColor

    @MainActor
    init(settings: SettingsStore) {
        backdrop = settings.overview.backdropColor
        normalBorder = settings.overview.normalBorderColor
        hoveredBorder = settings.overview.hoveredBorderColor
        selectedBorder = settings.overview.selectedBorderColor
    }

    var renderPalette: OverviewRenderPalette {
        OverviewRenderPalette(
            backdropColor: backdrop,
            normalBorderColor: normalBorder,
            hoveredBorderColor: hoveredBorder,
            selectedBorderColor: selectedBorder
        )
    }
}

@MainActor
struct OverviewPresentation {
    private(set) var configuredScale: CGFloat
    private var appearance: OverviewAppearance
    private(set) var renderPalette: OverviewRenderPalette

    init(settings: SettingsStore) {
        appearance = OverviewAppearance(settings: settings)
        configuredScale = OverviewLayoutCalculator.clampedScale(CGFloat(settings.overview.zoom))
        renderPalette = appearance.renderPalette
    }

    mutating func update(settings: SettingsStore) -> (scaleChanged: Bool, appearanceChanged: Bool) {
        let nextConfiguredScale = OverviewLayoutCalculator.clampedScale(CGFloat(settings.overview.zoom))
        let nextAppearance = OverviewAppearance(settings: settings)
        let scaleChanged = abs(nextConfiguredScale - configuredScale) > OverviewViewportProjection.zoomEpsilon
        let appearanceChanged = nextAppearance != appearance
        configuredScale = nextConfiguredScale
        if appearanceChanged {
            appearance = nextAppearance
            renderPalette = nextAppearance.renderPalette
        }
        return (scaleChanged, appearanceChanged)
    }
}
