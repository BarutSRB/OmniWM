// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum QuakeTerminalGeometryPolicy {
    static let minimumDimensionPercent = 10.0
    static let maximumDimensionPercent = 100.0
    static let defaultDimensionPercent = 50.0
    static let minimumFrameWidthPoints: CGFloat = 200
    static let minimumFrameHeightPoints: CGFloat = 100
    static let maximumCustomFrameDimensionPoints: CGFloat = 100_000

    static func normalizedDimensionPercent(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDimensionPercent }
        return min(max(value, minimumDimensionPercent), maximumDimensionPercent)
    }

    static func configuredFrameSize(
        visibleFrame: CGRect,
        widthPercent: Double,
        heightPercent: Double
    ) -> CGSize {
        CGSize(
            width: visibleFrame.width * normalizedDimensionPercent(widthPercent) / 100.0,
            height: visibleFrame.height * normalizedDimensionPercent(heightPercent) / 100.0
        )
    }

    static func normalizedCustomFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame else { return nil }
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.size.width.isFinite,
              frame.size.height.isFinite,
              frame.size.width >= minimumFrameWidthPoints,
              frame.size.height >= minimumFrameHeightPoints,
              frame.size.width <= maximumCustomFrameDimensionPoints,
              frame.size.height <= maximumCustomFrameDimensionPoints
        else {
            return nil
        }
        return frame
    }
}
