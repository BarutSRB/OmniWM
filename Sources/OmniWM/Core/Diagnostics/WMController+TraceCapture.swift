// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
extension WMController {
    var isTraceCaptureActive: Bool {
        traceCaptureCoordinator.isActive
    }

    var traceCaptureStatus: TraceCaptureStatus {
        traceCaptureCoordinator.status
    }

    @discardableResult
    func toggleTraceCaptureForUI(
        desiredState: TraceCaptureDesiredState = .toggle
    ) async -> TraceCaptureOutcome {
        let outcome = await traceCaptureCoordinator.toggle(
            desiredState: desiredState,
            reportProvider: { [weak self] in
                self?.diagnosticsReportText() ?? ""
            },
            automaticEvidenceProvider: { [weak self] in
                await self?.automaticTraceEvidence() ?? "status=controller_unavailable"
            }
        )
        if case .started = outcome {
            seedWindowAdmissionTrace()
        }
        return outcome
    }

    private func automaticTraceEvidence() async -> String {
        guard let request = automaticAXSnapshotRequest() else {
            let snapshot = AutomaticAXSnapshot(
                generatedAt: Date().ISO8601Format(),
                reason: "no_external_target",
                pid: 0,
                windowId: nil,
                status: "unavailable",
                app: nil,
                window: nil
            )
            return await Task.detached(priority: .utility) {
                AutomaticAXSnapshotCollector.shared.encoded(snapshot)
            }.value
        }
        let snapshot = await AutomaticAXSnapshotCollector.shared.capture(request)
        return await Task.detached(priority: .utility) {
            AutomaticAXSnapshotCollector.shared.encoded(snapshot)
        }.value
    }

    private func automaticAXSnapshotRequest() -> AutomaticAXSnapshotRequest? {
        let ownPID = getpid()
        if let target = WindowAdmissionTrace.shared.finalizationTarget(excludingPID: ownPID) {
            return AutomaticAXSnapshotRequest(
                reason: "window_admission:\(target.reason)",
                pid: target.pid,
                windowId: target.windowId
            )
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID
        {
            let pid = frontmost.processIdentifier
            let token = workspaceManager.focusedToken.flatMap { $0.pid == pid ? $0 : nil }
            return AutomaticAXSnapshotRequest(
                reason: "frontmost_external",
                pid: pid,
                windowId: token?.windowId
            )
        }
        guard let token = workspaceManager.focusedToken,
              token.pid != ownPID
        else {
            return nil
        }
        return AutomaticAXSnapshotRequest(
            reason: "last_managed_focus",
            pid: token.pid,
            windowId: token.windowId
        )
    }

    private func seedWindowAdmissionTrace() {
        for pid in AppAXContext.contexts.keys.sorted() {
            guard let context = AppAXContext.contexts[pid] else { continue }
            WindowAdmissionTrace.record(
                .init(
                    action: .endpointCreated,
                    pid: pid,
                    bundleId: context.nsApp.bundleIdentifier,
                    callbackGeneration: context.callbackGeneration
                )
            )
        }
        let ownPID = getpid()
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID
        {
            recordInitialTarget(
                action: .frontmostObserved,
                pid: frontmost.processIdentifier,
                bundleId: frontmost.bundleIdentifier,
                reason: "recording_start_frontmost"
            )
            return
        }
        guard let focused = workspaceManager.focusedToken,
              focused.pid != ownPID
        else { return }
        recordInitialTarget(
            action: .managedFocusObserved,
            pid: focused.pid,
            bundleId: NSRunningApplication(processIdentifier: focused.pid)?.bundleIdentifier,
            reason: "recording_start_managed_focus"
        )
    }

    private func recordInitialTarget(
        action: WindowAdmissionTraceAction,
        pid: pid_t,
        bundleId: String?,
        reason: String
    ) {
        let token = workspaceManager.focusedToken.flatMap { $0.pid == pid ? $0 : nil }
        WindowAdmissionTrace.record(
            WindowAdmissionTraceEvent(
                action: action,
                pid: pid,
                windowId: token?.windowId,
                bundleId: bundleId,
                axPid: pid,
                reason: reason,
                axRef: token.flatMap { workspaceManager.entry(for: $0)?.axRef }
            )
        )
    }
}
