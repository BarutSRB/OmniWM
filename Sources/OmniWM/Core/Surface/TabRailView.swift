// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

final class TabRailView: NSView {
    private var tabs: [TabRailTabInfo] = []

    private var isHovered = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    private var hoveredVisualIndex: Int? {
        didSet {
            if oldValue != hoveredVisualIndex {
                needsDisplay = true
            }
        }
    }

    private var tracking: NSTrackingArea?
    private var accessibilityTabElements: [TabRailAccessibilityElement] = []
    private var suppressAccessibilityGeometryUpdates = false

    private var tabCount: Int {
        tabs.count
    }

    private var activeVisualIndex = 0

    var onSelect: ((Int) -> Void)?

    func update(tabs: [TabRailTabInfo], activeVisualIndex: Int) {
        let metadataChanged = !Self.hasSameAccessibilityMetadata(self.tabs, tabs)
        let tabsChanged = self.tabs != tabs
        let activeChanged = self.activeVisualIndex != activeVisualIndex
        self.tabs = tabs
        self.activeVisualIndex = activeVisualIndex

        if tabsChanged || activeChanged {
            needsDisplay = true
        }

        if metadataChanged {
            refreshAccessibilityElements()
        } else if activeChanged {
            updateAccessibilitySelection(postNotification: true)
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !suppressAccessibilityGeometryUpdates {
            refreshAccessibilityElements()
        }
    }

    func performWithoutAccessibilityGeometryUpdates(_ body: () -> Void) {
        suppressAccessibilityGeometryUpdates = true
        body()
        suppressAccessibilityGeometryUpdates = false
    }

    func refreshAccessibilityFrames() {
        let items = currentLayout().items
        guard items.count == accessibilityTabElements.count,
              zip(accessibilityTabElements, items).allSatisfy({ pair in
                  pair.0.visualIndex == pair.1.visualIndex
              })
        else {
            refreshAccessibilityElements()
            NSAccessibility.post(element: self, notification: .layoutChanged)
            return
        }
        for (element, item) in zip(accessibilityTabElements, items) {
            element.updateScreenFrame(screenFrame(for: item.hitRect))
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let nextTracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = nextTracking
        addTrackingArea(nextTracking)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoveredVisualIndex(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredVisualIndex(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        hoveredVisualIndex = nil
    }

    override func draw(_: NSRect) {
        guard tabCount > 0 else { return }

        let layout = currentLayout()
        guard !layout.items.isEmpty else { return }
        let visualRailRect = TabRailLayout.visualRailRect(in: layout.railRect)

        fillRoundedRect(visualBarRect(in: visualRailRect), color: TabRailMetrics.backgroundColor)
        fillRect(gutterRect(in: visualRailRect), color: TabRailMetrics.gutterColor)
        fillRect(edgeRect(in: visualRailRect), color: TabRailMetrics.edgeColor)

        if isHovered {
            fillRoundedRect(visualRailRect, color: TabRailMetrics.hoverColor)
        }

        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)

        for item in layout.items where item.visualIndex != clampedActiveVisualIndex {
            drawSegment(item, selected: false)
        }

        if let selectedItem = layout.items.first(where: { $0.visualIndex == clampedActiveVisualIndex }) {
            drawSegment(selectedItem, selected: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let visualIndex = visualIndex(at: point) else { return }
        onSelect?(visualIndex)
    }

    private func visualIndex(at point: CGPoint) -> Int? {
        guard tabCount > 0 else { return nil }
        for item in currentLayout().items where item.hitRect.contains(point) {
            return item.visualIndex
        }
        return nil
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityTabElements
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityTabElements.filter(\.isSelected)
    }

    override func accessibilityLabel() -> String? {
        "Window tabs"
    }

    override func accessibilityValue() -> Any? {
        guard tabCount > 0 else { return "No tabs" }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)
        return "Tab \(clampedActiveVisualIndex + 1) of \(tabCount) selected"
    }

    override func accessibilityHelp() -> String? {
        "Click a segment to select that tab."
    }

    private func visualBarRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX,
            y: railRect.minY,
            width: TabRailMetrics.barThickness,
            height: railRect.height
        )
    }

    private func gutterRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX + TabRailMetrics.barThickness,
            y: railRect.minY,
            width: TabRailMetrics.spacing,
            height: railRect.height
        )
    }

