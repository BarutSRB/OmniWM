// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct WindowAdmissionTraceLifetimes {
    private struct ProcessState {
        var generation: UInt64
        var isLive: Bool
    }

    private struct WindowState {
        var generation: UInt64
        var isLive: Bool
        var ownerPID: pid_t?
        var ownerProcessGeneration: UInt64?

        func matchesOwner(
            eventPID: pid_t?,
            processGeneration: UInt64?
        ) -> Bool {
            guard let eventPID, let ownerPID else { return true }
            guard eventPID == ownerPID else { return false }
            guard let processGeneration, let ownerProcessGeneration else {
                return true
            }
            return processGeneration == ownerProcessGeneration
        }

        mutating func observe(
            _ event: WindowAdmissionTraceEvent,
            processGeneration: UInt64?,
            establishesOwner: Bool
        ) {
            if event.axRef != nil {
                let ownerChanged = establishesOwner
                    && ownerPID != nil
                    && !matchesOwner(
                        eventPID: event.pid,
                        processGeneration: processGeneration
                    )
                if !isLive || ownerChanged {
                    generation &+= 1
                }
                isLive = true
            }
            if establishesOwner, ownerPID == nil || event.axRef != nil {
                ownerPID = event.pid ?? ownerPID
                ownerProcessGeneration = processGeneration ?? ownerProcessGeneration
            }
        }
    }

    private struct EndpointState {
        var generation: UInt64
        var isLive: Bool
        var callbackGeneration: UInt64?
    }

    private var processes: [pid_t: ProcessState] = [:]
    private var windows: [Int: WindowState] = [:]
    private var endpoints: [pid_t: EndpointState] = [:]
    private var finalizationTargets = WindowAdmissionFinalizationTargets()

    mutating func processGeneration(for event: WindowAdmissionTraceEvent) -> UInt64? {
        guard let pid = event.pid else { return nil }
        var process = processes[pid] ?? ProcessState(generation: 1, isLive: true)
        switch event.action {
        case .processLaunched:
            if processes[pid] != nil, !process.isLive {
                process.generation &+= 1
            }
            process.isLive = true
        case .processTerminated:
            process.isLive = false
        default:
            break
        }
        processes[pid] = process
        return process.generation
    }

    mutating func endpointGeneration(for event: WindowAdmissionTraceEvent) -> UInt64? {
        guard let pid = event.pid, usesEndpoint(event) else { return nil }
        guard endpoints[pid] != nil || event.action == .endpointCreated else { return nil }
        var endpoint = endpoints[pid] ?? EndpointState(
            generation: 1,
            isLive: true,
            callbackGeneration: event.callbackGeneration
        )
        switch event.action {
        case .endpointCreated:
            if let existing = endpoints[pid],
               let incomingGeneration = event.callbackGeneration,
               let currentGeneration = existing.callbackGeneration
            {
                if incomingGeneration == currentGeneration {
                    return existing.isLive ? existing.generation : nil
                }
                guard incomingGeneration > currentGeneration else { return nil }
            }
            if endpoints[pid] != nil {
                endpoint.generation &+= 1
            }
            endpoint.isLive = true
            endpoint.callbackGeneration = event.callbackGeneration
        case .endpointDestroyed:
            if endpoint.callbackGeneration == nil {
                endpoint.callbackGeneration = event.callbackGeneration
            }
            guard endpoint.isLive,
                  callbackMatches(event.callbackGeneration, endpoint.callbackGeneration)
            else { return nil }
            endpoint.isLive = false
        default:
            if endpoint.callbackGeneration == nil {
                endpoint.callbackGeneration = event.callbackGeneration
            }
            guard endpoint.isLive,
                  callbackMatches(event.callbackGeneration, endpoint.callbackGeneration)
            else { return nil }
        }
        endpoints[pid] = endpoint
        return endpoint.generation
    }

    mutating func windowGeneration(
        for event: WindowAdmissionTraceEvent,
        processGeneration: UInt64?,
        allowMutation: Bool
    ) -> UInt64? {
        guard let windowId = event.windowId else { return nil }
        guard allowMutation else { return windows[windowId]?.generation }
        let existing = windows[windowId]
        let establishesOwner = establishesWindowOwner(event.action)
        var window = existing ?? WindowState(
            generation: 1,
            isLive: true,
            ownerPID: establishesOwner ? event.pid : nil,
            ownerProcessGeneration: establishesOwner ? processGeneration : nil
        )
        switch event.action {
        case .cgsCreated:
            if existing != nil {
                window.generation &+= 1
            }
            window.isLive = true
            window.ownerPID = nil
            window.ownerProcessGeneration = nil
        case .cgsDestroyed,
             .admissionDestroyed,
             .admissionDisappeared:
            guard window.matchesOwner(
                eventPID: event.pid,
                processGeneration: processGeneration
            ) else {
                return window.generation
            }
            window.isLive = false
            if window.ownerPID == nil {
                window.ownerPID = event.pid
                window.ownerProcessGeneration = processGeneration
            }
        default:
            window.observe(event, processGeneration: processGeneration, establishesOwner: establishesOwner)
        }
        windows[windowId] = window
        return window.generation
    }

    private func establishesWindowOwner(_ action: WindowAdmissionTraceAction) -> Bool {
        switch action {
        case .frontmostObserved,
             .managedFocusObserved,
             .fullRescanSelected,
             .admissionPrepared,
             .admissionAlreadyTracked,
             .admissionReplaced,
             .admissionPending,
             .admissionRetryScheduled,
             .admissionRetryExhausted,
             .admissionTracked,
             .admissionQuarantined,
             .terminalFrameRefusal:
            true
        default:
            false
        }
    }

    mutating func updateTargets(
        event: WindowAdmissionTraceEvent,
        record: WindowAdmissionTraceRecord
    ) {
        guard let pid = event.pid,
              let processGeneration = record.processGeneration
        else { return }
        guard event.action != .processTerminated else {
            finalizationTargets.clear(for: pid)
            return
        }
        guard let process = processes[pid],
              process.isLive,
              process.generation == processGeneration,
              event.callbackGeneration == nil || record.endpointGeneration != nil,
              windowLifecycleEventMatchesOwner(
                  event,
                  processGeneration: processGeneration
              ),
              event.action != .admissionDisappeared || event.reason != "process_terminated"
        else {
            return
        }
        let candidate = WindowAdmissionFinalizationTarget(
            action: event.action,
            pid: pid,
            windowId: event.windowId,
            bundleId: event.bundleId,
            reason: event.reason ?? event.action.rawValue,
            processGeneration: processGeneration,
            windowGeneration: record.windowGeneration,
            endpointGeneration: record.endpointGeneration,
            callbackGeneration: event.callbackGeneration
        )
        finalizationTargets.update(action: event.action, candidate: candidate, count: event.count)
    }

    private func windowLifecycleEventMatchesOwner(
        _ event: WindowAdmissionTraceEvent,
        processGeneration: UInt64
    ) -> Bool {
        switch event.action {
        case .cgsDestroyed,
             .admissionDestroyed,
             .admissionDisappeared:
            guard let windowId = event.windowId, let window = windows[windowId] else {
                return true
            }
            return window.matchesOwner(
                eventPID: event.pid,
                processGeneration: processGeneration
            )
        default:
            return true
        }
    }

    func finalizationTarget(excludingPID excludedPID: pid_t) -> WindowAdmissionFinalizationTarget? {
        finalizationTargets.prioritized
            .first { target in
                guard target.pid != excludedPID,
                      let process = processes[target.pid],
                      process.isLive,
                      process.generation == target.processGeneration
                else {
                    return false
                }
                if let windowId = target.windowId {
                    guard let window = windows[windowId],
                          window.isLive,
                          target.windowGeneration == window.generation
                    else {
                        return false
                    }
                }
                if let endpointGeneration = target.endpointGeneration {
                    guard let endpoint = endpoints[target.pid],
                          endpoint.isLive,
                          endpoint.generation == endpointGeneration
                    else {
                        return false
                    }
                    if let callbackGeneration = target.callbackGeneration,
                       endpoint.callbackGeneration != callbackGeneration
                    {
                        return false
                    }
                } else if target.callbackGeneration != nil {
                    return false
                }
                return true
            }
    }

    mutating func prune(using buffer: borrowing RingBuffer<WindowAdmissionTraceRecord>) {
        let limit = buffer.capacity + 256
        guard windows.count > limit
            || endpoints.count > limit
        else { return }
        let records = buffer.snapshot()
        let pids = Set(records.compactMap(\.pid))
        let windowIds = Set(records.compactMap(\.windowId))
        windows = windows.filter { windowIds.contains($0.key) }
        endpoints = endpoints.filter { pids.contains($0.key) }
    }

    private func usesEndpoint(_ event: WindowAdmissionTraceEvent) -> Bool {
        event.callbackGeneration != nil || event.action == .endpointCreated || event.action == .endpointDestroyed
    }

    private func callbackMatches(_ eventGeneration: UInt64?, _ currentGeneration: UInt64?) -> Bool {
        eventGeneration == nil || eventGeneration == currentGeneration
    }
}
