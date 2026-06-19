// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
struct WorldView {
    private let controller: WMController
    private let borderFrameResolver: ((Int) -> CGRect?)?

    init(controller: WMController, borderFrameResolver: ((Int) -> CGRect?)? = nil) {
        self.controller = controller
        self.borderFrameResolver = borderFrameResolver
    }

    var hasStartedServices: Bool {
        controller.hasStartedServices
    }

    var monitors: [Monitor] {
        controller.workspaceManager.monitors
    }

    var renderableFocusToken: WindowToken? {
        controller.workspaceManager.renderableFocusToken
    }

    var isNonManagedFocusActive: Bool {
        controller.workspaceManager.isNonManagedFocusActive
    }

    var suppressedFocusToken: WindowToken? {
        controller.workspaceManager.suppressedFocusToken
    }

    var systemModalFocusToken: WindowToken? {
        controller.workspaceManager.systemModalFocusToken
    }

    var hasPendingNativeFullscreenTransition: Bool {
        controller.workspaceManager.hasPendingNativeFullscreenTransition
    }

    var isAppFullscreenActive: Bool {
        controller.workspaceManager.isAppFullscreenActive
    }

    var spaceTopology: SpaceTopology {
        controller.workspaceManager.spaceTopology
    }

    var borderConfig: BorderConfig {
        BorderConfig.from(settings: controller.settings)
    }

    func entry(for token: WindowToken) -> WindowState? {
        controller.workspaceManager.entry(for: token)
    }

    func isOwnedWindow(windowId: Int) -> Bool {
        controller.isOwnedWindow(windowNumber: windowId)
    }

    func isWindowFullscreenInLayout(_ token: WindowToken) -> Bool {
        guard let workspaceId = controller.workspaceManager.entry(for: token)?.workspaceId else { return false }
        return controller.workspaceManager.layoutTopology(for: workspaceId).isFullscreen(token)
    }

    func isManagedWindowDisplayable(_ token: WindowToken) -> Bool {
        controller.isManagedWindowDisplayable(token)
    }

    func isWorkspaceVisible(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        controller.workspaceManager.visibleWorkspaceIds().contains(workspaceId)
    }

    func tabRailInfos() -> [TabbedColumnOverlayInfo] {
        controller.niriLayoutHandler.desiredTabRailInfos()
    }

    func barSurfaces() -> [DesiredBarSurface] {
        guard controller.hasWorkspaceBarDataConsumers else { return [] }
        let settings = controller.settings
        var bars: [DesiredBarSurface] = []
        for monitor in controller.workspaceManager.monitors {
            let resolved = settings.resolvedBarSettings(for: monitor)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            let projection = controller.workspaceBarProjection(
                for: monitor,
                projection: resolved.projectionOptions
            )
            bars.append(
                DesiredBarSurface(
                    monitor: monitor,
                    visible: controller.isWorkspaceBarVisible(on: monitor, resolved: resolved),
                    snapshot: WorkspaceBarSnapshot(
                        projection: projection,
                        showLabels: resolved.showLabels,
                        backgroundOpacity: resolved.backgroundOpacity,
                        barHeight: geometry.barHeight,
                        accentColor: resolved.accentColor,
                        textColor: resolved.textColor
                    )
                )
            )
        }
        return bars
    }

    func nativeFullscreenPlaceholders() -> [NativeFullscreenPlaceholderUpdate] {
        let workspaceManager = controller.workspaceManager
        var updates: [NativeFullscreenPlaceholderUpdate] = []
        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            for entry in workspaceManager.entries(in: workspace.id) {
                guard entry.layoutReason == .nativeFullscreen,
                      workspaceManager.showsNativeFullscreenPlaceholder(for: entry.token),
                      !workspaceManager.isHiddenInCorner(entry.token),
                      let frame = placeholderFrame(for: entry.token),
                      frame.width > 1, frame.height > 1
                else { continue }
                let appInfo = controller.appInfoCache.info(for: entry.pid)
                updates.append(
                    NativeFullscreenPlaceholderUpdate(
                        token: entry.token,
                        workspaceId: workspace.id,
                        frame: frame,
                        selected: workspaceManager.focusedToken == entry.token
                            || workspaceManager.pendingFocusedToken == entry.token,
                        appName: appInfo?.name,
                        icon: appInfo?.icon
                    )
                )
            }
        }
        return updates
    }

    private func placeholderFrame(for token: WindowToken) -> CGRect? {
        if let node = controller.niriEngine?.findNode(for: token) {
            return node.renderedFrame ?? node.frame
        }
        if let node = controller.dwindleEngine?.findNode(for: token) {
            return node.cachedFrame
        }
        return nil
    }

    func borderFrame(forWindowId windowId: Int) -> CGRect? {
        if let borderFrameResolver {
            return borderFrameResolver(windowId)
        }
        if let pending = controller.axManager.pendingFrameWrite(for: windowId) {
            return pending
        }
        return observedWindowBounds(windowId: windowId)
    }

    func observedWindowBounds(windowId: Int) -> CGRect? {
        guard windowId > 0,
              let bounds = SkyLight.shared.getWindowBounds(UInt32(windowId)),
              bounds.width > 0, bounds.height > 0
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: bounds)
    }
}
