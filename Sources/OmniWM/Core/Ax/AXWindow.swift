import AppKit
import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<Int>) -> AXError

struct AXWindowRef: Hashable, @unchecked Sendable {
    let id: UUID
    let element: AXUIElement
}

enum AXErrorWrapper: Error {
    case cannotSetFrame
    case cannotGetAttribute
    case cannotGetWindowId
    case cannotGetRole
}

enum AXWindowService {
    static func role(_ window: AXWindowRef) throws(AXErrorWrapper) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value)
        guard result == .success, let role = value as? String else { throw .cannotGetRole }
        return role
    }

    static func title(_ window: AXWindowRef) throws(AXErrorWrapper) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.element, kAXTitleAttribute as CFString, &value)
        guard result == .success, let title = value as? String else { throw .cannotGetAttribute }
        return title
    }

    static func windowId(_ window: AXWindowRef) throws(AXErrorWrapper) -> Int {
        var value = 0

        let result = _AXUIElementGetWindow(window.element, &value)
        guard result == .success else { throw .cannotGetWindowId }
        return value
    }

    static func frame(_ window: AXWindowRef) throws(AXErrorWrapper) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(window.element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(window.element, kAXSizeAttribute as CFString, &sizeValue)
        guard posResult == .success,
              sizeResult == .success,
              let posRaw = positionValue,
              let sizeRaw = sizeValue,
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { throw .cannotGetAttribute }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { throw .cannotGetAttribute }
        return convertFromAX(CGRect(origin: pos, size: size))
    }

    static func setFrame(_ window: AXWindowRef, frame: CGRect) throws(AXErrorWrapper) {
        let axFrame = convertToAX(frame)
        var position = CGPoint(x: axFrame.origin.x, y: axFrame.origin.y)
        var size = CGSize(width: axFrame.size.width, height: axFrame.size.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { throw .cannotSetFrame }
        let err1 = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        let err2 = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        guard err1 == .success, err2 == .success else { throw .cannotSetFrame }
    }

    nonisolated(unsafe) private static var _cachedGlobalFrame: CGRect?

    static func invalidateGlobalFrameCache() {
        _cachedGlobalFrame = nil
    }

    private static var globalFrame: CGRect {
        if let cached = _cachedGlobalFrame {
            return cached
        }
        let frame = NSScreen.screens.reduce(into: CGRect.null) { result, screen in
            result = result.union(screen.frame)
        }
        _cachedGlobalFrame = frame
        return frame
    }

    private static func convertFromAX(_ rect: CGRect) -> CGRect {
        let global = globalFrame
        let flippedY = global.maxY - (rect.origin.y + rect.size.height)
        return CGRect(origin: CGPoint(x: rect.origin.x, y: flippedY), size: rect.size)
    }

    private static func convertToAX(_ rect: CGRect) -> CGRect {
        let global = globalFrame
        let flippedY = global.maxY - (rect.origin.y + rect.size.height)
        return CGRect(origin: CGPoint(x: rect.origin.x, y: flippedY), size: rect.size)
    }

    static func subrole(_ window: AXWindowRef) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return nil }
        return subrole
    }

    static func hasButton(_ window: AXWindowRef, button: CFString) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.element, button, &value)
        return result == .success && value != nil
    }

    static func isButtonEnabled(_ window: AXWindowRef, button: CFString) -> Bool {
        var buttonValue: CFTypeRef?
        let buttonResult = AXUIElementCopyAttributeValue(window.element, button, &buttonValue)
        guard buttonResult == .success, let buttonElement = buttonValue else { return false }

        var enabledValue: CFTypeRef?
        let enabledResult = AXUIElementCopyAttributeValue(
            buttonElement as! AXUIElement,
            kAXEnabledAttribute as CFString,
            &enabledValue
        )
        guard enabledResult == .success, let enabled = enabledValue as? Bool else { return false }
        return enabled
    }

    static func hasFullscreenButton(_ window: AXWindowRef) -> Bool {
        isButtonEnabled(window, button: kAXFullScreenButtonAttribute as CFString)
    }

    static func hasCloseButton(_ window: AXWindowRef) -> Bool {
        hasButton(window, button: kAXCloseButtonAttribute as CFString)
    }

    static func isPopup(_ window: AXWindowRef, appPolicy: NSApplication.ActivationPolicy?) -> Bool {
        if appPolicy == .accessory && !hasButton(window, button: kAXCloseButtonAttribute as CFString) {
            return true
        }

        let hasAnyButton = hasButton(window, button: kAXCloseButtonAttribute as CFString) ||
                           hasButton(window, button: kAXFullScreenButtonAttribute as CFString) ||
                           hasButton(window, button: kAXZoomButtonAttribute as CFString) ||
                           hasButton(window, button: kAXMinimizeButtonAttribute as CFString)

        if !hasAnyButton {
            let sub = subrole(window)
            if sub != kAXStandardWindowSubrole as String {
                return true
            }
        }

        return false
    }

    static func isFullscreen(_ window: AXWindowRef) -> Bool {
        if let subrole = subrole(window), subrole == "AXFullScreenWindow" {
            return true
        }

        var value: CFTypeRef?
        let fullScreenAttribute = "AXFullScreen" as CFString
        let result = AXUIElementCopyAttributeValue(
            window.element,
            fullScreenAttribute,
            &value
        )
        if result == .success, let boolValue = value as? Bool {
            return boolValue
        }

        if let frame = try? frame(window) {
            return isFullscreenFrame(frame)
        }

        return false
    }

    static func setNativeFullscreen(_ window: AXWindowRef, fullscreen: Bool) -> Bool {
        let fullScreenAttribute = "AXFullScreen" as CFString
        let result = AXUIElementSetAttributeValue(
            window.element,
            fullScreenAttribute,
            fullscreen as CFBoolean
        )
        return result == .success
    }

    static func isMinimized(_ window: AXWindowRef) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window.element,
            kAXMinimizedAttribute as CFString,
            &value
        )
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    static func setMinimized(_ window: AXWindowRef, minimized: Bool) -> Bool {
        let result = AXUIElementSetAttributeValue(
            window.element,
            kAXMinimizedAttribute as CFString,
            minimized as CFBoolean
        )
        return result == .success
    }

    private static func isFullscreenFrame(_ frame: CGRect) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            return false
        }

        let tolerance: CGFloat = 2.0
        let screenFrame = screen.frame

        return abs(frame.origin.x - screenFrame.origin.x) <= tolerance &&
            abs(frame.origin.y - screenFrame.origin.y) <= tolerance &&
            abs(frame.size.width - screenFrame.size.width) <= tolerance &&
            abs(frame.size.height - screenFrame.size.height) <= tolerance
    }

    static func windowType(_ window: AXWindowRef, appPolicy: NSApplication.ActivationPolicy?) -> AXWindowType {
        if isPopup(window, appPolicy: appPolicy) {
            return .floating
        }

        let subrole = subrole(window)
        if let subrole, subrole != (kAXStandardWindowSubrole as String) {
            return .floating
        }

        if !hasFullscreenButton(window) {
            return .floating
        }

        return .tiling
    }

    static func isResizable(_ window: AXWindowRef) -> Bool {
        var value: CFTypeRef?

        let growResult = AXUIElementCopyAttributeValue(
            window.element,
            "AXGrowArea" as CFString,
            &value
        )
        if growResult == .success, value != nil {
            return true
        }

        let zoomResult = AXUIElementCopyAttributeValue(
            window.element,
            kAXZoomButtonAttribute as CFString,
            &value
        )
        if zoomResult == .success, value != nil {
            return true
        }

        if let subrole = subrole(window), subrole == (kAXStandardWindowSubrole as String) {
            return true
        }

        return false
    }

    static func sizeConstraints(_ window: AXWindowRef, currentSize: CGSize? = nil) -> WindowSizeConstraints {
        let resizable = isResizable(window)

        if !resizable {
            if let size = currentSize {
                return .fixed(size: size)
            }

            if let frame = try? frame(window) {
                return .fixed(size: frame.size)
            }
            return .unconstrained
        }

        var minSize = CGSize(width: 100, height: 100)
        var maxSize = CGSize.zero

        var value: CFTypeRef?

        let minResult = AXUIElementCopyAttributeValue(
            window.element,
            "AXMinSize" as CFString,
            &value
        )
        if minResult == .success,
           let rawValue = value,
           CFGetTypeID(rawValue) == AXValueGetTypeID()
        {
            var size = CGSize.zero
            if AXValueGetValue(rawValue as! AXValue, .cgSize, &size) {
                minSize = size
            }
        }

        let maxResult = AXUIElementCopyAttributeValue(
            window.element,
            "AXMaxSize" as CFString,
            &value
        )
        if maxResult == .success,
           let rawValue = value,
           CFGetTypeID(rawValue) == AXValueGetTypeID()
        {
            var size = CGSize.zero
            if AXValueGetValue(rawValue as! AXValue, .cgSize, &size) {
                maxSize = size
            }
        }

        return WindowSizeConstraints(
            minSize: minSize,
            maxSize: maxSize,
            isFixed: false
        )
    }
}

enum AXWindowType {
    case tiling
    case floating
}
