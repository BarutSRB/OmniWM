// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func mergePersistedHydration(
        _ hydration: PersistedHydrationMutation,
        into plan: ActionPlan,
        existingEntry: WindowState?
    ) -> ActionPlan {
        var mergedPlan = plan
        let monitorId = hydration.monitorId

        var observedState = mergedPlan.observedState
            ?? existingEntry?.observedState
            ?? ObservedWindowState.initial(
                workspaceId: hydration.workspaceId,
                monitorId: monitorId
            )
        observedState.workspaceId = hydration.workspaceId
        observedState.monitorId = monitorId ?? observedState.monitorId
        mergedPlan.observedState = observedState

        var desiredState = mergedPlan.desiredState
            ?? existingEntry?.desiredState
            ?? DesiredWindowState.initial(
                workspaceId: hydration.workspaceId,
                monitorId: monitorId,
                disposition: hydration.targetMode
            )
        desiredState.workspaceId = hydration.workspaceId
        desiredState.monitorId = monitorId ?? desiredState.monitorId
        desiredState.disposition = hydration.targetMode
        if let floatingFrame = hydration.floatingFrame {
            desiredState.floatingFrame = floatingFrame
            desiredState.rescueEligible = true
        } else if hydration.targetMode == .floating {
            desiredState.rescueEligible = true
        }
        mergedPlan.desiredState = desiredState
        mergedPlan.lifecyclePhase = hydration.targetMode == .floating ? .floating : .tiled
        mergedPlan.persistedHydration = hydration
        mergedPlan.notes.append("persisted_hydration")
        return mergedPlan
    }
}
