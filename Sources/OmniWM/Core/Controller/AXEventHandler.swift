import AppKit
import Foundation

@MainActor
final class AXEventHandler {
    private weak var controller: WMController?

    private var pendingFocusHandle: WindowHandle?
    private var deferredFocusHandle: WindowHandle?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast
    private var lastAnyFocusTime: Date = .distantPast
    private let globalFocusCooldown: TimeInterval = 0.0

    init(controller: WMController) {
        self.controller = controller
    }

    func handleEvent(_ event: AXEvent) {
        switch event {
        case let .created(ref, pid, winId):
            handleCreated(ref: ref, pid: pid, winId: winId)
        case let .removed(_, pid, winId):
            handleRemoved(pid: pid, winId: winId)
        case let .focused(ref, pid, winId):
            handleFocused(ref: ref, pid: pid, winId: winId)
        case .changed:
            controller?.internalLayoutRefreshController?.refreshWindowsAndLayout()
        }
    }

    private func handleCreated(ref: AXWindowRef, pid: pid_t, winId: Int) {
        guard let controller else { return }
        if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           controller.internalAppRulesByBundleId[bundleId]?.alwaysFloat == true
        {
            return
        }

        let workspaceId = controller.resolveWorkspaceForNewWindow(
            axRef: ref,
            pid: pid,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )
        _ = controller.internalWorkspaceManager.addWindow(ref, pid: pid, windowId: winId, to: workspaceId)
        controller.updateWorkspaceBar()

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    private func handleRemoved(pid: pid_t, winId: Int) {
        guard let controller else { return }
        var affectedWorkspaceId: WorkspaceDescriptor.ID?
        var removedHandle: WindowHandle?
        for ws in controller.internalWorkspaceManager.workspaces {
            for entry in controller.internalWorkspaceManager.entries(in: ws.id) {
                if entry.windowId == winId, entry.handle.pid == pid {
                    affectedWorkspaceId = ws.id
                    removedHandle = entry.handle
                    break
                }
            }
            if affectedWorkspaceId != nil { break }
        }

        controller.internalWorkspaceManager.removeWindow(pid: pid, windowId: winId)

        if let wsId = affectedWorkspaceId {
            controller.internalLayoutRefreshController?.layoutWithNiriEngine(activeWorkspaces: [wsId])

            if let removed = removedHandle, removed.id == controller.internalFocusedHandle?.id {
                ensureFocusedHandleValid(in: wsId)
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

    private func handleFocused(ref: AXWindowRef, pid: pid_t, winId: Int) {
        guard let controller else { return }
        if let app = NSRunningApplication(processIdentifier: pid) {
            let windowType = AXWindowService.windowType(ref, appPolicy: app.activationPolicy)
            if windowType != .tiling {
                controller.internalIsNonManagedFocusActive = true
                controller.internalIsAppFullscreenActive = false
                controller.internalBorderManager.hideBorder()
                return
            }
        }
        controller.internalIsNonManagedFocusActive = false
        for ws in controller.internalWorkspaceManager.workspaces {
            for entry in controller.internalWorkspaceManager.entries(in: ws.id) {
                if entry.windowId == winId, entry.handle.pid == pid {
                    if ws.id != controller.activeWorkspace()?.id {
                        guard let monitor = controller.internalWorkspaceManager.monitor(for: ws.id),
                              controller.internalWorkspaceManager.workspaces(on: monitor.id)
                              .contains(where: { $0.id == ws.id })
                        else {
                            return
                        }

                        if let currentMonitorId = controller.internalActiveMonitorId ?? controller
                            .monitorForInteraction()?.id,
                            currentMonitorId != monitor.id
                        {
                            controller.internalPreviousMonitorId = currentMonitorId
                        }
                        controller.internalActiveMonitorId = monitor.id
                        _ = controller.internalWorkspaceManager.setActiveWorkspace(ws.id, on: monitor.id)
                        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
                    }

                    controller.internalFocusedHandle = entry.handle
                    controller.internalLastFocusedByWorkspace[ws.id] = entry.handle

                    if let engine = controller.internalNiriEngine,
                       let node = engine.findNode(for: entry.handle)
                    {
                        var state = controller.internalWorkspaceManager.niriViewportState(for: ws.id)
                        state.selectedNodeId = node.id
                        controller.internalWorkspaceManager.updateNiriViewportState(state, for: ws.id)

                        engine.updateFocusTimestamp(for: node.id)
                    }

                    if let frame = try? AXWindowService.frame(entry.axRef) {
                        updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                    }
                    return
                }
            }
        }
        controller.internalBorderManager.hideBorder()
        handleCreated(ref: ref, pid: pid, winId: winId)
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

        let axRef = AXWindowRef(id: UUID(), element: windowElement as! AXUIElement)
        guard let winId = try? AXWindowService.windowId(axRef) else {
            controller.internalIsNonManagedFocusActive = true
            controller.internalIsAppFullscreenActive = false
            controller.internalBorderManager.hideBorder()
            return
        }

        for ws in controller.internalWorkspaceManager.workspaces {
            for entry in controller.internalWorkspaceManager.entries(in: ws.id) {
                if entry.windowId == winId, entry.handle.pid == pid {
                    controller.internalIsNonManagedFocusActive = false

                    controller.internalFocusedHandle = entry.handle
                    controller.internalLastFocusedByWorkspace[ws.id] = entry.handle

                    if let engine = controller.internalNiriEngine,
                       let node = engine.findNode(for: entry.handle)
                    {
                        var state = controller.internalWorkspaceManager.niriViewportState(for: ws.id)
                        state.selectedNodeId = node.id
                        controller.internalWorkspaceManager.updateNiriViewportState(state, for: ws.id)
                        engine.updateFocusTimestamp(for: node.id)
                    }

                    if let frame = try? AXWindowService.frame(entry.axRef) {
                        updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                    }
                    controller.internalLayoutRefreshController?.updateTabbedColumnOverlays()
                    return
                }
            }
        }
        controller.internalIsNonManagedFocusActive = true
        controller.internalIsAppFullscreenActive = false
        controller.internalBorderManager.hideBorder()
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.internalHiddenAppPIDs.insert(pid)

        for ws in controller.internalWorkspaceManager.workspaces {
            for entry in controller.internalWorkspaceManager.entries(in: ws.id) {
                if entry.handle.pid == pid {
                    controller.internalWorkspaceManager.setLayoutReason(.macosHiddenApp, for: entry.handle)
                }
            }
        }
        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.internalHiddenAppPIDs.remove(pid)

        for ws in controller.internalWorkspaceManager.workspaces {
            for entry in controller.internalWorkspaceManager.entries(in: ws.id) {
                if entry.handle.pid == pid,
                   controller.internalWorkspaceManager.layoutReason(for: entry.handle) == .macosHiddenApp
                {
                    _ = controller.internalWorkspaceManager.restoreFromNativeState(for: entry.handle)
                }
            }
        }
        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func focusWindow(_ handle: WindowHandle) {
        guard let controller else { return }
        guard let entry = controller.internalWorkspaceManager.entry(for: handle) else { return }
        controller.internalIsNonManagedFocusActive = false

        let now = Date()

        if now.timeIntervalSince(lastAnyFocusTime) < globalFocusCooldown {
            return
        }

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
        defer {
            isFocusOperationPending = false
            if let deferred = deferredFocusHandle, deferred != handle {
                deferredFocusHandle = nil
                focusWindow(deferred)
            }
        }

        pendingFocusHandle = handle
        lastFocusTime = now
        lastAnyFocusTime = now
        controller.internalLastFocusedByWorkspace[entry.workspaceId] = handle

        let app = AXUIElementCreateApplication(handle.pid)
        let focusResult = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, entry.axRef.element)
        let raiseResult = AXUIElementPerformAction(entry.axRef.element, kAXRaiseAction as CFString)

        if let runningApp = NSRunningApplication(processIdentifier: handle.pid) {
            runningApp.activate()
        }

        if focusResult != .success || raiseResult != .success {
            NSLog("WMController: Focus failed - focus: \(focusResult.rawValue), raise: \(raiseResult.rawValue)")
        }

        if controller.internalMoveMouseToFocusedWindowEnabled {
            controller.moveMouseToWindow(handle)
        }

        let handleForBorder = handle
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            guard let entry = controller.internalWorkspaceManager.entry(for: handleForBorder) else { return }
            if let frame = try? AXWindowService.frame(entry.axRef) {
                updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
        }
    }

    func ensureFocusedHandleValid(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        if let focused = controller.internalFocusedHandle,
           controller.internalWorkspaceManager.entry(for: focused)?.workspaceId == workspaceId
        {
            controller.internalLastFocusedByWorkspace[workspaceId] = focused
            return
        }
        if let remembered = controller.internalLastFocusedByWorkspace[workspaceId],
           controller.internalWorkspaceManager.entry(for: remembered) != nil
        {
            controller.internalFocusedHandle = remembered
            return
        }
        controller.internalFocusedHandle = controller.internalWorkspaceManager.entries(in: workspaceId).first?.handle
        if let focusedHandle = controller.internalFocusedHandle {
            controller.internalLastFocusedByWorkspace[workspaceId] = focusedHandle
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
