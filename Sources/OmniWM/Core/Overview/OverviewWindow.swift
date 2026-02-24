import AppKit
import Foundation

@MainActor
final class OverviewWindow: NSPanel {
    private let overlayView: OverviewView
    private let monitor: Monitor

    var onWindowSelected: ((WindowHandle) -> Void)?
    var onWindowClosed: ((WindowHandle) -> Void)?
    var onDismiss: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onNavigate: ((Direction) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onScrollWithModifiers: ((CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    var onDragBegin: ((WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    var onDragCancel: (() -> Void)?

    init(monitor: Monitor) {
        self.monitor = monitor
        overlayView = OverviewView(frame: .zero)

        super.init(
            contentRect: monitor.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        contentView = overlayView
        overlayView.frame = CGRect(origin: .zero, size: monitor.frame.size)

        overlayView.onWindowSelected = { [weak self] handle in
            self?.onWindowSelected?(handle)
        }
        overlayView.onWindowClosed = { [weak self] handle in
            self?.onWindowClosed?(handle)
        }
        overlayView.onDismiss = { [weak self] in
            self?.onDismiss?()
        }
        overlayView.onSearchChanged = { [weak self] query in
            self?.onSearchChanged?(query)
        }
        overlayView.onNavigate = { [weak self] direction in
            self?.onNavigate?(direction)
        }
        overlayView.onScroll = { [weak self] delta in
            self?.onScroll?(delta)
        }
        overlayView.onScrollWithModifiers = { [weak self] delta, modifiers, isPrecise in
            self?.onScrollWithModifiers?(delta, modifiers, isPrecise)
        }
        overlayView.onDragBegin = { [weak self] handle, start in
            self?.onDragBegin?(handle, start)
        }
        overlayView.onDragUpdate = { [weak self] point in
            self?.onDragUpdate?(point)
        }
        overlayView.onDragEnd = { [weak self] point in
            self?.onDragEnd?(point)
        }
        overlayView.onDragCancel = { [weak self] in
            self?.onDragCancel?()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        setFrame(monitor.frame, display: false)
        overlayView.frame = CGRect(origin: .zero, size: monitor.frame.size)
        makeKeyAndOrderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }

    func updateLayout(_ layout: OverviewLayout, state: OverviewState, searchQuery: String) {
        overlayView.layout = layout
        overlayView.overviewState = state
        overlayView.searchQuery = searchQuery
        overlayView.needsDisplay = true
    }

    func updateThumbnails(_ thumbnails: [Int: CGImage]) {
        overlayView.thumbnails = thumbnails
        overlayView.needsDisplay = true
    }
}

@MainActor
final class OverviewView: NSView {
    var layout: OverviewLayout = .init()
    var overviewState: OverviewState = .closed
    var searchQuery: String = ""
    var thumbnails: [Int: CGImage] = [:]

    var onWindowSelected: ((WindowHandle) -> Void)?
    var onWindowClosed: ((WindowHandle) -> Void)?
    var onDismiss: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onNavigate: ((Direction) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onScrollWithModifiers: ((CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    var onDragBegin: ((WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    var onDragCancel: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var dragCandidateHandle: WindowHandle?
    private var dragStartPoint: CGPoint = .zero
    private var isDragging: Bool = false
    private let dragThreshold: CGFloat = 6.0
    private let scrollAxisEpsilon: CGFloat = 0.0001

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return handleKeyDown(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if (self.isDragging || self.dragCandidateHandle != nil),
               !event.modifierFlags.contains(.option)
            {
                self.cancelDrag()
            }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard overviewState.isOpen else { return false }

        switch event.keyCode {
        case 53:
            if !searchQuery.isEmpty {
                searchQuery = ""
                onSearchChanged?("")
            } else {
                onDismiss?()
            }
            return true
        case 36, 76:
            if let selected = layout.selectedWindow() {
                onWindowSelected?(selected.handle)
            }
            return true
        case 123:
            onNavigate?(.left)
            return true
        case 124:
            onNavigate?(.right)
            return true
        case 125:
            onNavigate?(.down)
            return true
        case 126:
            onNavigate?(.up)
            return true
        case 48:
            let direction: Direction = event.modifierFlags.contains(.shift) ? .left : .right
            onNavigate?(direction)
            return true
        case 51:
            if !searchQuery.isEmpty {
                searchQuery = String(searchQuery.dropLast())
                onSearchChanged?(searchQuery)
            }
            return true
        default:
            if let characters = event.charactersIgnoringModifiers,
               !characters.isEmpty,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            {
                let char = characters.first!
                if char.isLetter || char.isNumber || char == " " {
                    searchQuery += String(char)
                    onSearchChanged?(searchQuery)
                    return true
                }
            }
        }
        return false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoverState(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if layout.isCloseButtonAt(point: point) {
            if let window = layout.windowAt(point: point) {
                onWindowClosed?(window.handle)
            }
            return
        }

        if let window = layout.windowAt(point: point) {
            if event.modifierFlags.contains(.option) {
                dragCandidateHandle = window.handle
                dragStartPoint = point
                isDragging = false
            } else {
                onWindowSelected?(window.handle)
            }
            return
        }

        onDismiss?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = dragCandidateHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y)

        if !isDragging {
            guard distance >= dragThreshold else { return }
            isDragging = true
            onDragBegin?(handle, dragStartPoint)
        }

        onDragUpdate?(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDragging {
            onDragEnd?(point)
            cancelDragState()
            return
        }

        guard dragCandidateHandle != nil else { return }
        cancelDragState()

        if layout.isCloseButtonAt(point: point) {
            if let window = layout.windowAt(point: point) {
                onWindowClosed?(window.handle)
            }
            return
        }

        if let window = layout.windowAt(point: point) {
            onWindowSelected?(window.handle)
            return
        }

        onDismiss?()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = normalizedScrollDelta(for: event)
        if let onScrollWithModifiers {
            onScrollWithModifiers(delta, event.modifierFlags, event.hasPreciseScrollingDeltas)
        } else {
            onScroll?(delta)
        }
    }

    private func normalizedScrollDelta(for event: NSEvent) -> CGFloat {
        let rawY = event.scrollingDeltaY
        let rawX = event.scrollingDeltaX
        let dominantRaw = abs(rawY) >= abs(rawX) ? rawY : rawX
        if abs(dominantRaw) <= scrollAxisEpsilon {
            return 0
        }
        return event.isDirectionInvertedFromDevice ? -dominantRaw : dominantRaw
    }

    private func cancelDrag() {
        if isDragging {
            onDragCancel?()
        }
        cancelDragState()
    }

    private func cancelDragState() {
        dragCandidateHandle = nil
        isDragging = false
    }

    private func updateHoverState(at point: CGPoint) {
        let isCloseButton = layout.isCloseButtonAt(point: point)
        if let window = layout.windowAt(point: point) {
            layout.setHovered(handle: window.handle, closeButtonHovered: isCloseButton)
        } else {
            layout.setHovered(handle: nil)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let progress: Double = switch overviewState {
        case .closed: 0.0
        case let .opening(p): p
        case .open: 1.0
        case let .closing(_, p): 1.0 - p
        }

        OverviewRenderer.render(
            context: context,
            layout: layout,
            thumbnails: thumbnails,
            searchQuery: searchQuery,
            progress: progress,
            bounds: bounds
        )
    }
}
