// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import OmniWMIPC

extension WorldStore {
    func applyWindowStateAndRefreshRestoreIntent(
        _ plan: ActionPlan,
        to token: WindowToken,
        monitors: [Monitor]
    ) -> RestoreIntent? {
        applyWindowState(plan, to: token)
        guard let entry = windows.entry(for: token) else { return nil }
        let restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
        guard entry.restoreIntent != restoreIntent else { return nil }
        setRestoreIntent(restoreIntent, for: token)
        return restoreIntent
    }

    func refreshRestoreIntents(monitors: [Monitor]) {
        for entry in windows.allEntries() {
            setRestoreIntent(StateReducer.restoreIntent(for: entry, monitors: monitors), for: entry.token)
        }
    }

    func refreshWindowMonitorReferences(resolveMonitorId: (WorkspaceDescriptor.ID) -> Monitor.ID?) {
        for entry in windows.allEntries() {
            let currentMonitorId = resolveMonitorId(entry.workspaceId)
            if entry.observedState.monitorId != currentMonitorId {
                var observedState = entry.observedState
                observedState.monitorId = currentMonitorId
                setObservedState(observedState, for: entry.token)
            }
            if entry.desiredState.monitorId != currentMonitorId {
                var desiredState = entry.desiredState
                desiredState.monitorId = currentMonitorId
                setDesiredState(desiredState, for: entry.token)
            }
        }
    }
}
