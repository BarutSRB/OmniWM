// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

extension MultitouchGestureSource {
    struct RegistrationToken: Equatable, Sendable {
        static let slotCapacity = 64
        private static let slotBits: UInt = 6

        let generation: UInt
        let slot: Int

        init(generation: UInt, slot: Int) {
            self.generation = generation
            self.slot = slot
        }

        init(bitPattern: UInt) {
            generation = bitPattern >> Self.slotBits
            slot = Int(bitPattern & UInt(Self.slotCapacity - 1))
        }

        var refcon: UnsafeMutableRawPointer? {
            UnsafeMutableRawPointer(bitPattern: generation << Self.slotBits | UInt(slot))
        }
    }

    enum LifecycleState: String, Sendable {
        case stopped
        case suspended
        case waiting
        case enumerating
        case running
        case retrying
        case exhausted
        case unavailable
    }

    enum RevalidationReason: String, CaseIterable, Hashable, Sendable {
        case startup
        case wake
        case unlock
        case arrival
        case removal
        case observerRecovery
    }

    enum TopologySignal: String, Sendable {
        case arrival
        case removal
    }

    enum TopologyObserverState: Equatable, Sendable {
        case stopped
        case monitoring
        case retrying(Int)
        case exhausted
    }

    struct DiagnosticsSnapshot: Sendable {
        let state: LifecycleState
        let activeGeneration: UInt?
        let registeredDeviceCount: Int
        let lastEnumeration: MultitouchBinding.EnumerationOutcome?
        let lastRegister: OperationResult
        let lastStart: OperationResult
        let lastRunningCheck: OperationResult
        let lastStop: OperationResult
        let lastUnregister: OperationResult
        let retryReasons: [RevalidationReason]
        let retryEpisode: UInt64
        let retryAttempt: Int
        let maximumAttempts: Int
        let nextRetryDelay: Duration?
        let retryExhausted: Bool
        let topologyObserverState: TopologyObserverState
        let lastTopologySignal: TopologySignal?
        let lastRawCallbackTimestamp: Double?
        let lastRawCallbackGeneration: UInt?
        let lastAcceptedCallbackTimestamp: Double?
        let lastAcceptedCallbackGeneration: UInt?

        func formatted() -> String {
            [
                "state=\(state.rawValue)",
                "activeGeneration=\(String(describing: activeGeneration))",
                "registeredDevices=\(registeredDeviceCount)",
                "lastEnumeration=\(String(describing: lastEnumeration))",
                "lastRegister=\(String(describing: lastRegister))",
                "lastStart=\(String(describing: lastStart))",
                "lastRunningCheck=\(String(describing: lastRunningCheck))",
                "lastStop=\(String(describing: lastStop))",
                "lastUnregister=\(String(describing: lastUnregister))",
                "retryReasons=\(retryReasons.map(\.rawValue).joined(separator: ","))",
                "retryEpisode=\(retryEpisode)",
                "retryAttempt=\(retryAttempt)/\(maximumAttempts)",
                "nextRetryDelay=\(String(describing: nextRetryDelay))",
                "retryExhausted=\(retryExhausted)",
                "topologyObserver=\(String(describing: topologyObserverState))",
                "lastTopologySignal=\(String(describing: lastTopologySignal?.rawValue))",
                "lastRawCallbackTimestamp=\(String(describing: lastRawCallbackTimestamp))",
                "lastRawCallbackGeneration=\(String(describing: lastRawCallbackGeneration))",
                "lastAcceptedCallbackTimestamp=\(String(describing: lastAcceptedCallbackTimestamp))",
                "lastAcceptedCallbackGeneration=\(String(describing: lastAcceptedCallbackGeneration))"
            ].joined(separator: "\n")
        }
    }

    struct LifecycleOperations {
        let enumerate: () -> MultitouchBinding.Enumeration
        let register: (
            MultitouchBinding.DeviceRef,
            MultitouchBinding.ContactCallback,
            UnsafeMutableRawPointer
        ) -> Bool
        let start: (MultitouchBinding.DeviceRef) -> Int32
        let isRunning: (MultitouchBinding.DeviceRef) -> Bool
        let stop: (MultitouchBinding.DeviceRef) -> Int32
        let unregister: (MultitouchBinding.DeviceRef, MultitouchBinding.ContactCallback) -> Bool
        let sleep: @MainActor (Duration) async throws -> Void

        init(
            enumerate: @escaping () -> MultitouchBinding.Enumeration,
            register: @escaping (
                MultitouchBinding.DeviceRef,
                MultitouchBinding.ContactCallback,
                UnsafeMutableRawPointer
            ) -> Bool,
            start: @escaping (MultitouchBinding.DeviceRef) -> Int32,
            isRunning: @escaping (MultitouchBinding.DeviceRef) -> Bool,
            stop: @escaping (MultitouchBinding.DeviceRef) -> Int32,
            unregister: @escaping (MultitouchBinding.DeviceRef, MultitouchBinding.ContactCallback) -> Bool,
            sleep: @escaping @MainActor (Duration) async throws -> Void
        ) {
            self.enumerate = enumerate
            self.register = register
            self.start = start
            self.isRunning = isRunning
            self.stop = stop
            self.unregister = unregister
            self.sleep = sleep
        }

        init(binding: MultitouchBinding) {
            enumerate = { binding.enumerateDevices() }
            register = { binding.register($0, callback: $1, refcon: $2) }
            start = { binding.start($0) }
            isRunning = { binding.isRunning($0) }
            stop = { binding.stop($0) }
            unregister = { binding.unregister($0, callback: $1) }
            sleep = { try await Task.sleep(for: $0) }
        }
    }

    struct TopologyMonitoringOperations {
        typealias Notifications = AsyncThrowingStream<TopologySignal, any Error>

        let notifications: @MainActor () async -> Notifications
        let sleep: @MainActor (Duration) async throws -> Void
    }
}
