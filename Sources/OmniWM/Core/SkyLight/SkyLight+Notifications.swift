// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension SkyLight {
    func registerForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else {
            return false
        }
        let result = notifications.registerConnectionNotifyProc(cid, callback, event.rawValue, context)
        return result == 0
    }

    func unregisterForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback
    ) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        let result = notifications.unregisterConnectionNotifyProc(cid, callback, event.rawValue)
        return result == 0
    }

    func registerNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        let result = notifications.registerNotifyProc(callback, event.rawValue, context)
        return result == 0
    }

    func unregisterNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        let result = notifications.unregisterNotifyProcFunc(callback, event.rawValue, context)
        return result == 0
    }

    func subscribeToWindowNotifications(_ windowIds: [UInt32]) -> Bool {
        guard !windowIds.isEmpty else {
            return true
        }
        let cid = getMainConnectionID()
        guard cid != 0 else {
            return false
        }
        let result = windowIds.withUnsafeBufferPointer { buffer in
            notifications.requestNotificationsForWindows(cid, buffer.baseAddress!, Int32(windowIds.count))
        }
        return result == 0
    }
}
