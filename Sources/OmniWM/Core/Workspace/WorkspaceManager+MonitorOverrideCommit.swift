// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

private struct MonitorOverrideClearPlan {
    let moves: [WorkspaceMonitorRelocation]
    let floatingRelocations: [WorkspaceFloatingRelocation]
}

extension WorkspaceManager {
    func commitRuntimeMonitorOverrideClears(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> [WorkspaceFloatingRelocation] {
        let relocationPlan = planMonitorOverrideClears(workspaceIds)
        removeAnimationMotions(for: relocationPlan.moves.lazy.map(\.workspaceId))
        commitWorldEvent(
            .userCommand(
                workspaceId: nil,
                label: "workspace_monitor_overrides_cleared",
                source: .workspaceManager
            ),
            monitors: monitors,
            preMutate: {
                for move in relocationPlan.moves {
                    let transfersManagedFocus = self.nativeManagedFocusToken
                        .flatMap { self.windowQueries.entry(for: $0)?.workspaceId } == move.workspaceId
                    self.applyWorkspaceMonitorRelocation(
                        move,
                        sessions: self.monitorSessionSnapshots,
                        transferInteraction: transfersManagedFocus
                    )
                }
            },
            resolvePlan: { plan, _, _ in plan }
        )
        noteInvalidation(
            workspaceIds: affectedWorkspaceIds,
            domains: [.workspace, .layout, .focus]
        )
        schedulePersistedWindowRestoreCatalogSave()
        notifySessionStateChanged()
        return relocationPlan.floatingRelocations
    }

    private func planMonitorOverrideClears(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> MonitorOverrideClearPlan {
        let context = monitorResolutionContext()
        let moves: [WorkspaceMonitorRelocation] = workspaceIds.sorted { $0.uuidString < $1.uuidString }
            .compactMap { workspaceId in
                guard let targetMonitor = effectiveMonitor(for: workspaceId, context: context) else {
                    return nil
                }
                return WorkspaceMonitorRelocation(
                    workspaceId: workspaceId,
                    targetMonitor: targetMonitor,
                    floatingStates: translatedFloatingStates(in: workspaceId, to: targetMonitor)
                )
            }
        let visibleWorkspaces = Set(activeVisibleWorkspaceMap().values)
        let floatingRelocations = moves.flatMap { move -> [WorkspaceFloatingRelocation] in
            guard visibleWorkspaces.contains(move.workspaceId) else { return [] }
            return self.floatingRelocations(in: move.workspaceId, from: move.floatingStates)
        }.sorted(by: WorkspaceFloatingRelocation.precedes)

        return MonitorOverrideClearPlan(moves: moves, floatingRelocations: floatingRelocations)
    }
}
