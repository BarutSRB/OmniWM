import AppKit

private enum TabbedOverlayMetrics {
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

struct TabbedColumnOverlayTabInfo: Equatable {
    let visualIndex: Int
    let windowId: Int?
    let appName: String?
    let title: String?
    let isActive: Bool

    var accessibilityLabel: String {
        let ordinal = "Tab \(visualIndex + 1)"
        switch (title?.nilIfEmpty, appName?.nilIfEmpty) {
        case let (title?, appName?):
            return "\(ordinal), \(title), \(appName)"
        case let (title?, nil):
            return "\(ordinal), \(title)"
        case let (nil, appName?):
            return "\(ordinal), \(appName)"
        case (nil, nil):
            return ordinal
        }
    }
}

struct TabbedColumnOverlayInfo: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let columnId: NodeId
    let columnFrame: CGRect
    let visibleColumnFrame: CGRect
    let activeVisualIndex: Int
    let activeWindowId: Int?
    let tabs: [TabbedColumnOverlayTabInfo]

    var tabCount: Int {
        tabs.count
    }

    var key: TabbedColumnOverlayKey {
        TabbedColumnOverlayKey(workspaceId: workspaceId, columnId: columnId)
    }

    init(
        workspaceId: WorkspaceDescriptor.ID,
        columnId: NodeId,
        columnFrame: CGRect,
        visibleColumnFrame: CGRect? = nil,
        tabCount: Int,
        activeVisualIndex: Int,
        activeWindowId: Int?,
        tabs: [TabbedColumnOverlayTabInfo]? = nil
    ) {
        self.workspaceId = workspaceId
        self.columnId = columnId
        self.columnFrame = columnFrame
        self.visibleColumnFrame = visibleColumnFrame ?? columnFrame
        self.activeVisualIndex = activeVisualIndex
        self.activeWindowId = activeWindowId
        self.tabs = tabs ?? Self.defaultTabs(tabCount: tabCount, activeVisualIndex: activeVisualIndex)
    }

    private static func defaultTabs(tabCount: Int, activeVisualIndex: Int) -> [TabbedColumnOverlayTabInfo] {
        guard tabCount > 0 else { return [] }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)
        return (0 ..< tabCount).map { visualIndex in
            TabbedColumnOverlayTabInfo(
                visualIndex: visualIndex,
                windowId: nil,
                appName: nil,
                title: nil,
                isActive: visualIndex == clampedActiveVisualIndex
            )
        }
    }
}

struct TabbedColumnOverlayKey: Hashable {
    let workspaceId: WorkspaceDescriptor.ID
    let columnId: NodeId
}

struct TabbedRailLayout: Equatable {
    struct Item: Equatable {
        let visualIndex: Int
        let hitRect: CGRect
        let pillRect: CGRect
    }

    static let empty = TabbedRailLayout(railRect: .zero, items: [])

    let railRect: CGRect
    let items: [Item]

    private init(railRect: CGRect, items: [Item]) {
        self.railRect = railRect
        self.items = items
    }

    init(tabCount: Int, bounds: CGRect) {
        guard tabCount > 0,
              bounds.width > 0,
              bounds.height >= TabbedOverlayMetrics.minimumRailHeight
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
                y: hitRect.minY + TabbedOverlayMetrics.segmentVerticalInset,
                width: visualRailRect.width,
                height: max(0, hitRect.height - TabbedOverlayMetrics.segmentVerticalInset * 2)
            )
            guard !hitRect.isNull, hitRect.width > 0, hitRect.height > 0 else { continue }
            items.append(Item(visualIndex: visualIndex, hitRect: hitRect, pillRect: pillRect))
        }

        self.railRect = railRect
        self.items = items
    }

    static func fittedHeight(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard tabCount > 0, availableHeight >= TabbedOverlayMetrics.minimumRailHeight else { return 0 }
        let segmentGap = segmentGap(tabCount: tabCount, availableHeight: availableHeight)
        let segmentHeight = segmentHeight(
            tabCount: tabCount,
            availableHeight: availableHeight,
            segmentGap: segmentGap
        )
        guard segmentHeight >= TabbedOverlayMetrics.minimumSegmentHeight else { return 0 }
        return min(availableHeight, totalHeight(tabCount: tabCount, segmentHeight: segmentHeight, segmentGap: segmentGap))
    }

    static func visualRailRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX - TabbedOverlayMetrics.totalWidth,
            y: bounds.minY,
            width: TabbedOverlayMetrics.totalWidth,
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
            segmentHeight: TabbedOverlayMetrics.preferredSegmentHeight,
            segmentGap: TabbedOverlayMetrics.preferredSegmentGap
        )
        guard preferredHeight > availableHeight else {
            return TabbedOverlayMetrics.preferredSegmentGap
        }
        let scale = max(0, availableHeight / preferredHeight)
        return max(
            TabbedOverlayMetrics.minimumSegmentGap,
            min(TabbedOverlayMetrics.preferredSegmentGap, TabbedOverlayMetrics.preferredSegmentGap * scale)
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
        guard fitHeight >= TabbedOverlayMetrics.minimumSegmentHeight else { return 0 }
        return min(TabbedOverlayMetrics.preferredSegmentHeight, fitHeight)
    }
}

