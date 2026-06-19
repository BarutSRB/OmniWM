// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import GhosttyKit

struct GhosttySurfaceCellMetrics: Equatable {
    static let fallback = GhosttySurfaceCellMetrics(cellWidthPx: 1, cellHeightPx: 1)!

    let cellWidthPx: UInt32
    let cellHeightPx: UInt32

    init?(cellWidthPx: UInt32, cellHeightPx: UInt32) {
        guard cellWidthPx > 0, cellHeightPx > 0 else { return nil }
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
    }

    init?(surfaceSize: ghostty_surface_size_s) {
        self.init(
            cellWidthPx: surfaceSize.cell_width_px,
            cellHeightPx: surfaceSize.cell_height_px
        )
    }
}

struct GhosttySurfacePixelSize: Equatable {
    let widthPx: UInt32
    let heightPx: UInt32
}

enum GhosttySurfacePixelSizeNormalizer {
    private static let maxGhosttyGridCellCount = UInt64(UInt16.max)

    static func normalize(
        pointSize: CGSize,
        backingScale: CGFloat,
        cellMetrics: GhosttySurfaceCellMetrics?
    ) -> GhosttySurfacePixelSize? {
        guard pointSize.width.isFinite,
              pointSize.height.isFinite,
              pointSize.width > 0,
              pointSize.height > 0,
              backingScale.isFinite,
              backingScale > 0
        else {
            return nil
        }

        let scaledWidth = Double(pointSize.width) * Double(backingScale)
        let scaledHeight = Double(pointSize.height) * Double(backingScale)
        guard scaledWidth.isFinite,
              scaledHeight.isFinite,
              scaledWidth > 0,
              scaledHeight > 0
        else {
            return nil
        }

        let roundedWidth = ceil(scaledWidth)
        let roundedHeight = ceil(scaledHeight)
        guard roundedWidth.isFinite, roundedHeight.isFinite else { return nil }

        let metrics = cellMetrics ?? GhosttySurfaceCellMetrics.fallback
        let widthPx = UInt32(min(roundedWidth, Double(maxPixelDimension(for: metrics.cellWidthPx))))
        let heightPx = UInt32(min(roundedHeight, Double(maxPixelDimension(for: metrics.cellHeightPx))))

        return GhosttySurfacePixelSize(widthPx: widthPx, heightPx: heightPx)
    }

    private static func maxPixelDimension(for cellDimensionPx: UInt32) -> UInt32 {
        let product = maxGhosttyGridCellCount * UInt64(cellDimensionPx)
        return UInt32(min(product, UInt64(UInt32.max)))
    }
}
