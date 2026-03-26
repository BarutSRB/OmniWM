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

enum AXFrameWriteOrder {
    case sizeThenPosition
    case positionThenSize
}

enum AXFrameWriteFailureReason: Equatable, Sendable {
    case valueCreationFailed
    case sizeWriteFailed(AXError)
    case positionWriteFailed(AXError)
    case staleElement
    case cacheMiss
    case contextUnavailable
    case readbackFailed
    case verificationMismatch
    case cancelled
    case suppressed
}

struct AXFrameWriteResult: Equatable, Sendable {
    let targetFrame: CGRect
    let observedFrame: CGRect?
    let writeOrder: AXFrameWriteOrder
    let sizeError: AXError
    let positionError: AXError
    let failureReason: AXFrameWriteFailureReason?

    var isVerifiedSuccess: Bool {
        failureReason == nil
    }

    var shouldRetryAfterRefresh: Bool {
        failureReason == .staleElement || failureReason == .cacheMiss
    }

    static func skipped(
        targetFrame: CGRect,
        currentFrameHint: CGRect?,
        failureReason: AXFrameWriteFailureReason,
        observedFrame: CGRect? = nil
    ) -> Self {
        Self(
            targetFrame: targetFrame,
            observedFrame: observedFrame,
            writeOrder: AXWindowService.frameWriteOrder(currentFrame: currentFrameHint, targetFrame: targetFrame),
            sizeError: .success,
            positionError: .success,
            failureReason: failureReason
        )
    }
}

struct AXFrameApplyResult: Equatable, Sendable {
    let pid: pid_t
    let windowId: Int
    let targetFrame: CGRect
    let currentFrameHint: CGRect?
    let writeResult: AXFrameWriteResult

    var confirmedFrame: CGRect? {
        guard writeResult.isVerifiedSuccess else { return nil }
        return writeResult.observedFrame ?? targetFrame
    }
}

enum AXWindowHeuristicReason: String, Sendable {
    case attributeFetchFailed
    case browserPictureInPicture
    case accessoryWithoutClose
    case trustedFloatingSubrole
    case noButtonsOnNonStandardSubrole
    case nonStandardSubrole
    case missingFullscreenButton
    case disabledFullscreenButton
    case fixedSizeWindow
}

struct AXWindowFacts: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let title: String?
    let hasCloseButton: Bool
    let hasFullscreenButton: Bool
    let fullscreenButtonEnabled: Bool?
    let hasZoomButton: Bool
    let hasMinimizeButton: Bool
    let appPolicy: NSApplication.ActivationPolicy?
    let bundleId: String?
    let attributeFetchSucceeded: Bool
}

struct AXWindowHeuristicDisposition: Equatable, Sendable {
    let disposition: WindowDecisionDisposition
    let reasons: [AXWindowHeuristicReason]
}

enum AXWindowService {
    private enum WindowTypeAttributeIndex: Int {
        case role
        case subrole
        case closeButton
        case fullScreenButton
        case zoomButton
        case minimizeButton
        case title
    }

    nonisolated(unsafe) static var axWindowRefProviderForTests: ((UInt32, pid_t) -> AXWindowRef?)?
    nonisolated(unsafe) static var setFrameResultProviderForTests: ((AXWindowRef, CGRect, CGRect?) -> AXFrameWriteResult)?
    @MainActor static var titleLookupProviderForTests: ((UInt32) -> String?)?
    @MainActor static var timeSourceForTests: (() -> TimeInterval)?

    private struct CachedTitle {
        let title: String?
        let fetchedAt: TimeInterval
    }

    private static let titleTTL: TimeInterval = 0.5
    private static let titleCacheCap = 512
    @MainActor private static var titleCache: [UInt32: CachedTitle] = [:]
    @MainActor private static var titleInsertionOrder: [UInt32] = []

    @MainActor
    static func titlePreferFast(windowId: UInt32) -> String? {
        let now = timeSourceForTests?() ?? ProcessInfo.processInfo.systemUptime
        if let cached = titleCache[windowId],
           now - cached.fetchedAt < titleTTL
        {
            return cached.title
        }
        let title = titleLookupProviderForTests?(windowId) ?? SkyLight.shared.getWindowTitle(windowId)
        storeTitleCacheEntry(windowId: windowId, title: title, at: now)
        return title
    }

    @MainActor
    static func invalidateCachedTitle(windowId: UInt32) {
        titleCache.removeValue(forKey: windowId)
        titleInsertionOrder.removeAll { $0 == windowId }
    }

