// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func applyActionPlan(
        _ plan: ActionPlan,
        to token: WindowToken?
    ) -> ActionPlan {
        var resolvedPlan = plan
        resolvedPlan.restoreIntent = nil

        if let restoreRefresh = plan.restoreRefresh {
            applyRestoreRefresh(restoreRefresh)
        }

        applyPlannedFocusAndViewport(plan)

        if let topologyTransition = plan.topologyTransition {
            applyTopologyTransition(topologyTransition)
            notifySessionStateChanged()
        }

        guard let token else {
            if resolvedPlan.restoreRefresh?.refreshRestoreIntents == true || resolvedPlan.topologyTransition != nil {
                schedulePersistedWindowRestoreCatalogSave()
            }
            return resolvedPlan
        }

        if let persistedHydration = plan.persistedHydration {
            _ = applyPersistedHydrationMutation(persistedHydration, to: token)
        }

        if let restoreIntent = applyPlannedWindowState(plan, to: token) {
            resolvedPlan.restoreIntent = restoreIntent
        }
        if !resolvedPlan.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return resolvedPlan
    }

    @discardableResult
    func applyFocusReconcileEvent(_ event: WMEvent) -> Bool {
        let previousFocusSession = focusSessionSnapshot
        recordReconcileEvent(event)
        return focusSessionSnapshot != previousFocusSession
    }

    func plannedRestoreRefresh(
        from eventPlan: RestorePlanner.EventPlan,
        snapshot: ReconcileSnapshot
    ) -> RestoreRefreshPlan? {
        let hasInteractionChange = eventPlan.interactionMonitorId != snapshot.interactionMonitorId
            || eventPlan.previousInteractionMonitorId != snapshot.previousInteractionMonitorId
        guard eventPlan.refreshRestoreIntents || hasInteractionChange else {
            return nil
        }

        return RestoreRefreshPlan(
            refreshRestoreIntents: eventPlan.refreshRestoreIntents,
            interactionMonitorId: eventPlan.interactionMonitorId,
            previousInteractionMonitorId: eventPlan.previousInteractionMonitorId
        )
    }
}
