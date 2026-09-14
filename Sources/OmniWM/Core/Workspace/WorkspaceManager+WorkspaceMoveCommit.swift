// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func commitWorkspaceMonitorMove(
        _ workspace: WorkspaceDescriptor,
        to targetMonitor: Monitor,
        monitorSessions nextMonitorSessions: [Monitor.ID: MonitorSession],
        floatingStates: [WindowToken: FloatingState],
        transfersManagedFocus: Bool
    ) {
        let workspaceId = workspace.id
        removeAnimationMotions(for: [workspaceId])
        commitWorldEvent(
            .userCommand(
                workspaceId: workspaceId,
                label: "workspace_monitor_move",
                source: .command
            ),
            monitors: monitors,
            preMutate: {
                self.workspaceCatalog.storeRelocatedWorkspace(workspace)
                self.pendingRuntimeMonitorOverrideClearWorkspaceIds.remove(workspaceId)
                self.applyWorkspaceMonitorRelocation(
                    WorkspaceMonitorRelocation(
                        workspaceId: workspaceId,
                        targetMonitor: targetMonitor,
                        floatingStates: floatingStates
                    ),
                    sessions: nextMonitorSessions,
                    transferInteraction: transfersManagedFocus
                )
                self.invalidateWorkspaceProjectionCaches()
            },
            resolvePlan: { plan, _, _ in plan }
        )
    }
}
