// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DwindleGapCalculator {
    static let sticksTolerance: CGFloat = 2.0

    static func applyGaps(
        nodeRect: CGRect,
        tilingArea: CGRect,
        settings: DwindleSettings
    ) -> CGRect {
        let atLeft = abs(nodeRect.minX - tilingArea.minX) < sticksTolerance
        let atRight = abs(nodeRect.maxX - tilingArea.maxX) < sticksTolerance
        let atBottom = abs(nodeRect.minY - tilingArea.minY) < sticksTolerance
        let atTop = abs(nodeRect.maxY - tilingArea.maxY) < sticksTolerance

        let leftGap = atLeft ? 0 : settings.innerGap / 2
        let rightGap = atRight ? 0 : settings.innerGap / 2
        let bottomGap = atBottom ? 0 : settings.innerGap / 2
        let topGap = atTop ? 0 : settings.innerGap / 2

        return CGRect(
            x: nodeRect.minX + leftGap,
            y: nodeRect.minY + bottomGap,
            width: max(1, nodeRect.width - leftGap - rightGap),
            height: max(1, nodeRect.height - topGap - bottomGap)
        )
    }
}
