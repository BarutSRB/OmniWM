// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXWindowRebindCommitOperation: Sendable {
    private struct Destination {
        let subscription: AppAXWindowSubscription?
    }

    let oldWindow: AXWindowRef
    let newWindow: AXWindowRef
    let binding: AppAXWindowRebindBinding
    let retireOldWindowState: Bool
    let state: AppAXWindowOperationState

    func perform(job: RunLoopJob) throws -> Bool {
        let observer = state.axObserver.value
        var additionalUnpublishedSubscriptions: [AppAXWindowSubscription] = []
        var committedCache = false
        defer {
            if !committedCache, let observer {
                AppAXContext.cleanUpUnpublishedWindowRebind(
                    binding,
                    additionalSubscriptions: additionalUnpublishedSubscriptions,
                    observer: observer,
                    subscribedWindows: state.subscribedWindows,
                    pendingNotificationRemovals: state.pendingNotificationRemovals
                )
            }
        }
        guard try validateDestination(observer: observer, job: job) else { return false }
        guard let destination = try prepareSubscription(
            observer: observer,
            additionalUnpublishedSubscriptions: &additionalUnpublishedSubscriptions,
            job: job
        ) else { return false }
        let destinationSubscription = destination.subscription

        let cleanup = try AppAXContext.commitWindowRebindCache(
            commit: AppAXWindowRebindCommit(
                oldWindow: oldWindow,
                newWindow: newWindow,
                destinationSubscription: destinationSubscription,
                retireOldWindowState: retireOldWindowState,
                binding: binding
            ),
            windows: state.windows,
            subscribedWindows: state.subscribedWindows,
            job: job
        )
        committedCache = true
        for subscription in cleanup.subscriptions {
            AppAXContext.stageSubscriptionRemoval(
                subscription,
                in: state.pendingNotificationRemovals,
                observerKey: observer.map(axCallbackObserverKey)
            )
        }
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
        }
        return true
    }

    private func validateDestination(observer: AXObserver?, job: RunLoopJob) throws -> Bool {
        if binding.hasLifecycleObserver {
            guard observer != nil else { return false }
            guard !AppAXContext.hasPendingNotificationRemoval(
                for: newWindow.element,
                in: state.pendingNotificationRemovals.value
            ) else {
                return false
            }
        }
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
        }
        if binding.hasLifecycleObserver {
            guard !AppAXContext.hasPendingNotificationRemoval(
                for: newWindow.element,
                in: state.pendingNotificationRemovals.value
            ) else {
                return false
            }
        }
        guard AppAXContext.sameElement(
            state.windows[newWindow.windowId],
            binding.destinationWindowElement
        ), AppAXContext.sameSubscription(
            state.subscribedWindows[newWindow.windowId],
            binding.destinationSubscription
        ) else {
            return false
        }
        let permittedSourceWindowId = binding.requiresRetag ? oldWindow.windowId : nil
        guard !AppAXContext.hasConflictingWindowIdentity(
            for: newWindow.element,
            destinationWindowId: newWindow.windowId,
            permittedSourceWindowId: permittedSourceWindowId,
            windows: state.windows.value,
            subscriptions: state.subscribedWindows.value
        ) else {
            return false
        }

        return true
    }

    private func prepareSubscription(
        observer: AXObserver?,
        additionalUnpublishedSubscriptions: inout [AppAXWindowSubscription],
        job: RunLoopJob
    ) throws -> Destination? {
        let destinationSubscription: AppAXWindowSubscription?
        if binding.hasLifecycleObserver {
            guard let observer else { return nil }
            guard try retagSourceIfNeeded(observer: observer, job: job) else { return nil }
            let installation = try AppAXContext.addWindowNotifications(
                observer: observer,
                window: newWindow,
                ownedSubscription: nil,
                alreadyRegisteredPolicy: .adopt,
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
            destinationSubscription = subscription
            if !installation.newlyInstalled.isEmpty {
                var installed = subscription
                installed.notifications = installation.newlyInstalled
                additionalUnpublishedSubscriptions.append(installed)
            }
        } else {
            destinationSubscription = nil
        }

        return Destination(subscription: destinationSubscription)
    }

    private func retagSourceIfNeeded(observer: AXObserver, job: RunLoopJob) throws -> Bool {
        if binding.requiresRetag {
            let sourceSubscription = AppAXContext.ownedSubscription(
                for: newWindow.element,
                windowId: oldWindow.windowId,
                in: state.subscribedWindows.value
            )
            guard let sourceSubscription,
                  sourceSubscription.windowId == oldWindow.windowId
            else {
                return false
            }
            AppAXContext.stageSubscriptionRemoval(
                sourceSubscription,
                in: state.pendingNotificationRemovals,
                observerKey: axCallbackObserverKey(observer)
            )
            state.subscribedWindows[sourceSubscription.windowId] = nil
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
            guard !AppAXContext.hasPendingNotificationRemoval(
                for: newWindow.element,
                in: state.pendingNotificationRemovals.value
            ) else {
                return false
            }
        }
        return true
    }
}
