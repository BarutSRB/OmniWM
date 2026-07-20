// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import IOKit

final class MultitouchBinding {
    typealias DeviceRef = OpaquePointer
    typealias ContactCallback = @convention(c) (
        DeviceRef,
        UnsafeMutableRawPointer?,
        Int32,
        Double,
        Int32,
        UnsafeMutableRawPointer?
    ) -> Int32

    struct Device {
        let ref: DeviceRef
        let registryId: UInt64
    }

    enum EnumerationOutcome: Equatable, Sendable {
        case unavailable
        case empty
        case invalidDeviceReference
        case missingService
        case registryIdFailure(Int32)
        case duplicateRegistryId
        case success(Int)
    }

    struct Enumeration {
        let list: CFArray?
        let devices: [Device]
        let outcome: EnumerationOutcome
    }

    private typealias CreateListFunc = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DeviceModeFunc = @convention(c) (DeviceRef, Int32) -> Int32
    private typealias DeviceFunc = @convention(c) (DeviceRef) -> Int32
    private typealias DeviceIsRunningFunc = @convention(c) (DeviceRef) -> Bool
    private typealias DeviceGetServiceFunc = @convention(c) (DeviceRef) -> io_service_t
    private typealias RegisterWithRefconFunc = @convention(c) (
        DeviceRef,
        ContactCallback,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias UnregisterFunc = @convention(c) (DeviceRef, ContactCallback) -> Int32

    private let createListFunc: CreateListFunc
    private let startFunc: DeviceModeFunc
    private let stopFunc: DeviceFunc
    private let isRunningFunc: DeviceIsRunningFunc
    private let getServiceFunc: DeviceGetServiceFunc
    private let registerWithRefconFunc: RegisterWithRefconFunc
    private let unregisterFunc: UnregisterFunc

    init?() {
        guard let lib = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            Self.logUnavailable("dlopen failed")
            return nil
        }

        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let pointer = dlsym(lib, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard let createListFunc = symbol("MTDeviceCreateList", as: CreateListFunc.self),
              let startFunc = symbol("MTDeviceStart", as: DeviceModeFunc.self),
              let stopFunc = symbol("MTDeviceStop", as: DeviceFunc.self),
              let isRunningFunc = symbol("MTDeviceIsRunning", as: DeviceIsRunningFunc.self),
              let getServiceFunc = symbol("MTDeviceGetService", as: DeviceGetServiceFunc.self),
              let registerWithRefconFunc = symbol(
                  "MTRegisterContactFrameCallbackWithRefcon",
                  as: RegisterWithRefconFunc.self
              ),
              let unregisterFunc = symbol("MTUnregisterContactFrameCallback", as: UnregisterFunc.self)
        else {
            Self.logUnavailable("missing required symbols")
            return nil
        }

        self.createListFunc = createListFunc
        self.startFunc = startFunc
        self.stopFunc = stopFunc
        self.isRunningFunc = isRunningFunc
        self.getServiceFunc = getServiceFunc
        self.registerWithRefconFunc = registerWithRefconFunc
        self.unregisterFunc = unregisterFunc
    }

    static let symbolNames = [
        "MTDeviceCreateList",
        "MTDeviceStart",
        "MTDeviceStop",
        "MTDeviceIsRunning",
        "MTDeviceGetService",
        "MTRegisterContactFrameCallback",
        "MTRegisterContactFrameCallbackWithRefcon",
        "MTUnregisterContactFrameCallback"
    ]

    static func resolvedSymbols() -> [(name: String, resolved: Bool)] {
        guard let lib = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            return symbolNames.map { ($0, false) }
        }
        return symbolNames.map { ($0, dlsym(lib, $0) != nil) }
    }

    func deviceCount() -> Int {
        guard let array = createListFunc()?.takeRetainedValue() else { return -1 }
        return CFArrayGetCount(array)
    }

    func enumerateDevices() -> Enumeration {
        guard let array = createListFunc()?.takeRetainedValue() else {
            return Enumeration(list: nil, devices: [], outcome: .unavailable)
        }
        let count = CFArrayGetCount(array)
        guard count > 0 else {
            return Enumeration(list: array, devices: [], outcome: .empty)
        }

        var devices: [Device] = []
        devices.reserveCapacity(count)
        var registryIds: Set<UInt64> = []
        registryIds.reserveCapacity(count)
        for index in 0 ..< count {
            guard let value = CFArrayGetValueAtIndex(array, index),
                  let ref = OpaquePointer(UnsafeMutableRawPointer(mutating: value))
            else {
                return Enumeration(list: array, devices: [], outcome: .invalidDeviceReference)
            }
            let service = getServiceFunc(ref)
            guard service != IO_OBJECT_NULL else {
                return Enumeration(list: array, devices: [], outcome: .missingService)
            }
            var registryId: UInt64 = 0
            let status = IORegistryEntryGetRegistryEntryID(service, &registryId)
            guard status == KERN_SUCCESS else {
                return Enumeration(list: array, devices: [], outcome: .registryIdFailure(status))
            }
            guard registryIds.insert(registryId).inserted else {
                return Enumeration(list: array, devices: [], outcome: .duplicateRegistryId)
            }
            devices.append(Device(ref: ref, registryId: registryId))
        }
        return Enumeration(list: array, devices: devices, outcome: .success(devices.count))
    }

    func start(_ device: DeviceRef) -> Int32 {
        startFunc(device, 0)
    }

    func stop(_ device: DeviceRef) -> Int32 {
        stopFunc(device)
    }

    func isRunning(_ device: DeviceRef) -> Bool {
        isRunningFunc(device)
    }

    func register(
        _ device: DeviceRef,
        callback: ContactCallback,
        refcon: UnsafeMutableRawPointer
    ) -> Bool {
        registerWithRefconFunc(device, callback, refcon) != 0
    }

    func unregister(_ device: DeviceRef, callback: ContactCallback) -> Bool {
        unregisterFunc(device, callback) != 0
    }

    private static func logUnavailable(_ reason: String) {
        let message = "OmniWM: trackpad gestures unavailable — MultitouchSupport \(reason)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
