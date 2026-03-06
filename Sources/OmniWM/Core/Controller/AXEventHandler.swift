import AppKit
import Foundation

@MainActor
final class AXEventHandler: CGSEventDelegate {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        CGSEventObserver.shared.delegate = self
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        CGSEventObserver.shared.delegate = nil
        CGSEventObserver.shared.stop()
    }

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, _):
            handleCGSWindowCreated(windowId: windowId)

        case let .destroyed(windowId, _):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .closed(windowId):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .moved(windowId):
            handleWindowMoveOrResize(windowId: windowId)
            if !isWindowHidden(windowId: windowId) {
                controller.layoutRefreshController.scheduleRefreshSession(.axWindowChanged)
            }

        case let .resized(windowId):
            handleWindowMoveOrResize(windowId: windowId)
            if !isWindowHidden(windowId: windowId) {
                controller.layoutRefreshController.scheduleRefreshSession(.axWindowChanged)
            }

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid)

        case .titleChanged:
            controller.updateWorkspaceBar()
        }
    }

    private func isWindowHidden(windowId: UInt32) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(forWindowId: Int(windowId)) else {
            return false
        }
        return controller.workspaceManager.isHiddenInCorner(entry.handle)
    }

    private func handleCGSWindowCreated(windowId: UInt32) {
        guard let controller else { return }

        if controller.isDiscoveryInProgress {
            return
        }

        if controller.workspaceManager.entry(forWindowId: Int(windowId)) != nil {
            return
        }

        guard let windowInfo = SkyLight.shared.queryWindowInfo(windowId) else {
            return
        }

        let pid = windowInfo.pid
        CGSEventObserver.shared.subscribeToWindows([windowId])

        if let axRef = AXWindowService.axWindowRef(for: windowId, pid: pid) {
            handleCreated(ref: axRef, pid: pid, winId: Int(windowId))
        }
    }

    private func handleWindowMoveOrResize(windowId: UInt32) {
        guard let controller else { return }
        guard let focusedHandle = controller.focusedHandle,
              let entry = controller.workspaceManager.entry(for: focusedHandle),
              entry.windowId == Int(windowId)
        else { return }

        if let frame = try? AXWindowService.frame(entry.axRef) {
            controller.borderCoordinator.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: Int(windowId))
        }
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(
            forWindowId: Int(windowId),
            inVisibleWorkspaces: true
        ) else {
            return
        }

        handleRemoved(pid: entry.handle.pid, winId: Int(windowId))
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.workspaceManager.allEntries().compactMap { entry -> UInt32? in
            UInt32(entry.windowId)
        }
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    private func handleCreated(ref: AXWindowRef, pid: pid_t, winId: Int) {
        guard let controller else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier
        let appPolicy = app?.activationPolicy
        let windowType = AXWindowService.windowType(ref, appPolicy: appPolicy, bundleId: bundleId)
        guard windowType == .tiling else { return }

        if let bundleId, controller.appRulesByBundleId[bundleId]?.alwaysFloat == true {
            return
        }

        let workspaceId = controller.resolveWorkspaceForNewWindow(
            axRef: ref,
            pid: pid,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )

        if workspaceId != controller.activeWorkspace()?.id {
            if let monitor = controller.workspaceManager.monitor(for: workspaceId),
               controller.workspaceManager.workspaces(on: monitor.id)
               .contains(where: { $0.id == workspaceId })
            {
                if let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id,
                    currentMonitorId != monitor.id
                {
                    controller.previousMonitorId = currentMonitorId
                }
                controller.activeMonitorId = monitor.id
                _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
            }
        }

        _ = controller.workspaceManager.addWindow(ref, pid: pid, windowId: winId, to: workspaceId)
        CGSEventObserver.shared.subscribeToWindows([UInt32(winId)])
        controller.updateWorkspaceBar()

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        controller.layoutRefreshController.scheduleRefreshSession(.axWindowCreated)
    }

    func handleRemoved(pid: pid_t, winId: Int) {
        guard let controller else { return }
        let entry = controller.workspaceManager.entry(forPid: pid, windowId: winId)
        let affectedWorkspaceId = entry?.workspaceId
        let removedHandle = entry?.handle

        if let entry,
           let wsId = affectedWorkspaceId,
           let monitor = controller.workspaceManager.monitor(for: wsId),
           controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId,
           let workspaceName = controller.workspaceManager.descriptor(for: wsId)?.name,
           controller.settings.layoutType(for: workspaceName) != .dwindle
        {
            let shouldAnimate: Bool
            if let nodeId = controller.zigNodeId(for: entry.handle, workspaceId: wsId),
               let workspaceView = controller.syncZigNiriWorkspace(workspaceId: wsId),
               let windowView = workspaceView.windowsById[nodeId],
               let columnId = windowView.columnId,
               let columnView = workspaceView.columns.first(where: { $0.nodeId == columnId }),
               columnView.display == .tabbed
            {
                let activeWindowId: NodeId? = {
                    guard let activeIndex = columnView.activeWindowIndex,
                          columnView.windowIds.indices.contains(activeIndex)
                    else {
                        return nil
                    }
                    return columnView.windowIds[activeIndex]
                }()
                shouldAnimate = activeWindowId == nil || activeWindowId == nodeId
            } else {
                shouldAnimate = true
            }
            if shouldAnimate {
                controller.layoutRefreshController.startWindowCloseAnimation(
                    entry: entry,
                    monitor: monitor
                )
            }
        }

        let needsFocusRecovery = removedHandle?.id == controller.focusedHandle?.id

        if let removed = removedHandle {
            controller.focusManager.handleWindowRemoved(removed, in: affectedWorkspaceId)
        }

        let oldFrames: [WindowHandle: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, let handle = removedHandle {
            removedNodeId = controller.zigNodeId(for: handle, workspaceId: wsId)
        }

        controller.workspaceManager.removeWindow(pid: pid, windowId: winId)

        if needsFocusRecovery, let wsId = affectedWorkspaceId {
            controller.focusManager.ensureFocusedHandleValid(
                in: wsId,
                zigEngine: controller.zigNiriEngine,
                workspaceManager: controller.workspaceManager,
                focusWindowAction: { [weak controller] handle in controller?.focusWindow(handle) }
            )
        }

        if let wsId = affectedWorkspaceId {
            Task { @MainActor [weak controller] in
                guard let controller else { return }

                await controller.layoutRefreshController.layoutWithNiriEngine(
                    activeWorkspaces: [wsId],
                    useScrollAnimationPath: true,
                    removedNodeId: removedNodeId
                )
                _ = oldFrames
            }
        }

        if let focused = controller.focusedHandle,
           let entry = controller.workspaceManager.entry(for: focused),
           let frame = try? AXWindowService.frame(entry.axRef)
        {
            controller.borderCoordinator.updateBorderIfAllowed(handle: focused, frame: frame, windowId: entry.windowId)
        } else {
            controller.borderManager.hideBorder()
        }
    }

    func handleAppActivation(pid: pid_t) {
        guard let controller else { return }
        guard controller.hasStartedServices else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowElement = focusedWindow else {
            controller.focusManager.setNonManagedFocus(active: true)
            controller.focusManager.setAppFullscreen(active: false)
            controller.borderManager.hideBorder()
            return
        }

        guard let axRef = try? AXWindowRef(element: windowElement as! AXUIElement) else {
            controller.focusManager.setNonManagedFocus(active: true)
            controller.focusManager.setAppFullscreen(active: false)
            controller.borderManager.hideBorder()
            return
        }
        let winId = axRef.windowId

        if let entry = controller.workspaceManager.entry(forPid: pid, windowId: winId) {
            let wsId = entry.workspaceId
            controller.focusManager.setNonManagedFocus(active: false)

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            if !isWorkspaceActive && !controller.isTransferringWindow {
                let wsName = controller.workspaceManager.descriptor(for: wsId)?.name ?? ""
                if let result = controller.workspaceManager.focusWorkspace(named: wsName) {
                    let currentMonitorId = controller.activeMonitorId
                        ?? controller.monitorForInteraction()?.id
                    if let currentMonitorId, currentMonitorId != result.monitor.id {
                        controller.previousMonitorId = currentMonitorId
                    }
                    controller.activeMonitorId = result.monitor.id
                    controller.syncMonitorsToNiriEngine()
                }
            }

            controller.focusManager.setFocus(entry.handle, in: wsId)

            if let nodeId = controller.zigNodeId(for: entry.handle, workspaceId: wsId) {
                controller.workspaceManager.setSelection(nodeId, for: wsId)
                _ = controller.zigNiriEngine?.applyWorkspace(
                    .setSelection(
                        ZigNiriSelection(
                            selectedNodeId: nodeId,
                            focusedWindowId: nodeId
                        )
                    ),
                    in: wsId
                )
                if isWorkspaceActive {
                    controller.layoutRefreshController.executeLayoutRefreshImmediate()
                }
                if let frame = try? AXWindowService.frame(entry.axRef) {
                    controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                }
            } else if let frame = try? AXWindowService.frame(entry.axRef) {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
            controller.niriLayoutHandler.updateTabbedColumnOverlays()
            if !isWorkspaceActive {
                controller.layoutRefreshController.refreshWindowsAndLayout()
                controller.focusWindow(entry.handle)
            }
            return
        }

        controller.focusManager.setNonManagedFocus(active: true)
        controller.focusManager.setAppFullscreen(active: false)
        controller.borderManager.hideBorder()
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.handle)
        }
        controller.layoutRefreshController.scheduleRefreshSession(.appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.handle) == .macosHiddenApp {
                _ = controller.workspaceManager.restoreFromNativeState(for: entry.handle)
            }
        }
        controller.layoutRefreshController.scheduleRefreshSession(.appUnhidden)
    }
}
