// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import GhosttyKit
import QuartzCore

struct GhosttySurfaceResizeEdgeClassifier {
    private static let perimeterTolerance: CGFloat = 0.5

    static func classifyEdges(
        at point: CGPoint,
        localBounds: CGRect,
        paneFrame: CGRect,
        containerBounds: CGRect,
        threshold: CGFloat
    ) -> ResizeEdge {
        var edges: ResizeEdge = []

        if point.x <= threshold,
           abs(paneFrame.minX - containerBounds.minX) <= perimeterTolerance {
            edges.insert(.left)
        } else if point.x >= localBounds.width - threshold,
                  abs(paneFrame.maxX - containerBounds.maxX) <= perimeterTolerance {
            edges.insert(.right)
        }

        if point.y <= threshold,
           abs(paneFrame.minY - containerBounds.minY) <= perimeterTolerance {
            edges.insert(.bottom)
        } else if point.y >= localBounds.height - threshold,
                  abs(paneFrame.maxY - containerBounds.maxY) <= perimeterTolerance {
            edges.insert(.top)
        }

        return edges
    }
}

@MainActor
final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    private(set) var ghosttySurface: ghostty_surface_t?
    private var markedText: NSMutableAttributedString = NSMutableAttributedString()
    private var keyTextAccumulator: [String]? = nil
    private var lastPerformKeyEvent: TimeInterval?

    private let resizeEdgeThreshold: CGFloat = 8.0

    private enum InteractionMode {
        case terminal
        case windowMove(startOrigin: CGPoint, startMouseLocation: CGPoint)
        case windowResize(edges: ResizeEdge, startFrame: NSRect, startMouseLocation: CGPoint)
    }

    private var interactionMode: InteractionMode = .terminal
    private(set) var isInteracting: Bool = false
    var onFrameChanged: ((NSRect) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init(testFrame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 400)) {
        super.init(frame: testFrame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    init(ghosttyApp: ghostty_app_t, userdata: UnsafeMutableRawPointer) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 1.0)
        config.userdata = userdata

        guard let surface = ghostty_surface_new(ghosttyApp, &config) else {
            return
        }
        self.ghosttySurface = surface

        if let layer {
            let scale = layer.contentsScale
            ghostty_surface_set_content_scale(surface, scale, scale)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let displayId, let surface = ghosttySurface {
            ghostty_surface_set_display_id(surface, displayId)
        }
        return metalLayer
    }

    private var displayId: UInt32? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        updateContentScale()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeBackingProperties(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: window
        )
    }

    @objc private func windowDidChangeBackingProperties(_ notification: Notification) {
        updateContentScale()
    }

    private func updateContentScale() {
        guard let metalLayer = layer as? CAMetalLayer, let surface = ghosttySurface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        metalLayer.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface = ghosttySurface else { return }
        let scale = window?.backingScaleFactor ?? 1.0
        ghostty_surface_set_size(surface, UInt32(newSize.width * scale), UInt32(newSize.height * scale))
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
        guard let surface = ghosttySurface else {
            interpretKeyEvents([event])
            return
        }

        let translationEvent = event.quakeTranslationEvent(surface: surface)
        let markedTextBefore = markedText.length > 0
        let keyboardLayoutBefore = markedTextBefore ? nil : QuakeGhosttyInputBridge.keyboardLayoutID
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardLayoutBefore != QuakeGhosttyInputBridge.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text
                )
            }
            return
        }

        _ = keyAction(
            action,
            event: event,
            translationEvent: translationEvent,
            text: translationEvent.quakeGhosttyCharacters,
            composing: markedText.length > 0 || markedTextBefore
        )
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if hasMarkedText() { return }
        guard let action = QuakeGhosttyInputBridge.modifierAction(for: event) else { return }
        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard window?.firstResponder === self, window?.isKeyWindow == true else { return false }

        if keyEventIsBinding(event) {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers ?? "" {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            if event.timestamp == 0 {
                return false
            }

            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let translatedEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else {
            return false
        }

        keyDown(with: translatedEvent)
        return true
    }

    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }

        switch selector {
        case #selector(moveToBeginningOfDocument(_:)):
            performBindingAction("scroll_to_top")
        case #selector(moveToEndOfDocument(_:)):
            performBindingAction("scroll_to_bottom")
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            handleMouseButton(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let edges = detectResizeEdges(at: point)

        if !edges.isEmpty {
            isInteracting = true
            interactionMode = .windowResize(edges: edges, startFrame: window.frame, startMouseLocation: NSEvent.mouseLocation)
            return
        }

        if event.modifierFlags.contains(.option) {
            isInteracting = true
            interactionMode = .windowMove(startOrigin: window.frame.origin, startMouseLocation: NSEvent.mouseLocation)
            NSCursor.closedHand.set()
            return
        }

        handleMouseButton(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        switch interactionMode {
        case .terminal:
            handleMouseButton(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_RELEASE)
        case .windowMove, .windowResize:
            if let frame = window?.frame {
                onFrameChanged?(frame)
            }
            NSCursor.arrow.set()
        }
        isInteracting = false
        interactionMode = .terminal
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
        let point = convert(event.locationInWindow, from: nil)
        let edges = detectResizeEdges(at: point)

        if !edges.isEmpty {
            edges.cursor.set()
        } else {
            NSCursor.arrow.set()
        }

        handleMouseMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        switch interactionMode {
        case .terminal:
            handleMouseMove(event)
        case let .windowMove(startOrigin, startMouseLocation):
            let current = NSEvent.mouseLocation
            let delta = CGPoint(x: current.x - startMouseLocation.x, y: current.y - startMouseLocation.y)
            window?.setFrameOrigin(CGPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y))
        case let .windowResize(edges, startFrame, startMouseLocation):
            let current = NSEvent.mouseLocation
            let delta = CGPoint(x: current.x - startMouseLocation.x, y: current.y - startMouseLocation.y)
            let newFrame = calculateResizedFrame(startFrame: startFrame, edges: edges, delta: delta)
            window?.setFrame(newFrame, display: true)
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

    private func handleMouseButton(_ event: NSEvent, button: ghostty_input_mouse_button_e, state: ghostty_input_mouse_state_e) {
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

    private func detectResizeEdges(at point: CGPoint) -> ResizeEdge {
        GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: point,
            localBounds: bounds,
            paneFrame: frame,
            containerBounds: superview?.bounds ?? frame,
            threshold: resizeEdgeThreshold
        )
    }

    private func calculateResizedFrame(startFrame: NSRect, edges: ResizeEdge, delta: CGPoint) -> NSRect {
        var frame = startFrame
        let minWidth: CGFloat = 200
        let minHeight: CGFloat = 100

        if edges.contains(.right) {
            frame.size.width = max(minWidth, startFrame.width + delta.x)
        }
        if edges.contains(.left) {
            let proposed = startFrame.width - delta.x
            if proposed >= minWidth {
                frame.origin.x = startFrame.origin.x + delta.x
                frame.size.width = proposed
            }
        }
        if edges.contains(.top) {
            frame.size.height = max(minHeight, startFrame.height + delta.y)
        }
        if edges.contains(.bottom) {
            let proposed = startFrame.height - delta.y
            if proposed >= minHeight {
                frame.origin.y = startFrame.origin.y + delta.y
                frame.size.height = proposed
            }
        }
        return frame
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = QuakeGhosttyInputBridge.committedText(from: string) else { return }

        unmarkText()

        if var accumulated = keyTextAccumulator {
            accumulated.append(text)
            keyTextAccumulator = accumulated
            return
        }

        sendSurfaceText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: value)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            return
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
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

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface = ghosttySurface else { return false }

        var keyEvent = event.quakeGhosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        if let text,
           !text.isEmpty,
           let codepoint = text.utf8.first,
           codepoint >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }

        return ghostty_surface_key(surface, keyEvent)
    }

    private func keyEventIsBinding(_ event: NSEvent) -> Bool {
        guard let surface = ghosttySurface else { return false }

        var keyEvent = event.quakeGhosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        let text = event.characters ?? ""
        return text.withCString { ptr in
            var bindingFlags = ghostty_binding_flags_e(0)
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &bindingFlags)
        }
    }

    private func sendSurfaceText(_ text: String) {
        guard let surface = ghosttySurface else { return }

        let length = text.utf8CString.count
        guard length > 1 else { return }

        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(length - 1))
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        if markedText.length > 0 {
            let text = markedText.string

            guard let surface = ghosttySurface else { return }
            let length = text.utf8CString.count
            guard length > 1 else { return }

            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(length - 1))
            }
        } else if clearIfNeeded {
            guard let surface = ghosttySurface else { return }
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private func performBindingAction(_ action: String) {
        guard let surface = ghosttySurface else { return }
        let length = action.utf8CString.count
        guard length > 1 else { return }

        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(length - 1))
        }
    }
}
