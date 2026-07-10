// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Synchronization

final class AXCallbackGenerationRegistry: Sendable {
    private struct State {
        var generation: UInt64 = 1
        var observerGenerations: [UInt: UInt64] = [:]
    }

    private let state = Mutex(State())

    var currentGeneration: UInt64 {
        state.withLock { $0.generation }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation }
    }

    @discardableResult
    func register(observerKey: UInt, generation: UInt64) -> Bool {
        state.withLock {
            guard $0.generation == generation else { return false }
            $0.observerGenerations[observerKey] = generation
            return true
        }
    }

    func unregister(observerKey: UInt) {
        state.withLock { state in
            _ = state.observerGenerations.removeValue(forKey: observerKey)
        }
    }

    @discardableResult
    func advance() -> UInt64 {
        state.withLock {
            $0.generation &+= 1
            $0.observerGenerations.removeAll(keepingCapacity: true)
            return $0.generation
        }
    }

    @discardableResult
    func performIfCurrent(observerKey: UInt, _ operation: () -> Void) -> Bool {
        state.withLock {
            guard $0.observerGenerations[observerKey] == $0.generation else { return false }
            operation()
            return true
        }
    }
}

let appAXCallbackGenerationRegistry = AXCallbackGenerationRegistry()
