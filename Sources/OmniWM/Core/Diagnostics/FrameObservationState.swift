// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct FrameObservationState {
    struct Pending: Equatable, Sendable {
        let traceRequestId: UInt64
        let requestId: AXFrameRequestId
        let pid: pid_t
        let windowId: Int
        let lane: AppAXFrameLane
        let attempt: UInt8
        var target: CGRect
        let startedNs: UInt64
        let deadlineNs: UInt64
        var mismatchCount: UInt8 = 0
        var lastEventNs: UInt64 = 0
        var lastSampleNs: UInt64 = 0
        var lastObserved: CGRect?
    }

    struct Completion {
        let pending: Pending?
        let outcome: String?
        let terminal: Bool
        let rescheduleToken: UInt64?
    }

    private let capacity: Int
    private let timeoutNs: UInt64
    private let maxMismatchCount: UInt8
    private var captureGeneration: UInt64 = 0
    private var pendingByWindowId: [Int: Pending] = [:]
    private var observationSchedule = FrameObservationSchedule()

    init(capacity: Int, timeoutNs: UInt64, maxMismatchCount: UInt8) {
        self.capacity = max(1, capacity)
        self.timeoutNs = timeoutNs
        self.maxMismatchCount = max(1, maxMismatchCount)
    }

    var pendingCount: Int {
        pendingByWindowId.count
    }

    var retainedStorageCapacity: Int {
        pendingByWindowId.capacity + observationSchedule.retainedStorageCapacity
    }

    mutating func beginCapture(generation: UInt64) {
        captureGeneration = generation & 0xFFFF_FFFF
        pendingByWindowId.removeAll(keepingCapacity: true)
        observationSchedule.clear(keepingCapacity: true)
    }

    mutating func endCapture() -> [Pending] {
        let pending = Array(pendingByWindowId.values)
        captureGeneration = 0
        pendingByWindowId.removeAll(keepingCapacity: false)
        observationSchedule.clear(keepingCapacity: false)
        return pending
    }

    mutating func register(
        _ request: AppAXFrameWriteRequest,
        pid: pid_t,
        lane: AppAXFrameLane,
        attempt: UInt8,
        startedNs: UInt64
    ) -> (Pending?, Pending?) {
        let traceRequestId = request.traceRequestId
        let windowId = request.windowId
        guard captureGeneration == FrameEffectTraceContext.captureGeneration(of: traceRequestId) else {
            return (nil, nil)
        }
        let superseded = pendingByWindowId.removeValue(forKey: windowId)
        var capacityEviction: Pending?
        observationSchedule.removeDirty(for: windowId)
        if superseded == nil,
           pendingByWindowId.count >= capacity,
           let oldest = pendingByWindowId.min(by: { $0.value.startedNs < $1.value.startedNs })
        {
            capacityEviction = pendingByWindowId.removeValue(forKey: oldest.key)
            if let capacityEviction {
                observationSchedule.clearObservationEvents(
                    windowId: oldest.key,
                    traceRequestId: capacityEviction.traceRequestId
                )
            }
        }
        pendingByWindowId[windowId] = Pending(
            traceRequestId: traceRequestId,
            requestId: request.requestId,
            pid: pid,
            windowId: windowId,
            lane: lane,
            attempt: attempt,
            target: request.frame,
            startedNs: startedNs,
            deadlineNs: startedNs &+ timeoutNs
        )
        return (superseded, capacityEviction)
    }

    mutating func noteFrameChanged(windowId: Int, eventNs: UInt64) -> UInt64? {
        guard let pending = pendingByWindowId[windowId] else { return nil }
        return observationSchedule.noteFrameChanged(
            windowId: windowId,
            traceRequestId: pending.traceRequestId,
            eventNs: eventNs
        )
    }

    mutating func prepareObservation(windowId: Int, token: UInt64) -> FrameObservationSchedule.Work {
        guard let scheduled = observationSchedule.scheduled(for: windowId),
              scheduled.token == token
        else {
            return .none
        }
        guard let pending = pendingByWindowId[windowId] else {
            observationSchedule.removeScheduled(for: windowId)
            observationSchedule.removeDirty(for: windowId)
            return .none
        }
        guard pending.traceRequestId == scheduled.traceRequestId else {
            return observationSchedule.retireStaleSchedule(
                windowId: windowId,
                traceRequestId: pending.traceRequestId
            )
        }
        return .sample
    }

    mutating func completeObservation(
        windowId: Int,
        token: UInt64,
        observed: CGRect?,
        sampledNs: UInt64
    ) -> Completion {
        guard let scheduled = observationSchedule.scheduled(for: windowId),
              scheduled.token == token
        else {
            return Completion(pending: nil, outcome: nil, terminal: false, rescheduleToken: nil)
        }
        guard var pending = pendingByWindowId[windowId] else {
            observationSchedule.removeScheduled(for: windowId)
            observationSchedule.removeDirty(for: windowId)
            return Completion(pending: nil, outcome: nil, terminal: false, rescheduleToken: nil)
        }
        guard pending.traceRequestId == scheduled.traceRequestId else {
            let work = observationSchedule.retireStaleSchedule(
                windowId: windowId,
                traceRequestId: pending.traceRequestId
            )
            let token: UInt64? = if case let .reschedule(token) = work { token } else { nil }
            return Completion(pending: nil, outcome: nil, terminal: false, rescheduleToken: token)
        }
        observationSchedule.removeScheduled(for: windowId)
        pending.lastEventNs = scheduled.eventNs
        pending.lastSampleNs = sampledNs
        pending.lastObserved = observed
        return applySample(windowId: windowId, pending: &pending, observed: observed)
    }

    private mutating func applySample(windowId: Int, pending: inout Pending, observed: CGRect?) -> Completion {
        if let observed,
           observed.approximatelyEqual(to: pending.target, tolerance: FrameTolerance.frameWrite)
        {
            pendingByWindowId.removeValue(forKey: windowId)
            observationSchedule.removeDirty(for: windowId)
            return Completion(
                pending: pending,
                outcome: "server-observation/match",
                terminal: true,
                rescheduleToken: nil
            )
        }
        pending.mismatchCount &+= 1
        let terminal = pending.mismatchCount >= maxMismatchCount
        let outcome = observed == nil
            ? "server-observation/unavailable"
            : "server-observation/mismatch"
        if terminal {
            pendingByWindowId.removeValue(forKey: windowId)
            observationSchedule.removeDirty(for: windowId)
            return Completion(
                pending: pending,
                outcome: outcome,
                terminal: true,
                rescheduleToken: nil
            )
        }
        pendingByWindowId[windowId] = pending
        var rescheduleToken: UInt64?
        if let dirty = observationSchedule.removeDirty(for: windowId),
           dirty.traceRequestId == pending.traceRequestId
        {
            rescheduleToken = observationSchedule.schedule(dirty, windowId: windowId)
        }
        return Completion(
            pending: pending,
            outcome: outcome + "/sample",
            terminal: false,
            rescheduleToken: rescheduleToken
        )
    }

    mutating func updateAcceptedTarget(traceRequestId: UInt64, target: CGRect) -> Pending? {
        guard let entry = pendingByWindowId.first(where: {
            $0.value.traceRequestId == traceRequestId
        }) else { return nil }
        var pending = entry.value
        pending.target = target
        if let observed = pending.lastObserved,
           observed.approximatelyEqual(to: target, tolerance: FrameTolerance.frameWrite)
        {
            pendingByWindowId.removeValue(forKey: entry.key)
            observationSchedule.clearObservationEvents(
                windowId: entry.key,
                traceRequestId: traceRequestId
            )
            return pending
        } else {
            pendingByWindowId[entry.key] = pending
            return nil
        }
    }

    mutating func expire(nowNs: UInt64) -> [Pending] {
        let windowIds = pendingByWindowId.compactMap { entry in
            entry.value.deadlineNs <= nowNs ? entry.key : nil
        }
        return windowIds.compactMap { windowId -> Pending? in
            guard let pending = pendingByWindowId.removeValue(forKey: windowId) else {
                return nil
            }
            observationSchedule.clearObservationEvents(
                windowId: windowId,
                traceRequestId: pending.traceRequestId
            )
            return pending
        }
    }

    mutating func remove(traceRequestId: UInt64) -> Pending? {
        guard let entry = pendingByWindowId.first(where: {
            $0.value.traceRequestId == traceRequestId
        }) else { return nil }
        let removed = pendingByWindowId.removeValue(forKey: entry.key)
        observationSchedule.clearObservationEvents(
            windowId: entry.key,
            traceRequestId: traceRequestId
        )
        return removed
    }
}
