// SPDX-License-Identifier: GPL-2.0-only
import AppKit

private enum TabbedOverlayMetrics {
    static let barThickness: CGFloat = 10
    static let spacing: CGFloat = 2
    static let totalWidth: CGFloat = barThickness + spacing
    static let cornerRadius: CGFloat = 3
    static let segmentGap: CGFloat = 2
    static let minVisibleIntersection: CGFloat = 10

    static let backgroundColor = NSColor.black.withAlphaComponent(0.4)
    static let selectedColor = NSColor(red: 0.0, green: 0.8, blue: 0.2, alpha: 0.9)
    static let unselectedColor = NSColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.7)
}

struct TabbedColumnOverlayInfo {
    let workspaceId: WorkspaceDescriptor.ID
    let columnId: NodeId
    let columnFrame: CGRect
    let tabCount: Int
    let activeVisualIndex: Int
    let activeWindowId: Int?
}

@MainActor
final class TabbedColumnOverlayManager {
    typealias SelectionHandler = (WorkspaceDescriptor.ID, NodeId, Int) -> Void

    static let tabIndicatorWidth: CGFloat = TabbedOverlayMetrics.totalWidth

    var onSelect: SelectionHandler?

    private var overlays: [NodeId: TabbedColumnOverlayWindow] = [:]

    func updateOverlays(_ infos: [TabbedColumnOverlayInfo]) {
        let filtered = infos.filter { $0.tabCount > 0 }
        let desiredIds = Set(filtered.map(\.columnId))

        for (columnId, overlay) in overlays where !desiredIds.contains(columnId) {
            overlay.close()
            overlays.removeValue(forKey: columnId)
        }

        for info in filtered {
            let overlay = overlays[info.columnId] ?? {
                let window = TabbedColumnOverlayWindow(columnId: info.columnId, workspaceId: info.workspaceId)
                window.onSelect = { [weak self] workspaceId, columnId, visualIndex in
                    self?.onSelect?(workspaceId, columnId, visualIndex)
                }
                overlays[info.columnId] = window
                return window
            }()
            overlay.update(info: info)
        }
    }

    func removeAll() {
        for (_, overlay) in overlays {
            overlay.close()
        }
        overlays.removeAll()
    }

    static func shouldShowOverlay(columnFrame: CGRect, visibleFrame: CGRect) -> Bool {
        let intersection = columnFrame.intersection(visibleFrame)
        return intersection.width >= TabbedOverlayMetrics.minVisibleIntersection &&
            intersection.height >= TabbedOverlayMetrics.minVisibleIntersection
    }
}

@MainActor
private final class TabbedColumnOverlayWindow: NSPanel {
    private let overlayView: TabbedColumnOverlayView
    private var columnId: NodeId
    private var workspaceId: WorkspaceDescriptor.ID

    var onSelect: ((WorkspaceDescriptor.ID, NodeId, Int) -> Void)?

    init(columnId: NodeId, workspaceId: WorkspaceDescriptor.ID) {
        self.columnId = columnId
        self.workspaceId = workspaceId
        overlayView = TabbedColumnOverlayView(frame: .zero)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        contentView = overlayView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func update(info: TabbedColumnOverlayInfo) {
        workspaceId = info.workspaceId
        columnId = info.columnId

        overlayView.tabCount = info.tabCount
        overlayView.activeVisualIndex = min(max(0, info.activeVisualIndex), max(0, info.tabCount - 1))
        overlayView.onSelect = { [weak self] visualIndex in
            guard let self else { return }
            onSelect?(workspaceId, columnId, visualIndex)
        }

        let frame = Self.overlayFrame(for: info.columnFrame)
        guard frame.width > 1, frame.height > 1 else {
            orderOut(nil)
            return
        }

        setFrame(frame, display: false)
        overlayView.frame = CGRect(origin: .zero, size: frame.size)

        orderFront(nil)

        if let targetWid = info.activeWindowId {
            let wid = UInt32(windowNumber)
            SkyLight.shared.orderWindow(wid, relativeTo: UInt32(targetWid))
        }
    }

    private static func overlayFrame(for columnFrame: CGRect) -> CGRect {
        let x = columnFrame.minX
        let y = columnFrame.origin.y
        let width = TabbedOverlayMetrics.barThickness
        let height = columnFrame.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private final class TabbedColumnOverlayView: NSView {
    var tabCount: Int = 0 {
        didSet { if oldValue != tabCount { needsDisplay = true } }
    }

    var activeVisualIndex: Int = 0 {
        didSet { if oldValue != activeVisualIndex { needsDisplay = true } }
    }

    var onSelect: ((Int) -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func draw(_: NSRect) {
        guard tabCount > 0 else { return }

        TabbedOverlayMetrics.backgroundColor.setFill()
        let backgroundPath = NSBezierPath(
            roundedRect: bounds,
            xRadius: TabbedOverlayMetrics.cornerRadius,
            yRadius: TabbedOverlayMetrics.cornerRadius
        )
        backgroundPath.fill()

        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)

        for visualIndex in 0 ..< tabCount {
            let segmentRect = rectForSegment(visualIndex)
            let path = NSBezierPath(
                roundedRect: segmentRect,
                xRadius: TabbedOverlayMetrics.cornerRadius,
                yRadius: TabbedOverlayMetrics.cornerRadius
            )
            if visualIndex == clampedActiveVisualIndex {
                TabbedOverlayMetrics.selectedColor.setFill()
            } else {
                TabbedOverlayMetrics.unselectedColor.setFill()
            }
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let visualIndex = visualIndex(at: point) else { return }
        onSelect?(visualIndex)
    }

    private func visualIndex(at point: CGPoint) -> Int? {
        guard tabCount > 0 else { return nil }
        for visualIndex in 0 ..< tabCount {
            if rectForSegment(visualIndex).contains(point) {
                return visualIndex
            }
        }
        return nil
    }

    private func rectForSegment(_ visualIndex: Int) -> CGRect {
        guard tabCount > 0 else { return .zero }

        let totalGaps = CGFloat(tabCount - 1) * TabbedOverlayMetrics.segmentGap
        let availableHeight = bounds.height - totalGaps
        let segmentHeight = availableHeight / CGFloat(tabCount)

        let y = bounds.height
            - CGFloat(visualIndex + 1) * segmentHeight
            - CGFloat(visualIndex) * TabbedOverlayMetrics.segmentGap

        return CGRect(
            x: 0,
            y: y,
            width: bounds.width,
            height: segmentHeight
        )
    }
}
