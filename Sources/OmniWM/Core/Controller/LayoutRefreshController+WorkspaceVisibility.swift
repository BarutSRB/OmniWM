// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func hideInactiveWorkspacesSync() {
        guard let controller else { return }
        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
    }

    private func workspaceEntriesSnapshot(
        on controller: WMController
    ) -> [(workspace: WorkspaceDescriptor, entries: [WindowState])] {
        controller.workspaceManager.workspaces.map { workspace in
            (workspace, controller.workspaceManager.entries(in: workspace.id))
        }
    }

    func rebuildInactiveWorkspaceWindowSet(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        for workspace in controller.workspaceManager.workspaces {
            for entry in controller.workspaceManager.entries(in: workspace.id) {
                allEntries.append((workspace.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds,
            nativeInactiveWindowIds: nativeInactiveWindowIds()
        )
    }

    private func nativeInactiveWindowIds() -> Set<Int> {
        guard let controller else { return [] }
        let topology = controller.workspaceManager.spaceTopology
        guard topology.isPopulated else { return [] }
        var result: Set<Int> = []
        for entry in controller.workspaceManager.allEntries()
            where topology.isWindowOnKnownInactiveSpace(entry.windowId)
        {
            result.insert(entry.windowId)
        }
        return result
    }

    private func isWindowOnKnownInactiveNativeSpace(_ windowId: Int) -> Bool {
        controller?.workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(windowId) ?? false
    }

    func hasWorkspaceInactiveFloatingWindows(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) -> Bool {
        guard let controller else { return false }
        for workspaceId in activeWorkspaceIds {
            guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { continue }
            for entry in controller.workspaceManager.floatingEntries(in: workspaceId)
                where workspaceInactiveFloatingRestoreFrame(for: entry, monitor: monitor) != nil
            {
                return true
            }
        }
        return false
    }

    @discardableResult
    func restoreWorkspaceInactiveFloatingWindows(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) -> Int {
        guard let controller else { return 0 }
        var frameUpdates: [AXFrameApplicationTarget] = []
        var visibleJobs: [(pid: pid_t, windowId: Int)] = []

        for workspaceId in activeWorkspaceIds {
            guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { continue }
            for entry in controller.workspaceManager.floatingEntries(in: workspaceId) {
                guard let frame = workspaceInactiveFloatingRestoreFrame(for: entry, monitor: monitor) else { continue }
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
                visibleJobs.append((entry.pid, entry.windowId))
                controller.axManager.markWindowActive(entry.windowId)
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                frameUpdates.append(.init(pid: entry.pid, window: entry.axRef, frame: frame))
            }
        }

        if !visibleJobs.isEmpty {
            controller.axManager.unsuppressFrameWrites(visibleJobs)
        }
        controller.axManager.applyFramesParallel(frameUpdates)
        return frameUpdates.count
    }

    private func workspaceInactiveFloatingRestoreFrame(
        for entry: WindowState,
        monitor: Monitor
    ) -> CGRect? {
        guard let controller else { return nil }
        guard !isWindowOnKnownInactiveNativeSpace(entry.windowId) else { return nil }
        guard entry.mode == .floating,
              entry.layoutReason == .standard,
              !controller.workspaceManager.isAppHidden(pid: entry.pid),
              controller.workspaceManager.hiddenState(for: entry.token)?.workspaceInactive == true
        else {
            return nil
        }
        return controller.workspaceManager.resolvedFloatingFrame(for: entry.token, preferredMonitor: monitor)
    }

    func hideInactiveWorkspaces(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }
        let workspaceEntries = workspaceEntriesSnapshot(on: controller)

        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        allEntries.reserveCapacity(workspaceEntries.reduce(into: 0) { $0 += $1.entries.count })
        for snapshot in workspaceEntries {
            for entry in snapshot.entries {
                allEntries.append((snapshot.workspace.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds,
            nativeInactiveWindowIds: nativeInactiveWindowIds()
        )

        var inactiveWindowJobs: [(pid: pid_t, windowId: Int)] = []
        let hiddenPlacementMonitors = controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init)
        for snapshot in workspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
            for entry in snapshot.entries {
                inactiveWindowJobs.append((entry.pid, entry.windowId))
            }
        }
        if !inactiveWindowJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(inactiveWindowJobs, reason: "inactive-workspace-hide")
        }

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for snapshot in workspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
            guard let monitor = controller.workspaceManager.monitor(for: snapshot.workspace.id) else { continue }
            let preferredSide = preferredSides[monitor.id] ?? .right
            hideWorkspace(
                snapshot.entries,
                monitor: monitor,
                preferredSide: preferredSide,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
        }
    }

    private func hideWorkspace(
        _ entries: [WindowState],
        monitor: Monitor,
        preferredSide: HideSide,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) {
        guard let controller else { return }
        for entry in entries {
            guard controller.workspaceManager.layoutReason(for: entry.token) != .nativeFullscreen else {
                continue
            }
            controller.axManager.markWindowInactive(entry.windowId)
            if isWindowOnKnownInactiveNativeSpace(entry.windowId) {
                continue
            }
            hideWindow(
                entry,
                monitor: monitor,
                side: preferredSide,
                reason: .workspaceInactive,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
        }
    }
}