struct TabbedColumnOverlayAccessibilitySnapshot: Equatable {
    let visualIndex: Int
    let role: NSAccessibility.Role?
    let label: String?
    let value: Bool
    let frame: CGRect
}

@MainActor
final class TabbedColumnOverlayManager {
    typealias SelectionHandler = (WorkspaceDescriptor.ID, NodeId, Int) -> Void

    static let tabIndicatorWidth: CGFloat = TabbedOverlayMetrics.totalWidth

    var onSelect: SelectionHandler?
    var disablesWindowUpdatesForTests = false
    var updateHookForTests: ((WorkspaceDescriptor.ID?, Bool) -> Void)?
    var frontHookForTests: ((Int) -> Void)?
    var orderingHookForTests: ((Int, Int) -> Void)?
    var orderWindowForTests: ((Int, Int) -> Void)?
    private(set) var lastUpdateInfosForTests: [TabbedColumnOverlayInfo] = []
    private(set) var lastScopedWorkspaceIdForTests: WorkspaceDescriptor.ID?
    private(set) var lastForceOrderingForTests = false

    private var overlays: [TabbedColumnOverlayKey: TabbedColumnOverlayWindow] = [:]

    func updateOverlays(_ infos: [TabbedColumnOverlayInfo], forceOrdering: Bool = false) {
        recordUpdateForTests(infos: infos, scopedWorkspaceId: nil, forceOrdering: forceOrdering)
        guard !disablesWindowUpdatesForTests else { return }

        var desiredKeys = Set<TabbedColumnOverlayKey>()
        desiredKeys.reserveCapacity(infos.count)
        for info in infos where info.tabCount > 0 {
            desiredKeys.insert(info.key)
            updateOverlay(info, forceOrdering: forceOrdering)
        }

        for (key, overlay) in overlays where !desiredKeys.contains(key) {
            overlay.close()
            overlays.removeValue(forKey: key)
        }
    }

    func updateOverlays(
        _ infos: [TabbedColumnOverlayInfo],
        in workspaceId: WorkspaceDescriptor.ID,
        forceOrdering: Bool = false
    ) {
        recordUpdateForTests(infos: infos, scopedWorkspaceId: workspaceId, forceOrdering: forceOrdering)
        guard !disablesWindowUpdatesForTests else { return }

        var desiredKeys = Set<TabbedColumnOverlayKey>()
        desiredKeys.reserveCapacity(infos.count)
        for info in infos where info.tabCount > 0 {
            desiredKeys.insert(info.key)
        }

        for (key, overlay) in overlays where key.workspaceId == workspaceId && !desiredKeys.contains(key) {
            overlay.close()
            overlays.removeValue(forKey: key)
        }

        for info in infos where info.tabCount > 0 {
            updateOverlay(info, forceOrdering: forceOrdering)
        }
    }

    private func recordUpdateForTests(
        infos: [TabbedColumnOverlayInfo],
        scopedWorkspaceId: WorkspaceDescriptor.ID?,
        forceOrdering: Bool
    ) {
        updateHookForTests?(scopedWorkspaceId, forceOrdering)
        guard disablesWindowUpdatesForTests else { return }
        lastUpdateInfosForTests = infos.filter { $0.tabCount > 0 }
        lastScopedWorkspaceIdForTests = scopedWorkspaceId
        lastForceOrderingForTests = forceOrdering
    }

