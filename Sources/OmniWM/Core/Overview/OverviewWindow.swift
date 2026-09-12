// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class OverviewWindow: NSPanel {
    private let overlayView: OverviewView
    private let monitor: Monitor

    var monitorId: Monitor.ID {
        monitor.id
    }

    var displayId: CGDirectDisplayID {
        monitor.displayId
    }

    var onWindowSelected: ((Monitor.ID, WindowHandle) -> Void)?
    var onWindowClosed: ((Monitor.ID, WindowHandle) -> Void)?
    var onDismiss: ((Monitor.ID) -> Void)?
    var onScroll: ((Monitor.ID, CGFloat) -> Void)?
    var onScrollWithModifiers: ((Monitor.ID, CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    var onDragBegin: ((Monitor.ID, WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((Monitor.ID, CGPoint) -> Void)?
    var onDragEnd: ((Monitor.ID, CGPoint) -> Void)?
    var onDragCancel: (() -> Void)?

    init(monitor: Monitor, palette: OverviewRenderPalette = .default) {
        self.monitor = monitor
        overlayView = OverviewView(frame: .zero, displayId: monitor.displayId, palette: palette)

        super.init(
            contentRect: monitor.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        bindOverlayEvents()
    }

    private func configurePanel() {
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
    }

    private func bindOverlayEvents() {
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

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

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

    func updateLayout(
        _ layout: OverviewLayout,
        state: OverviewState,
        searchQuery: String,
        selectedWindowHandle: WindowHandle?,
        palette: OverviewRenderPalette? = nil,
        thumbnails: [Int: CGImage]? = nil
    ) {
        overlayView.updateLayout(
            layout,
            state: state,
            searchQuery: searchQuery,
            selectedWindowHandle: selectedWindowHandle,
            palette: palette,
            thumbnails: thumbnails
        )
    }

    func updateThumbnails(_ thumbnails: [Int: CGImage]) {
        overlayView.updateThumbnails(thumbnails)
    }

    func updateAnimationProgress(
        _ progress: Double,
        generation: UInt64,
        sequence: UInt64
    ) {
        overlayView.updateAnimationProgress(
            progress,
            generation: generation,
            sequence: sequence
        )
    }

    func updatePalette(_ palette: OverviewRenderPalette) {
        overlayView.updatePalette(palette)
    }
}
