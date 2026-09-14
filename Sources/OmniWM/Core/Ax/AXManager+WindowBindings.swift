// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func bindManagedWindows(_ entries: [WindowState]) {
        managedWindowBindings.bindManagedWindows(entries)
    }

    func reconcileManagedWindowBindings(_ entries: [WindowState], scopedPIDs: Set<pid_t>? = nil) {
        managedWindowBindings.reconcileManagedWindowBindings(entries, scopedPIDs: scopedPIDs)
    }

    func pendingManagedWindowBindingRetryPIDs(intersecting pids: Set<pid_t>) -> Set<pid_t> {
        managedWindowBindings.pendingManagedWindowBindingRetryPIDs(intersecting: pids)
    }

    nonisolated static func managedWindowBindingRetryDelay(afterFailure failure: Int) -> Duration? {
        switch failure {
        case 1: .milliseconds(100)
        case 2: .milliseconds(250)
        case 3: .milliseconds(500)
        default: nil
        }
    }

    static func managedWindowBindingPIDs(
        contextPIDs: Set<pid_t>,
        windowPIDs: Set<pid_t>,
        scopedPIDs: Set<pid_t>?
    ) -> Set<pid_t> {
        scopedPIDs ?? contextPIDs.union(windowPIDs)
    }
}
