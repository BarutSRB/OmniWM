// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

struct AppAXWindowNotificationInstaller {
    private enum NotificationOutcome {
        case adopted
        case installed
        case failed([AppAXPendingNotificationRemoval])
    }

    private let element: AXUIElement
    private let windowId: Int
    private let refcon: UnsafeMutableRawPointer
    private var installed: AppAXWindowNotificationSet
    private var newlyInstalled: AppAXWindowNotificationSet = []

    private init?(element: AXUIElement, windowId: Int, ownedSubscription: AppAXWindowSubscription?) {
        guard let refcon = AppAXContext.destroyNotificationRefcon(for: windowId) else { return nil }
        let exactOwnership = ownedSubscription.flatMap { subscription in
            subscription.windowId == windowId && CFEqual(subscription.element, element)
                ? subscription
                : nil
        }
        if ownedSubscription != nil, exactOwnership == nil { return nil }
        self.element = element
        self.windowId = windowId
        self.refcon = refcon
        installed = exactOwnership?.notifications ?? []
    }

    static func install(
        element: AXUIElement,
        windowId: Int,
        ownedSubscription: AppAXWindowSubscription?,
        addNotification: (AppAXWindowNotification, UnsafeMutableRawPointer?) -> AXError,
        removeNotification: (AppAXWindowNotification) -> AXError,
        alreadyRegisteredPolicy: AppAXAlreadyRegisteredPolicy = .adopt,
        checkCancellation: () throws -> Void = {},
        recordPendingRemovals: ([AppAXPendingNotificationRemoval]) -> Void = { _ in }
    ) throws -> AppAXWindowNotificationInstallResult {
        guard var installer = Self(element: element, windowId: windowId, ownedSubscription: ownedSubscription) else {
            return .init(subscription: nil, newlyInstalled: [], pendingRemovals: [])
        }
        return try installer.installLifecycle(
            addNotification: addNotification,
            removeNotification: removeNotification,
            alreadyRegisteredPolicy: alreadyRegisteredPolicy,
            checkCancellation: checkCancellation,
            recordPendingRemovals: recordPendingRemovals
        )
    }

    private mutating func installLifecycle(
        addNotification: (AppAXWindowNotification, UnsafeMutableRawPointer?) -> AXError,
        removeNotification: (AppAXWindowNotification) -> AXError,
        alreadyRegisteredPolicy: AppAXAlreadyRegisteredPolicy,
        checkCancellation: () throws -> Void,
        recordPendingRemovals: ([AppAXPendingNotificationRemoval]) -> Void
    ) throws -> AppAXWindowNotificationInstallResult {
        do {
            for notification in AppAXWindowNotification.allCases where !installed.contains(notification.ownership) {
                try checkCancellation()
                let outcome = try installNotification(
                    notification,
                    addNotification: addNotification,
                    removeNotification: removeNotification,
                    alreadyRegisteredPolicy: alreadyRegisteredPolicy,
                    checkCancellation: checkCancellation
                )
                switch outcome {
                case .adopted:
                    installed.insert(notification.ownership)
                case .installed:
                    installed.insert(notification.ownership)
                    newlyInstalled.insert(notification.ownership)
                case var .failed(pendingRemovals):
                    pendingRemovals.append(contentsOf: rollback(removeNotification: removeNotification))
                    return .init(subscription: nil, newlyInstalled: [], pendingRemovals: pendingRemovals)
                }
            }
            try checkCancellation()
        } catch {
            recordPendingRemovals(rollback(removeNotification: removeNotification))
            throw error
        }
        return .init(
            subscription: .init(windowId: windowId, element: element, notifications: installed),
            newlyInstalled: newlyInstalled,
            pendingRemovals: []
        )
    }

    private func installNotification(
        _ notification: AppAXWindowNotification,
        addNotification: (AppAXWindowNotification, UnsafeMutableRawPointer?) -> AXError,
        removeNotification: (AppAXWindowNotification) -> AXError,
        alreadyRegisteredPolicy: AppAXAlreadyRegisteredPolicy,
        checkCancellation: () throws -> Void
    ) throws -> NotificationOutcome {
        var result = addNotification(notification, refcon)
        if result == .notificationAlreadyRegistered {
            switch alreadyRegisteredPolicy {
            case .adopt:
                return .adopted
            case .reject:
                return .failed([])
            case .replace:
                break
            }
            let removeResult = removeNotification(notification)
            if removeResult != .success, removeResult != .notificationNotRegistered {
                return .failed([.init(element: element, notification: notification)])
            }
            try checkCancellation()
            result = addNotification(notification, refcon)
        }
        guard result == .success else {
            return .failed(result == .notificationAlreadyRegistered
                ? [.init(element: element, notification: notification)]
                : [])
        }
        return .installed
    }

    private func rollback(
        removeNotification: (AppAXWindowNotification) -> AXError
    ) -> [AppAXPendingNotificationRemoval] {
        var pending: [AppAXPendingNotificationRemoval] = []
        for notification in AppAXWindowNotification.allCases.reversed()
            where newlyInstalled.contains(notification.ownership)
        {
            let result = removeNotification(notification)
            if result != .success, result != .notificationNotRegistered {
                pending.append(.init(element: element, notification: notification))
            }
        }
        return pending
    }
}
