// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import QuartzCore

struct OverviewRenderState {
    let searchQuery: String
    let selectedWindowHandle: WindowHandle?
    let hoveredWindowHandle: WindowHandle?
    let closeButtonHovered: Bool
    let progress: Double
    let bounds: CGRect
    let palette: OverviewRenderPalette
}

enum OverviewRenderer {
    static func borderColor(
        isSelected: Bool,
        isHovered: Bool,
        palette: OverviewRenderPalette
    ) -> CGColor {
        if isSelected { return palette.selectedBorder }
        if isHovered { return palette.hoveredBorder }
        return palette.normalBorder
    }

    @MainActor
    static func textLayer(size: CGFloat, color: CGColor, alignment: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let layer = CATextLayer()
        layer.font = NSFont.systemFont(ofSize: size)
        layer.fontSize = size
        layer.foregroundColor = color
        layer.alignmentMode = alignment
        layer.truncationMode = .end
        return layer
    }

    @MainActor
    static func withoutAnimation(_ update: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }
}
