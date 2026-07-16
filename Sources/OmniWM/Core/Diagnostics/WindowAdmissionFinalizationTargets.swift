// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct WindowAdmissionFinalizationTargets {
    private(set) var terminal: WindowAdmissionFinalizationTarget?
    private(set) var pending: WindowAdmissionFinalizationTarget?
    private(set) var external: WindowAdmissionFinalizationTarget?
    private(set) var managed: WindowAdmissionFinalizationTarget?

    var prioritized: [WindowAdmissionFinalizationTarget] {
        [terminal, pending, external, managed].compactMap { $0 }
    }

    mutating func clear(for pid: pid_t) {
        terminal = terminal?.pid == pid ? nil : terminal
        pending = pending?.pid == pid ? nil : pending
        external = external?.pid == pid ? nil : external
        managed = managed?.pid == pid ? nil : managed
    }

    mutating func update(
        action: WindowAdmissionTraceAction,
        candidate: WindowAdmissionFinalizationTarget
    ) {
        terminal = enriched(terminal, with: candidate)
        pending = enriched(pending, with: candidate)
        external = enriched(external, with: candidate)
        managed = enriched(managed, with: candidate)
        assign(action: action, candidate: candidate)
        resolve(action: action, candidate: candidate)
    }

    private mutating func assign(
        action: WindowAdmissionTraceAction,
        candidate: WindowAdmissionFinalizationTarget
    ) {
        switch action {
        case .admissionRetryExhausted,
             .admissionQuarantined,
             .terminalFrameRefusal:
            terminal = candidate
        case .admissionPending,
             .admissionRetryScheduled,
             .admissionIgnored,
             .topLevelRejected,
             .fullRescanRejected,
             .enumerationFailed,
             .enumerationEmpty:
            pending = candidate
        case .frontmostObserved:
            external = candidate
        case .managedFocusObserved:
            managed = candidate
        default:
            break
        }
    }

    private mutating func resolve(
        action: WindowAdmissionTraceAction,
        candidate: WindowAdmissionFinalizationTarget
    ) {
        switch action {
        case .admissionTracked,
             .admissionAlreadyTracked,
             .admissionReplaced,
             .admissionDestroyed:
            terminal = removing(candidate, from: terminal)
            pending = removing(candidate, from: pending)
        case .admissionDisappeared:
            terminal = removing(candidate, from: terminal)
            pending = candidate
        case .enumerationCompleted:
            clearResolvedEnumerationTargets(for: candidate.pid)
        default:
            break
        }
    }

    private mutating func clearResolvedEnumerationTargets(for pid: pid_t) {
        if terminal?.pid == pid, terminal?.windowId == nil {
            terminal = nil
        }
        if pending?.pid == pid,
           pending?.windowId == nil,
           pending?.action == .enumerationFailed
        {
            pending = nil
        }
    }

    private func enriched(
        _ existing: WindowAdmissionFinalizationTarget?,
        with candidate: WindowAdmissionFinalizationTarget
    ) -> WindowAdmissionFinalizationTarget? {
        guard let existing,
              existing.pid == candidate.pid,
              existing.processGeneration == candidate.processGeneration,
              existing.windowId == nil || candidate.windowId == nil || existing.windowId == candidate.windowId
        else {
            return existing
        }
        return WindowAdmissionFinalizationTarget(
            action: existing.action,
            pid: existing.pid,
            windowId: candidate.windowId ?? existing.windowId,
            bundleId: candidate.bundleId ?? existing.bundleId,
            axRef: candidate.axRef ?? existing.axRef,
            reason: existing.reason,
            processGeneration: candidate.processGeneration,
            windowGeneration: candidate.windowGeneration ?? existing.windowGeneration,
            endpointGeneration: candidate.endpointGeneration ?? existing.endpointGeneration
        )
    }

    private func removing(
        _ candidate: WindowAdmissionFinalizationTarget,
        from existing: WindowAdmissionFinalizationTarget?
    ) -> WindowAdmissionFinalizationTarget? {
        guard let existing,
              existing.pid == candidate.pid,
              existing.processGeneration == candidate.processGeneration,
              existing.windowId == nil || candidate.windowId == nil || existing.windowId == candidate.windowId
        else {
            return existing
        }
        return nil
    }
}
