// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func restoreClearedRuntimeOverrideVisibility(
        visibleMonitorByWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]
    ) -> Bool {
        guard !visibleMonitorByWorkspace.isEmpty else { return false }
        let context = monitorResolutionContext()
        var sessions = monitorSessionSnapshots
        let managedFocusedWorkspaceId = nativeManagedFocusToken
            .flatMap { windowQueries.entry(for: $0)?.workspaceId }

        for workspaceId in visibleMonitorByWorkspace.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let sourceMonitorId = visibleMonitorByWorkspace[workspaceId],
                  sessions[sourceMonitorId]?.visibleWorkspaceId == workspaceId,
                  let targetMonitorId = effectiveMonitor(for: workspaceId, context: context)?.id,
                  targetMonitorId != sourceMonitorId
            else {
                continue
            }

            let sourceReplacementWorkspaceId = sourceReplacementWorkspaceId(
                for: workspaceId,
                on: sourceMonitorId,
                context: context
            )
            var sourceSession = sessions[sourceMonitorId] ?? MonitorSession()
            sourceSession.visibleWorkspaceId = sourceReplacementWorkspaceId
            sourceSession.previousVisibleWorkspaceId = nil
            if sourceSession.visibleWorkspaceId == nil {
                sessions.removeValue(forKey: sourceMonitorId)
            } else {
                sessions[sourceMonitorId] = sourceSession
            }

            let destinationWorkspaceId = sessions[targetMonitorId]?.visibleWorkspaceId
            let destinationIsProtected = targetMonitorId == focusSessionSnapshot.interactionMonitorId
                || destinationWorkspaceId.map {
                    $0 == managedFocusedWorkspaceId
                        || $0 == focusSessionSnapshot.pendingManagedFocus.workspaceId
                } ?? false
            if managedFocusedWorkspaceId == workspaceId || !destinationIsProtected {
                var targetSession = sessions[targetMonitorId] ?? MonitorSession()
                targetSession.previousVisibleWorkspaceId = targetSession.visibleWorkspaceId
                targetSession.visibleWorkspaceId = workspaceId
                sessions[targetMonitorId] = targetSession
            }
        }

        guard sessions != monitorSessionSnapshots else { return false }
        commitMonitorSessions(sessions)
        return true
    }

    func reconcileConfiguredVisibleWorkspaces(notify: Bool = true) {
        var changed = false
        let context = monitorResolutionContext()

        for monitor in context.sortedMonitors {
            let assigned = workspaces(on: monitor.id)
            guard !assigned.isEmpty else {
                if visibleWorkspaceId(on: monitor.id) != nil || previousVisibleWorkspaceId(on: monitor.id) != nil {
                    updateMonitorSession(monitor.id) { session in
                        session.visibleWorkspaceId = nil
                        session.previousVisibleWorkspaceId = nil
                    }
                    changed = true
                }
                continue
            }

            if let currentVisibleId = visibleWorkspaceId(on: monitor.id),
               assigned.contains(where: { $0.id == currentVisibleId })
            {
                continue
            }

            guard let defaultWorkspaceId = assigned.first?.id else { continue }
            if setActiveWorkspaceInternal(
                defaultWorkspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                notify: false,
                context: context
            ) {
                changed = true
            }
        }

        if notify, changed {
            notifySessionStateChanged()
        }
    }

    func ensureVisibleWorkspaces() {
        let currentMonitorIds = Set(monitors.map(\.id))
        let expectedVisibleMonitorIds = expectedVisibleMonitorIds()
        let previousMonitorSessions = monitorSessionSnapshots
        commitMonitorSessions(previousMonitorSessions.filter {
            currentMonitorIds.contains($0.key) && expectedVisibleMonitorIds.contains($0.key)
        })

        let currentVisibleMonitorIds = Set(activeVisibleWorkspaceMap(from: monitorSessionSnapshots).keys)
        if currentVisibleMonitorIds != expectedVisibleMonitorIds {
            rearrangeWorkspacesOnMonitors(previousMonitorSessions: previousMonitorSessions)
        }
    }
}
