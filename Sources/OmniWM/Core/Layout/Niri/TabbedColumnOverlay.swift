import AppKit

private enum TabbedOverlayMetrics {
    static let headerHeight: CGFloat = 28
    static let overlayHeight: CGFloat = 22
    static let padding: CGFloat = 6
    static let itemSize = CGSize(width: 20, height: 20)
    static let itemSpacing: CGFloat = 6
    static let backgroundRadius: CGFloat = 8
    static let itemRadius: CGFloat = 6
    static let minVisibleIntersection: CGFloat = 10

    static let backgroundColor = NSColor.black.withAlphaComponent(0.4)
    static let inactiveItemColor = NSColor.white.withAlphaComponent(0.12)
    static let activeItemColor = NSColor.white.withAlphaComponent(0.28)
    static let inactiveTextColor = NSColor.white.withAlphaComponent(0.85)
    static let activeTextColor = NSColor.white
    @MainActor static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
}

struct TabbedColumnOverlayInfo {
    let workspaceId: WorkspaceDescriptor.ID
    let columnId: NodeId
    let columnFrame: CGRect
    let tabCount: Int
    let activeIndex: Int
    let activeWindowId: Int?
}

@MainActor
final class TabbedColumnOverlayManager {
    typealias SelectionHandler = (WorkspaceDescriptor.ID, NodeId, Int) -> Void

    static let tabIndicatorHeight: CGFloat = TabbedOverlayMetrics.headerHeight

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
                window.onSelect = { [weak self] workspaceId, columnId, index in
                    self?.onSelect?(workspaceId, columnId, index)
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

        let clampedCount = max(1, min(5, info.tabCount))
        let clampedActive = min(max(0, info.activeIndex), clampedCount - 1)

        overlayView.tabCount = clampedCount
        overlayView.activeIndex = clampedActive
        overlayView.onSelect = { [weak self] index in
            guard let self else { return }
            onSelect?(workspaceId, columnId, index)
        }

        let frame = Self.overlayFrame(for: info.columnFrame, tabCount: clampedCount)
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

    private static func overlayFrame(for columnFrame: CGRect, tabCount: Int) -> CGRect {
        let idealWidth = TabbedColumnOverlayView.idealWidth(for: tabCount)
        let maxWidth = max(0, columnFrame.width - TabbedOverlayMetrics.padding * 2)
        let width = min(idealWidth, maxWidth)
        let height = TabbedOverlayMetrics.overlayHeight

        let x = columnFrame.minX + (columnFrame.width - width) / 2
        let y = columnFrame.maxY - TabbedOverlayMetrics.headerHeight +
            (TabbedOverlayMetrics.headerHeight - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private final class TabbedColumnOverlayView: NSView {
    var tabCount: Int = 0 {
        didSet { needsDisplay = true }
    }

    var activeIndex: Int = 0 {
        didSet { needsDisplay = true }
    }

    var onSelect: ((Int) -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func draw(_: NSRect) {
        TabbedOverlayMetrics.backgroundColor.setFill()
        let backgroundPath = NSBezierPath(
            roundedRect: bounds,
            xRadius: TabbedOverlayMetrics.backgroundRadius,
            yRadius: TabbedOverlayMetrics.backgroundRadius
        )
        backgroundPath.fill()

        let count = max(1, min(5, tabCount))
        let clampedActive = min(max(0, activeIndex), count - 1)

        for index in 0 ..< count {
            let itemRect = rectForItem(index)
            let path = NSBezierPath(
                roundedRect: itemRect,
                xRadius: TabbedOverlayMetrics.itemRadius,
                yRadius: TabbedOverlayMetrics.itemRadius
            )
            if index == clampedActive {
                TabbedOverlayMetrics.activeItemColor.setFill()
            } else {
                TabbedOverlayMetrics.inactiveItemColor.setFill()
            }
            path.fill()

            let text = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: TabbedOverlayMetrics.font,
                .foregroundColor: index == clampedActive
                    ? TabbedOverlayMetrics.activeTextColor
                    : TabbedOverlayMetrics.inactiveTextColor
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: itemRect.midX - textSize.width / 2,
                y: itemRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        onSelect?(index)
    }

    private func index(at point: CGPoint) -> Int? {
        let count = max(1, min(5, tabCount))
        for index in 0 ..< count {
            if rectForItem(index).contains(point) {
                return index
            }
        }
        return nil
    }

    private func rectForItem(_ index: Int) -> CGRect {
        let count = max(1, min(5, tabCount))
        let totalWidth = TabbedColumnOverlayView.idealWidth(for: count)
        let offsetX = (bounds.width - totalWidth) / 2 + TabbedOverlayMetrics.padding
        let x = offsetX + CGFloat(index) * (TabbedOverlayMetrics.itemSize.width + TabbedOverlayMetrics.itemSpacing)
        let y = (bounds.height - TabbedOverlayMetrics.itemSize.height) / 2
        return CGRect(origin: CGPoint(x: x, y: y), size: TabbedOverlayMetrics.itemSize)
    }

    static func idealWidth(for tabCount: Int) -> CGFloat {
        let count = max(1, min(5, tabCount))
        let items = CGFloat(count) * TabbedOverlayMetrics.itemSize.width
        let gaps = CGFloat(max(0, count - 1)) * TabbedOverlayMetrics.itemSpacing
        return TabbedOverlayMetrics.padding * 2 + items + gaps
    }
}
