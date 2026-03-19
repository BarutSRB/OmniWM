import AppKit
import Foundation

@MainActor
final class WindowActionHandler {
    weak var controller: WMController?

    @ObservationIgnored
    private lazy var overviewController: OverviewController = {
        guard let controller else { fatalError("WindowActionHandler requires controller") }
        let oc = OverviewController(wmController: controller)
        oc.onActivateWindow = { [weak self] handle, workspaceId in
            self?.activateWindowFromOverview(handle: handle, workspaceId: workspaceId)
        }
        oc.onCloseWindow = { [weak self] handle in
            self?.closeWindowFromOverview(handle: handle)
        }
        return oc
    }()

    init(controller: WMController) {
        self.controller = controller
    }

    func openMenuAnywhere() {
        guard controller != nil else { return }
        MenuAnywhereController.shared.showNativeMenu()
    }

    func toggleOverview() {
        overviewController.toggle()
    }

    func isOverviewOpen() -> Bool {
        overviewController.isOpen
    }

    func isPointInOverview(_ point: CGPoint) -> Bool {
        overviewController.isPointInside(point)
    }

    private func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.entry(for: handle) != nil else { return }
        navigateToWindowInternal(token: handle.id, workspaceId: workspaceId)
    }

    private func closeWindowFromOverview(handle: WindowHandle) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return }

        let element = entry.axRef.element
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        var closeButton: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success {
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        }
    }

    func raiseAllFloatingWindows() {
        guard let controller else { return }
        guard let monitor = controller.monitorForInteraction() else { return }
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else { return }

        let floatingEntries = controller.workspaceManager.floatingEntries(in: workspaceId).filter { entry in
            entry.layoutReason == .standard && !controller.workspaceManager.isHiddenInCorner(entry.token)
        }
        guard !floatingEntries.isEmpty else { return }

        let lastFloatingFocusedToken = controller.workspaceManager.lastFloatingFocusedToken(in: workspaceId)
        let orderedEntries = floatingEntries.sorted { lhs, rhs in
            switch (lhs.token == lastFloatingFocusedToken, rhs.token == lastFloatingFocusedToken) {
            case (true, false):
                return false
            case (false, true):
                return true
            default:
                if lhs.pid != rhs.pid {
                    return lhs.pid < rhs.pid
                }
                return lhs.windowId < rhs.windowId
            }
        }

        for entry in orderedEntries {
            SkyLight.shared.orderWindow(UInt32(entry.windowId), relativeTo: 0, order: .above)
        }

        guard let focusEntry = orderedEntries.last else { return }
        let ownPid = ProcessInfo.processInfo.processIdentifier

        if focusEntry.pid == ownPid {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let appInfo = controller.appInfoCache.info(for: focusEntry.pid),
              appInfo.activationPolicy != .prohibited,
              let app = NSRunningApplication(processIdentifier: focusEntry.pid)
        else {
            return
        }

        app.activate()
        var psn = ProcessSerialNumber()
        if GetProcessForPID(app.processIdentifier, &psn) == noErr {
            _ = _SLPSSetFrontProcessWithOptions(&psn, UInt32(focusEntry.windowId), kCPSUserGenerated)
            makeKeyWindow(psn: &psn, windowId: UInt32(focusEntry.windowId))
        }
    }

    func navigateToWindow(handle: WindowHandle) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return }
        navigateToWindowInternal(token: handle.id, workspaceId: entry.workspaceId)
    }

    func summonWindowRight(handle: WindowHandle) {
        guard let controller,
              let currentWorkspace = controller.activeWorkspace(),
              let focusedToken = controller.workspaceManager.focusedToken,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              focusedEntry.workspaceId == currentWorkspace.id
        else {
            return
        }

        summonWindowRight(
            handle: handle,
            anchorToken: focusedToken,
            anchorWorkspaceId: currentWorkspace.id
        )
    }

    func summonWindowRight(
        handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let anchorEntry = controller.workspaceManager.entry(for: anchorToken),
              anchorEntry.workspaceId == anchorWorkspaceId,
              let targetEntry = controller.workspaceManager.entry(for: handle)
        else {
            return
        }

        let token = handle.id
        guard token != anchorToken else { return }

        let targetWorkspaceId = anchorWorkspaceId
        switch layoutType(for: targetWorkspaceId) {
        case .dwindle:
            summonWindowRightInDwindle(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        case .niri, .defaultLayout:
            summonWindowRightInNiri(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        }
    }

    func navigateToWindowInternal(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard !controller.isManagedWindowSuspendedForNativeFullscreen(token) else { return }

        let currentWsId = controller.activeWorkspace()?.id

        if workspaceId != currentWsId {
            let wsName = controller.workspaceManager.descriptor(for: workspaceId)?.name ?? ""
            if let result = controller.workspaceManager.focusWorkspace(named: wsName) {
                _ = controller.workspaceManager.setInteractionMonitor(result.monitor.id)
                controller.syncMonitorsToNiriEngine()
            }
        }

        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let niriWindow = engine.findNode(for: token) {
            targetState.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: workspaceId),
               let colIdx = engine.columnIndex(of: column, in: workspaceId),
               let monitor = controller.workspaceManager.monitor(for: workspaceId)
            {
                engine.activateWindow(niriWindow.id)

                let cols = engine.columns(in: workspaceId)
                let gap = CGFloat(controller.workspaceManager.gaps)
                targetState.snapToColumn(
                    colIdx,
                    columns: cols,
                    gap: gap,
                    viewportWidth: monitor.visibleFrame.width
                )
            }
        }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: targetState,
                rememberedFocusToken: token
            )
        )
        controller.layoutRefreshController.commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
            controller?.focusWindow(token)
        }
    }

    private func summonWindowRightInNiri(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) {
        guard let controller,
              let engine = controller.niriEngine,
              let focusedNode = engine.findNode(for: focusedToken),
              let focusedColumn = engine.findColumn(containing: focusedNode, in: targetWorkspaceId),
              let focusedColumnIndex = engine.columnIndex(of: focusedColumn, in: targetWorkspaceId)
        else {
            return
        }

        let insertIndex = focusedColumnIndex + 1
        let sourceLayoutType = layoutType(for: sourceWorkspaceId)

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.niriLayoutHandler.insertWindowInNewColumn(
                handle: WindowHandle(id: token),
                insertIndex: insertIndex,
                in: targetWorkspaceId
            ) else {
                return
            }
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
            return
        }

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else {
            return
        }

        if sourceLayoutType == .dwindle {
            commitSummonedWindowFocus(
                token: token,
                workspaceId: targetWorkspaceId,
                rememberedFocusToken: focusedToken,
                startNiriScrollAnimation: true
            )
            return
        }

        guard controller.niriLayoutHandler.insertWindowInNewColumn(
            handle: WindowHandle(id: token),
            insertIndex: insertIndex,
            in: targetWorkspaceId
        ) else {
            return
        }
        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
    }

    private func summonWindowRightInDwindle(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let focusedNode = engine.findNode(for: focusedToken),
              focusedNode.isLeaf
        else {
            return
        }

        if sourceWorkspaceId == targetWorkspaceId {
            guard engine.summonWindowRight(token, beside: focusedToken, in: targetWorkspaceId) else {
                return
            }
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
            return
        }

        engine.setSelectedNode(focusedNode, in: targetWorkspaceId)
        engine.setPreselection(.right, in: targetWorkspaceId)

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else {
            return
        }

        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
    }

    private func commitSummonedWindowFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken? = nil,
        startNiriScrollAnimation: Bool = false
    ) {
        guard let controller else { return }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: rememberedFocusToken ?? token
            )
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand) { [weak controller] in
            controller?.focusWindow(token)
        }
        if startNiriScrollAnimation {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private func layoutType(for workspaceId: WorkspaceDescriptor.ID) -> LayoutType {
        guard let controller,
              let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name
        else {
            return .defaultLayout
        }
        return controller.settings.layoutType(for: workspaceName)
    }

    func focusWorkspaceFromBar(named name: String) {
        guard let controller else { return }
        if let currentWorkspace = controller.activeWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: name) else { return }

        let focusedToken = controller.resolveAndSetWorkspaceFocusToken(for: result.workspace.id)
        controller.layoutRefreshController.commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
            if let focusedToken {
                controller?.focusWindow(focusedToken)
            }
        }
    }

    func focusWindowFromBar(token: WindowToken) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }
        navigateToWindowInternal(token: token, workspaceId: entry.workspaceId)
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        guard let controller else { return [] }
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in controller.workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let cachedInfo = controller.appInfoCache.info(for: entry.handle.pid)
            guard let bundleId = cachedInfo?.bundleId else { continue }

            if appInfoMap[bundleId] != nil { continue }

            let frame = (AXWindowService.framePreferFast(entry.axRef)) ?? .zero

            appInfoMap[bundleId] = RunningAppInfo(
                id: bundleId,
                bundleId: bundleId,
                appName: cachedInfo?.name ?? "Unknown",
                icon: cachedInfo?.icon,
                windowSize: frame.size
            )
        }

        return appInfoMap.values.sorted { $0.appName < $1.appName }
    }
}
