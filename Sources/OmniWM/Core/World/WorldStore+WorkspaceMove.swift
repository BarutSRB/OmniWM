// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension WorldStore {
    func applyWorkspaceMonitorMove(
        _ move: WorkspaceMonitorRelocation,
        monitorSessions: [Monitor.ID: MonitorSession],
        transferInteraction: Bool,
        monitors: [Monitor]
    ) {
        assertInCommit("applyWorkspaceMonitorMove")
        let workspaceId = move.workspaceId
        let targetMonitorId = move.targetMonitor.id
        let floatingStates = move.floatingStates
        applyMonitorSessions(monitorSessions)

        for entry in windows.windows(in: workspaceId) {
            if let floatingState = floatingStates[entry.token] {
                setFloatingState(floatingState, for: entry.token)
            }

            var observedState = entry.observedState
            observedState.monitorId = targetMonitorId
            setObservedState(observedState, for: entry.token)

            var desiredState = entry.desiredState
            desiredState.monitorId = targetMonitorId
            if let floatingState = floatingStates[entry.token] {
                desiredState.floatingFrame = floatingState.lastFrame
            }
            setDesiredState(desiredState, for: entry.token)

            if let updatedEntry = windows.entry(for: entry.token) {
                setRestoreIntent(
                    StateReducer.restoreIntent(for: updatedEntry, monitors: monitors),
                    for: entry.token
                )
            }
        }

        updateFocus {
            if $0.pendingManagedFocus.workspaceId == workspaceId {
                $0.pendingManagedFocus.monitorId = targetMonitorId
            }
            if transferInteraction {
                $0.previousInteractionMonitorId = $0.interactionMonitorId
                $0.interactionMonitorId = targetMonitorId
            }
        }
    }

    func applyWindowState(_ plan: ActionPlan, to token: WindowToken) {
        if let lifecyclePhase = plan.lifecyclePhase {
            setLifecyclePhase(lifecyclePhase, for: token)
        }
        if let observedState = plan.observedState {
            setObservedState(observedState, for: token)
        }
        if let desiredState = plan.desiredState {
            setDesiredState(desiredState, for: token)
        }
    }
}
