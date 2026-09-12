// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXContextShutdown: Sendable {
    let state: AppAXWindowOperationState
    let axApp: ThreadGuardedValue<AXUIElement>
    let focusedWindowObserver: ThreadGuardedValue<AXObserver?>

    func perform() {
        let subscribed = state.subscribedWindows.valueIfExists ?? [:]
        if let obs = state.axObserver.valueIfExists.flatMap({ $0 }) {
            for (_, subscription) in subscribed {
                _ = AppAXContext.removeWindowNotifications(
                    observer: obs,
                    subscription: subscription
                )
            }
            try? AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: obs,
                checkCancellation: {}
            )
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        if let focusObs = focusedWindowObserver.valueIfExists.flatMap({ $0 }) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(focusObs), .defaultMode)
        }
        state.subscribedWindows.destroy()
        state.pendingNotificationRemovals.destroy()
        state.axObserver.destroy()
        focusedWindowObserver.destroy()
        state.windows.destroy()
        axApp.destroy()
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}
