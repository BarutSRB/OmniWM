// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

@MainActor
final class OverviewWindow: NSPanel {
    private let overlayView: OverviewView
    private let monitor: Monitor

    var monitorId: Monitor.ID { monitor.id }

    var onWindowSelected: ((Monitor.ID, WindowHandle) -> Void)?
    var onWindowClosed: ((Monitor.ID, WindowHandle) -> Void)?
    var onDismiss: ((Monitor.ID) -> Void)?
    var onScroll: ((Monitor.ID, CGFloat) -> Void)?
    var onScrollWithModifiers: ((Monitor.ID, CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    var onDragBegin: ((Monitor.ID, WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((Monitor.ID, CGPoint) -> Void)?
    var onDragEnd: ((Monitor.ID, CGPoint) -> Void)?
    var onDragCancel: (() -> Void)?

    init(monitor: Monitor) {
        self.monitor = monitor
        overlayView = OverviewView(frame: .zero)

        super.init(
            contentRect: monitor.frame,
            styleMask: [.borderless],
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
            guard let self else { return }
            self.onWindowSelected?(self.monitor.id, handle)
        }
        overlayView.onWindowClosed = { [weak self] handle in
            guard let self else { return }
            self.onWindowClosed?(self.monitor.id, handle)
        }
        overlayView.onDismiss = { [weak self] in
            guard let self else { return }
            self.onDismiss?(self.monitor.id)
        }
        overlayView.onScroll = { [weak self] delta in
            guard let self else { return }
            self.onScroll?(self.monitor.id, delta)
        }
        overlayView.onScrollWithModifiers = { [weak self] delta, modifiers, isPrecise in
            guard let self else { return }
            self.onScrollWithModifiers?(self.monitor.id, delta, modifiers, isPrecise)
        }
        overlayView.onDragBegin = { [weak self] handle, start in
            guard let self else { return }
            self.onDragBegin?(self.monitor.id, handle, start)
        }
        overlayView.onDragUpdate = { [weak self] point in
            guard let self else { return }
            self.onDragUpdate?(self.monitor.id, point)
        }
        overlayView.onDragEnd = { [weak self] point in
            guard let self else { return }
            self.onDragEnd?(self.monitor.id, point)
        }
        overlayView.onDragCancel = { [weak self] in
            self?.onDragCancel?()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(asKeyWindow: Bool) {
        setFrame(monitor.frame, display: false)
        overlayView.frame = CGRect(origin: .zero, size: monitor.frame.size)
        if asKeyWindow {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(overlayView)
        } else {
            orderFrontRegardless()
        }
    }

    func hide() {
        orderOut(nil)
    }

    func cancelPendingDragIfNeeded(optionPressed: Bool) {
        overlayView.cancelPendingDragIfNeeded(optionPressed: optionPressed)
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
    var onScroll: ((CGFloat) -> Void)?
    var onScrollWithModifiers: ((CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    var onDragBegin: ((WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    var onDragCancel: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragCandidateHandle: WindowHandle?
    private var dragStartPoint: CGPoint = .zero
    private var isDragging: Bool = false
    private let dragThreshold: CGFloat = 6.0
    private let scrollAxisEpsilon: CGFloat = 0.0001

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    func cancelPendingDragIfNeeded(optionPressed: Bool) {
        if (isDragging || dragCandidateHandle != nil), !optionPressed {
            cancelDrag()
        }
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
