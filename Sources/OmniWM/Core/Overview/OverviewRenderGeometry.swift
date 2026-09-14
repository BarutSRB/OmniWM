// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

enum OverviewRenderGeometry {
    static func visibleContentRect(bounds: CGRect, scrollOffset: CGFloat) -> CGRect {
        return bounds.offsetBy(dx: 0, dy: scrollOffset)
    }

    static func shouldRender(frame: CGRect, visibleContentRect: CGRect) -> Bool {
        frame.intersects(visibleContentRect.insetBy(dx: -8, dy: -8))
    }

    static func sectionCullingFrame(
        _ section: OverviewWorkspaceSection,
        progress: Double
    ) -> CGRect {
        section.windows.reduce(section.sectionFrame.union(section.labelFrame)) { frame, window in
            frame.union(window.interpolatedFrame(progress: progress))
        }
    }

    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let fittedSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - fittedSize.width) / 2,
            y: bounds.minY + (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
