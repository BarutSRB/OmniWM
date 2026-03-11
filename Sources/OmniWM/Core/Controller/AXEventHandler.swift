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
                controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged)
            }

        case let .resized(windowId):
            handleWindowMoveOrResize(windowId: windowId)
            if !isWindowHidden(windowId: windowId) {
                controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged)
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
        guard let focusedHandle = controller.workspaceManager.focusedHandle,
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

        controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
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
            let shouldAnimate = if let engine = controller.niriEngine,
                                    let windowNode = engine.findNode(for: entry.handle)
            {
                !windowNode.isHiddenInTabbedMode
            } else {
                true
            }
            if shouldAnimate {
                controller.layoutRefreshController.startWindowCloseAnimation(
                    entry: entry,
                    monitor: monitor
                )
            }
        }

        let needsFocusRecovery = removedHandle?.id == controller.workspaceManager.focusedHandle?.id

        if let removed = removedHandle {
            controller.focusCoordinator.discardPendingFocus(removed)
        }

        var oldFrames: [WindowHandle: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: wsId)
            if let handle = removedHandle {
                removedNodeId = engine.findNode(for: handle)?.id
            }
        }

        _ = controller.workspaceManager.removeWindow(pid: pid, windowId: winId)

        if needsFocusRecovery, let wsId = affectedWorkspaceId {
            controller.ensureFocusedHandleValid(in: wsId)
        }

        if let wsId = affectedWorkspaceId {
            Task { @MainActor [weak controller] in
                guard let controller else { return }

                await controller.layoutRefreshController.layoutWithNiriEngine(
                    activeWorkspaces: [wsId],
                    useScrollAnimationPath: true,
                    removedNodeId: removedNodeId
                )

                if let engine = controller.niriEngine {
                    let newFrames = engine.captureWindowFrames(in: wsId)
                    let animationsTriggered = engine.triggerMoveAnimations(
                        in: wsId,
                        oldFrames: oldFrames,
                        newFrames: newFrames
                    )
                    let hasWindowAnimations = engine.hasAnyWindowAnimationsRunning(in: wsId)
                    let hasColumnAnimations = engine.hasAnyColumnAnimationsRunning(in: wsId)

                    if animationsTriggered || hasWindowAnimations || hasColumnAnimations {
                        controller.layoutRefreshController.startScrollAnimation(for: wsId)
                    }
                }
            }
        }

        if let focused = controller.workspaceManager.focusedHandle,
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
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }

        guard let axRef = try? AXWindowRef(element: windowElement as! AXUIElement) else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }
        let winId = axRef.windowId

        let appFullscreen = AXWindowService.isFullscreen(axRef)

        if let entry = controller.workspaceManager.entry(forPid: pid, windowId: winId) {
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            if !isWorkspaceActive && !controller.isTransferringWindow {
                let wsName = controller.workspaceManager.descriptor(for: wsId)?.name ?? ""
                if controller.workspaceManager.focusWorkspace(named: wsName) != nil {
                    controller.syncMonitorsToNiriEngine()
                }
            }

            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen
            )
            return
        }

        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: appFullscreen)
        controller.borderManager.hideBorder()
    }

    func handleManagedAppActivation(
        entry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        appFullscreen: Bool
    ) {
        guard let controller else { return }
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)

        _ = controller.workspaceManager.setManagedFocus(entry.handle, in: wsId, onMonitor: monitorId)
        _ = controller.workspaceManager.setManagedAppFullscreen(appFullscreen)

        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            controller.workspaceManager.withNiriViewportState(for: wsId) { state in
                controller.niriLayoutHandler.activateNode(
                    node, in: wsId, state: &state,
                    options: .init(layoutRefresh: isWorkspaceActive, axFocus: false)
                )
            }

            if let frame = node.frame {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            } else if let frame = try? AXWindowService.frame(entry.axRef) {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
        } else if let frame = try? AXWindowService.frame(entry.axRef) {
            controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
        }
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        if !isWorkspaceActive {
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            ) { [weak controller] in
                controller?.focusWindow(entry.handle)
            }
        }
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.handle)
        }
        controller.layoutRefreshController.requestRelayout(reason: .appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.handle) == .macosHiddenApp {
                _ = controller.workspaceManager.restoreFromNativeState(for: entry.handle)
            }
        }
        controller.layoutRefreshController.requestRelayout(reason: .appUnhidden)
    }
}
