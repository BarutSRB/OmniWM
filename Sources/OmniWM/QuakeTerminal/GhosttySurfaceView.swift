// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import GhosttyKit
import QuartzCore

@MainActor
final class GhosttySurfaceCallbackContext {
    weak var controller: QuakeTerminalController?
    weak var view: GhosttySurfaceView?

    init(controller: QuakeTerminalController) {
        self.controller = controller
    }

    static func installCloseCallback(in runtimeConfig: inout ghostty_runtime_config_s) {
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            guard let userdata else { return }
            let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard let controller = context.controller, let view = context.view else { return }
                controller.surfaceClosed(view: view, processAlive: processAlive)
            }
        }
    }
}

@MainActor
final class GhosttySurfaceView: NSView {
    private(set) var ghosttySurface: ghostty_surface_t?
    private var retainedCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    private lazy var textInput = GhosttySurfaceTextInput(view: self)
    private var lastAppliedSurfacePixelSize: GhosttySurfacePixelSize?
    private var lastAppliedContentScale: CGFloat?
    private var lastAppliedDisplayId: UInt32?
    private var occlusionHandlerForTests: ((Bool) -> Void)?

    private let windowInteraction = QuakeWindowInteraction()

    var isInteracting: Bool {
        windowInteraction.isInteracting
    }

    private var pendingProtectedClipboardRequests: [GhosttyProtectedClipboardRequest] = []
    var onFrameChanged: ((NSRect) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        false
    }

