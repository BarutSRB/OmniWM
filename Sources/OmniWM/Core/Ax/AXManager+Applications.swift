// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    private static let systemUIBundleIds: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight"
    ]

    func windowsForApp(_ app: NSRunningApplication) async -> [AXWindowRef] {
        guard shouldTrack(app) else { return [] }
        var callbackGeneration: UInt64?
        do {
            guard let context = try await AppAXContextRegistry.getOrCreate(app) else {
                WindowAdmissionTrace.record(
                    .init(
                        action: .enumerationFailed,
                        pid: app.processIdentifier,
                        bundleId: app.bundleIdentifier,
                        reason: "context_unavailable"
                    )
                )
                return []
            }
            callbackGeneration = context.callbackGeneration
            let windows = try await context.getWindowsAsync(timeoutSeconds: Self.perAppTimeout)
            return windows.map(\.axRef)
        } catch {
            WindowAdmissionTrace.record(
                .init(
                    action: .enumerationFailed,
                    pid: app.processIdentifier,
                    bundleId: app.bundleIdentifier,
                    reason: String(describing: error),
                    callbackGeneration: callbackGeneration
                )
            )
        }
        return []
    }

    func ensureContext(for app: NSRunningApplication) async -> Bool {
        guard shouldTrack(app) else { return false }
        return (try? await AppAXContextRegistry.getOrCreate(app)) != nil
    }

    func requestPermission() -> Bool {
        if AccessibilityPermissionMonitor.shared.isGranted { return true }

        let options: NSDictionary = [axTrustedCheckOptionPrompt as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)

        return AccessibilityPermissionMonitor.shared.isGranted
    }

    func shouldTrack(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.activationPolicy != .prohibited else { return false }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        if let bundleId = app.bundleIdentifier, Self.systemUIBundleIds.contains(bundleId) {
            return false
        }

        return true
    }

    func hasContext(for pid: pid_t) -> Bool {
        AppAXContextRegistry.contexts[pid] != nil
    }
}