    private func updateOverlay(_ info: TabbedColumnOverlayInfo, forceOrdering: Bool) {
        let key = info.key
        let overlay = overlays[key] ?? {
            let window = TabbedColumnOverlayWindow(columnId: info.columnId, workspaceId: info.workspaceId)
            window.onSelect = { [weak self] workspaceId, columnId, visualIndex in
                self?.onSelect?(workspaceId, columnId, visualIndex)
            }
            overlays[key] = window
            return window
        }()
        overlay.frontHookForTests = frontHookForTests
        overlay.orderingHookForTests = orderingHookForTests
        overlay.orderWindowForTests = orderWindowForTests
        overlay.update(info: info, forceOrdering: forceOrdering)
    }

    func overlayWindowNumberForTests(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId) -> Int? {
        overlays[TabbedColumnOverlayKey(workspaceId: workspaceId, columnId: columnId)]?.windowNumber
    }

    func overlayAccessibilitySnapshotForTests(
        workspaceId: WorkspaceDescriptor.ID,
        columnId: NodeId
    ) -> [TabbedColumnOverlayAccessibilitySnapshot] {
        overlays[TabbedColumnOverlayKey(workspaceId: workspaceId, columnId: columnId)]?.accessibilitySnapshotForTests() ?? []
    }

