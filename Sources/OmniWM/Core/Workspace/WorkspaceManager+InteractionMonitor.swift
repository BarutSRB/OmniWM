// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func updateInteractionMonitor(
        _ monitorId: Monitor.ID?,
        preservePrevious: Bool,
        notify: Bool,
        drainRuntimeOverrides: Bool = true
    ) -> Bool {
        guard focusSessionSnapshot.interactionMonitorId != monitorId else { return false }
        let previousWorkspaceId = focusSessionSnapshot.interactionMonitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        let nextWorkspaceId = monitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        var previousMonitorId = focusSessionSnapshot.previousInteractionMonitorId
        if preservePrevious, let currentMonitorId = focusSessionSnapshot.interactionMonitorId {
            previousMonitorId = currentMonitorId
        }
        recordReconcileEvent(
            .interactionMonitorChanged(
                monitorId: monitorId,
                previousMonitorId: previousMonitorId,
                source: .workspaceManager
            )
        )
        noteFocusInvalidation(
            previousWorkspaceId: previousWorkspaceId,
            currentWorkspaceId: nextWorkspaceId
        )
        if notify {
            notifySessionStateChanged()
        }
        if drainRuntimeOverrides {
            drainPendingRuntimeMonitorOverrideClears()
        }
        return true
    }

    func reconcileInteractionMonitorState(notify: Bool = true) {
        let validMonitorIds = Set(monitors.map(\.id))
        let focusedWorkspaceMonitorId = nativeManagedFocusToken
            .flatMap { entry(for: $0)?.workspaceId }
            .flatMap { monitorId(for: $0) }
        let newInteractionMonitorId = focusSessionSnapshot.interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? focusedWorkspaceMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? monitors.first?.id
        let newPreviousInteractionMonitorId = focusSessionSnapshot.previousInteractionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }

        let changed = focusSessionSnapshot.interactionMonitorId != newInteractionMonitorId
            || focusSessionSnapshot.previousInteractionMonitorId != newPreviousInteractionMonitorId
        guard changed else { return }

        recordReconcileEvent(
            .interactionMonitorChanged(
                monitorId: newInteractionMonitorId,
                previousMonitorId: newPreviousInteractionMonitorId,
                source: .workspaceManager
            )
        )
        if notify {
            notifySessionStateChanged()
        }
    }

    func notifySessionStateChanged(surfaceScope: SessionSurfaceInvalidationScope = .full) {
        onSessionStateChanged?(surfaceScope)
    }
}
