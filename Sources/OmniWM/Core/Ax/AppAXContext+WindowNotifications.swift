// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AppAXContext {
    nonisolated static func removeOwnedWindowNotifications(
        _ subscription: AppAXWindowSubscription,
        removeNotification: (AppAXWindowNotification) -> AXError
    ) -> [AppAXPendingNotificationRemoval] {
        var pending: [AppAXPendingNotificationRemoval] = []
        for notification in AppAXWindowNotification.allCases where subscription.owns(notification) {
            let result = removeNotification(notification)
            if result != .success, result != .notificationNotRegistered {
                pending.append(.init(element: subscription.element, notification: notification))
            }
        }
        return pending
    }

    nonisolated static func addWindowNotifications(
        observer: AXObserver,
        window: AXWindowRef,
        ownedSubscription: AppAXWindowSubscription?,
        alreadyRegisteredPolicy: AppAXAlreadyRegisteredPolicy = .adopt,
        checkCancellation: () throws -> Void,
        recordPendingRemovals: ([AppAXPendingNotificationRemoval]) -> Void
    ) throws -> AppAXWindowNotificationInstallResult {
        guard appAXCallbackGenerationRegistry.allowsWindowRegistration(
            observerKey: axCallbackObserverKey(observer),
            element: window.element
        ) else {
            return .init(subscription: nil, newlyInstalled: [], pendingRemovals: [])
        }
        let result = try AppAXWindowNotificationInstaller.install(
            element: window.element,
            windowId: window.windowId,
            ownedSubscription: ownedSubscription,
            addNotification: { notification, refcon in
                AXObserverAddNotification(observer, window.element, notification.name, refcon)
            },
            removeNotification: { notification in
                AXObserverRemoveNotification(observer, window.element, notification.name)
            },
            alreadyRegisteredPolicy: alreadyRegisteredPolicy,
            checkCancellation: checkCancellation,
            recordPendingRemovals: recordPendingRemovals
        )
        if result.subscription == nil {
            FallbackFiringRecorder.shared.note(.ax, "windowSubscribeFailed")
        }
        return result
    }

    nonisolated static func removeWindowNotifications(
        observer: AXObserver,
        subscription: AppAXWindowSubscription
    ) -> [AppAXPendingNotificationRemoval] {
        removeOwnedWindowNotifications(subscription) { notification in
            AXObserverRemoveNotification(observer, subscription.element, notification.name)
        }
    }

    nonisolated static func appendPendingNotificationRemovals(
        _ additions: [AppAXPendingNotificationRemoval],
        to state: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        observerKey: UInt?
    ) {
        guard !additions.isEmpty else { return }
        if let observerKey,
           pendingNotificationRemovalMergeWouldOverflow(additions, into: state.value)
        {
            appAXCallbackGenerationRegistry.rejectWindowNotifications(observerKey: observerKey)
        }
        state.value = mergePendingNotificationRemovals(additions, into: state.value)
    }

    nonisolated static func pendingNotificationRemovalMergeWouldOverflow(
        _ additions: [AppAXPendingNotificationRemoval],
        into existing: [AppAXPendingNotificationRemoval]
    ) -> Bool {
        var pending = existing
        for addition in additions where !pending.contains(where: {
            $0.notification == addition.notification && CFEqual($0.element, addition.element)
        }) {
            pending.append(addition)
            if pending.count > pendingNotificationRemovalLimit {
                return true
            }
        }
        return false
    }

    nonisolated static func mergePendingNotificationRemovals(
        _ additions: [AppAXPendingNotificationRemoval],
        into existing: [AppAXPendingNotificationRemoval]
    ) -> [AppAXPendingNotificationRemoval] {
        var pending = existing
        for addition in additions where !pending.contains(where: {
            $0.notification == addition.notification && CFEqual($0.element, addition.element)
        }) {
            pending.append(addition)
        }
        if pending.count > pendingNotificationRemovalLimit {
            pending.removeFirst(pending.count - pendingNotificationRemovalLimit)
        }
        return pending
    }

    nonisolated static func drainPendingNotificationRemovals(
        _ state: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        observer: AXObserver,
        checkCancellation: () throws -> Void
    ) throws {
        state.value = try retryPendingNotificationRemovals(
            state.value,
            checkCancellation: checkCancellation,
            removeNotification: {
                AXObserverRemoveNotification(observer, $0, $1.name)
            },
            recordAbandonedElement: {
                appAXCallbackGenerationRegistry.retireWindowElement(
                    observerKey: axCallbackObserverKey(observer),
                    element: $0
                )
            }
        )
    }

    nonisolated static func retryPendingNotificationRemovals(
        _ pending: [AppAXPendingNotificationRemoval],
        checkCancellation: () throws -> Void,
        removeNotification: (AXUIElement, AppAXWindowNotification) -> AXError,
        recordAbandonedElement: (AXUIElement) -> Void = { _ in }
    ) throws -> [AppAXPendingNotificationRemoval] {
        var remaining: [AppAXPendingNotificationRemoval] = []
        remaining.reserveCapacity(pending.count)
        for var removal in pending {
            try checkCancellation()
            let result = removeNotification(removal.element, removal.notification)
            guard result != .success,
                  result != .notificationNotRegistered,
                  result != .invalidUIElement
            else {
                continue
            }
            if removal.attempts < pendingNotificationRemovalAttemptLimit - 1 {
                removal.attempts += 1
                remaining.append(removal)
            } else {
                recordAbandonedElement(removal.element)
            }
        }
        return remaining
    }

    nonisolated static func hasPendingNotificationRemoval(
        for element: AXUIElement,
        in pending: [AppAXPendingNotificationRemoval]
    ) -> Bool {
        pending.contains { CFEqual($0.element, element) }
    }

    nonisolated static func stageSubscriptionRemoval(
        _ subscription: AppAXWindowSubscription,
        in state: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        observerKey: UInt?
    ) {
        appendPendingNotificationRemovals(
            AppAXWindowNotification.allCases.compactMap { notification in
                subscription.owns(notification)
                    ? AppAXPendingNotificationRemoval(
                        element: subscription.element,
                        notification: notification
                    )
                    : nil
            },
            to: state,
            observerKey: observerKey
        )
    }
}
