import AppKit
import GhosttyKit
import QuartzCore

@MainActor
final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    private(set) var ghosttySurface: ghostty_surface_t?
    private var markedText: NSMutableAttributedString = NSMutableAttributedString()
    private var keyTextAccumulator: [String]? = nil

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

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
            print("QuakeTerminal: Failed to create surface")
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
        guard let surface = ghosttySurface else { return }
        keyTextAccumulator = []
        defer {
            keyTextAccumulator = nil
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let handled = sendKeyEvent(event, action: action)

        if !handled {
            interpretKeyEvents([event])
        }

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                text.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
                }
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        _ = sendKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
    }

    @discardableResult
    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface = ghosttySurface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false

        if let chars = event.characters, !chars.isEmpty {
            return chars.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    override func mouseDown(with event: NSEvent) {
        handleMouseButton(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseButton(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_RELEASE)
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
        handleMouseMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseMove(event)
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
        let mods = modsFromEvent(event)

        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
        _ = ghostty_surface_mouse_button(surface, state, button, mods)
    }

    private func handleMouseMove(_ event: NSEvent) {
        guard let surface = ghosttySurface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = modsFromEvent(event)
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods: UInt32 = 0
        let flags = event.modifierFlags

        if flags.contains(.shift) { mods |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { mods |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { mods |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }

        return ghostty_input_mods_e(rawValue: mods)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String else { return }
        keyTextAccumulator?.append(str)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let str = string as? String {
            markedText = NSMutableAttributedString(string: str)
        } else if let attrStr = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attrStr)
        }
        guard let surface = ghosttySurface else { return }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    }

    func unmarkText() {
        markedText.mutableString.setString("")
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
}
