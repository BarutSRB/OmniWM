// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct FrameObservationSchedule {
    struct Event: Equatable, Sendable {
        let traceRequestId: UInt64
        let eventNs: UInt64
    }

    struct Scheduled: Equatable, Sendable {
        let token: UInt64
        let traceRequestId: UInt64
        let eventNs: UInt64
    }

    enum Work: Equatable, Sendable {
        case none
        case sample
        case reschedule(UInt64)
    }

    private var scheduledByWindowId: [Int: Scheduled] = [:]
    private var dirtyByWindowId: [Int: Event] = [:]
    private var nextScheduleToken: UInt64 = 1

    var retainedStorageCapacity: Int {
        scheduledByWindowId.capacity + dirtyByWindowId.capacity
    }

    mutating func clear(keepingCapacity: Bool) {
        scheduledByWindowId.removeAll(keepingCapacity: keepingCapacity)
        dirtyByWindowId.removeAll(keepingCapacity: keepingCapacity)
    }

    func scheduled(for windowId: Int) -> Scheduled? {
        scheduledByWindowId[windowId]
    }

    @discardableResult
    mutating func removeScheduled(for windowId: Int) -> Scheduled? {
        scheduledByWindowId.removeValue(forKey: windowId)
    }

    @discardableResult
    mutating func removeDirty(for windowId: Int) -> Event? {
        dirtyByWindowId.removeValue(forKey: windowId)
    }

    mutating func noteFrameChanged(windowId: Int, traceRequestId: UInt64, eventNs: UInt64) -> UInt64? {
        let event = Event(traceRequestId: traceRequestId, eventNs: eventNs)
        if scheduledByWindowId[windowId] != nil {
            dirtyByWindowId[windowId] = event
            return nil
        }
        return schedule(event, windowId: windowId)
    }

    mutating func schedule(_ event: Event, windowId: Int) -> UInt64 {
        var token = nextScheduleToken
        nextScheduleToken &+= 1
        if token == 0 {
            token = nextScheduleToken
            nextScheduleToken &+= 1
        }
        scheduledByWindowId[windowId] = Scheduled(
            token: token,
            traceRequestId: event.traceRequestId,
            eventNs: event.eventNs
        )
        return token
    }

    mutating func retireStaleSchedule(windowId: Int, traceRequestId: UInt64) -> Work {
        scheduledByWindowId.removeValue(forKey: windowId)
        guard let dirty = dirtyByWindowId.removeValue(forKey: windowId),
              dirty.traceRequestId == traceRequestId
        else {
            return .none
        }
        return .reschedule(schedule(dirty, windowId: windowId))
    }

    mutating func clearObservationEvents(windowId: Int, traceRequestId: UInt64) {
        if scheduledByWindowId[windowId]?.traceRequestId == traceRequestId {
            scheduledByWindowId.removeValue(forKey: windowId)
        }
        if dirtyByWindowId[windowId]?.traceRequestId == traceRequestId {
            dirtyByWindowId.removeValue(forKey: windowId)
        }
    }
}
