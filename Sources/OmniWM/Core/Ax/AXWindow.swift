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
}

enum AXWindowService {
    @MainActor
    static func titlePreferFast(windowId: UInt32) -> String? {
        SkyLight.shared.getWindowTitle(windowId)
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
    static func fastFrame(_ window: AXWindowRef) -> CGRect? {
        guard let frame = SkyLight.shared.getWindowBounds(UInt32(windowId(window))) else { return nil }
        return ScreenCoordinateSpace.toAppKit(rect: frame)
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
        let err1 = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        let err2 = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        guard err1 == .success, err2 == .success else { throw .cannotSetFrame }
    }

    private static func convertFromAX(_ rect: CGRect) -> CGRect {
        ScreenCoordinateSpace.toAppKit(rect: rect)
    }

    private static func convertToAX(_ rect: CGRect) -> CGRect {
        ScreenCoordinateSpace.toWindowServer(rect: rect)
    }

    static func subrole(_ window: AXWindowRef) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return nil }
        return subrole
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
