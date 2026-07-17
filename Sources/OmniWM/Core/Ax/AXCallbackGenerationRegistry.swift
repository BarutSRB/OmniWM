// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Synchronization

final class AXCallbackGenerationRegistry: Sendable {
    private struct ObserverState {
        let serviceGeneration: UInt64
        let callbackGeneration: UInt64
        var isActive: Bool
    }

    private struct State {
        var serviceGeneration: UInt64 = 1
        var nextCallbackGeneration: UInt64 = 1
        var observers: [UInt: ObserverState] = [:]
    }

    private let state = Mutex(State())

    var currentGeneration: UInt64 {
        state.withLock { $0.serviceGeneration }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.serviceGeneration == generation }
    }

    func reserveCallbackGeneration(serviceGeneration: UInt64) -> UInt64? {
        state.withLock {
            guard $0.serviceGeneration == serviceGeneration else { return nil }
            let generation = $0.nextCallbackGeneration
            $0.nextCallbackGeneration &+= 1
            return generation
        }
    }

    @discardableResult
    func register(
        observerKey: UInt,
        serviceGeneration: UInt64,
        callbackGeneration: UInt64
    ) -> Bool {
        state.withLock {
            guard $0.serviceGeneration == serviceGeneration else { return false }
            $0.observers[observerKey] = ObserverState(
                serviceGeneration: serviceGeneration,
                callbackGeneration: callbackGeneration,
                isActive: true
            )
            return true
        }
    }

    func unregister(observerKey: UInt) {
        state.withLock { state in
            state.observers[observerKey]?.isActive = false
        }
    }

    func generation(observerKey: UInt) -> UInt64? {
        state.withLock { $0.observers[observerKey]?.callbackGeneration }
    }

    @discardableResult
    func advance() -> UInt64 {
        state.withLock {
            $0.serviceGeneration &+= 1
            for key in Array($0.observers.keys) {
                $0.observers[key]?.isActive = false
            }
            return $0.serviceGeneration
        }
    }

    @discardableResult
    func performIfCurrent(observerKey: UInt, _ operation: () -> Void) -> Bool {
        state.withLock {
            guard let observer = $0.observers[observerKey],
                  observer.isActive,
                  observer.serviceGeneration == $0.serviceGeneration
            else {
                return false
            }
            operation()
            return true
        }
    }
}

let appAXCallbackGenerationRegistry = AXCallbackGenerationRegistry()
