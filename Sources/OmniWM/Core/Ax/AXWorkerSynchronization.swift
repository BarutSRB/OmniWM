// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

final class LockedWindowIdSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []
    private var hardSuppressed = false

    func insert(_ id: Int) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func remove(_ id: Int) {
        lock.lock()
        ids.remove(id)
        lock.unlock()
    }

    func contains(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hardSuppressed || ids.contains(id)
    }

    func setHardSuppressed(_ hardSuppressed: Bool) {
        lock.lock()
        self.hardSuppressed = hardSuppressed
        lock.unlock()
    }

    func isHardSuppressed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hardSuppressed
    }

    func moveIfPresent(from oldId: Int, to newId: Int) {
        lock.lock()
        if oldId != newId, ids.remove(oldId) != nil {
            ids.insert(newId)
        }
        lock.unlock()
    }

    func retainOnly(_ retainedIds: Set<Int>) {
        lock.lock()
        ids.formIntersection(retainedIds)
        lock.unlock()
    }
}

final class LockedWindowGenerationMap: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 1
    private var generations: [Int: UInt64] = [:]

    func nextGeneration(for id: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let generation = nextGeneration
        nextGeneration &+= 1
        generations[id] = generation
        return generation
    }

    func isCurrent(_ generation: UInt64, for id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[id] == generation
    }

    func invalidateAndRemove(_ id: Int) {
        lock.lock()
        nextGeneration &+= 1
        generations.removeValue(forKey: id)
        lock.unlock()
    }

    func invalidateAndMoveValue(from oldId: Int, to newId: Int) {
        lock.lock()
        let generation = nextGeneration
        nextGeneration &+= 1
        if oldId != newId {
            generations.removeValue(forKey: oldId)
        }
        generations[newId] = generation
        lock.unlock()
    }

    func retainOnly(_ retainedIds: Set<Int>) {
        lock.lock()
        generations = generations.filter { retainedIds.contains($0.key) }
        lock.unlock()
    }
}

final class LockedEnhancedUIStateMap: @unchecked Sendable {
    private enum State {
        case enabled
        case disabled(expiresAt: ContinuousClock.Instant)
    }

    static let shared = LockedEnhancedUIStateMap()

    private static let disabledStateLifetime: Duration = .seconds(1)

    private let clock: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var statesByPid: [pid_t: State] = [:]

    init(clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.clock = clock
    }

    func state(for pid: pid_t) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = statesByPid[pid] else { return nil }
        switch state {
        case .enabled:
            return true
        case let .disabled(expiresAt):
            guard clock() < expiresAt else {
                statesByPid.removeValue(forKey: pid)
                return nil
            }
            return false
        }
    }

    func store(_ enabled: Bool, for pid: pid_t) {
        if enabled {
            lock.lock()
            statesByPid[pid] = .enabled
            lock.unlock()
            return
        }

        let expiresAt = clock().advanced(by: Self.disabledStateLifetime)
        lock.lock()
        if case .enabled? = statesByPid[pid] {
            lock.unlock()
            return
        }
        statesByPid[pid] = .disabled(expiresAt: expiresAt)
        lock.unlock()
    }

    func invalidate(_ pid: pid_t) {
        lock.lock()
        statesByPid.removeValue(forKey: pid)
        lock.unlock()
    }
}

final class LockedClosingFrameGenerationMap: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 1
    private var generations: [UUID: UInt64] = [:]

    func nextGeneration(for animationId: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let generation = nextGeneration
        nextGeneration &+= 1
        generations[animationId] = generation
        return generation
    }

    func isCurrent(_ generation: UInt64, for animationId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[animationId] == generation
    }

    func removeIfCurrent(_ generation: UInt64, for animationId: UUID) {
        lock.lock()
        if generations[animationId] == generation {
            generations.removeValue(forKey: animationId)
        }
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        nextGeneration &+= 1
        generations.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

final class LockedGenerationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        generation &+= 1
        let currentGeneration = generation
        lock.unlock()
        return currentGeneration
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func performIfCurrent<T>(
        _ expectedGeneration: UInt64,
        _ body: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return nil }
        return try body()
    }
}
