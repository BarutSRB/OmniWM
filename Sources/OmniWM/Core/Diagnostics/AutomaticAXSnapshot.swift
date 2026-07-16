// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation
import Synchronization

struct AutomaticAXSnapshotRequest: Sendable {
    let reason: String
    let pid: pid_t
    let windowId: Int?
    let axRef: AXWindowRef?
}

struct AutomaticAXSnapshot: Codable, Equatable, Sendable {
    let generatedAt: String
    let reason: String
    let pid: pid_t
    let windowId: Int?
    let status: String
    let app: AXDirectSnapshot?
    let window: AXDirectSnapshot?
}

struct AXDirectSnapshot: Codable, Equatable, Sendable {
    let attributes: [String: String]
    let writable: [String]
    let failures: [String]
}

private final class AutomaticAXSnapshotContinuation: @unchecked Sendable {
    private let state: Mutex<CheckedContinuation<AutomaticAXSnapshot, Never>?>

    init(_ continuation: CheckedContinuation<AutomaticAXSnapshot, Never>) {
        state = Mutex(continuation)
    }

    func resume(returning snapshot: AutomaticAXSnapshot) {
        let continuation = state.withLock { state in
            defer { state = nil }
            return state
        }
        continuation?.resume(returning: snapshot)
    }
}

private struct AutomaticAXSnapshotRead {
    let snapshot: AXDirectSnapshot
    let values: [Any?]?
    let succeeded: Bool
}

final class AutomaticAXSnapshotCollector: @unchecked Sendable {
    static let shared = AutomaticAXSnapshotCollector()

    private static let arrayLimit = 64
    private static let stringLimit = 16 * 1024
    private static let encodedLimit = 512 * 1024
    private static let messagingTimeoutSeconds: Float = 0.5
    private static let overallTimeoutSeconds = 2.5

    private let queue = DispatchQueue(label: "com.omniwm.diagnostics.ax-snapshot", qos: .utility)
    private let overallTimeoutSeconds: Double
    private let captureOperation: @Sendable (AutomaticAXSnapshotRequest) -> AutomaticAXSnapshot

    init(
        overallTimeoutSeconds: Double = AutomaticAXSnapshotCollector.overallTimeoutSeconds,
        captureOperation: (@Sendable (AutomaticAXSnapshotRequest) -> AutomaticAXSnapshot)? = nil
    ) {
        self.overallTimeoutSeconds = overallTimeoutSeconds
        if let captureOperation {
            self.captureOperation = captureOperation
        } else {
            self.captureOperation = { request in
                Self.captureSynchronously(
                    request,
                    deadline: ProcessInfo.processInfo.systemUptime + overallTimeoutSeconds
                )
            }
        }
    }

    func capture(_ request: AutomaticAXSnapshotRequest) async -> AutomaticAXSnapshot {
        await withCheckedContinuation { continuation in
            let completion = AutomaticAXSnapshotContinuation(continuation)
            queue.async { [captureOperation] in
                completion.resume(returning: captureOperation(request))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + overallTimeoutSeconds
            ) {
                completion.resume(returning: Self.failure(request, status: "timed_out"))
            }
        }
    }

