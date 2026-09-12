// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let maxConcurrentFullRescanEnumerations = 4

extension AXManager {
    func enumerateFullRescanApps(
        _ targets: [FullRescanAppTarget]
    ) async throws -> [FullRescanAppEnumerationResult] {
        try await boundedFullRescanMap(
            targets,
            maxConcurrent: maxConcurrentFullRescanEnumerations,
            priority: { $0.route == .oneShot ? .utility : nil },
            operation: { target in
                try await Self.enumerateFullRescanApp(
                    target.app,
                    route: target.route,
                    inspectionContext: target.inspectionContext,
                    includedWindowIds: target.includedWindowIds
                )
            }
        )
    }

    nonisolated static func enumerateFullRescanApp(
        _ app: NSRunningApplication,
        route: FullRescanEnumerationRoute,
        inspectionContext: AXWindowInspectionContext,
        includedWindowIds: Set<Int>?
    ) async throws -> FullRescanAppEnumerationResult {
        try Task.checkCancellation()
        let pid = app.processIdentifier
        var callbackGeneration: UInt64?
        do {
            let windows: [AXEnumeratedWindow]
            switch route {
            case .persistent:
                guard let context = try await AppAXContextRegistry.getOrCreate(app) else {
                    recordFullRescanEnumerationFailure(app, reason: "context_unavailable")
                    return .failed(pid: pid, route: route, callbackGeneration: nil)
                }
                callbackGeneration = context.callbackGeneration
                windows = try await context.getWindowsAsync(
                    timeoutSeconds: Self.perAppTimeout,
                    includeTitle: inspectionContext.includeTitle,
                    includedWindowIds: includedWindowIds
                )
            case .oneShot:
                windows = try enumerateOneShotRescanApp(
                    app,
                    inspectionContext: inspectionContext,
                    includedWindowIds: includedWindowIds
                )
            }
            return .init(
                pid: pid,
                route: route,
                windows: windows,
                failed: false,
                callbackGeneration: callbackGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordFullRescanEnumerationFailure(
                app,
                reason: String(describing: error),
                callbackGeneration: callbackGeneration
            )
            return .failed(pid: pid, route: route, callbackGeneration: callbackGeneration)
        }
    }

    nonisolated static func recordFullRescanEnumerationFailure(
        _ app: NSRunningApplication,
        reason: String,
        callbackGeneration: UInt64? = nil
    ) {
        WindowAdmissionTrace.record(
            .init(
                action: .enumerationFailed,
                pid: app.processIdentifier,
                bundleId: app.bundleIdentifier,
                reason: reason,
                callbackGeneration: callbackGeneration
            )
        )
    }

    private nonisolated static func enumerateOneShotRescanApp(
        _ app: NSRunningApplication,
        inspectionContext: AXWindowInspectionContext,
        includedWindowIds: Set<Int>?
    ) throws -> [AXEnumeratedWindow] {
        let pid = app.processIdentifier
        WindowAdmissionTrace.record(
            .init(
                action: .enumerationStarted,
                pid: pid,
                bundleId: app.bundleIdentifier
            )
        )
        let windows = try AXWindowEnumerationInspector.enumerateApplication(
            pid: pid,
            timeout: Self.perAppTimeout,
            context: inspectionContext,
            includedWindowIds: includedWindowIds
        )
        try Task.checkCancellation()
        WindowAdmissionTrace.record(
            .init(action: .enumerationCompleted, pid: pid, count: windows.count)
        )
        return windows
    }
}
