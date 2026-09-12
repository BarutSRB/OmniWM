// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

private let multitouchLiftTimeout = 0.12

final class MultitouchFrameMailbox: @unchecked Sendable {
    struct PerformanceSnapshot: Equatable, Sendable {
        let rawCallbacks: UInt64
        let staleCallbacks: UInt64
        let drainBatches: UInt64
        let overwrittenChanges: UInt64
        let transitionsQueued: UInt64
        let cursorSamples: UInt64
        let pendingFrames: Int
        let maximumPendingFrames: Int
    }

    private final class PerformanceCounters: @unchecked Sendable {
        let rawCallbacks = Atomic<UInt64>(0)
        let staleCallbacks = Atomic<UInt64>(0)
        let drainBatches = Atomic<UInt64>(0)
        let overwrittenChanges = Atomic<UInt64>(0)
        let transitionsQueued = Atomic<UInt64>(0)
        let cursorSamples = Atomic<UInt64>(0)
        var maximumPendingFrames: Int

        init(maximumPendingFrames: Int) {
            self.maximumPendingFrames = maximumPendingFrames
        }

        func snapshot(pendingFrames: Int) -> PerformanceSnapshot {
            PerformanceSnapshot(
                rawCallbacks: rawCallbacks.load(ordering: .relaxed),
                staleCallbacks: staleCallbacks.load(ordering: .relaxed),
                drainBatches: drainBatches.load(ordering: .relaxed),
                overwrittenChanges: overwrittenChanges.load(ordering: .relaxed),
                transitionsQueued: transitionsQueued.load(ordering: .relaxed),
                cursorSamples: cursorSamples.load(ordering: .relaxed),
                pendingFrames: pendingFrames,
                maximumPendingFrames: maximumPendingFrames
            )
        }
    }

    enum Kind: Equatable, Sendable {
        case began
        case changed
        case ended
        case cancelled

        var isTerminal: Bool {
            self == .ended || self == .cancelled
        }
    }

    struct Delivery: Sendable {
        let frame: MultitouchGestureSource.RawFrame
        let generation: UInt
        let kind: Kind
    }

    private struct State {
        var generation: UInt = 0
        var touchingSlots: UInt64 = 0
        var ownerSlot: Int?
        var ownerTimestamp: Double = 0
        var drainScheduled = false
        var pending: [Delivery] = []
        var spare: [Delivery] = []
        var performanceCounters: PerformanceCounters?
    }

