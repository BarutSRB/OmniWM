// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct SkyLightNotificationFunctions {
    typealias RegisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        SkyLight.ConnectionNotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32
    typealias UnregisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        SkyLight.ConnectionNotifyCallback,
        UInt32
    ) -> Int32
    typealias RequestNotificationsForWindowsFunc = @convention(c) (
        Int32,
        UnsafePointer<UInt32>,
        Int32
    ) -> Int32
    typealias RegisterNotifyProcFunc = @convention(c) (
        SkyLight.NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32
    typealias UnregisterNotifyProcFunc = @convention(c) (
        SkyLight.NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    let registerConnectionNotifyProc: RegisterConnectionNotifyProcFunc
    let unregisterConnectionNotifyProc: UnregisterConnectionNotifyProcFunc
    let requestNotificationsForWindows: RequestNotificationsForWindowsFunc
    let registerNotifyProc: RegisterNotifyProcFunc
    let unregisterNotifyProcFunc: UnregisterNotifyProcFunc

    init(resolver: inout SkyLightSymbolResolver) {
        registerConnectionNotifyProc = resolver.resolve(
            "SLSRegisterConnectionNotifyProc",
            as: RegisterConnectionNotifyProcFunc.self
        )
        unregisterConnectionNotifyProc = resolver.resolve(
            "SLSRemoveConnectionNotifyProc",
            as: UnregisterConnectionNotifyProcFunc.self
        )
        requestNotificationsForWindows = resolver.resolve(
            "SLSRequestNotificationsForWindows",
            as: RequestNotificationsForWindowsFunc.self
        )
        registerNotifyProc = resolver.resolve("SLSRegisterNotifyProc", as: RegisterNotifyProcFunc.self)
        unregisterNotifyProcFunc = resolver.resolve("SLSRemoveNotifyProc", as: UnregisterNotifyProcFunc.self)
    }
}
