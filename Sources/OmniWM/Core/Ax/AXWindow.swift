import AppKit
import ApplicationServices
import Foundation

struct AXWindowRef: Hashable, @unchecked Sendable {
    let element: AXUIElement
    let windowId: Int

    init(element: AXUIElement, windowId: Int) {
        self.element = element
        self.windowId = windowId
    }

    init(element: AXUIElement) throws {
        self.element = element
        var value: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &value)
        guard result == .success else { throw AXErrorWrapper.cannotGetWindowId }
        self.windowId = Int(value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowId == rhs.windowId
    }
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

    @MainActor
    static func titlePreferFast(windowId: UInt32) -> String? {
        SkyLight.shared.getWindowTitle(windowId)
    }

    @MainActor
    static func titlePreferFast(_ window: AXWindowRef) -> String? {
        SkyLight.shared.getWindowTitle(UInt32(windowId(window)))
    }

    static func windowId(_ window: AXWindowRef) -> Int {
        window.windowId
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

    @MainActor
    static func fastFrame(windowId: UInt32) -> CGRect? {
        SkyLight.shared.getWindowBounds(windowId)
    }

    @MainActor
    static func fastFrame(_ window: AXWindowRef) -> CGRect? {
        SkyLight.shared.getWindowBounds(UInt32(windowId(window)))
    }

    @MainActor
    static func framePreferFast(_ window: AXWindowRef) -> CGRect? {
        fastFrame(window)
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
    nonisolated(unsafe) private static var _screenConfigurationToken: Int = 0

    private static var globalFrame: CGRect {
        let currentToken = NSScreen.screens.hashValue
        if let cached = _cachedGlobalFrame, currentToken == _screenConfigurationToken {
            return cached
        }
        let frame = NSScreen.screens.reduce(into: CGRect.null) { result, screen in
            result = result.union(screen.frame)
        }
        _cachedGlobalFrame = frame
        _screenConfigurationToken = currentToken
        return frame
    }

    static func invalidateGlobalFrameCache() {
        _cachedGlobalFrame = nil
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

    @MainActor
    static func isMinimizedPreferFast(_ window: AXWindowRef) -> Bool {
        !SkyLight.shared.isWindowOrderedIn(UInt32(windowId(window)))
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
        let center = frame.center
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            return false
        }
        return frame.approximatelyEqual(to: screen.frame, tolerance: 2.0)
    }

    static func windowType(
        _ window: AXWindowRef,
        appPolicy: NSApplication.ActivationPolicy?,
        bundleId: String? = nil
    ) -> AXWindowType {
        if DefaultFloatingApps.shouldFloat(bundleId) {
            return .floating
        }

        let attributes: [CFString] = [
            kAXSubroleAttribute as CFString,
            kAXCloseButtonAttribute as CFString,
            kAXFullScreenButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString
        ]

        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )

        guard result == .success, let valuesArray = values as? [Any?] else {
            return .floating
        }

        let subroleValue = valuesArray[0] as? String
        let hasCloseButton = valuesArray[1] != nil && !(valuesArray[1] is NSError)
        let fullscreenButtonElement = valuesArray[2]
        let hasFullscreenButton = fullscreenButtonElement != nil && !(fullscreenButtonElement is NSError)
        let hasZoomButton = valuesArray[3] != nil && !(valuesArray[3] is NSError)
        let hasMinimizeButton = valuesArray[4] != nil && !(valuesArray[4] is NSError)

        let hasAnyButton = hasCloseButton || hasFullscreenButton || hasZoomButton || hasMinimizeButton

        if appPolicy == .accessory && !hasCloseButton {
            return .floating
        }
        if !hasAnyButton && subroleValue != kAXStandardWindowSubrole as String {
            return .floating
        }

        if let subroleValue, subroleValue != (kAXStandardWindowSubrole as String) {
            return .floating
        }

        if hasFullscreenButton, let buttonElement = fullscreenButtonElement {
            var enabledValue: CFTypeRef?
            let enabledResult = AXUIElementCopyAttributeValue(
                buttonElement as! AXUIElement,
                kAXEnabledAttribute as CFString,
                &enabledValue
            )
            if enabledResult != .success || enabledValue as? Bool != true {
                return .floating
            }
        } else {
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
        fetchSizeConstraintsBatched(window, currentSize: currentSize)
    }

    private static func fetchSizeConstraintsBatched(
        _ window: AXWindowRef,
        currentSize: CGSize? = nil
    ) -> WindowSizeConstraints {
        let attributes: [CFString] = [
            "AXGrowArea" as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXSubroleAttribute as CFString,
            "AXMinSize" as CFString,
            "AXMaxSize" as CFString
        ]

        var values: CFArray?
        let attributesCFArray = attributes as CFArray
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributesCFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )

        var hasGrowArea = false
        var hasZoomButton = false
        var subroleValue: String?
        var minSize = CGSize(width: 100, height: 100)
        var maxSize = CGSize.zero

        if result == .success, let valuesArray = values as? [Any?] {
            if !valuesArray.isEmpty, valuesArray[0] != nil, !(valuesArray[0] is NSError) {
                hasGrowArea = true
            }
            if valuesArray.count > 1, valuesArray[1] != nil, !(valuesArray[1] is NSError) {
                hasZoomButton = true
            }
            if valuesArray.count > 2, let subrole = valuesArray[2] as? String {
                subroleValue = subrole
            }
            if valuesArray.count > 3, let minValue = valuesArray[3],
               CFGetTypeID(minValue as CFTypeRef) == AXValueGetTypeID()
            {
                var size = CGSize.zero
                if AXValueGetValue(minValue as! AXValue, .cgSize, &size) {
                    minSize = size
                }
            }
            if valuesArray.count > 4, let maxValue = valuesArray[4],
               CFGetTypeID(maxValue as CFTypeRef) == AXValueGetTypeID()
            {
                var size = CGSize.zero
                if AXValueGetValue(maxValue as! AXValue, .cgSize, &size) {
                    maxSize = size
                }
            }
        }

        let resizable = hasGrowArea || hasZoomButton || (subroleValue == (kAXStandardWindowSubrole as String))

        if !resizable {
            if let size = currentSize {
                return .fixed(size: size)
            }
            if let frame = try? frame(window) {
                return .fixed(size: frame.size)
            }
            return .unconstrained
        }

        return WindowSizeConstraints(
            minSize: minSize,
            maxSize: maxSize,
            isFixed: false
        )
    }

    static func axWindowRef(for windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )

        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            var winId: CGWindowID = 0
            if _AXUIElementGetWindow(window, &winId) == .success, winId == windowId {
                return AXWindowRef(element: window, windowId: Int(winId))
            }
        }

        return nil
    }
}

enum AXWindowType {
    case tiling
    case floating
}
