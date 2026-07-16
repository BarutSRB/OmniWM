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
        axRef: AXWindowRef? = nil
    ) {
        self.action = action
        self.pid = pid
        self.windowId = windowId
        self.bundleId = bundleId
        self.axPid = axPid
        self.windowServerPid = windowServerPid
        self.competingPid = competingPid
        self.role = role
        self.subrole = subrole
        self.reason = reason
        self.outcome = outcome
        self.count = count
        self.attempt = attempt
        self.retryGeneration = retryGeneration
        self.callbackGeneration = callbackGeneration
        self.manageable = manageable
        self.targetFrame = targetFrame.map(WindowAdmissionTraceRect.init)
        self.observedFrame = observedFrame.map(WindowAdmissionTraceRect.init)
        self.observation = observation
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
    let axRef: AXWindowRef?
    let reason: String
    let processGeneration: UInt64
    let windowGeneration: UInt64?
    let endpointGeneration: UInt64?
}

final class WindowAdmissionTrace: RuntimeTraceRecording, @unchecked Sendable {
    static let shared = WindowAdmissionTrace()

    let sectionTitle = "Window Admission Timeline"

    private struct ProcessState {
        var generation: UInt64
        var isLive: Bool
    }

    private struct WindowState {
        var generation: UInt64
        var isLive: Bool
        var axRef: AXWindowRef?
    }

    private struct EndpointState {
        var generation: UInt64
        var isLive: Bool
    }

    private struct State {
        var records: RingBuffer<WindowAdmissionTraceRecord>
        var nextSequence: UInt64 = 0
        var processes: [pid_t: ProcessState] = [:]
        var windows: [Int: WindowState] = [:]
        var endpoints: [pid_t: EndpointState] = [:]
        var finalizationTargets = WindowAdmissionFinalizationTargets()
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
            let processGeneration = processGeneration(for: event, state: &state)
            let windowGeneration = windowGeneration(for: event, state: &state)
            let endpointGeneration = endpointGeneration(for: event, state: &state)
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
            state.records.append(record)
            updateTargets(event: event, record: record, state: &state)
            pruneAuxiliaryState(&state)
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

    func dump() -> String {
        let records = state.withLock { $0.records.snapshot() }
        guard !records.isEmpty else { return "none" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var output = ""
        for record in records {
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8)
            else { continue }
            if !output.isEmpty {
                output.append("\n")
            }
            output.append(line)
        }
        return output.isEmpty ? "none" : output
    }

    func recordsSnapshot() -> [WindowAdmissionTraceRecord] {
        state.withLock { $0.records.snapshot() }
    }

    func finalizationTarget(excludingPID excludedPID: pid_t) -> WindowAdmissionFinalizationTarget? {
        state.withLock { state in
            state.finalizationTargets.prioritized
                .first {
                    let process = state.processes[$0.pid]
                    return $0.pid != excludedPID && process?.isLive == true
                        && process?.generation == $0.processGeneration
                }
        }
    }

    private func processGeneration(for event: WindowAdmissionTraceEvent, state: inout State) -> UInt64? {
        guard let pid = event.pid else { return nil }
        var process = state.processes[pid] ?? ProcessState(generation: 1, isLive: true)
        switch event.action {
        case .processLaunched:
            if state.processes[pid] != nil, !process.isLive {
                process.generation &+= 1
            }
            process.isLive = true
        case .processTerminated:
            process.isLive = false
        default:
            break
        }
        state.processes[pid] = process
        return process.generation
    }

    private func windowGeneration(for event: WindowAdmissionTraceEvent, state: inout State) -> UInt64? {
        guard let windowId = event.windowId else { return nil }
        var window = state.windows[windowId] ?? WindowState(generation: 1, isLive: true, axRef: nil)
        switch event.action {
        case .cgsCreated:
            if state.windows[windowId] != nil {
                window.generation &+= 1
            }
            window.isLive = true
            window.axRef = nil
        case .cgsDestroyed,
             .admissionDestroyed,
             .admissionDisappeared:
            window.isLive = false
            window.axRef = nil
        default:
            if let axRef = event.axRef {
                if !window.isLive {
                    window.generation &+= 1
                }
                window.isLive = true
                window.axRef = axRef
            }
        }
        state.windows[windowId] = window
        return window.generation
    }

    private func endpointGeneration(for event: WindowAdmissionTraceEvent, state: inout State) -> UInt64? {
        guard let pid = event.pid, usesEndpoint(event) else { return nil }
        var endpoint = state.endpoints[pid] ?? EndpointState(generation: 1, isLive: true)
        switch event.action {
        case .endpointCreated:
            if state.endpoints[pid] != nil {
                endpoint.generation &+= 1
            }
            endpoint.isLive = true
        case .endpointDestroyed:
            endpoint.isLive = false
        default:
            break
        }
        state.endpoints[pid] = endpoint
        return endpoint.generation
    }

    private func updateTargets(
        event: WindowAdmissionTraceEvent,
        record: WindowAdmissionTraceRecord,
        state: inout State
    ) {
        guard let pid = event.pid,
              let processGeneration = record.processGeneration
        else { return }
        guard event.action != .processTerminated else {
            state.finalizationTargets.clear(for: pid)
            return
        }
        guard let process = state.processes[pid],
              process.isLive,
              process.generation == processGeneration,
              event.action != .admissionDisappeared || event.reason != "process_terminated"
        else {
            return
        }
        let candidate = WindowAdmissionFinalizationTarget(
            action: event.action,
            pid: pid,
            windowId: event.windowId,
            bundleId: event.bundleId,
            axRef: event.axRef,
            reason: event.reason ?? event.action.rawValue,
            processGeneration: processGeneration,
            windowGeneration: record.windowGeneration,
            endpointGeneration: record.endpointGeneration
        )
        state.finalizationTargets.update(action: event.action, candidate: candidate)
    }

    private func pruneAuxiliaryState(_ state: inout State) {
        let limit = state.records.capacity + 256
        guard state.windows.count > limit
            || state.endpoints.count > limit
        else { return }
        let records = state.records.snapshot()
        let pids = Set(records.compactMap(\.pid))
        let windowIds = Set(records.compactMap(\.windowId))
        state.windows = state.windows.filter { windowIds.contains($0.key) }
        state.endpoints = state.endpoints.filter { pids.contains($0.key) }
    }
}

private func usesEndpoint(_ event: WindowAdmissionTraceEvent) -> Bool {
    event.axRef != nil || event.action == .endpointCreated || event.action == .endpointDestroyed
        || event.action == .enumerationStarted || event.action == .enumerationCompleted
        || event.action == .enumerationEmpty || event.action == .enumerationFailed
        || event.action == .topLevelAccepted || event.action == .topLevelRejected
        || event.action == .fullRescanCandidate || event.action == .fullRescanSelected
        || event.action == .fullRescanRejected
}
