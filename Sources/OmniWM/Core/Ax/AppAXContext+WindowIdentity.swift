// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AppAXContext {
    nonisolated static func ownedSubscription(
        for element: AXUIElement,
        windowId: Int,
        in subscriptions: [Int: AppAXWindowSubscription]
    ) -> AppAXWindowSubscription? {
        if let direct = subscriptions[windowId], CFEqual(direct.element, element) {
            return direct
        }
        return subscriptions.values.first {
            CFEqual($0.element, element)
        }
    }

    nonisolated static func rebindSubscriptionOwnership(
        _ subscription: AppAXWindowSubscription?,
        oldWindowId: Int,
        newWindowId: Int
    ) -> AppAXWindowRebindSubscriptionOwnership {
        guard let subscription else { return .unowned }
        if subscription.windowId == newWindowId { return .destination }
        if subscription.windowId == oldWindowId { return .source }
        return .conflict
    }

    nonisolated static func sameSubscription(
        _ lhs: AppAXWindowSubscription?,
        _ rhs: AppAXWindowSubscription?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.windowId == rhs.windowId
                && lhs.notifications == rhs.notifications
                && CFEqual(lhs.element, rhs.element)
        default:
            false
        }
    }

    nonisolated static func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            CFEqual(lhs, rhs)
        default:
            false
        }
    }

    nonisolated static func removeExactWindowState(
        expectedWindow: AXWindowRef,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        observerKey: UInt?
    ) -> AppAXWindowStateRemovalOutcome {
        let windowId = expectedWindow.windowId
        let cachedElement = windows[windowId]
        let subscription = subscribedWindows[windowId]
        let removesCachedWindow = cachedElement.map {
            CFEqual($0, expectedWindow.element)
        } == true
        let removesSubscription = subscription.map {
            CFEqual($0.element, expectedWindow.element)
        } == true
        if removesSubscription, let subscription {
            stageSubscriptionRemoval(
                subscription,
                in: pendingNotificationRemovals,
                observerKey: observerKey
            )
            subscribedWindows[windowId] = nil
        }
        if removesCachedWindow {
            windows[windowId] = nil
        }
        return .init(
            removedCachedWindow: removesCachedWindow,
            removedSubscription: removesSubscription
        )
    }

    nonisolated static func hasConflictingWindowIdentity(
        for element: AXUIElement,
        destinationWindowId: Int,
        permittedSourceWindowId: Int?,
        windows: [Int: AXUIElement],
        subscriptions: [Int: AppAXWindowSubscription]
    ) -> Bool {
        windows.contains { windowId, candidate in
            windowId != destinationWindowId
                && windowId != permittedSourceWindowId
                && CFEqual(candidate, element)
        } || subscriptions.contains { windowId, subscription in
            (windowId != destinationWindowId && windowId != permittedSourceWindowId)
                && CFEqual(subscription.element, element)
        }
    }

    nonisolated static func cleanUpUnpublishedWindowRebind(
        _ binding: AppAXWindowRebindBinding,
        additionalSubscriptions: [AppAXWindowSubscription] = [],
        observer: AXObserver,
        subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>
    ) {
        func removeIfUnadopted(_ unpublished: AppAXWindowSubscription) {
            var removable = unpublished
            if let current = ownedSubscription(
                for: unpublished.element,
                windowId: unpublished.windowId,
                in: subscribedWindows.value
            ) {
                removable.notifications.subtract(current.notifications)
            }
            guard !removable.notifications.isEmpty else { return }
            appendPendingNotificationRemovals(
                removeWindowNotifications(observer: observer, subscription: removable),
                to: pendingNotificationRemovals,
                observerKey: axCallbackObserverKey(observer)
            )
        }

        if !binding.newlyInstalledNotifications.isEmpty,
           var stagedSubscription = binding.stagedSubscription
        {
            stagedSubscription.notifications = binding.newlyInstalledNotifications
            removeIfUnadopted(stagedSubscription)
        }
        for subscription in additionalSubscriptions {
            removeIfUnadopted(subscription)
        }
    }

    nonisolated static func preservesCrossIdentitySubscription(
        _ subscription: AppAXWindowSubscription?,
        for window: AXWindowRef
    ) -> Bool {
        subscription.map {
            $0.windowId != window.windowId && CFEqual($0.element, window.element)
        } == true
    }

    nonisolated static func resolvedWindowBindingResult(
        hasObserver: Bool,
        readyCount: Int,
        targetCount: Int,
        retryRequired: Bool
    ) -> AppAXWindowBindingResult {
        if retryRequired { return .retryRequired }
        if !hasObserver || readyCount == targetCount { return .bound }
        return .superseded
    }

    nonisolated static func commitWindowRebindCache(
        commit: AppAXWindowRebindCommit,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        job: RunLoopJob
    ) throws -> AppAXSubscriptionCleanup {
        try job.performUnlessCancelled {
            guard sameElement(windows[commit.newWindow.windowId], commit.binding.destinationWindowElement),
                  sameSubscription(
                      subscribedWindows[commit.newWindow.windowId],
                      commit.binding.destinationSubscription
                  )
            else {
                throw AXWindowEnumerationError.subscriptionFailed
            }
            let oldWindowId = commit.oldWindow.windowId
            let newWindowId = commit.newWindow.windowId
            let previousDestinationSubscription = subscribedWindows[newWindowId]
            var retiredSubscriptions: [AppAXWindowSubscription] = []
            if let previousDestinationSubscription,
               !CFEqual(previousDestinationSubscription.element, commit.newWindow.element)
            {
                retiredSubscriptions.append(previousDestinationSubscription)
            }
            if commit.retireOldWindowState,
               oldWindowId != newWindowId,
               let oldSubscription = subscribedWindows[oldWindowId],
               CFEqual(oldSubscription.element, commit.oldWindow.element),
               !CFEqual(oldSubscription.element, commit.newWindow.element),
               !retiredSubscriptions.contains(where: {
                   CFEqual($0.element, oldSubscription.element)
               })
            {
                retiredSubscriptions.append(oldSubscription)
            }

            windows[newWindowId] = commit.newWindow.element
            subscribedWindows[newWindowId] = commit.destinationSubscription
            if commit.retireOldWindowState, oldWindowId != newWindowId {
                if subscribedWindows[oldWindowId].map({
                    CFEqual($0.element, commit.oldWindow.element)
                }) == true {
                    subscribedWindows[oldWindowId] = nil
                }
                if windows[oldWindowId].map({
                    CFEqual($0, commit.oldWindow.element)
                        || (commit.binding.requiresRetag && CFEqual($0, commit.newWindow.element))
                }) == true {
                    windows[oldWindowId] = nil
                }
            }
            return AppAXSubscriptionCleanup(subscriptions: retiredSubscriptions)
        }
    }
}
