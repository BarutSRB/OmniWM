// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation

struct WindowAdmissionGeometryEvidence: Equatable, Sendable {
    let isSizeSettable: Bool
    let frame: CGRect?

    var isManageable: Bool {
        guard isSizeSettable, let frame else { return false }
        return !frame.isNull
            && !frame.isInfinite
            && frame.width > 1
            && frame.height > 1
    }
}

struct AXEnumeratedWindow: Sendable {
    let axRef: AXWindowRef
    let axPid: pid_t?
    let role: String?
    let subrole: String?
    let admissionGeometry: WindowAdmissionGeometryEvidence
    let fullscreenAttribute: Bool?

    init(
        axRef: AXWindowRef,
        axPid: pid_t?,
        role: String?,
        subrole: String?,
        admissionGeometry: WindowAdmissionGeometryEvidence,
        fullscreenAttribute: Bool? = nil
    ) {
        self.axRef = axRef
        self.axPid = axPid
        self.role = role
        self.subrole = subrole
        self.admissionGeometry = admissionGeometry
        self.fullscreenAttribute = fullscreenAttribute
    }
}

enum FullRescanEnumerationRoute: Equatable, Sendable {
    case persistent
    case oneShot
}

struct FullRescanWindowCandidate: Sendable {
    let enumeratedWindow: AXEnumeratedWindow
    let logicalPID: pid_t
    let windowServerInfo: WindowServerInfo?
    let windowServerOwnerPID: pid_t?
    let enumerationRoute: FullRescanEnumerationRoute

    var axRef: AXWindowRef {
        enumeratedWindow.axRef
    }

    var pid: pid_t {
        logicalPID
    }

    var windowId: Int {
        enumeratedWindow.axRef.windowId
    }

    var axPid: pid_t? {
        enumeratedWindow.axPid
    }

    var isManageable: Bool {
        enumeratedWindow.admissionGeometry.isManageable
    }

    func isFullscreen(screenFrames: [CGRect]) -> Bool {
        if enumeratedWindow.subrole == "AXFullScreenWindow" {
            return true
        }
        if let fullscreenAttribute = enumeratedWindow.fullscreenAttribute {
            return fullscreenAttribute
        }
        guard let frame = enumeratedWindow.admissionGeometry.frame ?? windowServerInfo?.frame,
              let screenFrame = screenFrames.first(where: { $0.contains(frame.center) })
        else {
            return false
        }
        return frame.approximatelyEqual(to: screenFrame, tolerance: FrameTolerance.screenMatch)
    }

    init(
        enumeratedWindow: AXEnumeratedWindow,
        logicalPID: pid_t,
        windowServerInfo: WindowServerInfo?,
        windowServerOwnerPID: pid_t?,
        enumerationRoute: FullRescanEnumerationRoute
    ) {
        self.enumeratedWindow = enumeratedWindow
        self.logicalPID = logicalPID
        self.windowServerInfo = windowServerInfo
        self.windowServerOwnerPID = windowServerOwnerPID
        self.enumerationRoute = enumerationRoute
    }
}

struct AXManagedWindowIdentity: Sendable {
    let token: WindowToken
    let axRef: AXWindowRef
}

enum AXWindowEnumerationError: Error, Sendable {
    case applicationUnavailable(AXError)
    case contextUnavailable
    case invalidApplicationWindows
    case timedOut
}

enum AXWindowEnumerationInspector {
    static func enumerateApplication(
        pid: pid_t,
        timeout: TimeInterval
    ) throws -> [AXEnumeratedWindow] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let appElement = AXUIElementCreateApplication(pid)
        let windowElements = try applicationWindowElements(
            appElement,
            deadline: deadline,
            checkCancellation: { try Task.checkCancellation() }
        )
        var results: [AXEnumeratedWindow] = []
        results.reserveCapacity(windowElements.count)
        for element in windowElements {
            try Task.checkCancellation()
            if let window = try inspect(
                element,
                deadline: deadline,
                checkCancellation: { try Task.checkCancellation() }
            ) {
                results.append(window)
            }
        }
        return results
    }

    static func applicationWindowElements(
        _ appElement: AXUIElement,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> [AXUIElement] {
        try checkCancellation()
        try setRemainingTimeout(on: appElement, until: deadline)
        defer { AXUIElementSetMessagingTimeout(appElement, 0) }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        try checkCancellation()
        _ = try remainingTimeout(until: deadline)
        guard result == .success else {
            throw AXWindowEnumerationError.applicationUnavailable(result)
        }
        guard let elements = value as? [AXUIElement] else {
            throw AXWindowEnumerationError.invalidApplicationWindows
        }
        return elements
    }

    static func inspect(
        _ element: AXUIElement,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> AXEnumeratedWindow? {
        try checkCancellation()
        try setRemainingTimeout(on: element, until: deadline)
        defer { AXUIElementSetMessagingTimeout(element, 0) }

        var windowIdRaw: CGWindowID = 0
        let windowIdResult = _AXUIElementGetWindow(element, &windowIdRaw)
        try checkCancellation()
        guard windowIdResult == .success else { return nil }

        try setRemainingTimeout(on: element, until: deadline)
        var axPid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &axPid)
        try checkCancellation()
        let resolvedPid = pidResult == .success ? axPid : nil

        let attributes = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            "AXFullScreen" as CFString
        ] as CFArray
        var values: CFArray?
        try setRemainingTimeout(on: element, until: deadline)
        let valuesResult = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes,
            .init(),
            &values
        )
        try checkCancellation()

        let resolvedValues = valuesResult == .success ? values as? [Any?] : nil
        let role = value(at: 0, in: resolvedValues) as? String
        let subrole = value(at: 1, in: resolvedValues) as? String
        guard AXWindowService.shouldTreatAsTopLevelWindow(role: role, subrole: subrole) else {
            return nil
        }

        let geometry = try admissionGeometry(
            for: element,
            values: resolvedValues,
            deadline: deadline,
            checkCancellation: checkCancellation
        )
        return AXEnumeratedWindow(
            axRef: AXWindowRef(element: element, windowId: Int(windowIdRaw)),
            axPid: resolvedPid,
            role: role,
            subrole: subrole,
            admissionGeometry: geometry,
            fullscreenAttribute: value(at: 4, in: resolvedValues) as? Bool
        )
    }

    private static func admissionGeometry(
        for element: AXUIElement,
        values: [Any?]?,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> WindowAdmissionGeometryEvidence {
        try setRemainingTimeout(on: element, until: deadline)
        var isSizeSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXSizeAttribute as CFString,
            &isSizeSettable
        )
        try checkCancellation()
        return WindowAdmissionGeometryEvidence(
            isSizeSettable: result == .success && isSizeSettable.boolValue,
            frame: frame(from: values)
        )
    }

    private static func frame(from values: [Any?]?) -> CGRect? {
        guard let positionValue = value(at: 2, in: values),
              let sizeValue = value(at: 3, in: values),
              CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAXValue = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: CGRect(origin: position, size: size))
    }

    private static func value(at index: Int, in values: [Any?]?) -> Any? {
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private static func remainingTimeout(until deadline: TimeInterval) throws -> TimeInterval {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw AXWindowEnumerationError.timedOut }
        return remaining
    }

    private static func setRemainingTimeout(on element: AXUIElement, until deadline: TimeInterval) throws {
        AXUIElementSetMessagingTimeout(element, Float(try remainingTimeout(until: deadline)))
    }
}
