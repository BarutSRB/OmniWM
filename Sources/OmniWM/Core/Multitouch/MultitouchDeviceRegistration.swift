// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

extension MultitouchGestureSource {
    enum OperationResult: Equatable, Sendable {
        case notAttempted
        case success
        case alreadyStopped(Int32)
        case alreadyUnregistered
        case status(Int32)
        case rejected

        fileprivate mutating func record(_ result: OperationResult) {
            if self == .notAttempted {
                self = result
            } else if self == .success, result != .success {
                self = result
            }
        }
    }
}

@MainActor
final class MultitouchDeviceRegistration {
    private typealias RegistrationToken = MultitouchGestureSource.RegistrationToken
    private typealias OperationResult = MultitouchGestureSource.OperationResult
    private let operations: MultitouchGestureSource.LifecycleOperations?
    private let callback: MultitouchBinding.ContactCallback
    private var registrations: [Registration] = []
    private var deviceList: CFArray?
    private(set) var lastRegister: MultitouchGestureSource.OperationResult = .notAttempted
    private(set) var lastStart: MultitouchGestureSource.OperationResult = .notAttempted
    private(set) var lastRunningCheck: MultitouchGestureSource.OperationResult = .notAttempted
    private(set) var lastStop: MultitouchGestureSource.OperationResult = .notAttempted
    private(set) var lastUnregister: MultitouchGestureSource.OperationResult = .notAttempted

    init(
        operations: MultitouchGestureSource.LifecycleOperations?,
        callback: @escaping MultitouchBinding.ContactCallback
    ) {
        self.operations = operations
        self.callback = callback
    }

    var isEmpty: Bool {
        registrations.isEmpty
    }

    var registryIds: Set<UInt64> {
        Set(registrations.map(\.device.registryId))
    }

    var registeredCount: Int {
        registrations.filter(\.registered).count
    }

    func allRunning() -> Bool {
        guard let operations else { return false }
        let result = registrations.allSatisfy { operations.isRunning($0.device.ref) }
        lastRunningCheck = result ? .success : .rejected
        return result
    }

    func teardown() -> Bool {
        guard cleanup(&registrations) else { return false }
        registrations.removeAll(keepingCapacity: false)
        deviceList = nil
        return true
    }

    private struct Registration {
        let device: MultitouchBinding.Device
        var startAttempted: Bool
        var registered: Bool
    }

    func register(enumeration: MultitouchBinding.Enumeration, generation: UInt) -> Bool {
        guard let operations else { return false }
        guard enumeration.devices.count <= RegistrationToken.slotCapacity else {
            lastRegister = .rejected
            return false
        }

        var candidates: [Registration] = []
        candidates.reserveCapacity(enumeration.devices.count)
        for (slot, device) in enumeration.devices.enumerated() {
            let refcon = RegistrationToken(generation: generation, slot: slot).refcon
            let registered = refcon.map { operations.register(device.ref, callback, $0) } ?? false
            lastRegister = registered ? .success : .rejected
            guard registered else {
                _ = cleanup(&candidates)
                retainIncompleteCleanup(candidates, list: enumeration.list)
                return false
            }
            candidates.append(Registration(device: device, startAttempted: false, registered: true))

            candidates[candidates.count - 1].startAttempted = true
            let startStatus = operations.start(device.ref)
            lastStart = startStatus == KERN_SUCCESS ? .success : .status(startStatus)
            guard startStatus == KERN_SUCCESS else {
                _ = cleanup(&candidates)
                retainIncompleteCleanup(candidates, list: enumeration.list)
                return false
            }
            let running = operations.isRunning(device.ref)
            lastRunningCheck = running ? .success : .rejected
            guard running else {
                _ = cleanup(&candidates)
                retainIncompleteCleanup(candidates, list: enumeration.list)
                return false
            }
        }

        registrations = candidates
        deviceList = enumeration.list
        return true
    }

    private func retainIncompleteCleanup(_ candidates: [Registration], list: CFArray?) {
        let incomplete = candidates.filter { $0.startAttempted || $0.registered }
        guard !incomplete.isEmpty else { return }
        registrations = incomplete
        deviceList = list
    }

    private func cleanup(_ registrations: inout [Registration]) -> Bool {
        guard let operations else { return registrations.isEmpty }
        var succeeded = true
        var stopResult: OperationResult = .notAttempted
        var stopFailure: OperationResult?
        var unregisterResult: OperationResult = .notAttempted
        for index in registrations.indices where registrations[index].startAttempted {
            let status = operations.stop(registrations[index].device.ref)
            let stopped = status == KERN_SUCCESS || status == kIOReturnNotOpen
            let result: OperationResult = if status == KERN_SUCCESS {
                .success
            } else if status == kIOReturnNotOpen {
                .alreadyStopped(status)
            } else {
                .status(status)
            }
            stopResult.record(result)
            if stopped {
                registrations[index].startAttempted = false
            } else {
                succeeded = false
                if stopFailure == nil {
                    stopFailure = result
                }
            }
        }
        for index in registrations.indices where registrations[index].registered {
            let unregistered = operations.unregister(registrations[index].device.ref, callback)
            let result: OperationResult = unregistered ? .success : .alreadyUnregistered
            unregisterResult.record(result)
            registrations[index].registered = false
        }
        lastStop = stopFailure ?? stopResult
        lastUnregister = unregisterResult
        return succeeded
    }
}
