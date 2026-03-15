import AppKit
import Foundation

extension NiriLayoutEngine {
    func ensureMonitor(
        for monitorId: Monitor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> NiriMonitor {
        if let existing = monitors[monitorId] {
            if let orientation {
                existing.updateOrientation(orientation)
            }
            return existing
        }
        let niriMonitor = NiriMonitor(monitor: monitor, orientation: orientation)
        monitors[monitorId] = niriMonitor
        return niriMonitor
    }

    func monitor(for monitorId: Monitor.ID) -> NiriMonitor? {
        monitors[monitorId]
    }

    func updateMonitors(_ newMonitors: [Monitor], orientations: [Monitor.ID: Monitor.Orientation] = [:]) {
        for monitor in newMonitors {
            if let niriMonitor = monitors[monitor.id] {
                let orientation = orientations[monitor.id]
                niriMonitor.updateOutputSize(monitor: monitor, orientation: orientation)
            }
        }

        let newIds = Set(newMonitors.map(\.id))
        monitors = monitors.filter { newIds.contains($0.key) }
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        monitors.removeValue(forKey: monitorId)
    }

    func updateMonitorOrientations(_ orientations: [Monitor.ID: Monitor.Orientation]) {
        for (monitorId, orientation) in orientations {
            monitors[monitorId]?.updateOrientation(orientation)
        }
    }

    func updateMonitorSettings(_ settings: ResolvedNiriSettings, for monitorId: Monitor.ID) {
        monitors[monitorId]?.resolvedSettings = settings
    }

    func globalResolvedSettings() -> ResolvedNiriSettings {
        ResolvedNiriSettings(
            maxVisibleColumns: maxVisibleColumns,
            maxWindowsPerColumn: maxWindowsPerColumn,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            infiniteLoop: infiniteLoop
        )
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> ResolvedNiriSettings {
        monitors[monitorId]?.resolvedSettings ?? globalResolvedSettings()
    }

    func effectiveSettings(in workspaceId: WorkspaceDescriptor.ID) -> ResolvedNiriSettings {
        guard let monitorId = monitorContaining(workspace: workspaceId) else {
            return globalResolvedSettings()
        }
        return effectiveSettings(for: monitorId)
    }

    func effectiveMaxVisibleColumns(for monitorId: Monitor.ID) -> Int {
        effectiveSettings(for: monitorId).maxVisibleColumns
    }

    func effectiveMaxVisibleColumns(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        effectiveSettings(in: workspaceId).maxVisibleColumns
    }

    func effectiveMaxWindowsPerColumn(for monitorId: Monitor.ID) -> Int {
        effectiveSettings(for: monitorId).maxWindowsPerColumn
    }

    func effectiveMaxWindowsPerColumn(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        effectiveSettings(in: workspaceId).maxWindowsPerColumn
    }

    func effectiveCenterFocusedColumn(for monitorId: Monitor.ID) -> CenterFocusedColumn {
        effectiveSettings(for: monitorId).centerFocusedColumn
    }

    func effectiveCenterFocusedColumn(in workspaceId: WorkspaceDescriptor.ID) -> CenterFocusedColumn {
        effectiveSettings(in: workspaceId).centerFocusedColumn
    }

    func effectiveAlwaysCenterSingleColumn(for monitorId: Monitor.ID) -> Bool {
        effectiveSettings(for: monitorId).alwaysCenterSingleColumn
    }

    func effectiveAlwaysCenterSingleColumn(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        effectiveSettings(in: workspaceId).alwaysCenterSingleColumn
    }

    func effectiveSingleWindowAspectRatio(for monitorId: Monitor.ID) -> SingleWindowAspectRatio {
        effectiveSettings(for: monitorId).singleWindowAspectRatio
    }

    func effectiveSingleWindowAspectRatio(in workspaceId: WorkspaceDescriptor.ID) -> SingleWindowAspectRatio {
        effectiveSettings(in: workspaceId).singleWindowAspectRatio
    }

    func effectiveInfiniteLoop(for monitorId: Monitor.ID) -> Bool {
        effectiveSettings(for: monitorId).infiniteLoop
    }

    func effectiveInfiniteLoop(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        effectiveSettings(in: workspaceId).infiniteLoop
    }

    func moveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitorId: Monitor.ID,
        monitor: Monitor
    ) {
        let targetMonitor = ensureMonitor(for: monitorId, monitor: monitor)

        if let currentMonitorId = monitorContaining(workspace: workspaceId),
           currentMonitorId == monitorId
        {
            return
        }

        if let currentMonitorId = monitorContaining(workspace: workspaceId),
           let currentMonitor = monitors[currentMonitorId]
        {
            if let root = currentMonitor.workspaceRoots.removeValue(forKey: workspaceId) {
                targetMonitor.workspaceRoots[workspaceId] = root
                roots[workspaceId] = root
            }
        }

        if targetMonitor.workspaceRoots[workspaceId] == nil {
            let root = ensureRoot(for: workspaceId)
            targetMonitor.workspaceRoots[workspaceId] = root
        }
    }

    func monitorContaining(workspace workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        for (monitorId, niriMonitor) in monitors {
            if niriMonitor.containsWorkspace(workspaceId) {
                return monitorId
            }
        }
        return nil
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> NiriMonitor? {
        for niriMonitor in monitors.values {
            if niriMonitor.containsWorkspace(workspaceId) {
                return niriMonitor
            }
        }
        return nil
    }
}
