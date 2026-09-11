// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension WMController {
    func restoreQuakeTerminalFocus(to target: QuakeTerminalRestoreTarget) {
        switch target {
        case let .managed(token):
            guard workspaceManager.entry(for: token) != nil else { return }
            focusWindow(token)

        case let .external(target):
            if workspaceManager.entry(for: target.token) != nil {
                focusWindow(target.token)
                return
            }
            guard !isLockScreenActive else { return }
            if hasStartedServices {
                guard !isFrontmostAppLockScreen() else { return }
            }

            let pid = target.pid
            guard !workspaceManager.isAppHidden(pid: pid) else { return }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated
            else {
                return
            }

            let intent = intentLedger.registerActivateApp(pid: pid)
            deadlineWheel.schedule(intentId: intent.id, after: .seconds(1))
            if let axRef = AXWindowService.axWindowRef(for: UInt32(target.windowId), pid: pid) {
                performWindowFronting(
                    pid: pid,
                    windowId: target.windowId,
                    axRef: axRef
                )
            } else {
                windowFocusOperations.activateApp(pid)
            }
        }
    }
}
