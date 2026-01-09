import AppKit
import Foundation

@MainActor
final class AXEventHandler: CGSEventDelegate {
    private weak var controller: WMController?

    private var pendingFocusHandle: WindowHandle?
    private var deferredFocusHandle: WindowHandle?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    init(controller: WMController) {
        self.controller = controller
        setupCGSEventObserver()
    }

    private func setupCGSEventObserver() {
        CGSEventObserver.shared.delegate = self
        CGSEventObserver.shared.start()
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
            controller.internalLayoutRefreshController?.scheduleRefreshSession(.axWindowChanged)

        case let .resized(windowId):
            handleWindowMoveOrResize(windowId: windowId)
            controller.internalLayoutRefreshController?.scheduleRefreshSession(.axWindowChanged)

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid)

        case .titleChanged:
            controller.updateWorkspaceBar()
        }
    }

    private func handleCGSWindowCreated(windowId: UInt32) {
        guard let controller else { return }

        if controller.internalLayoutRefreshController?.isDiscoveryInProgress ?? false {
            return
        }

        if controller.internalWorkspaceManager.entry(forWindowId: Int(windowId)) != nil {
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
        guard let focusedHandle = controller.internalFocusedHandle,
              let entry = controller.internalWorkspaceManager.entry(for: focusedHandle),
              entry.windowId == Int(windowId)
        else { return }

        if let frame = try? AXWindowService.frame(entry.axRef) {
            updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: Int(windowId))
        }
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        guard let controller else { return }

        if let entry = controller.internalWorkspaceManager.entry(forWindowId: Int(windowId)) {
            handleRemoved(pid: entry.handle.pid, winId: Int(windowId))
        }
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.internalWorkspaceManager.allEntries().compactMap { entry -> UInt32? in
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

        if let bundleId, controller.internalAppRulesByBundleId[bundleId]?.alwaysFloat == true {
            return
        }

        let workspaceId = controller.resolveWorkspaceForNewWindow(
            axRef: ref,
            pid: pid,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )

        if workspaceId != controller.activeWorkspace()?.id {
            if let monitor = controller.internalWorkspaceManager.monitor(for: workspaceId),
               controller.internalWorkspaceManager.workspaces(on: monitor.id)
               .contains(where: { $0.id == workspaceId })
            {
                if let currentMonitorId = controller.internalActiveMonitorId ?? controller
                    .monitorForInteraction()?.id,
                    currentMonitorId != monitor.id
                {
                    controller.internalPreviousMonitorId = currentMonitorId
                }
                controller.internalActiveMonitorId = monitor.id
                _ = controller.internalWorkspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
            }
        }

        _ = controller.internalWorkspaceManager.addWindow(ref, pid: pid, windowId: winId, to: workspaceId)
        CGSEventObserver.shared.subscribeToWindows([UInt32(winId)])
        controller.updateWorkspaceBar()

        Task { @MainActor in
            if let app = NSRunningApplication(processIdentifier: pid) {
                _ = await controller.internalAXManager.windowsForApp(app)
            }
        }

        controller.internalLayoutRefreshController?.scheduleRefreshSession(.axWindowCreated)
    }

    func handleRemoved(pid: pid_t, winId: Int) {
        guard let controller else { return }

        let entry = controller.internalWorkspaceManager.entry(forPid: pid, windowId: winId)
        let affectedWorkspaceId = entry?.workspaceId
        let removedHandle = entry?.handle

        var oldFrames: [WindowHandle: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, let engine = controller.internalNiriEngine {
            oldFrames = engine.captureWindowFrames(in: wsId)
            if let handle = removedHandle {
                removedNodeId = engine.findNode(for: handle)?.id
            }
        }

        controller.internalWorkspaceManager.removeWindow(pid: pid, windowId: winId)

        if let wsId = affectedWorkspaceId {
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller else { return }

                await controller.internalLayoutRefreshController?.layoutWithNiriEngine(
                    activeWorkspaces: [wsId],
                    useScrollAnimationPath: true,
                    removedNodeId: removedNodeId
                )

                if let engine = controller.internalNiriEngine {
                    let newFrames = engine.captureWindowFrames(in: wsId)
                    let animationsTriggered = engine.triggerMoveAnimations(
                        in: wsId,
                        oldFrames: oldFrames,
                        newFrames: newFrames
                    )
                    let hasWindowAnimations = engine.hasAnyWindowAnimationsRunning(in: wsId)
                    let hasColumnAnimations = engine.hasAnyColumnAnimationsRunning(in: wsId)

                    if animationsTriggered || hasWindowAnimations || hasColumnAnimations {
                        controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
                    }
                }

                if let removed = removedHandle, removed.id == controller.internalFocusedHandle?.id {
                    self.ensureFocusedHandleValid(in: wsId)
                }
            }
        }

        if let focused = controller.internalFocusedHandle,
           let entry = controller.internalWorkspaceManager.entry(for: focused),
           let frame = try? AXWindowService.frame(entry.axRef)
        {
            updateBorderIfAllowed(handle: focused, frame: frame, windowId: entry.windowId)
        } else {
            controller.internalBorderManager.hideBorder()
        }
    }

    func handleAppActivation(pid: pid_t) {
        guard let controller else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowElement = focusedWindow else {
            controller.internalIsNonManagedFocusActive = true
            controller.internalIsAppFullscreenActive = false
            controller.internalBorderManager.hideBorder()
            return
        }

        guard let axRef = try? AXWindowRef(element: windowElement as! AXUIElement) else {
            controller.internalIsNonManagedFocusActive = true
            controller.internalIsAppFullscreenActive = false
            controller.internalBorderManager.hideBorder()
            return
        }
        let winId = axRef.windowId

        if let entry = controller.internalWorkspaceManager.entry(forPid: pid, windowId: winId) {
            let wsId = entry.workspaceId
            controller.internalIsNonManagedFocusActive = false

            controller.internalFocusedHandle = entry.handle
            controller.internalLastFocusedByWorkspace[wsId] = entry.handle

            if let engine = controller.internalNiriEngine,
               let node = engine.findNode(for: entry.handle)
            {
                var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)
                state.selectedNodeId = node.id
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                engine.updateFocusTimestamp(for: node.id)
            }

            if let engine = controller.internalNiriEngine,
               let node = engine.findNode(for: entry.handle),
               let frame = node.frame {
                updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            } else if let frame = try? AXWindowService.frame(entry.axRef) {
                updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
            controller.internalLayoutRefreshController?.updateTabbedColumnOverlays()
            return
        }

        controller.internalIsNonManagedFocusActive = true
        controller.internalIsAppFullscreenActive = false
        controller.internalBorderManager.hideBorder()
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.internalHiddenAppPIDs.insert(pid)

        for entry in controller.internalWorkspaceManager.entries(forPid: pid) {
            controller.internalWorkspaceManager.setLayoutReason(.macosHiddenApp, for: entry.handle)
        }
        controller.internalLayoutRefreshController?.scheduleRefreshSession(.appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.internalHiddenAppPIDs.remove(pid)

        for entry in controller.internalWorkspaceManager.entries(forPid: pid) {
            if controller.internalWorkspaceManager.layoutReason(for: entry.handle) == .macosHiddenApp {
                _ = controller.internalWorkspaceManager.restoreFromNativeState(for: entry.handle)
            }
        }
        controller.internalLayoutRefreshController?.scheduleRefreshSession(.appUnhidden)
    }

    func focusWindow(_ handle: WindowHandle) {
        guard let controller else { return }
        guard let entry = controller.internalWorkspaceManager.entry(for: handle) else { return }
        controller.internalIsNonManagedFocusActive = false

        let now = Date()

        if pendingFocusHandle == handle {
            let timeSinceFocus = now.timeIntervalSince(lastFocusTime)
            if timeSinceFocus < 0.016 {
                return
            }
        }

        if isFocusOperationPending {
            deferredFocusHandle = handle
            return
        }

        isFocusOperationPending = true

        pendingFocusHandle = handle
        lastFocusTime = now
        controller.internalLastFocusedByWorkspace[entry.workspaceId] = handle

        let axRef = entry.axRef
        let pid = handle.pid
        let windowId = entry.windowId
        let moveMouseEnabled = controller.internalMoveMouseToFocusedWindowEnabled

        Task { @MainActor [weak self, weak controller] in
            OmniWM.focusWindow(pid: pid, windowId: UInt32(windowId), windowRef: axRef.element)
            AXUIElementPerformAction(axRef.element, kAXRaiseAction as CFString)

            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate()
            }

            guard let self, let controller else { return }

            if moveMouseEnabled {
                controller.moveMouseToWindow(handle)
            }

            if let entry = controller.internalWorkspaceManager.entry(for: handle) {
                if let engine = controller.internalNiriEngine,
                   let node = engine.findNode(for: handle),
                   let frame = node.frame {
                    updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                } else if let frame = try? AXWindowService.frame(entry.axRef) {
                    updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                }
            }

            isFocusOperationPending = false
            if let deferred = deferredFocusHandle, deferred != handle {
                deferredFocusHandle = nil
                focusWindow(deferred)
            }
        }
    }

    func ensureFocusedHandleValid(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        if let focused = controller.internalFocusedHandle,
           controller.internalWorkspaceManager.entry(for: focused)?.workspaceId == workspaceId
        {
            controller.internalLastFocusedByWorkspace[workspaceId] = focused
            if let engine = controller.internalNiriEngine,
               let node = engine.findNode(for: focused)
            {
                var state = controller.internalWorkspaceManager.niriViewportState(for: workspaceId)
                if state.selectedNodeId != node.id {
                    state.selectedNodeId = node.id
                    controller.internalWorkspaceManager.updateNiriViewportState(state, for: workspaceId)
                }
            }
            return
        }
        if let remembered = controller.internalLastFocusedByWorkspace[workspaceId],
           controller.internalWorkspaceManager.entry(for: remembered) != nil
        {
            controller.internalFocusedHandle = remembered
            if let engine = controller.internalNiriEngine,
               let node = engine.findNode(for: remembered)
            {
                var state = controller.internalWorkspaceManager.niriViewportState(for: workspaceId)
                state.selectedNodeId = node.id
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: workspaceId)
            }
            return
        }
        let newHandle = controller.internalWorkspaceManager.entries(in: workspaceId).first?.handle
        controller.internalFocusedHandle = newHandle
        if let focusedHandle = newHandle {
            controller.internalLastFocusedByWorkspace[workspaceId] = focusedHandle
            if let engine = controller.internalNiriEngine,
               let node = engine.findNode(for: focusedHandle)
            {
                var state = controller.internalWorkspaceManager.niriViewportState(for: workspaceId)
                state.selectedNodeId = node.id
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: workspaceId)
            }
        }
    }

    func updateBorderIfAllowed(handle: WindowHandle, frame: CGRect, windowId: Int) {
        guard let controller else { return }
        guard let activeWs = controller.activeWorkspace(),
              controller.internalWorkspaceManager.workspace(for: handle) == activeWs.id
        else {
            controller.internalBorderManager.hideBorder()
            return
        }

        if controller.internalIsNonManagedFocusActive {
            controller.internalBorderManager.hideBorder()
            return
        }

        if shouldDeferBorderUpdates(for: activeWs.id) {
            controller.internalBorderManager.hideBorder()
            return
        }

        if let entry = controller.internalWorkspaceManager.entry(for: handle) {
            controller.internalIsAppFullscreenActive = AXWindowService.isFullscreen(entry.axRef)
        } else {
            controller.internalIsAppFullscreenActive = false
        }

        if controller.internalIsAppFullscreenActive || isManagedWindowFullscreen(handle) {
            controller.internalBorderManager.hideBorder()
            return
        }
        controller.internalBorderManager.updateFocusedWindow(frame: frame, windowId: windowId)
    }

    private func shouldDeferBorderUpdates(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }

        let state = controller.internalWorkspaceManager.niriViewportState(for: workspaceId)
        if state.viewOffsetPixels.isAnimating {
            return true
        }

        guard let engine = controller.internalNiriEngine else { return false }
        if engine.hasAnyWindowAnimationsRunning(in: workspaceId) {
            return true
        }
        if engine.hasAnyColumnAnimationsRunning(in: workspaceId) {
            return true
        }
        return false
    }

    private func isManagedWindowFullscreen(_ handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.internalNiriEngine,
              let windowNode = engine.findNode(for: handle)
        else {
            return false
        }
        return windowNode.isFullscreen
    }
}