    func encoded(_ snapshot: AutomaticAXSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return "status=encoding_failed"
        }
        guard data.count <= Self.encodedLimit else {
            return "status=snapshot_too_large bytes=\(data.count)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func captureSynchronously(
        _ request: AutomaticAXSnapshotRequest,
        deadline: TimeInterval
    ) -> AutomaticAXSnapshot {
        let appElement = AXUIElementCreateApplication(request.pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)
        defer { AXUIElementSetMessagingTimeout(appElement, 0) }

        let appAttributes = [
            kAXRoleAttribute as String,
            kAXTitleAttribute as String,
            kAXFrontmostAttribute as String,
            kAXFocusedWindowAttribute as String,
            kAXMainWindowAttribute as String,
            kAXWindowsAttribute as String
        ]
        let appRead = snapshot(
            element: appElement,
            attributes: appAttributes,
            writableAttributes: [],
            deadline: deadline
        )
        if ProcessInfo.processInfo.systemUptime >= deadline {
            return AutomaticAXSnapshot(
                generatedAt: Date().ISO8601Format(),
                reason: request.reason,
                pid: request.pid,
                windowId: request.windowId,
                status: "timed_out",
                app: appRead.snapshot,
                window: nil
            )
        }
        let windowElement = request.axRef?.element
            ?? selectedWindowElement(
                windowId: request.windowId,
                values: appRead.values,
                focusedIndex: appAttributes.firstIndex(of: kAXFocusedWindowAttribute as String),
                windowsIndex: appAttributes.firstIndex(of: kAXWindowsAttribute as String),
                deadline: deadline
            )
        var resolvedWindowId = request.windowId ?? request.axRef?.windowId
        if resolvedWindowId == nil,
           ProcessInfo.processInfo.systemUptime < deadline,
           let windowElement
        {
            var windowId: CGWindowID = 0
            if _AXUIElementGetWindow(windowElement, &windowId) == .success {
                resolvedWindowId = Int(windowId)
            }
        }

        var windowRead: AutomaticAXSnapshotRead?
        if let windowElement, ProcessInfo.processInfo.systemUptime < deadline {
            AXUIElementSetMessagingTimeout(windowElement, messagingTimeoutSeconds)
            windowRead = snapshot(
                element: windowElement,
                attributes: [
                    kAXRoleAttribute as String,
                    kAXSubroleAttribute as String,
                    kAXTitleAttribute as String,
                    kAXIdentifierAttribute as String,
                    kAXPositionAttribute as String,
                    kAXSizeAttribute as String,
                    kAXMinimizedAttribute as String,
                    "AXFullScreen",
                    kAXMainAttribute as String,
                    kAXFocusedAttribute as String,
                    kAXModalAttribute as String,
                    kAXParentAttribute as String,
                    kAXTopLevelUIElementAttribute as String,
                    kAXCloseButtonAttribute as String,
                    kAXMinimizeButtonAttribute as String,
                    kAXZoomButtonAttribute as String,
                    kAXFullScreenButtonAttribute as String
                ],
                writableAttributes: [
                    kAXPositionAttribute as String,
                    kAXSizeAttribute as String
                ],
                deadline: deadline
            )
            AXUIElementSetMessagingTimeout(windowElement, 0)
        }
        let status = if ProcessInfo.processInfo.systemUptime >= deadline {
            "timed_out"
        } else if !appRead.succeeded {
            "application_unavailable"
        } else if let windowRead {
            windowRead.succeeded ? "captured" : "window_unavailable"
        } else if request.windowId != nil {
            "window_unavailable"
        } else {
            "captured_app_only"
        }
        return AutomaticAXSnapshot(
            generatedAt: Date().ISO8601Format(),
            reason: request.reason,
            pid: request.pid,
            windowId: resolvedWindowId,
            status: status,
            app: appRead.snapshot,
            window: windowRead?.snapshot
        )
    }