    @MainActor
    static func invalidateCachedTitles(windowIds: [UInt32]) {
        for windowId in windowIds {
            titleCache.removeValue(forKey: windowId)
        }
        let windowIdSet = Set(windowIds)
        titleInsertionOrder.removeAll { windowIdSet.contains($0) }
    }

    @MainActor
    static func clearTitleCacheForTests() {
        titleCache.removeAll()
        titleInsertionOrder.removeAll()
    }

    @MainActor
    private static func storeTitleCacheEntry(windowId: UInt32, title: String?, at time: TimeInterval) {
        if titleCache[windowId] == nil {
            titleInsertionOrder.append(windowId)
        }
        titleCache[windowId] = CachedTitle(title: title, fetchedAt: time)
        while titleCache.count > titleCacheCap, let oldest = titleInsertionOrder.first {
            titleInsertionOrder.removeFirst()
            titleCache.removeValue(forKey: oldest)
        }
    }

    static func windowId(_ window: AXWindowRef) -> Int {
        window.windowId
    }

    static func frame(_ window: AXWindowRef) throws(AXErrorWrapper) -> CGRect {
        let attributes = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
        ] as CFArray
        var valuesPtr: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributes,
            .init(),
            &valuesPtr
        )
        guard result == .success,
              let values = valuesPtr as? [Any],
              values.count == 2
        else { throw .cannotGetAttribute }
        let posRaw = values[0] as CFTypeRef
        let sizeRaw = values[1] as CFTypeRef
        guard CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID()
        else { throw .cannotGetAttribute }
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

    static func frameWriteOrder(currentFrame: CGRect?, targetFrame: CGRect) -> AXFrameWriteOrder {
        guard let currentFrame else {
            return .sizeThenPosition
        }
        if targetFrame.width > currentFrame.width + 0.5 || targetFrame.height > currentFrame.height + 0.5 {
            return .positionThenSize
        }
        return .sizeThenPosition
    }

    static func setFrame(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect? = nil
    ) -> AXFrameWriteResult {
        if let setFrameResultProviderForTests {
            return setFrameResultProviderForTests(window, frame, currentFrameHint)
        }

        let writeOrder = frameWriteOrder(
            currentFrame: currentFrameHint ?? (try? self.frame(window)),
            targetFrame: frame
        )
        let axFrame = convertToAX(frame)
        var position = CGPoint(x: axFrame.origin.x, y: axFrame.origin.y)
        var size = CGSize(width: axFrame.size.width, height: axFrame.size.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return .skipped(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                failureReason: .valueCreationFailed
            )
        }

        let positionError: AXError
        let sizeError: AXError
        switch writeOrder {
        case .sizeThenPosition:
            sizeError = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
            positionError = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        case .positionThenSize:
            positionError = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
            sizeError = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        }

        let observedFrame = try? self.frame(window)

        let failureReason: AXFrameWriteFailureReason? = if sizeError != .success {
            mapFrameWriteFailure(sizeError, attribute: .size)
        } else if positionError != .success {
            mapFrameWriteFailure(positionError, attribute: .position)
        } else if let observedFrame {
            observedFrame.approximatelyEqual(to: frame, tolerance: 1.0) ? nil : .verificationMismatch
        } else {
            .readbackFailed
        }

        return AXFrameWriteResult(
            targetFrame: frame,
            observedFrame: observedFrame,
            writeOrder: writeOrder,
            sizeError: sizeError,
            positionError: positionError,
            failureReason: failureReason
        )
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

    static func collectWindowFacts(
        _ window: AXWindowRef,
        appPolicy: NSApplication.ActivationPolicy?,
        bundleId: String? = nil,
        includeTitle: Bool
    ) -> AXWindowFacts {
        var attributes: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXCloseButtonAttribute as CFString,
            kAXFullScreenButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString
        ]
        if includeTitle {
            attributes.append(kAXTitleAttribute as CFString)
        }

        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )

        guard result == .success,
              let valuesArray = values as? [Any?],
              valuesArray.count > WindowTypeAttributeIndex.minimizeButton.rawValue
        else {
            return AXWindowFacts(
                role: nil,
                subrole: nil,
                title: nil,
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: appPolicy,
                bundleId: bundleId,
                attributeFetchSucceeded: false
            )
        }

        func attributeValue(_ index: WindowTypeAttributeIndex) -> Any? {
            guard valuesArray.indices.contains(index.rawValue) else { return nil }
            return valuesArray[index.rawValue]
        }

        func hasResolvedAttribute(_ value: Any?) -> Bool {
            guard let value else { return false }
            return !(value is NSError)
        }

        let fullscreenButtonElement = attributeValue(.fullScreenButton)
        var attributeFetchSucceeded = true
        let hasFullscreenButton = hasResolvedAttribute(fullscreenButtonElement)

        var fullscreenButtonEnabled: Bool?
        if hasFullscreenButton, let fullscreenButtonElement {
            guard CFGetTypeID(fullscreenButtonElement as CFTypeRef) == AXUIElementGetTypeID() else {
                attributeFetchSucceeded = false
                return AXWindowFacts(
                    role: attributeValue(.role) as? String,
                    subrole: attributeValue(.subrole) as? String,
                    title: includeTitle ? (attributeValue(.title) as? String) : nil,
                    hasCloseButton: hasResolvedAttribute(attributeValue(.closeButton)),
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: hasResolvedAttribute(attributeValue(.zoomButton)),
                    hasMinimizeButton: hasResolvedAttribute(attributeValue(.minimizeButton)),
                    appPolicy: appPolicy,
                    bundleId: bundleId,
                    attributeFetchSucceeded: attributeFetchSucceeded
                )
            }
            let buttonElement = unsafeDowncast(fullscreenButtonElement as AnyObject, to: AXUIElement.self)
            var enabledValue: CFTypeRef?
            let enabledResult = AXUIElementCopyAttributeValue(
                buttonElement,
                kAXEnabledAttribute as CFString,
                &enabledValue
            )
            if enabledResult == .success {
                if let enabledValue {
                    if let resolvedEnabled = enabledValue as? Bool {
                        fullscreenButtonEnabled = resolvedEnabled
                    } else {
                        attributeFetchSucceeded = false
                    }
                }
            }
        }

        return AXWindowFacts(
            role: attributeValue(.role) as? String,
            subrole: attributeValue(.subrole) as? String,
            title: includeTitle ? (attributeValue(.title) as? String) : nil,
            hasCloseButton: hasResolvedAttribute(attributeValue(.closeButton)),
            hasFullscreenButton: hasFullscreenButton,
            fullscreenButtonEnabled: fullscreenButtonEnabled,
            hasZoomButton: hasResolvedAttribute(attributeValue(.zoomButton)),
            hasMinimizeButton: hasResolvedAttribute(attributeValue(.minimizeButton)),
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        )
    }

    static func heuristicDisposition(
        for facts: AXWindowFacts,
        sizeConstraints: WindowSizeConstraints? = nil,
        overriddenWindowType: AXWindowType? = nil
    ) -> AXWindowHeuristicDisposition {
        if let overriddenWindowType {
            let disposition: WindowDecisionDisposition = overriddenWindowType == .tiling ? .managed : .floating
            return AXWindowHeuristicDisposition(disposition: disposition, reasons: [])
        }

        if !facts.attributeFetchSucceeded {
            return AXWindowHeuristicDisposition(
                disposition: .undecided,
                reasons: [.attributeFetchFailed]
            )
        }

        let hasAnyButton = facts.hasCloseButton
            || facts.hasFullscreenButton
            || facts.hasZoomButton
            || facts.hasMinimizeButton

        if facts.appPolicy == .accessory && !facts.hasCloseButton {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.accessoryWithoutClose]
            )
        }

        if !hasAnyButton && facts.subrole != kAXStandardWindowSubrole as String {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.noButtonsOnNonStandardSubrole]
            )
        }

        if let subrole = facts.subrole,
           subrole != (kAXStandardWindowSubrole as String)
        {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.nonStandardSubrole]
            )
        }

        if !facts.hasFullscreenButton {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.missingFullscreenButton]
            )
        }

        if facts.fullscreenButtonEnabled != true {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.disabledFullscreenButton]
            )
        }

        return AXWindowHeuristicDisposition(
            disposition: .managed,
            reasons: []
        )
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
        if let axWindowRefProviderForTests {
            return axWindowRefProviderForTests(windowId, pid)
        }
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

    private enum FrameWriteAttribute {
        case size
        case position
    }

    private static func mapFrameWriteFailure(
        _ error: AXError,
        attribute: FrameWriteAttribute
    ) -> AXFrameWriteFailureReason {
        if error == .invalidUIElement || error == .cannotComplete {
            return .staleElement
        }

        return switch attribute {
        case .size:
            .sizeWriteFailed(error)
        case .position:
            .positionWriteFailed(error)
        }
    }
}

enum AXWindowType {
    case tiling
    case floating
}
