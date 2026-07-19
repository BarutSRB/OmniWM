// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    func captureCreatePlacementContext(windowId: UInt32, spaceId: UInt64) {
        pruneExpiredCreatePlacementContexts()
        guard createPlacementContextsByWindowId[windowId] == nil,
              let controller
        else {
            return
        }

        createPlacementContextsByWindowId[windowId] = liveCreatePlacementContext(
            controller: controller,
            nativeSpaceMonitorId: resolveNativeSpacePlacementMonitorId(spaceId: spaceId, controller: controller)
        )
    }

    func liveCreatePlacementContext(
        controller: WMController,
        nativeSpaceMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        let focusedWorkspaceId = resolveFocusedPlacementWorkspaceId(controller: controller)
        return WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            pendingFocusedMonitorId: resolvePendingFocusedPlacementMonitorId(controller: controller),
            focusedWorkspaceId: focusedWorkspaceId,
            focusedMonitorId: focusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            },
            interactionMonitorId: controller.workspaceManager.interactionMonitorId,
            createdAt: Date()
        )
    }

    private func resolvePendingFocusedPlacementMonitorId(
        controller: WMController
    ) -> Monitor.ID? {
        controller.workspaceManager.pendingFocusedMonitorId
            ?? controller.workspaceManager.pendingFocusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            }
    }

    private func resolveFocusedPlacementWorkspaceId(
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        guard let focusedToken = controller.workspaceManager.focusedToken,
              let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
        else {
            return nil
        }
        return workspaceId
    }

    private func resolveNativeSpacePlacementMonitorId(
        spaceId: UInt64,
        controller: WMController
    ) -> Monitor.ID? {
        let monitors = controller.workspaceManager.monitors
        let displayId = SkyLight.shared.displayId(forSpaceId: spaceId, among: monitors)
        guard let displayId,
              let monitor = monitors.first(where: { $0.displayId == displayId })
        else {
            return nil
        }

        return monitor.id
    }

    func discardCreatePlacementContext(windowId: UInt32) {
        createPlacementContextsByWindowId.removeValue(forKey: windowId)
    }

    func resetCreatePlacementContextState() {
        createPlacementContextsByWindowId.removeAll()
    }

    func pruneExpiredCreatePlacementContexts(now: Date = Date()) {
        createPlacementContextsByWindowId = createPlacementContextsByWindowId.filter { _, context in
            now.timeIntervalSince(context.createdAt) < Self.createPlacementContextTTL
        }
    }

    func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        windowInfoProvider(windowId)
    }

    func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        guard let windowInfo = resolveWindowInfo(windowId) else { return nil }
        return .init(pid: windowInfo.pid, windowId: Int(windowId))
    }

    func resolveTrackedToken(
        _ windowId: UInt32,
        resolvedWindowToken: WindowToken? = nil
    ) -> WindowToken? {
        guard let controller else { return nil }
        if let token = resolvedWindowToken ?? resolveWindowToken(windowId),
           controller.workspaceManager.entry(for: token) != nil
        {
            return token
        }
        return controller.workspaceManager.entry(forWindowId: Int(windowId))?.token
    }

    func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    func subscribeToWindows(_ windowIds: [UInt32]) {
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    func resolveBundleId(_ pid: pid_t) -> String? {
        guard let controller else { return nil }
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier
    }
}
