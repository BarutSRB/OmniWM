// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@MainActor
final class WorkspaceStore {
    var monitors: [Monitor]
    var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] = [:]
    var workspaceIdByName: [String: WorkspaceDescriptor.ID] = [:]
    var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]

    var cachedSortedWorkspaces: [WorkspaceDescriptor]?
    var cachedWorkspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]]?
    var cachedVisibleWorkspaceIds: Set<WorkspaceDescriptor.ID>?
    var cachedVisibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]?
    var cachedMonitorIdByVisibleWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]?
    var cachedWorkspaceMonitorProjection: [WorkspaceDescriptor.ID: WorkspaceMonitorProjection]?

    init(monitors: [Monitor]) {
        self.monitors = monitors
    }
}
