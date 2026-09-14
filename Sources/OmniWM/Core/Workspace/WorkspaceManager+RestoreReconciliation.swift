// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func applyRestoreRefresh(_ plan: RestoreRefreshPlan) {
        if plan.refreshRestoreIntents {
            refreshRestoreIntentsForAllEntries()
            schedulePersistedWindowRestoreCatalogSave()
        }

        let previousWorkspaceId = focusSessionSnapshot.interactionMonitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        let nextWorkspaceId = plan.interactionMonitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        let interactionChanged = focusSessionSnapshot.interactionMonitorId != plan.interactionMonitorId
            || focusSessionSnapshot.previousInteractionMonitorId != plan.previousInteractionMonitorId
        applyRestoreInteractionMonitors(plan)
        if interactionChanged {
            noteFocusInvalidation(
                previousWorkspaceId: previousWorkspaceId,
                currentWorkspaceId: nextWorkspaceId
            )
        }
    }

    func applyTopologyTransition(_ transition: TopologyTransitionPlan) {
        replaceMonitorsForTopologyTransition(with: transition.newMonitors)
        let context = monitorResolutionContext()

        for monitor in context.sortedMonitors {
            guard let workspaceId = transition.visibleAssignments[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false,
                context: context
            )
        }

        reconcileConfiguredVisibleWorkspaces(notify: false)
        applyTopologyInteractionState(transition, context: context)
        reconcileInteractionMonitorState(notify: false)
        refreshWindowMonitorReferencesForAllEntries()
        if transition.refreshRestoreIntents {
            refreshRestoreIntentsForAllEntries()
        }
    }
}
