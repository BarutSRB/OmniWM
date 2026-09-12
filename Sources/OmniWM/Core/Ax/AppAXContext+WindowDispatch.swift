// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AppAXContext {
    func getWindowsAsync(
        timeoutSeconds: TimeInterval = 0.5,
        includeTitle: Bool = false,
        includedWindowIds: Set<Int>? = nil
    ) async throws -> [AXEnumeratedWindow] {
        guard let thread = axThread else {
            WindowAdmissionTrace.record(
                .init(
                    action: .enumerationFailed,
                    pid: pid,
                    bundleId: nsApp.bundleIdentifier,
                    reason: "context_thread_unavailable",
                    callbackGeneration: callbackGeneration
                )
            )
            throw AXWindowEnumerationError.contextUnavailable
        }
        nonisolated(unsafe) let appThread = thread
        WindowAdmissionTrace.record(
            .init(
                action: .enumerationStarted,
                pid: pid,
                bundleId: nsApp.bundleIdentifier,
                callbackGeneration: callbackGeneration
            )
        )

        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        let inspectionContext = AXWindowInspectionContext(
            appPolicy: nsApp.activationPolicy,
            bundleId: nsApp.bundleIdentifier,
            includeTitle: includeTitle
        )
        let operation = makeWindowEnumerationOperation(
            inspectionContext: inspectionContext,
            includedWindowIds: includedWindowIds,
            deadline: deadline
        )
        return try await appThread.runInLoop(timeout: timeout) { job in
            try operation.perform(job: job)
        }
    }

    func bindWindows(
        _ boundWindows: [Int: AXWindowRef],
        timeoutSeconds: TimeInterval = 0.5,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        updateWindowBindings(
            boundWindows,
            pruningUnboundState: false,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
    }

    func reconcileWindowBindings(
        _ boundWindows: [Int: AXWindowRef],
        timeoutSeconds: TimeInterval = 0.5,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        updateWindowBindings(
            boundWindows,
            pruningUnboundState: true,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
    }
}
