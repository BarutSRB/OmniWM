// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXWindowNotificationSet: OptionSet, Sendable {
    let rawValue: UInt8

    static let destroyed = Self(rawValue: 1 << 0)
    static let miniaturized = Self(rawValue: 1 << 1)
    static let lifecycle: Self = [.destroyed, .miniaturized]
}

enum AppAXWindowNotification: CaseIterable, Hashable, Sendable {
    case destroyed
    case miniaturized

    var ownership: AppAXWindowNotificationSet {
        switch self {
        case .destroyed: .destroyed
        case .miniaturized: .miniaturized
        }
    }

    var name: CFString {
        switch self {
        case .destroyed: kAXUIElementDestroyedNotification as CFString
        case .miniaturized: kAXWindowMiniaturizedNotification as CFString
        }
    }
}

enum AppAXAlreadyRegisteredPolicy: Sendable {
    case adopt
    case reject
    case replace
}

enum AppAXWindowRebindSubscriptionOwnership: Equatable, Sendable {
    case unowned
    case destination
    case source
    case conflict
}

struct AppAXWindowSubscription: @unchecked Sendable {
    let windowId: Int
    let element: AXUIElement
    var notifications: AppAXWindowNotificationSet

    func owns(_ notification: AppAXWindowNotification) -> Bool {
        notifications.contains(notification.ownership)
    }
}

struct AppAXPendingNotificationRemoval: @unchecked Sendable {
    let element: AXUIElement
    let notification: AppAXWindowNotification
    var attempts: UInt8 = 0
}

struct AppAXWindowNotificationInstallResult: @unchecked Sendable {
    let subscription: AppAXWindowSubscription?
    let newlyInstalled: AppAXWindowNotificationSet
    let pendingRemovals: [AppAXPendingNotificationRemoval]
}

struct AppAXWindowRebindBinding: @unchecked Sendable {
    let destinationWindowElement: AXUIElement?
    let destinationSubscription: AppAXWindowSubscription?
    let stagedSubscription: AppAXWindowSubscription?
    let newlyInstalledNotifications: AppAXWindowNotificationSet
    let requiresRetag: Bool
    let hasLifecycleObserver: Bool
}

struct AppAXSubscriptionCleanup: @unchecked Sendable {
    let subscriptions: [AppAXWindowSubscription]
}

struct AppAXWindowStateRemovalOutcome: Sendable {
    let removedCachedWindow: Bool
    let removedSubscription: Bool
}

enum AppAXWindowBindingResult: Equatable, Sendable {
    case bound
    case superseded
    case retryRequired
}
