// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func visibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        visibleWorkspaceMap()[monitorId]
    }

    func previousVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        monitorSessionSnapshots[monitorId]?.previousVisibleWorkspaceId
    }

    func activeVisibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        visibleWorkspaceMap()
    }

    func activeVisibleWorkspaceMap(
        from monitorSessions: [Monitor.ID: MonitorSession]
    ) -> [Monitor.ID: WorkspaceDescriptor.ID] {
        Dictionary(uniqueKeysWithValues: monitorSessions.compactMap { monitorId, session in
            guard let visibleWorkspaceId = session.visibleWorkspaceId else { return nil }
            return (monitorId, visibleWorkspaceId)
        })
    }

    func updateMonitorSession(
        _ monitorId: Monitor.ID,
        _ mutate: (inout MonitorSession) -> Void
    ) {
        var sessions = monitorSessionSnapshots
        var monitorSession = sessions[monitorId] ?? MonitorSession()
        mutate(&monitorSession)
        if monitorSession.visibleWorkspaceId == nil, monitorSession.previousVisibleWorkspaceId == nil {
            sessions.removeValue(forKey: monitorId)
        } else {
            sessions[monitorId] = monitorSession
        }
        commitMonitorSessions(sessions)
    }

    func commitMonitorSessions(_ sessions: [Monitor.ID: MonitorSession]) {
        guard sessions != monitorSessionSnapshots else { return }
        recordReconcileEvent(.visibleWorkspacesChanged(sessions: sessions, source: .workspaceManager))
        invalidateWorkspaceProjectionCaches()
    }
}
