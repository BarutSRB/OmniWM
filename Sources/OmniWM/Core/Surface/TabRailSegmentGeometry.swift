// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

enum TabRailSegmentGeometry {
    static let inactiveHeightRatio: CGFloat = 0.67

    static func hitRects(markerRects: [Int: CGRect], railRect: CGRect) -> [Int: CGRect] {
        let ordered = markerRects.sorted { $0.value.midY < $1.value.midY }
        var result: [Int: CGRect] = [:]
        result.reserveCapacity(ordered.count)
        for index in ordered.indices {
            let marker = ordered[index]
            let minY = index == ordered.startIndex
                ? railRect.minY
                : (ordered[index - 1].value.midY + marker.value.midY) / 2
            let maxY = index == ordered.index(before: ordered.endIndex)
                ? railRect.maxY
                : (marker.value.midY + ordered[index + 1].value.midY) / 2
            result[marker.key] = CGRect(
                x: railRect.minX,
                y: minY,
                width: railRect.width,
                height: max(0, maxY - minY)
            ).intersection(railRect)
        }
        return result
    }

    static func rect(
        sourceRect: CGRect,
        trackBounds: CGRect,
        width: CGFloat,
        selected: Bool,
        scale: CGFloat
    ) -> CGRect {
        let height = aligned(
            sourceRect.height * (selected ? 1 : inactiveHeightRatio),
            scale: scale
        )
        let horizontalGeometry = pixelAlignedHorizontalGeometry(
            trackBounds: trackBounds,
            width: width,
            scale: scale
        )
        return CGRect(
            x: horizontalGeometry.x,
            y: aligned(sourceRect.midY - height / 2, scale: scale),
            width: horizontalGeometry.width,
            height: height
        )
    }

    static func packedHeight(
        sourceRects: [Int: CGRect],
        selectedVisualIndex: Int,
        verticalMargin: CGFloat,
        endInset: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let orderedRects = sourceRects.sorted { $0.value.midY < $1.value.midY }
        guard !orderedRects.isEmpty else { return 0 }

        let sourceGaps = zip(orderedRects, orderedRects.dropFirst()).map { lower, upper in
            max(0, upper.value.minY - lower.value.maxY - verticalMargin * 2)
        }
        let slotGap = sourceGaps.min() ?? 0
        let markerHeight = orderedRects.reduce(CGFloat.zero) { result, item in
            result + aligned(
                item.value.height * (item.key == selectedVisualIndex ? 1 : inactiveHeightRatio),
                scale: scale
            )
        }
        return markerHeight
            + CGFloat(max(0, orderedRects.count - 1)) * (verticalMargin * 2 + slotGap)
            + endInset * 2
    }

    static func equallyPaddedRects(
        sourceRects: [Int: CGRect],
        trackBounds: CGRect,
        selectedVisualIndex: Int,
        verticalMargin: CGFloat,
        scale: CGFloat
    ) -> [Int: CGRect] {
        let orderedRects = sourceRects.sorted { $0.value.midY < $1.value.midY }
        guard !orderedRects.isEmpty else { return [:] }

        let sourceGaps = zip(orderedRects, orderedRects.dropFirst()).map { lower, upper in
            max(0, upper.value.minY - lower.value.maxY - verticalMargin * 2)
        }
        let slotGap = sourceGaps.min() ?? 0
        let markerHeights = orderedRects.map { visualIndex, sourceRect in
            aligned(
                sourceRect.height * (visualIndex == selectedVisualIndex ? 1 : inactiveHeightRatio),
                scale: scale
            )
        }
        let totalHeight = markerHeights.reduce(0, +)
            + CGFloat(orderedRects.count) * verticalMargin * 2
            + CGFloat(max(0, orderedRects.count - 1)) * slotGap
        var cursorY = trackBounds.midY - totalHeight / 2
        let horizontalGeometry = pixelAlignedHorizontalGeometry(
            trackBounds: trackBounds,
            width: TabRailMetrics.segmentWidth,
            scale: scale
        )
        var result: [Int: CGRect] = [:]
        result.reserveCapacity(orderedRects.count)

        for ((visualIndex, _), markerHeight) in zip(orderedRects, markerHeights) {
            result[visualIndex] = CGRect(
                x: horizontalGeometry.x,
                y: aligned(cursorY + verticalMargin, scale: scale),
                width: horizontalGeometry.width,
                height: markerHeight
            )
            cursorY += markerHeight + verticalMargin * 2 + slotGap
        }
        return result
    }

    private static func pixelAlignedHorizontalGeometry(
        trackBounds: CGRect,
        width: CGFloat,
        scale: CGFloat
    ) -> (x: CGFloat, width: CGFloat) {
        guard scale > 0 else {
            return (trackBounds.midX - width / 2, width)
        }

        let trackPixelWidth = Int((trackBounds.width * scale).rounded())
        var segmentPixelWidth = max(1, Int((width * scale).rounded()))
        if trackPixelWidth.isMultiple(of: 2) != segmentPixelWidth.isMultiple(of: 2) {
            if segmentPixelWidth < trackPixelWidth {
                segmentPixelWidth += 1
            } else if segmentPixelWidth > 1 {
                segmentPixelWidth -= 1
            }
        }

        let alignedWidth = CGFloat(segmentPixelWidth) / scale
        let alignedX = (trackBounds.midX * scale - CGFloat(segmentPixelWidth) / 2).rounded() / scale
        return (alignedX, alignedWidth)
    }

    private static func aligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }
}
