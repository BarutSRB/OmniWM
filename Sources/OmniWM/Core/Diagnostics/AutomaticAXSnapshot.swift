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

    init(reason: String, pid: pid_t, windowId: Int?) {
        self.reason = RuntimeTraceLimits.boundedString(reason)
        self.pid = pid
        self.windowId = windowId
    }
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

final class AutomaticAXSnapshotCollector: @unchecked Sendable {
    static let shared = AutomaticAXSnapshotCollector()

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
        let appAttributes = [
            kAXRoleAttribute as String,
            kAXTitleAttribute as String,
            kAXFrontmostAttribute as String,
            kAXFocusedWindowAttribute as String,
            kAXMainWindowAttribute as String,
            kAXWindowsAttribute as String
        ]
        let appRead = readApplication(appElement, attributes: appAttributes, deadline: deadline)
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
        let windowElement = selectedWindowElement(
            windowId: request.windowId,
            values: appRead.values,
            focusedIndex: appAttributes.firstIndex(of: kAXFocusedWindowAttribute as String),
            windowsIndex: appAttributes.firstIndex(of: kAXWindowsAttribute as String),
            deadline: deadline
        )
        let resolvedWindowId = request.windowId ?? {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let windowElement
            else {
                return nil
            }
            return windowId(for: windowElement)
        }()

        var windowRead: AutomaticAXSnapshotRead?
        if let windowElement, ProcessInfo.processInfo.systemUptime < deadline {
            windowRead = readWindow(windowElement, deadline: deadline)
        }
        return captureResult(
            for: request,
            appRead: appRead,
            windowRead: windowRead,
            resolvedWindowId: resolvedWindowId,
            deadline: deadline
        )
    }

    private static func captureResult(
        for request: AutomaticAXSnapshotRequest,
        appRead: AutomaticAXSnapshotRead,
        windowRead: AutomaticAXSnapshotRead?,
        resolvedWindowId: Int?,
        deadline: TimeInterval
    ) -> AutomaticAXSnapshot {
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

    private static func readApplication(
        _ appElement: AXUIElement,
        attributes: [String],
        deadline: TimeInterval
    ) -> AutomaticAXSnapshotRead {
        withMessagingTimeout(appElement) {
            AutomaticAXSnapshotRead.read(
                element: appElement,
                attributes: attributes,
                writableAttributes: [],
                deadline: deadline
            )
        }
    }

    private static func readWindow(
        _ windowElement: AXUIElement,
        deadline: TimeInterval
    ) -> AutomaticAXSnapshotRead {
        withMessagingTimeout(windowElement) {
            AutomaticAXSnapshotRead.read(
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
        }
    }

    private static func selectedWindowElement(
        windowId: Int?,
        values: [Any?]?,
        focusedIndex: Int?,
        windowsIndex: Int?,
        deadline: TimeInterval
    ) -> AXUIElement? {
        guard let values else { return nil }
        let windows = windowsIndex.flatMap { index in
            values.indices.contains(index) ? values[index] as? [AXUIElement] : nil
        } ?? []
        let focusedWindow = focusedIndex.flatMap { index -> AXUIElement? in
            guard values.indices.contains(index), let rawValue = values[index] else { return nil }
            return AXUIElement.from(rawValue as CFTypeRef)
        }
        return selectWindowElement(
            windowId: windowId,
            focusedWindow: focusedWindow,
            windows: windows
        ) { element in
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            return self.windowId(for: element)
        }
    }

    private static func windowId(for element: AXUIElement) -> Int? {
        withMessagingTimeout(element) {
            var windowId: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &windowId) == .success else { return nil }
            return Int(windowId)
        }
    }

    static func selectWindowElement(
        windowId: Int?,
        focusedWindow: AXUIElement?,
        windows: [AXUIElement],
        resolveWindowId: (AXUIElement) -> Int?
    ) -> AXUIElement? {
        guard let windowId else { return focusedWindow }
        if let window = windows.prefix(RuntimeTraceLimits.axArrayElements)
            .first(where: { resolveWindowId($0) == windowId })
        {
            return window
        }
        guard let focusedWindow,
              resolveWindowId(focusedWindow) == windowId
        else {
            return nil
        }
        return focusedWindow
    }

    static func withMessagingTimeout<T>(
        _ element: AXUIElement,
        timeoutSeconds: Float = AutomaticAXSnapshotCollector.messagingTimeoutSeconds,
        setter: (AXUIElement, Float) -> Void = { AXUIElementSetMessagingTimeout($0, $1) },
        operation: () throws -> T
    ) rethrows -> T {
        setter(element, timeoutSeconds)
        defer { setter(element, 0) }
        return try operation()
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
