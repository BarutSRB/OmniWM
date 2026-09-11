// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import os
import Synchronization

enum WindowAdmissionTraceAction: String, Codable, Sendable {
    case processLaunched = "process_launched"
    case processTerminated = "process_terminated"
    case endpointCreated = "endpoint_created"
    case endpointDestroyed = "endpoint_destroyed"
    case enumerationStarted = "enumeration_started"
    case enumerationCompleted = "enumeration_completed"
    case enumerationEmpty = "enumeration_empty"
    case enumerationFailed = "enumeration_failed"
    case topLevelAccepted = "top_level_accepted"
    case topLevelRejected = "top_level_rejected"
    case fullRescanCandidate = "full_rescan_candidate"
    case fullRescanSelected = "full_rescan_selected"
    case fullRescanRejected = "full_rescan_rejected"
    case frontmostObserved = "frontmost_observed"
    case managedFocusObserved = "managed_focus_observed"
    case cgsCreated = "cgs_created"
    case cgsDestroyed = "cgs_destroyed"
    case classificationObserved = "classification_observed"
    case admissionPrepared = "admission_prepared"
    case admissionAlreadyTracked = "admission_already_tracked"
    case admissionReplaced = "admission_replaced"
    case admissionPending = "admission_pending"
    case admissionIgnored = "admission_ignored"
    case admissionRetryScheduled = "admission_retry_scheduled"
    case admissionRetryExhausted = "admission_retry_exhausted"
    case admissionTracked = "admission_tracked"
    case admissionDestroyed = "admission_destroyed"
    case admissionDisappeared = "admission_disappeared"
    case admissionQuarantined = "admission_quarantined"
    case terminalFrameRefusal = "terminal_frame_refusal"
}

struct WindowAdmissionTraceRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }
}

struct WindowAdmissionTraceEvent: Sendable {
    let action: WindowAdmissionTraceAction
    let pid: pid_t?
    let windowId: Int?
    let bundleId: String?
    let axPid: pid_t?
    let windowServerPid: pid_t?
    let competingPid: pid_t?
    let role: String?
    let subrole: String?
    let reason: String?
    let outcome: String?
    let count: Int?
    let attempt: Int?
    let retryGeneration: UInt64?
    let callbackGeneration: UInt64?
    let manageable: Bool?
    let targetFrame: WindowAdmissionTraceRect?
    let observedFrame: WindowAdmissionTraceRect?
    let observation: WindowClassificationObservation?
    let classificationRulesSnapshot: WindowClassificationRulesSnapshot?
    let axRef: AXWindowRef?

    init(
        action: WindowAdmissionTraceAction,
        pid: pid_t? = nil,
        windowId: Int? = nil,
        bundleId: String? = nil,
        axPid: pid_t? = nil,
        windowServerPid: pid_t? = nil,
        competingPid: pid_t? = nil,
        role: String? = nil,
        subrole: String? = nil,
        reason: String? = nil,
        outcome: String? = nil,
        count: Int? = nil,
        attempt: Int? = nil,
        retryGeneration: UInt64? = nil,
        callbackGeneration: UInt64? = nil,
        manageable: Bool? = nil,
        targetFrame: CGRect? = nil,
        observedFrame: CGRect? = nil,
        observation: WindowClassificationObservation? = nil,
        classificationRulesSnapshot: WindowClassificationRulesSnapshot? = nil,
        axRef: AXWindowRef? = nil
    ) {
        self.action = action
        self.pid = pid
        self.windowId = windowId
        self.bundleId = bundleId.map(RuntimeTraceLimits.boundedString)
        self.axPid = axPid
        self.windowServerPid = windowServerPid
        self.competingPid = competingPid
        self.role = role.map(RuntimeTraceLimits.boundedString)
        self.subrole = subrole.map(RuntimeTraceLimits.boundedString)
        self.reason = reason.map(RuntimeTraceLimits.boundedString)
        self.outcome = outcome.map(RuntimeTraceLimits.boundedString)
        self.count = count
        self.attempt = attempt
        self.retryGeneration = retryGeneration
        self.callbackGeneration = callbackGeneration
        self.manageable = manageable
        self.targetFrame = targetFrame.map(WindowAdmissionTraceRect.init)
        self.observedFrame = observedFrame.map(WindowAdmissionTraceRect.init)
        self.observation = observation?.boundedForDiagnostics()
        self.classificationRulesSnapshot = classificationRulesSnapshot
        self.axRef = axRef
    }
}

struct WindowAdmissionTraceRecord: Codable, Equatable, Sendable {
    let sequence: UInt64
    let timestamp: Date
    let action: WindowAdmissionTraceAction
    let pid: pid_t?
    let windowId: Int?
    let bundleId: String?
    let axPid: pid_t?
    let windowServerPid: pid_t?
    let competingPid: pid_t?
    let processGeneration: UInt64?
    let windowGeneration: UInt64?
    let endpointGeneration: UInt64?
    let callbackGeneration: UInt64?
    let retryGeneration: UInt64?
    let role: String?
    let subrole: String?
    let reason: String?
    let outcome: String?
    let count: Int?
    let attempt: Int?
    let manageable: Bool?
    let targetFrame: WindowAdmissionTraceRect?
    let observedFrame: WindowAdmissionTraceRect?
    let observation: WindowClassificationObservation?
}

