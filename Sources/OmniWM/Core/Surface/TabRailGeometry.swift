// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

enum TabRailMetrics {
    static let barThickness: CGFloat = 10
    static let spacing: CGFloat = 2
    static let totalWidth: CGFloat = barThickness + spacing
    static let hitWidth: CGFloat = 20
    static let cornerRadius: CGFloat = 3
    static let preferredSegmentHeight: CGFloat = 32
    static let minimumSegmentHeight: CGFloat = 2
    static let preferredSegmentGap: CGFloat = 6
    static let minimumSegmentGap: CGFloat = 0
    static let minVisibleIntersection: CGFloat = 10
    static let minimumRailHeight: CGFloat = 8
    static let activeSegmentWidth: CGFloat = 8
    static let inactiveSegmentWidth: CGFloat = 5
    static let hoveredSegmentWidth: CGFloat = 7
    static let segmentVerticalInset: CGFloat = 1
    static let edgeLineWidth: CGFloat = 1

    static var backgroundColor: NSColor {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return .windowBackgroundColor
        }
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.72 : 0.44
        return .black.withAlphaComponent(alpha)
    }

    static func selectedColor(hovered: Bool) -> NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : 0.92
        return NSColor.controlAccentColor.withAlphaComponent(min(1.0, alpha + (hovered ? 0.06 : 0)))
    }

    static func unselectedColor(hovered: Bool, railHovered: Bool) -> NSColor {
        let baseAlpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.45
        let hoverAlpha: CGFloat = if hovered {
            0.2
        } else if railHovered {
            0.08
        } else {
            0
        }
        let alpha = min(0.9, baseAlpha + hoverAlpha)
        return NSColor.labelColor.withAlphaComponent(alpha)
    }

    static var hoverColor: NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.22 : 0.14
        return NSColor.controlAccentColor.withAlphaComponent(alpha)
    }

    static var gutterColor: NSColor {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return NSColor.separatorColor.withAlphaComponent(0.55)
        }
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.34 : 0.18
        return NSColor.black.withAlphaComponent(alpha)
    }

    static var edgeColor: NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.86 : 0.42
        return NSColor.separatorColor.withAlphaComponent(alpha)
    }

    static var selectedStrokeColor: NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.0 : 0.9
        return NSColor.keyboardFocusIndicatorColor.withAlphaComponent(alpha)
    }
}

struct TabRailLayout: Equatable {
    struct Item: Equatable {
        let visualIndex: Int
        let hitRect: CGRect
        let pillRect: CGRect
    }

    static let empty = TabRailLayout(railRect: .zero, items: [])

    let railRect: CGRect
    let items: [Item]

    private init(railRect: CGRect, items: [Item]) {
        self.railRect = railRect
        self.items = items
    }

    init(tabCount: Int, bounds: CGRect) {
        guard tabCount > 0,
              bounds.width > 0,
              bounds.height >= TabRailMetrics.minimumRailHeight
        else {
            self = .empty
            return
        }

        let segmentGap = Self.segmentGap(tabCount: tabCount, availableHeight: bounds.height)
        let segmentHeight = Self.segmentHeight(
            tabCount: tabCount,
            availableHeight: bounds.height,
            segmentGap: segmentGap
        )
        guard segmentHeight > 0 else {
            self = .empty
            return
        }

        let totalHeight = Self.totalHeight(tabCount: tabCount, segmentHeight: segmentHeight, segmentGap: segmentGap)
        let railY = bounds.minY + max(0, (bounds.height - totalHeight) / 2)
        let railRect = CGRect(x: bounds.minX, y: railY, width: bounds.width, height: min(bounds.height, totalHeight))
        let visualRailRect = Self.visualRailRect(in: railRect)

        var items: [Item] = []
        items.reserveCapacity(tabCount)

        for visualIndex in 0 ..< tabCount {
            let y = railRect.maxY
                - CGFloat(visualIndex + 1) * segmentHeight
                - CGFloat(visualIndex) * segmentGap
            let hitRect = CGRect(
                x: railRect.minX,
                y: y,
                width: railRect.width,
                height: segmentHeight
            ).intersection(railRect)
            let pillRect = CGRect(
                x: visualRailRect.minX,
                y: hitRect.minY + TabRailMetrics.segmentVerticalInset,
                width: visualRailRect.width,
                height: max(0, hitRect.height - TabRailMetrics.segmentVerticalInset * 2)
            )
            guard !hitRect.isNull, hitRect.width > 0, hitRect.height > 0 else { continue }
            items.append(Item(visualIndex: visualIndex, hitRect: hitRect, pillRect: pillRect))
        }

        self.railRect = railRect
        self.items = items
    }

    static func fittedHeight(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard tabCount > 0, availableHeight >= TabRailMetrics.minimumRailHeight else { return 0 }
        let segmentGap = segmentGap(tabCount: tabCount, availableHeight: availableHeight)
        let segmentHeight = segmentHeight(
            tabCount: tabCount,
            availableHeight: availableHeight,
            segmentGap: segmentGap
        )
        guard segmentHeight >= TabRailMetrics.minimumSegmentHeight else { return 0 }
        return min(
            availableHeight,
            totalHeight(tabCount: tabCount, segmentHeight: segmentHeight, segmentGap: segmentGap)
        )
    }

    static func visualRailRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX - TabRailMetrics.totalWidth,
            y: bounds.minY,
            width: TabRailMetrics.totalWidth,
            height: bounds.height
        )
    }

    private static func totalHeight(tabCount: Int, segmentHeight: CGFloat, segmentGap: CGFloat) -> CGFloat {
        CGFloat(tabCount) * segmentHeight + CGFloat(max(0, tabCount - 1)) * segmentGap
    }

    private static func segmentGap(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard tabCount > 1 else { return 0 }
        let preferredHeight = totalHeight(
            tabCount: tabCount,
            segmentHeight: TabRailMetrics.preferredSegmentHeight,
            segmentGap: TabRailMetrics.preferredSegmentGap
        )
        guard preferredHeight > availableHeight else {
            return TabRailMetrics.preferredSegmentGap
        }
        let scale = max(0, availableHeight / preferredHeight)
        return max(
            TabRailMetrics.minimumSegmentGap,
            min(TabRailMetrics.preferredSegmentGap, TabRailMetrics.preferredSegmentGap * scale)
        )
    }

    private static func segmentHeight(
        tabCount: Int,
        availableHeight: CGFloat,
        segmentGap: CGFloat
    ) -> CGFloat {
        let totalGapHeight = CGFloat(max(0, tabCount - 1)) * segmentGap
        let availableForSegments = max(0, availableHeight - totalGapHeight)
        let fitHeight = availableForSegments / CGFloat(tabCount)
        guard fitHeight >= TabRailMetrics.minimumSegmentHeight else { return 0 }
        return min(TabRailMetrics.preferredSegmentHeight, fitHeight)
    }
}