    private func edgeRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX + TabRailMetrics.barThickness,
            y: railRect.minY + 1,
            width: TabRailMetrics.edgeLineWidth,
            height: max(0, railRect.height - 2)
        )
    }

    private func visualRectForSegment(_ item: TabRailLayout.Item, selected: Bool, hovered: Bool) -> CGRect {
        let segmentRect = item.pillRect
        let width = if selected {
            TabRailMetrics.activeSegmentWidth
        } else if hovered {
            TabRailMetrics.hoveredSegmentWidth
        } else {
            TabRailMetrics.inactiveSegmentWidth
        }
        let x = segmentRect.midX - width / 2
        return CGRect(
            x: x,
            y: segmentRect.origin.y,
            width: width,
            height: segmentRect.height
        )
    }

    private func drawSegment(_ item: TabRailLayout.Item, selected: Bool) {
        let hovered = hoveredVisualIndex == item.visualIndex
        let segmentRect = visualRectForSegment(item, selected: selected, hovered: hovered)
        guard segmentRect.width > 0, segmentRect.height > 0 else { return }
        let path = NSBezierPath(
            roundedRect: segmentRect,
            xRadius: TabRailMetrics.cornerRadius,
            yRadius: TabRailMetrics.cornerRadius
        )
        if selected {
            TabRailMetrics.selectedColor(hovered: hovered).setFill()
        } else {
            TabRailMetrics.unselectedColor(hovered: hovered, railHovered: isHovered).setFill()
        }
        path.fill()

        if selected {
            TabRailMetrics.selectedStrokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func fillRoundedRect(_ rect: CGRect, color: NSColor) {
        color.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: TabRailMetrics.cornerRadius,
            yRadius: TabRailMetrics.cornerRadius
        ).fill()
    }

    private func fillRect(_ rect: CGRect, color: NSColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        color.setFill()
        NSBezierPath(rect: rect).fill()
    }

    private func updateHoveredVisualIndex(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredVisualIndex = visualIndex(at: point)
    }

    private func currentLayout() -> TabRailLayout {
        TabRailLayout(tabCount: tabCount, bounds: bounds)
    }

    private func refreshAccessibilityElements() {
        let layout = currentLayout()
        let tabsByVisualIndex = Dictionary(tabs.map { ($0.visualIndex, $0) }, uniquingKeysWith: { first, _ in first })
        let existingElements = Dictionary(
            accessibilityTabElements.map { ($0.visualIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        accessibilityTabElements = layout.items.compactMap { item in
            guard let tab = tabsByVisualIndex[item.visualIndex] else {
                return nil
            }
            let screenFrame = screenFrame(for: item.hitRect)
            if let element = existingElements[item.visualIndex] {
                element.update(tab: tab, screenFrame: screenFrame)
                return element
            }
            let element = TabRailAccessibilityElement(
                parent: self,
                tab: tab,
                screenFrame: screenFrame,
                pressAction: { [weak self] visualIndex in
                    _ = self?.performAccessibilitySelection(visualIndex)
                }
            )
            return element
        }
        updateAccessibilitySelection(postNotification: false)
    }

    private func updateAccessibilitySelection(postNotification: Bool) {
        for element in accessibilityTabElements {
            element.updateSelected(element.visualIndex == activeVisualIndex, postNotification: postNotification)
        }
    }

    private func performAccessibilitySelection(_ visualIndex: Int) -> Bool {
        guard tabs.contains(where: { $0.visualIndex == visualIndex }) else { return false }
        onSelect?(visualIndex)
        return true
    }

    private func screenFrame(for rect: CGRect) -> CGRect {
        guard let window else { return .zero }
        let windowRect = convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    private static func hasSameAccessibilityMetadata(
        _ lhs: [TabRailTabInfo],
        _ rhs: [TabRailTabInfo]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.visualIndex == right.visualIndex,
                  left.windowId == right.windowId,
                  left.appName == right.appName,
                  left.title == right.title
            else {
                return false
            }
        }
        return true
    }
}