struct WindowAdmissionFinalizationTarget: Sendable {
    let action: WindowAdmissionTraceAction
    let pid: pid_t
    let windowId: Int?
    let bundleId: String?
    let reason: String
    let processGeneration: UInt64
    let windowGeneration: UInt64?
    let endpointGeneration: UInt64?
    let callbackGeneration: UInt64?
}

final class WindowAdmissionTrace: RuntimeTraceRecording, @unchecked Sendable {
    static let shared = WindowAdmissionTrace()

    let sectionTitle = "Window Admission Timeline"

    private struct State {
        var records: RingBuffer<WindowAdmissionTraceRecord>
        var nextSequence: UInt64 = 0
        var lifetimes = WindowAdmissionTraceLifetimes()
        var rulesSnapshots = WindowAdmissionRulesSnapshots()
    }

    private static let defaultCapacity = 4096
    private let active = Atomic<Bool>(false)
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int = WindowAdmissionTrace.defaultCapacity) {
        state = OSAllocatedUnfairLock(initialState: State(records: RingBuffer(capacity: capacity)))
    }

    var isActive: Bool {
        active.load(ordering: .relaxed)
    }

    static func record(_ make: @autoclosure () -> WindowAdmissionTraceEvent) {
        shared.record(make())
    }

    func record(_ make: @autoclosure () -> WindowAdmissionTraceEvent) {
        guard active.load(ordering: .relaxed) else { return }
        let event = make()
        guard active.load(ordering: .relaxed) else { return }
        let timestamp = Date()
        state.withLock { state in
            guard active.load(ordering: .relaxed) else { return }
            let processGeneration = state.lifetimes.processGeneration(for: event)
            let endpointGeneration = state.lifetimes.endpointGeneration(for: event)
            let windowGeneration = state.lifetimes.windowGeneration(
                for: event,
                processGeneration: processGeneration,
                allowMutation: event.callbackGeneration == nil || endpointGeneration != nil
            )
            let record = WindowAdmissionTraceRecord(
                sequence: state.nextSequence,
                timestamp: timestamp,
                action: event.action,
                pid: event.pid,
                windowId: event.windowId,
                bundleId: event.bundleId,
                axPid: event.axPid,
                windowServerPid: event.windowServerPid,
                competingPid: event.competingPid,
                processGeneration: processGeneration,
                windowGeneration: windowGeneration,
                endpointGeneration: endpointGeneration,
                callbackGeneration: event.callbackGeneration,
                retryGeneration: event.retryGeneration,
                role: event.role,
                subrole: event.subrole,
                reason: event.reason,
                outcome: event.outcome,
                count: event.count,
                attempt: event.attempt,
                manageable: event.manageable,
                targetFrame: event.targetFrame,
                observedFrame: event.observedFrame,
                observation: event.observation
            )
            state.nextSequence &+= 1
            let evicted = state.records.append(record)
            state.rulesSnapshots.update(for: event, evicting: evicted)
            state.lifetimes.updateTargets(event: event, record: record)
            state.lifetimes.prune(using: state.records)
        }
    }

    func beginCapture() {
        state.withLock { state in
            state = State(records: RingBuffer(capacity: state.records.capacity))
        }
        active.store(true, ordering: .relaxed)
    }

    func endCapture() {
        active.store(false, ordering: .relaxed)
        state.withLock { _ in }
    }

    func releaseStorage() {
        state.withLock { state in
            state = State(records: RingBuffer(capacity: state.records.capacity))
        }
    }

    func dump() -> String {
        var lines: [String] = []
        forEachLine {
            lines.append($0)
            return true
        }
        return lines.joined(separator: "\n")
    }

    func forEachLine(_ body: (String) -> Bool) {
        let snapshot = state.withLock { state in
            (
                records: state.records.snapshot(),
                rules: state.rulesSnapshots.snapshot()
            )
        }
        guard !snapshot.records.isEmpty else {
            _ = body("none")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard snapshot.rules.forEachLine(using: encoder, body) else { return }
        for record in snapshot.records {
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8)
            else { continue }
            guard body(line) else { return }
        }
    }

    func recordsSnapshot() -> [WindowAdmissionTraceRecord] {
        state.withLock { $0.records.snapshot() }
    }

    func finalizationTarget(excludingPID excludedPID: pid_t) -> WindowAdmissionFinalizationTarget? {
        state.withLock { state in
            state.lifetimes.finalizationTarget(excludingPID: excludedPID)
        }
    }
}
