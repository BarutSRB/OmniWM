// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class OverviewView: NSView {
    private(set) var layout: OverviewLayout = .init()
    private(set) var searchQuery: String = ""
    private(set) var palette: OverviewRenderPalette
    private(set) var selectedWindowHandle: WindowHandle?
    private(set) var presentationProgress: Double = 0

    private let displayId: CGDirectDisplayID

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
    private var hoveredWindowHandle: WindowHandle?
    private var closeButtonHovered = false
    let layerRenderer = OverviewLayerRenderer()
    private let dragThreshold: CGFloat = 6.0

    init(
        frame: NSRect,
        displayId: CGDirectDisplayID = CGMainDisplayID(),
        palette: OverviewRenderPalette = .default
    ) {
        self.displayId = displayId
        self.palette = palette
        selectedWindowHandle = nil
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(layerRenderer.root)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLayout(
        _ layout: OverviewLayout,
        state: OverviewState,
        searchQuery: String,
        selectedWindowHandle: WindowHandle?,
        palette: OverviewRenderPalette? = nil,
        animationsEnabled: Bool = true
    ) {
        self.layout = layout
        self.searchQuery = searchQuery
        self.selectedWindowHandle = selectedWindowHandle
        if let hoveredWindowHandle,
           layout.window(for: hoveredWindowHandle)?.matchesSearch != true
        {
            self.hoveredWindowHandle = nil
            closeButtonHovered = false
        }
        switch state {
        case .closed:
            cancelAnimation()
            presentationProgress = 0
        case .open:
            cancelAnimation()
            presentationProgress = 1
        case .opening,
             .closing:
            break
        }
        if let palette {
            self.palette = palette
        }
        layerRenderer.updateLayout(
            layout,
            state: renderState,
            caretAnimated: !state.isAnimating && state.isOpen && animationsEnabled
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        needsDisplay = true
    }

    @discardableResult
    func installAnimation(_ transition: OverviewNativeTransition, completion: OverviewAnimationCompletion) -> Bool {
        updateLayer()
        presentationProgress = transition.target
        needsDisplay = false
        guard window != nil, transition.duration > 0 else {
            cancelAnimation()
            updateLayer()
            return false
        }
        layerRenderer.installAnimation(transition, layout: layout, state: renderState, completion: completion)
        return true
    }

    func cancelAnimation() {
        layerRenderer.cancelAnimation()
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle) {
        layerRenderer.updatePreview(frame, for: handle)
    }

    func clearPreviews() {
        layerRenderer.clearPreviews()
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layerRenderer.updateContentsScale(window?.backingScaleFactor ?? 1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layerRenderer.updateContentsScale(window?.backingScaleFactor ?? 1)
    }

    func updatePalette(_ palette: OverviewRenderPalette) {
        self.palette = palette
        needsDisplay = true
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

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoverState(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = layerRenderer.windowHit(at: point, layout: layout)

        if let hit, hit.isCloseButton {
            onWindowClosed?(hit.window.handle)
            return
        }

        if let window = hit?.window {
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
        let hit = layerRenderer.windowHit(at: point, layout: layout)

        if let hit, hit.isCloseButton {
            onWindowClosed?(hit.window.handle)
            return
        }

        if let window = hit?.window {
            onWindowSelected?(window.handle)
            return
        }

        onDismiss?()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = OverviewScrollInput.dominantDelta(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        if let onScrollWithModifiers {
            onScrollWithModifiers(delta, event.modifierFlags, event.hasPreciseScrollingDeltas)
        } else {
            onScroll?(delta)
        }
    }

    private func cancelDrag() {
        if isDragging {
            onDragCancel?()
        }
        cancelDragState()
    }

    func cancelPendingDragIfNeeded(optionPressed: Bool) {
        if isDragging || dragCandidateHandle != nil, !optionPressed {
            cancelDrag()
        }
    }

    private func cancelDragState() {
        dragCandidateHandle = nil
        isDragging = false
    }

    private func updateHoverState(at point: CGPoint) {
        let hit = layerRenderer.windowHit(at: point, layout: layout)
        let nextHoveredHandle = hit?.window.handle
        let nextCloseButtonHovered = hit?.isCloseButton ?? false
        guard nextHoveredHandle != hoveredWindowHandle
            || nextCloseButtonHovered != closeButtonHovered
        else { return }
        let previous = hoveredWindowHandle
        hoveredWindowHandle = nextHoveredHandle
        closeButtonHovered = nextCloseButtonHovered
        layerRenderer.updateHover(from: previous, layout: layout, state: renderState)
    }

    override func updateLayer() {
        let traceActive = OverviewFrameTrace.shared.isActive
        let start = traceActive ? CACurrentMediaTime() : 0
        layerRenderer.updatePresentation(layout, state: renderState)
        if traceActive {
            let end = CACurrentMediaTime()
            OverviewFrameTrace.shared.record(OverviewFrameTrace.Record(
                event: .layerApply,
                mediaTime: end,
                displayId: displayId,
                generation: layerRenderer.activeTransition?.generation ?? 0,
                sequence: 0,
                progress: presentationProgress,
                durationMs: (end - start) * 1000,
                waitMs: 0,
                targetLeadMs: 0,
                pendingInvalidations: 0,
                endpointScheduled: false,
                sessionCompleted: false
            ))
        }
    }
}

extension OverviewView {
    private var renderState: OverviewRenderState {
        OverviewRenderState(
            searchQuery: searchQuery,
            selectedWindowHandle: selectedWindowHandle,
            hoveredWindowHandle: hoveredWindowHandle,
            closeButtonHovered: closeButtonHovered,
            progress: presentationProgress,
            bounds: bounds,
            palette: palette
        )
    }
}