    func performOverlayAccessibilityPressForTests(
        workspaceId: WorkspaceDescriptor.ID,
        columnId: NodeId,
        visualIndex: Int
    ) -> Bool {
        overlays[TabbedColumnOverlayKey(workspaceId: workspaceId, columnId: columnId)]?
            .performAccessibilitySelectionForTests(visualIndex) ?? false
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
    private let surfaceID: String
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var lastFrame: CGRect?
    private var lastActiveWindowId: Int?
    private var registeredSurfaceWindowNumber: Int?
    private var accessibilityDisplayObserver: NSObjectProtocol?
    var frontHookForTests: ((Int) -> Void)?
    var orderingHookForTests: ((Int, Int) -> Void)?
    var orderWindowForTests: ((Int, Int) -> Void)?

    var onSelect: ((WorkspaceDescriptor.ID, NodeId, Int) -> Void)?

    init(columnId: NodeId, workspaceId: WorkspaceDescriptor.ID) {
        self.columnId = columnId
        self.workspaceId = workspaceId
        surfaceID = Self.surfaceID(workspaceId: workspaceId, columnId: columnId)
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

        overlayView.onSelect = { [weak self] visualIndex in
            guard let self else { return }
            self.onSelect?(self.workspaceId, self.columnId, visualIndex)
        }
        contentView = overlayView

        accessibilityDisplayObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak overlayView] _ in
            Task { @MainActor [weak overlayView] in
                overlayView?.needsDisplay = true
            }
        }
    }

    override func close() {
        if let accessibilityDisplayObserver {
            NotificationCenter.default.removeObserver(accessibilityDisplayObserver)
            self.accessibilityDisplayObserver = nil
        }
        surfaceCoordinator.unregister(id: surfaceID)
        registeredSurfaceWindowNumber = nil
        super.close()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func update(info: TabbedColumnOverlayInfo, forceOrdering: Bool) {
        workspaceId = info.workspaceId
        columnId = info.columnId

        let frame = Self.overlayFrame(for: info.visibleColumnFrame, tabCount: info.tabCount)
        guard frame.width > 1, frame.height > 1 else {
            orderOut(nil)
            lastFrame = nil
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }

        if lastFrame != frame || self.frame != frame {
            setFrame(frame, display: false)
            overlayView.frame = CGRect(origin: .zero, size: frame.size)
            lastFrame = frame
        }

        let clampedActiveVisualIndex = min(max(0, info.activeVisualIndex), max(0, info.tabCount - 1))
        overlayView.update(tabs: info.tabs, activeVisualIndex: clampedActiveVisualIndex)

        let wasVisible = isVisible
        if forceOrdering || !wasVisible {
            orderFront(nil)
            frontHookForTests?(windowNumber)
        }
        syncSurfaceRegistration()

        if let targetWid = info.activeWindowId,
           forceOrdering || lastActiveWindowId != targetWid || !wasVisible
        {
            let wid = UInt32(windowNumber)
            if let orderWindowForTests {
                orderWindowForTests(Int(wid), targetWid)
            } else {
                SkyLight.shared.orderWindow(wid, relativeTo: UInt32(targetWid))
            }
            orderingHookForTests?(Int(wid), targetWid)
        }
        lastActiveWindowId = info.activeWindowId
    }

    private static func overlayFrame(for visibleColumnFrame: CGRect, tabCount: Int) -> CGRect {
        guard tabCount > 0, !visibleColumnFrame.isNull else { return .zero }
        let width = max(TabbedOverlayMetrics.hitWidth, TabbedOverlayMetrics.totalWidth)
        let height = TabbedRailLayout.fittedHeight(tabCount: tabCount, availableHeight: visibleColumnFrame.height)
        guard height > 1 else { return .zero }
        let x = visibleColumnFrame.minX - (width - TabbedOverlayMetrics.totalWidth)
        let y = visibleColumnFrame.minY + (visibleColumnFrame.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func syncSurfaceRegistration() {
        let currentWindowNumber = windowNumber
        guard currentWindowNumber > 0 else {
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }
        guard registeredSurfaceWindowNumber != currentWindowNumber else { return }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: currentWindowNumber,
            frameProvider: { [weak self] in
                self?.lastFrame
            },
            visibilityProvider: { [weak self] in
                self?.isVisible == true && self?.lastFrame != nil
            },
            policy: SurfacePolicy(
                kind: .tabbedColumnOverlay,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredSurfaceWindowNumber = currentWindowNumber
    }

    private static func surfaceID(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId) -> String {
        "tabbed-column-overlay-\(workspaceId.uuidString)-\(columnId.uuid.uuidString)"
    }

    func accessibilitySnapshotForTests() -> [TabbedColumnOverlayAccessibilitySnapshot] {
        overlayView.accessibilitySnapshotForTests()
    }

    func performAccessibilitySelectionForTests(_ visualIndex: Int) -> Bool {
        overlayView.performAccessibilitySelection(visualIndex)
    }
}

private final class TabbedColumnOverlayView: NSView {
    private var tabs: [TabbedColumnOverlayTabInfo] = []

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
    private var accessibilityTabElements: [TabbedColumnAccessibilityElement] = []

    private var tabCount: Int {
        tabs.count
    }

    private var activeVisualIndex = 0

    var onSelect: ((Int) -> Void)?

    func update(tabs: [TabbedColumnOverlayTabInfo], activeVisualIndex: Int) {
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
        refreshAccessibilityElements()
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
        let visualRailRect = TabbedRailLayout.visualRailRect(in: layout.railRect)

        fillRoundedRect(visualBarRect(in: visualRailRect), color: TabbedOverlayMetrics.backgroundColor)
        fillRect(gutterRect(in: visualRailRect), color: TabbedOverlayMetrics.gutterColor)
        fillRect(edgeRect(in: visualRailRect), color: TabbedOverlayMetrics.edgeColor)

        if isHovered {
            fillRoundedRect(visualRailRect, color: TabbedOverlayMetrics.hoverColor)
        }

        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)

        for item in layout.items {
            if item.visualIndex != clampedActiveVisualIndex {
                drawSegment(item, selected: false)
            }
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
        for item in currentLayout().items {
            if item.hitRect.contains(point) {
                return item.visualIndex
            }
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
        "Column tabs"
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
            width: TabbedOverlayMetrics.barThickness,
            height: railRect.height
        )
    }

    private func gutterRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX + TabbedOverlayMetrics.barThickness,
            y: railRect.minY,
            width: TabbedOverlayMetrics.spacing,
            height: railRect.height
        )
    }

    private func edgeRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX + TabbedOverlayMetrics.barThickness,
            y: railRect.minY + 1,
            width: TabbedOverlayMetrics.edgeLineWidth,
            height: max(0, railRect.height - 2)
        )
    }

    private func visualRectForSegment(_ item: TabbedRailLayout.Item, selected: Bool, hovered: Bool) -> CGRect {
        let segmentRect = item.pillRect
        let width = if selected {
            TabbedOverlayMetrics.activeSegmentWidth
        } else if hovered {
            TabbedOverlayMetrics.hoveredSegmentWidth
        } else {
            TabbedOverlayMetrics.inactiveSegmentWidth
        }
        let x = segmentRect.midX - width / 2
        return CGRect(
            x: x,
            y: segmentRect.origin.y,
            width: width,
            height: segmentRect.height
        )
    }

    private func drawSegment(_ item: TabbedRailLayout.Item, selected: Bool) {
        let hovered = hoveredVisualIndex == item.visualIndex
        let segmentRect = visualRectForSegment(item, selected: selected, hovered: hovered)
        guard segmentRect.width > 0, segmentRect.height > 0 else { return }
        let path = NSBezierPath(
            roundedRect: segmentRect,
            xRadius: TabbedOverlayMetrics.cornerRadius,
            yRadius: TabbedOverlayMetrics.cornerRadius
        )
        if selected {
            TabbedOverlayMetrics.selectedColor(hovered: hovered).setFill()
        } else {
            TabbedOverlayMetrics.unselectedColor(hovered: hovered, railHovered: isHovered).setFill()
        }
        path.fill()

        if selected {
            TabbedOverlayMetrics.selectedStrokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func fillRoundedRect(_ rect: CGRect, color: NSColor) {
        color.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: TabbedOverlayMetrics.cornerRadius,
            yRadius: TabbedOverlayMetrics.cornerRadius
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

    private func currentLayout() -> TabbedRailLayout {
        TabbedRailLayout(tabCount: tabCount, bounds: bounds)
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
            let element = TabbedColumnAccessibilityElement(
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

    fileprivate func performAccessibilitySelection(_ visualIndex: Int) -> Bool {
        guard tabs.contains(where: { $0.visualIndex == visualIndex }) else { return false }
        onSelect?(visualIndex)
        return true
    }

    private func screenFrame(for rect: CGRect) -> CGRect {
        guard let window else { return .zero }
        let windowRect = convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    fileprivate func accessibilitySnapshotForTests() -> [TabbedColumnOverlayAccessibilitySnapshot] {
        accessibilityTabElements.map { $0.snapshotForTests() }
    }

    private static func hasSameAccessibilityMetadata(
        _ lhs: [TabbedColumnOverlayTabInfo],
        _ rhs: [TabbedColumnOverlayTabInfo]
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

private final class TabbedColumnAccessibilityElement: NSAccessibilityElement {
    private weak var parentElement: AnyObject?
    private var tab: TabbedColumnOverlayTabInfo
    private var screenFrame: CGRect
    private let pressAction: (Int) -> Void
    private(set) var isSelected: Bool

    var visualIndex: Int {
        tab.visualIndex
    }

    init(parent: AnyObject, tab: TabbedColumnOverlayTabInfo, screenFrame: CGRect, pressAction: @escaping (Int) -> Void) {
        parentElement = parent
        self.tab = tab
        self.screenFrame = screenFrame
        self.pressAction = pressAction
        isSelected = tab.isActive
        super.init()
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .radioButton
    }

    override func accessibilityLabel() -> String? {
        tab.accessibilityLabel
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: isSelected)
    }

    override func accessibilityParent() -> Any? {
        parentElement
    }

    override func accessibilityFrame() -> NSRect {
        screenFrame
    }

    override func isAccessibilityEnabled() -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        pressAction(tab.visualIndex)
        return true
    }

    func update(tab: TabbedColumnOverlayTabInfo, screenFrame: CGRect) {
        self.tab = tab
        self.screenFrame = screenFrame
    }

    func updateSelected(_ selected: Bool, postNotification: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        if postNotification {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    func snapshotForTests() -> TabbedColumnOverlayAccessibilitySnapshot {
        TabbedColumnOverlayAccessibilitySnapshot(
            visualIndex: tab.visualIndex,
            role: accessibilityRole(),
            label: accessibilityLabel(),
            value: isSelected,
            frame: accessibilityFrame()
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
