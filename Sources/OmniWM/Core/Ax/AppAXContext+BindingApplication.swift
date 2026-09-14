// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXWindowBindingSuperseded: Error {}

extension AppAXContext {
    nonisolated static func performWindowBinding(
        _ boundWindows: [Int: AXWindowRef],
        options: AppAXWindowBindingOptions,
        state: AppAXWindowOperationState,
        job: RunLoopJob
    ) throws -> AppAXWindowBindingResult {
        try AppAXWindowBindingOperation(boundWindows: boundWindows, options: options, state: state).perform(job: job)
    }
}

struct AppAXWindowBindingOptions: Sendable {
    let generation: UInt64
    let pruningUnboundState: Bool
    let timeoutSeconds: TimeInterval
}

private struct AppAXWindowBindingOperation {
    private struct StagedBindings {
        var subscriptions: [Int: (subscription: AppAXWindowSubscription, newlyInstalled: AppAXWindowNotificationSet)] =
            [:]
        var readyCount = 0
        var retryRequired = false
    }

    let boundWindows: [Int: AXWindowRef]
    let options: AppAXWindowBindingOptions
    let state: AppAXWindowOperationState

    func perform(job: RunLoopJob) throws -> AppAXWindowBindingResult {
        guard state.windowBindingEpoch.isCurrent(options.generation) else {
            return .superseded
        }
        let observer = state.axObserver.value
        let observerKey = observer.map(axCallbackObserverKey)
        var retryRequired = false
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
            retryRequired = retryRequired || !state.pendingNotificationRemovals.value.isEmpty
        }
        if options.pruningUnboundState {
            retryRequired = try pruneUnboundState(observer: observer, job: job)
        }

        var staged = StagedBindings()
        var committedSubscriptions = false
        defer {
            if !committedSubscriptions, let observer {
                rollbackBindings(staged, observer: observer, observerKey: observerKey)
            }
        }
        if let observer {
            try stageBindings(observer: observer, staged: &staged, job: job)
            retryRequired = retryRequired || staged.retryRequired
        }
        try commitBindings(staged, observerKey: observerKey, job: job)
        committedSubscriptions = true
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
            retryRequired = retryRequired || !state.pendingNotificationRemovals.value.isEmpty
        }
        return AppAXContext.resolvedWindowBindingResult(
            hasObserver: observer != nil,
            readyCount: staged.readyCount,
            targetCount: boundWindows.count,
            retryRequired: retryRequired
        )
    }

    private func pruneUnboundState(observer: AXObserver?, job: RunLoopJob) throws -> Bool {
        let observerKey = observer.map(axCallbackObserverKey)
        try job.performUnlessCancelled {
            guard state.windowBindingEpoch.performIfCurrent(options.generation, {
                for (windowId, subscription) in state.subscribedWindows.value where boundWindows[windowId].map({
                    CFEqual($0.element, subscription.element)
                }) != true {
                    if observer != nil {
                        AppAXContext.stageSubscriptionRemoval(
                            subscription,
                            in: state.pendingNotificationRemovals,
                            observerKey: observerKey
                        )
                    }
                    state.subscribedWindows[windowId] = nil
                }
                for (windowId, element) in state.windows.value where boundWindows[windowId].map({
                    CFEqual($0.element, element)
                }) != true {
                    state.windows[windowId] = nil
                }
                return true
            }) == true else {
                throw AppAXWindowBindingSuperseded()
            }
        }
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
            return !state.pendingNotificationRemovals.value.isEmpty
        }

        return false
    }

    private func stageBindings(observer: AXObserver, staged: inout StagedBindings, job: RunLoopJob) throws {
        for window in boundWindows.values {
            try job.checkCancellation()
            guard state.windowBindingEpoch.isCurrent(options.generation) else {
                throw AppAXWindowBindingSuperseded()
            }
            guard !AppAXContext.hasPendingNotificationRemoval(
                for: window.element,
                in: state.pendingNotificationRemovals.value
            ) else {
                staged.retryRequired = true
                continue
            }
            let ownedSubscription = AppAXContext.ownedSubscription(
                for: window.element,
                windowId: window.windowId,
                in: state.subscribedWindows.value
            )
            if AppAXContext.preservesCrossIdentitySubscription(ownedSubscription, for: window) {
                continue
            }
            if ownedSubscription?.notifications == .lifecycle {
                staged.readyCount += 1
                continue
            }
            AXUIElementSetMessagingTimeout(window.element, Float(options.timeoutSeconds))
            defer { AXUIElementSetMessagingTimeout(window.element, 0) }
            let installation = try installBinding(
                window,
                observer: observer,
                ownedSubscription: ownedSubscription,
                job: job
            )
            guard let subscription = installation.subscription else {
                staged.retryRequired = true
                continue
            }
            staged.subscriptions[window.windowId] = (
                subscription,
                installation.newlyInstalled
            )
            staged.readyCount += 1
            try job.checkCancellation()
        }
    }

    private func installBinding(
        _ window: AXWindowRef,
        observer: AXObserver,
        ownedSubscription: AppAXWindowSubscription?,
        job: RunLoopJob
    ) throws -> AppAXWindowNotificationInstallResult {
        let observerKey = axCallbackObserverKey(observer)
        let installation = try AppAXContext.addWindowNotifications(
            observer: observer,
            window: window,
            ownedSubscription: ownedSubscription,
            alreadyRegisteredPolicy: ownedSubscription == nil ?
                .replace : .adopt,
            checkCancellation: { try job.checkCancellation() },
            recordPendingRemovals: {
                AppAXContext.appendPendingNotificationRemovals(
                    $0,
                    to: state.pendingNotificationRemovals,
                    observerKey: observerKey
                )
            }
        )
        AppAXContext.appendPendingNotificationRemovals(
            installation.pendingRemovals,
            to: state.pendingNotificationRemovals,
            observerKey: observerKey
        )
        return installation
    }

    private func commitBindings(_ staged: StagedBindings, observerKey: UInt?, job: RunLoopJob) throws {
        try job.performUnlessCancelled {
            guard state.windowBindingEpoch.performIfCurrent(options.generation, {
                for window in boundWindows.values {
                    if let previous = state.subscribedWindows[window.windowId],
                       !CFEqual(previous.element, window.element)
                    {
                        AppAXContext.stageSubscriptionRemoval(
                            previous,
                            in: state.pendingNotificationRemovals,
                            observerKey: observerKey
                        )
                        state.subscribedWindows[window.windowId] = nil
                    }
                    if let staged = staged.subscriptions[window.windowId] {
                        state.subscribedWindows[window.windowId] = staged.subscription
                    }
                    state.windows[window.windowId] = window.element
                }
                return true
            }) == true else {
                throw AppAXWindowBindingSuperseded()
            }
        }
    }

    private func rollbackBindings(_ staged: StagedBindings, observer: AXObserver, observerKey: UInt?) {
        for staged in staged.subscriptions.values where !staged.newlyInstalled.isEmpty {
            var rollback = staged.subscription
            rollback.notifications = staged.newlyInstalled
            AppAXContext.appendPendingNotificationRemovals(
                AppAXContext.removeWindowNotifications(observer: observer, subscription: rollback),
                to: state.pendingNotificationRemovals,
                observerKey: observerKey
            )
        }
    }
}