    init(ghosttyApp: ghostty_app_t, callbackContext: GhosttySurfaceCallbackContext) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))

        callbackContext.view = self
        let retainedContext = Unmanaged.passRetained(callbackContext)

        // libghostty installs its own IOSurface-backed CALayer on this view
        // (making it layer-hosting) and seeds that layer's contentsScale from
        // scale_factor. We have no window yet, so this is only a guess; the
        // authoritative scale is pushed from the window in updateDisplayState.
        let initialScale = NSScreen.main?.backingScaleFactor ?? 1.0

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = Double(initialScale)
        config.userdata = retainedContext.toOpaque()

        guard let surface = ghostty_surface_new(ghosttyApp, &config) else {
            Log.terminal.error("Failed to create surface")
            retainedContext.release()
            return
        }
        self.ghosttySurface = surface
        self.retainedCallbackContext = retainedContext
        lastAppliedContentScale = initialScale
        updateSurfaceOcclusion()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    init(occlusionHandlerForTests: @escaping (Bool) -> Void) {
        self.occlusionHandlerForTests = occlusionHandlerForTests
        super.init(frame: .zero)
        updateSurfaceOcclusion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        releaseSurface()
    }

    private var displayId: UInt32? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        updateSurfaceOcclusion()
        guard let window else { return }
        updateDisplayState()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeBackingProperties(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionState(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    @objc private func windowDidChangeBackingProperties(_ notification: Notification) {
        updateDisplayState()
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        updateDisplayState()
        // The window's backing scale can lag the screen change by a turn of
        // the run loop. Re-check once it has settled, as Ghostty's own view does.
        DispatchQueue.main.async { [weak self] in
            self?.updateDisplayState()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayState()
    }

    @objc private func windowDidChangeOcclusionState(_ notification: Notification) {
        updateSurfaceOcclusion()
    }

    private func updateSurfaceOcclusion() {
        let visible = window?.occlusionState.contains(.visible) == true
        if let occlusionHandlerForTests {
            occlusionHandlerForTests(visible)
        } else if let surface = ghosttySurface {
            ghostty_surface_set_occlusion(surface, visible)
        }
    }

    /// Pushes the window's backing scale, display, and pixel size to Ghostty.
    ///
    /// Ghostty sizes its render target from `layer.bounds * layer.contentsScale`
    /// and its grid from `ghostty_surface_set_size`, so the layer scale, the
    /// content scale, and the pixel size must all come from the same window.
    /// Without a window there is no authoritative scale, so nothing is pushed;
    /// `viewDidMoveToWindow` runs this again once one is available.
    private func updateDisplayState() {
        guard let surface = ghosttySurface, let window else { return }
        let scale = window.backingScaleFactor

        if let layer, layer.contentsScale != scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            CATransaction.commit()
        }

        if let displayId, displayId != lastAppliedDisplayId {
            ghostty_surface_set_display_id(surface, displayId)
            lastAppliedDisplayId = displayId
            lastAppliedSurfacePixelSize = nil
        }

        if lastAppliedContentScale != scale {
            ghostty_surface_set_content_scale(surface, scale, scale)
            lastAppliedContentScale = scale
            lastAppliedSurfacePixelSize = nil
        }

        syncGhosttySurfaceSize(backingScale: scale)
    }

    func refreshDisplayStateForCurrentScreen() {
        lastAppliedDisplayId = nil
        lastAppliedContentScale = nil
        lastAppliedSurfacePixelSize = nil
        updateDisplayState()
    }

    func registerProtectedClipboardRequest(_ request: GhosttyProtectedClipboardRequest) {
        pendingProtectedClipboardRequests.append(request)
    }

    func resolveProtectedClipboardRequest(
        _ request: GhosttyProtectedClipboardRequest,
        allowing allowed: Bool,
        remember: Bool = false
    ) {
        pendingProtectedClipboardRequests.removeAll { $0 === request }
        guard let surface = ghosttySurface else { return }
        request.complete(on: surface, allowing: allowed, remember: remember)
    }

    private func denyPendingProtectedClipboardRequests(on surface: ghostty_surface_t) {
        let requests = pendingProtectedClipboardRequests
        pendingProtectedClipboardRequests.removeAll()
        for request in requests {
            request.complete(on: surface, allowing: false)
        }
    }

    func releaseSurface() {
        guard let surface = ghosttySurface else { return }
        retainedCallbackContext?.takeUnretainedValue().controller?.cancelClipboardPrompt(for: self)
        denyPendingProtectedClipboardRequests(on: surface)
        ghosttySurface = nil
        ghostty_surface_free(surface)

        guard let retainedContext = retainedCallbackContext else { return }
        retainedCallbackContext = nil
        DispatchQueue.main.async {
            retainedContext.release()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncGhosttySurfaceSize()
    }

    func syncGhosttySurfaceSize(backingScale explicitBackingScale: CGFloat? = nil) {
        guard let surface = ghosttySurface else { return }
        // A detached view has no trustworthy scale. Pushing the point size at
        // 1x would hand Ghostty a half-size grid on a Retina window, so wait
        // for viewDidMoveToWindow to resync instead.
        guard let scale = explicitBackingScale ?? window?.backingScaleFactor else { return }
        let surfaceSize = ghostty_surface_size(surface)

        let pixelSize = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: frame.size,
            backingScale: scale,
            cellMetrics: GhosttySurfaceCellMetrics(surfaceSize: surfaceSize)
        )
        guard let pixelSize, pixelSize != lastAppliedSurfacePixelSize else { return }

        ghostty_surface_set_size(surface, pixelSize.widthPx, pixelSize.heightPx)
        lastAppliedSurfacePixelSize = pixelSize
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = ghosttySurface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = ghosttySurface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        textInput.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        textInput.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        textInput.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        textInput.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        textInput.doCommand(by: selector)
    }

    override func mouseDown(with event: NSEvent) {
        if !windowInteraction.handleMouseDown(event, in: self) {
            handleMouseButton(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !windowInteraction.handleMouseUp(in: self, onFrameChanged: onFrameChanged) {
            handleMouseButton(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_RELEASE)
        }
        windowInteraction.finishMouseUp()
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseButton(event, button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_PRESS)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseButton(event, button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func otherMouseDown(with event: NSEvent) {
        handleMouseButton(event, button: GHOSTTY_MOUSE_MIDDLE, state: GHOSTTY_MOUSE_PRESS)
    }

    override func otherMouseUp(with event: NSEvent) {
        handleMouseButton(event, button: GHOSTTY_MOUSE_MIDDLE, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func mouseMoved(with event: NSEvent) {
        windowInteraction.updateCursor(for: event, in: self)
        handleMouseMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !windowInteraction.handleMouseDrag(in: self) {
            handleMouseMove(event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = ghosttySurface else { return }
        var scrollMods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 1
        }

        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            scrollMods
        )
    }

    private func handleMouseButton(
        _ event: NSEvent,
        button: ghostty_input_mouse_button_e,
        state: ghostty_input_mouse_state_e
    ) {
        guard let surface = ghosttySurface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = QuakeGhosttyInputBridge.ghosttyMods(event.modifierFlags)
        let flippedY = bounds.height - point.y
        ghostty_surface_mouse_pos(surface, point.x, flippedY, mods)
        _ = ghostty_surface_mouse_button(surface, state, button, mods)
    }

    private func handleMouseMove(_ event: NSEvent) {
        guard let surface = ghosttySurface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = QuakeGhosttyInputBridge.ghosttyMods(event.modifierFlags)
        let flippedY = bounds.height - point.y
        ghostty_surface_mouse_pos(surface, point.x, flippedY, mods)
    }
}

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        textInput.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        textInput.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    func unmarkText() {
        textInput.unmarkText()
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        textInput.markedRange()
    }

    func hasMarkedText() -> Bool {
        textInput.hasMarkedText()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let screenFrame = window.convertToScreen(frame)
        return NSRect(x: screenFrame.minX, y: screenFrame.minY, width: 0, height: 0)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}
