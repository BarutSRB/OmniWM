// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

final class MultitouchBinding {
    typealias DeviceRef = OpaquePointer
    typealias ContactCallback = @convention(c) (
        Int32,
        UnsafeMutableRawPointer?,
        Int32,
        Double,
        Int32
    ) -> Int32

    private typealias CreateListFunc = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DeviceModeFunc = @convention(c) (DeviceRef, Int32) -> Void
    private typealias DeviceFunc = @convention(c) (DeviceRef) -> Void
    private typealias RegisterFunc = @convention(c) (DeviceRef, ContactCallback) -> Void

    private let createListFunc: CreateListFunc
    private let startFunc: DeviceModeFunc
    private let stopFunc: DeviceFunc
    private let registerFunc: RegisterFunc
    private let unregisterFunc: RegisterFunc

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
              let registerFunc = symbol("MTRegisterContactFrameCallback", as: RegisterFunc.self),
              let unregisterFunc = symbol("MTUnregisterContactFrameCallback", as: RegisterFunc.self)
        else {
            Self.logUnavailable("missing required symbols")
            return nil
        }

        self.createListFunc = createListFunc
        self.startFunc = startFunc
        self.stopFunc = stopFunc
        self.registerFunc = registerFunc
        self.unregisterFunc = unregisterFunc
    }

    func devices() -> (list: CFArray, refs: [DeviceRef])? {
        guard let array = createListFunc()?.takeRetainedValue() else { return nil }
        let count = CFArrayGetCount(array)
        var refs: [DeviceRef] = []
        refs.reserveCapacity(count)
        for index in 0 ..< count {
            guard let value = CFArrayGetValueAtIndex(array, index) else { continue }
            refs.append(OpaquePointer(UnsafeMutableRawPointer(mutating: value)))
        }
        return (array, refs)
    }

    func start(_ device: DeviceRef) {
        startFunc(device, 0)
    }

    func stop(_ device: DeviceRef) {
        stopFunc(device)
    }

    func register(_ device: DeviceRef, callback: ContactCallback) {
        registerFunc(device, callback)
    }

    func unregister(_ device: DeviceRef, callback: ContactCallback) {
        unregisterFunc(device, callback)
    }

    private static func logUnavailable(_ reason: String) {
        let message = "OmniWM: trackpad gestures unavailable — MultitouchSupport \(reason)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
