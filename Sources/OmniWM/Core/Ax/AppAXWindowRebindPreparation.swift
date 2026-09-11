// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXWindowRebindPreparation: Sendable {
    private struct Destination {
        let destinationWindowElement: AXUIElement?
        let destinationSubscription: AppAXWindowSubscription?
        func result(
            stagedSubscription: AppAXWindowSubscription? = nil,
            newlyInstalledNotifications: AppAXWindowNotificationSet = [],
            requiresRetag: Bool = false,
            hasLifecycleObserver: Bool
        ) -> AppAXWindowRebindBinding {
            .init(
                destinationWindowElement: destinationWindowElement,
                destinationSubscription: destinationSubscription,
                stagedSubscription: stagedSubscription,
                newlyInstalledNotifications: newlyInstalledNotifications,
                requiresRetag: requiresRetag,
                hasLifecycleObserver: hasLifecycleObserver
            )
        }
    }

    let oldWindowId: Int
    let newWindow: AXWindowRef
    let timeoutSeconds: TimeInterval
    let state: AppAXWindowOperationState

    func perform(job: RunLoopJob) throws -> AppAXWindowRebindBinding? {
        let observer = state.axObserver.value
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
        }
        let destination = Destination(
            destinationWindowElement: state.windows[newWindow.windowId],
            destinationSubscription: state.subscribedWindows[newWindow.windowId]
        )
        guard let observer else {
            try job.checkCancellation()
            return destination.result(hasLifecycleObserver: false)
        }
        guard !AppAXContext.hasPendingNotificationRemoval(
            for: newWindow.element,
            in: state.pendingNotificationRemovals.value
        ) else {
            return nil
        }
        let ownedSubscription = AppAXContext.ownedSubscription(
            for: newWindow.element,
            windowId: newWindow.windowId,
            in: state.subscribedWindows.value
        )
        switch AppAXContext.rebindSubscriptionOwnership(
            ownedSubscription,
            oldWindowId: oldWindowId,
            newWindowId: newWindow.windowId
        ) {
        case .source:
            try job.checkCancellation()
            return destination.result(requiresRetag: true, hasLifecycleObserver: true)
        case .conflict:
            return nil
        case .unowned,
             .destination:
            break
        }
        if let ownedSubscription, ownedSubscription.notifications == .lifecycle {
            try job.checkCancellation()
            return destination.result(hasLifecycleObserver: true)
        }
        return try install(observer: observer, ownedSubscription: ownedSubscription, destination: destination, job: job)
    }

    private func install(
        observer: AXObserver,
        ownedSubscription: AppAXWindowSubscription?,
        destination: Destination,
        job: RunLoopJob
    ) throws -> AppAXWindowRebindBinding? {
        AXUIElementSetMessagingTimeout(newWindow.element, Float(timeoutSeconds))
        defer { AXUIElementSetMessagingTimeout(newWindow.element, 0) }
        let installation = try AppAXContext.addWindowNotifications(
            observer: observer,
            window: newWindow,
            ownedSubscription: ownedSubscription,
            alreadyRegisteredPolicy: ownedSubscription ==
                nil ? .reject : .adopt,
            checkCancellation: {
                try job.checkCancellation()
            },
            recordPendingRemovals: {
                AppAXContext
                    .appendPendingNotificationRemovals(
                        $0,
                        to: state.pendingNotificationRemovals,
                        observerKey: axCallbackObserverKey(
                            observer
                        )
                    )
            }
        )
        AppAXContext.appendPendingNotificationRemovals(
            installation.pendingRemovals,
            to: state.pendingNotificationRemovals,
            observerKey: axCallbackObserverKey(observer)
        )
        guard let subscription = installation.subscription else { return nil }
        return destination.result(
            stagedSubscription: subscription,
            newlyInstalledNotifications: installation.newlyInstalled,
            hasLifecycleObserver: true
        )
    }
}