    private static func selectedWindowElement(
        windowId: Int?,
        values: [Any?]?,
        focusedIndex: Int?,
        windowsIndex: Int?,
        deadline: TimeInterval
    ) -> AXUIElement? {
        guard let values else { return nil }
        if let windowId,
           let windowsIndex,
           values.indices.contains(windowsIndex),
           let windows = values[windowsIndex] as? [AXUIElement]
        {
            for element in windows.prefix(arrayLimit) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                var candidateId: CGWindowID = 0
                if _AXUIElementGetWindow(element, &candidateId) == .success,
                   Int(candidateId) == windowId
                {
                    return element
                }
            }
            return nil
        }
        guard let focusedIndex,
              values.indices.contains(focusedIndex),
              let rawValue = values[focusedIndex]
        else { return nil }
        let value = rawValue as CFTypeRef
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func snapshot(
        element: AXUIElement,
        attributes: [String],
        writableAttributes: [String],
        deadline: TimeInterval
    ) -> AutomaticAXSnapshotRead {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return AutomaticAXSnapshotRead(
                snapshot: AXDirectSnapshot(
                    attributes: [:],
                    writable: [],
                    failures: ["deadline_exceeded"]
                ),
                values: nil,
                succeeded: false
            )
        }
        var copiedValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &copiedValues
        )
        var values: [String: String] = [:]
        var failures: [String] = []
        if result == .success, let copiedValues = copiedValues as? [Any?] {
            for (index, attribute) in attributes.enumerated() {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    failures.append("deadline_exceeded")
                    break
                }
                guard index < copiedValues.count,
                      let value = copiedValues[index],
                      !(value is NSError)
                else {
                    failures.append(attribute)
                    continue
                }
                let cfValue = value as CFTypeRef
                if let error = attributeError(cfValue) {
                    failures.append("\(attribute)(ax=\(error.rawValue))")
                    continue
                }
                values[attribute] = describe(cfValue)
            }
        } else {
            failures.append("AXCopyMultipleAttributeValues(ax=\(result.rawValue))")
        }

        var writable: [String] = []
        for attribute in writableAttributes {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                failures.append("deadline_exceeded")
                break
            }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
            if status == .success {
                if settable.boolValue {
                    writable.append(attribute)
                }
            } else {
                failures.append("\(attribute).settable(ax=\(status.rawValue))")
            }
        }
        return AutomaticAXSnapshotRead(
            snapshot: AXDirectSnapshot(
                attributes: values,
                writable: writable.sorted(),
                failures: failures.sorted()
            ),
            values: copiedValues as? [Any?],
            succeeded: result == .success && !values.isEmpty
        )
    }

    private static func attributeError(_ value: CFTypeRef) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(value) == .axError else { return nil }
        var error = AXError.success
        guard AXValueGetValue(value, .axError, &error) else { return nil }
        return error
    }

    private static func describe(_ value: CFTypeRef) -> String {
        let typeId = CFGetTypeID(value)
        if typeId == CFStringGetTypeID() {
            return bounded(value as? String ?? "")
        }
        if typeId == CFBooleanGetTypeID(), let value = value as? Bool {
            return value ? "true" : "false"
        }
        if typeId == CFNumberGetTypeID(), let value = value as? NSNumber {
            return value.stringValue
        }
        if typeId == AXValueGetTypeID() {
            return describeAXValue(unsafeDowncast(value, to: AXValue.self))
        }
        if typeId == AXUIElementGetTypeID() {
            return describeElement(unsafeDowncast(value, to: AXUIElement.self))
        }
        if typeId == CFArrayGetTypeID() {
            let values = (value as? [AnyObject]) ?? []
            var descriptions = values.prefix(arrayLimit).map { describe($0 as CFTypeRef) }
            if values.count > arrayLimit {
                descriptions.append("truncated=\(values.count - arrayLimit)")
            }
            return "[\(descriptions.joined(separator: ", "))]"
        }
        return bounded(String(describing: value))
    }

    private static func describeAXValue(_ value: AXValue) -> String {
        switch AXValueGetType(value) {
        case .cgPoint:
            var point = CGPoint.zero
            AXValueGetValue(value, .cgPoint, &point)
            return "point(x=\(point.x),y=\(point.y))"
        case .cgSize:
            var size = CGSize.zero
            AXValueGetValue(value, .cgSize, &size)
            return "size(w=\(size.width),h=\(size.height))"
        case .cgRect:
            var rect = CGRect.zero
            AXValueGetValue(value, .cgRect, &rect)
            return "rect(x=\(rect.minX),y=\(rect.minY),w=\(rect.width),h=\(rect.height))"
        case .cfRange:
            var range = CFRange()
            AXValueGetValue(value, .cfRange, &range)
            return "range(location=\(range.location),length=\(range.length))"
        default:
            return "axvalue"
        }
    }

    private static func describeElement(_ element: AXUIElement) -> String {
        "AXUIElement(reference=\(CFHash(element)))"
    }

    private static func bounded(_ value: String) -> String {
        guard value.utf8.count > stringLimit else { return value }
        var end = value.startIndex
        var count = 0
        while end < value.endIndex, count < stringLimit {
            let next = value.index(after: end)
            count += value[end ..< next].utf8.count
            if count > stringLimit { break }
            end = next
        }
        return String(value[..<end]) + "<truncated>"
    }

    private static func failure(
        _ request: AutomaticAXSnapshotRequest,
        status: String
    ) -> AutomaticAXSnapshot {
        AutomaticAXSnapshot(
            generatedAt: Date().ISO8601Format(),
            reason: request.reason,
            pid: request.pid,
            windowId: request.windowId,
            status: status,
            app: nil,
            window: nil
        )
    }
}
