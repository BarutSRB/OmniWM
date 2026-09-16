// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

enum OverviewRenderGeometry {
    struct RestAnchor: Equatable {
        let overviewBounds: CGRect
        let restBounds: CGRect
    }

    static func restAnchor(for section: OverviewWorkspaceSection) -> RestAnchor? {
        let overviewBounds = section.windows.reduce(CGRect.null) { $0.union($1.overviewFrame) }
        let restBounds = section.windows.reduce(CGRect.null) { $0.union($1.originalFrame) }
        guard overviewBounds.width > 0, overviewBounds.height > 0,
              restBounds.width > 0, restBounds.height > 0,
              overviewBounds.width.isFinite, overviewBounds.height.isFinite,
              restBounds.width.isFinite, restBounds.height.isFinite
        else {
            return nil
        }
        return RestAnchor(overviewBounds: overviewBounds, restBounds: restBounds)
    }

    static func restFrame(for overviewFrame: CGRect, anchor: RestAnchor) -> CGRect {
        let scaleX = anchor.restBounds.width / anchor.overviewBounds.width
        let scaleY = anchor.restBounds.height / anchor.overviewBounds.height
        return CGRect(
            x: anchor.restBounds.minX + (overviewFrame.minX - anchor.overviewBounds.minX) * scaleX,
            y: anchor.restBounds.minY + (overviewFrame.minY - anchor.overviewBounds.minY) * scaleY,
            width: overviewFrame.width * scaleX,
            height: overviewFrame.height * scaleY
        )
    }

    static func visibleContentRect(
        bounds: CGRect,
        scrollOffset: CGFloat,
        progress: Double = 1,
        transitioning: Bool = false
    ) -> CGRect {
        let visible = bounds.offsetBy(dx: 0, dy: scrollOffset * (transitioning ? 1 : CGFloat(progress)))
        return transitioning ? bounds.union(visible) : visible
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