    let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = 8) {
        self.capacity = max(3, capacity)
    }

    func activate(generation: UInt) {
        state.withLock { value in
            value.generation = generation
            value.touchingSlots = 0
            value.ownerSlot = nil
            value.drainScheduled = false
            value.pending.removeAll(keepingCapacity: true)
        }
    }

    func invalidate() {
        activate(generation: 0)
    }

    func offer(_ frame: MultitouchGestureSource.RawFrame, generation: UInt, slot: Int) -> Bool {
        state.withLock { value in
            if let counters = value.performanceCounters {
                _ = counters.rawCallbacks.wrappingAdd(1, ordering: .relaxed)
            }
            guard generation != 0, generation == value.generation else {
                if let counters = value.performanceCounters {
                    _ = counters.staleCallbacks.wrappingAdd(1, ordering: .relaxed)
                }
                return false
            }
            let hasTouches = !frame.touches.isEmpty
            var scheduled = false
            if let owner = value.ownerSlot, hasTouches,
               frame.timestamp - value.ownerTimestamp > multitouchLiftTimeout
            {
                value.touchingSlots &= ~(1 << UInt64(owner))
                value.ownerSlot = nil
                scheduled = enqueue(
                    .cancelled,
                    MultitouchGestureSource.RawFrame(
                        touches: MultitouchGestureSource.RawTouchBuffer(),
                        timestamp: frame.timestamp
                    ),
                    generation: generation,
                    in: &value
                )
            }
            return route(frame, hasTouches: hasTouches, generation: generation, slot: slot, in: &value) || scheduled
        }
    }

    private func route(
        _ frame: MultitouchGestureSource.RawFrame,
        hasTouches: Bool,
        generation: UInt,
        slot: Int,
        in value: inout State
    ) -> Bool {
        let slotMask: UInt64 = 1 << UInt64(slot)
        let wasTouching = value.touchingSlots & slotMask != 0
        if hasTouches {
            value.touchingSlots |= slotMask
        } else {
            value.touchingSlots &= ~slotMask
        }
        guard let owner = value.ownerSlot else {
            guard hasTouches, !wasTouching else { return false }
            value.ownerSlot = slot
            value.ownerTimestamp = frame.timestamp
            makeRoomForGesture(in: &value)
            return enqueue(.began, frame, generation: generation, in: &value)
        }
        guard owner == slot else { return false }
        guard hasTouches else {
            value.ownerSlot = nil
            return enqueue(.ended, frame, generation: generation, in: &value)
        }
        value.ownerTimestamp = frame.timestamp
        if value.pending.last?.kind == .changed {
            value.pending[value.pending.count - 1] = Delivery(
                frame: frame,
                generation: generation,
                kind: .changed
            )
            if let counters = value.performanceCounters {
                _ = counters.overwrittenChanges.wrappingAdd(1, ordering: .relaxed)
            }
            return scheduleDrainIfNeeded(in: &value)
        }
        return enqueue(.changed, frame, generation: generation, in: &value)
    }

    private func enqueue(
        _ kind: Kind,
        _ frame: MultitouchGestureSource.RawFrame,
        generation: UInt,
        in value: inout State
    ) -> Bool {
        if value.pending.count == capacity,
           let changedIndex = value.pending.firstIndex(where: { $0.kind == .changed })
        {
            value.pending.remove(at: changedIndex)
        }
        if kind.isTerminal {
            makeRoomForEnd(in: &value)
        }
        guard value.pending.count < capacity else { return scheduleDrainIfNeeded(in: &value) }
        value.pending.append(Delivery(frame: frame, generation: generation, kind: kind))
        if let counters = value.performanceCounters {
            if kind != .changed {
                _ = counters.transitionsQueued.wrappingAdd(1, ordering: .relaxed)
            }
            counters.maximumPendingFrames = max(counters.maximumPendingFrames, value.pending.count)
        }
        return scheduleDrainIfNeeded(in: &value)
    }

    func take() -> [Delivery] {
        state.withLock { value in
            var deliveries: [Delivery] = []
            swap(&deliveries, &value.spare)
            deliveries.removeAll(keepingCapacity: true)
            swap(&deliveries, &value.pending)
            value.drainScheduled = false
            if let counters = value.performanceCounters, !deliveries.isEmpty {
                _ = counters.drainBatches.wrappingAdd(1, ordering: .relaxed)
                _ = counters.cursorSamples.wrappingAdd(1, ordering: .relaxed)
            }
            return deliveries
        }
    }

    func recycle(_ deliveries: [Delivery]) {
        let recycled = deliveries
        state.withLock { value in
            if recycled.capacity > value.spare.capacity {
                value.spare = recycled
            }
        }
    }

    var pendingCount: Int {
        state.withLock { $0.pending.count }
    }

    func beginPerformanceCapture() {
        state.withLock { value in
            value.performanceCounters = PerformanceCounters(
                maximumPendingFrames: value.pending.count
            )
        }
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        state.withLock { value in
            value.performanceCounters?.snapshot(pendingFrames: value.pending.count)
        }
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        state.withLock { value in
            let snapshot = value.performanceCounters?.snapshot(pendingFrames: value.pending.count)
            value.performanceCounters = nil
            return snapshot
        }
    }

    private func scheduleDrainIfNeeded(in value: inout State) -> Bool {
        guard !value.drainScheduled, !value.pending.isEmpty else { return false }
        value.drainScheduled = true
        return true
    }

    private func makeRoomForGesture(in value: inout State) {
        while value.pending.count > capacity - 3 {
            guard let endIndex = value.pending.firstIndex(where: { $0.kind.isTerminal }) else {
                value.pending.removeAll(keepingCapacity: true)
                return
            }
            value.pending.removeFirst(endIndex + 1)
        }
    }

    private func makeRoomForEnd(in value: inout State) {
        while value.pending.count >= capacity,
              let endIndex = value.pending.firstIndex(where: { $0.kind.isTerminal })
        {
            value.pending.removeFirst(endIndex + 1)
        }
    }
}
