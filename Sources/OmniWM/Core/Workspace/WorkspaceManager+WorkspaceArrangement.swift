// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func rearrangeWorkspacesOnMonitors(
        previousMonitorSessions: [Monitor.ID: MonitorSession]
    ) {
        let context = monitorResolutionContext()
        let oldForward = activeVisibleWorkspaceMap(from: previousMonitorSessions)
        var oldMonitorById: [Monitor.ID: Monitor] = [:]

        for monitor in monitors {
            oldMonitorById[monitor.id] = monitor
        }
        let visibleSnapshots = oldForward.compactMap { monitorId, workspaceId -> WorkspaceRestoreSnapshot? in
            guard let monitor = oldMonitorById[monitorId] else { return nil }
            return WorkspaceRestoreSnapshot(
                monitor: MonitorRestoreKey(monitor: monitor),
                workspaceId: workspaceId
            )
        }
        let restoredAssignments = resolveWorkspaceRestoreAssignments(
            snapshots: visibleSnapshots,
            monitors: monitors,
            workspaceExists: { descriptor(for: $0) != nil }
        )

        commitMonitorSessions(monitorSessionSnapshots.mapValues { session in
            var pruned = session
            pruned.visibleWorkspaceId = nil
            return pruned
        })

        for newMonitor in context.sortedMonitors {
            if let existingWorkspaceId = restoredAssignments[newMonitor.id],
               workspaceMonitorId(for: existingWorkspaceId, context: context) == newMonitor.id,
               setActiveWorkspaceInternal(
                   existingWorkspaceId,
                   on: newMonitor.id,
                   anchorPoint: newMonitor.workspaceAnchorPoint,
                   notify: false,
                   context: context
               )
            {
                continue
            }
            if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: newMonitor.id) {
                _ = setActiveWorkspaceInternal(
                    defaultWorkspaceId,
                    on: newMonitor.id,
                    anchorPoint: newMonitor.workspaceAnchorPoint,
                    notify: false,
                    context: context
                )
            }
        }

        notifySessionStateChanged()
    }

    func defaultVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        let assigned = workspaces(on: monitorId)
        guard !assigned.isEmpty else { return nil }
        return assigned.first?.id
    }

    func expectedVisibleMonitorIds() -> Set<Monitor.ID> {
        Set(monitors.compactMap { monitor in
            defaultVisibleWorkspaceId(on: monitor.id) == nil ? nil : monitor.id
        })
    }

    func sourceReplacementWorkspaceId(
        for movedWorkspaceId: WorkspaceDescriptor.ID,
        on sourceMonitorId: Monitor.ID,
        context: MonitorResolutionContext
    ) -> WorkspaceDescriptor.ID? {
        let isEligible: (WorkspaceDescriptor.ID) -> Bool = { workspaceId in
            guard workspaceId != movedWorkspaceId,
                  self.effectiveMonitor(for: workspaceId, context: context)?.id == sourceMonitorId
            else {
                return false
            }
            guard let visibleMonitorId = self.monitorIdShowingWorkspace(workspaceId) else {
                return true
            }
            return visibleMonitorId == sourceMonitorId
        }

        if let previousWorkspaceId = previousVisibleWorkspaceId(on: sourceMonitorId),
           isEligible(previousWorkspaceId)
        {
            return previousWorkspaceId
        }
        return sortedWorkspaces().first { isEligible($0.id) }?.id
    }
}
