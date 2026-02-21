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

    func openWindowFinder() {
        guard let controller else { return }
        let entries = controller.workspaceManager.allEntries()
        var items: [WindowFinderItem] = []

        for entry in entries {
            guard entry.layoutReason == .standard else { continue }

            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) ?? ""

            let appInfo = controller.appInfoCache.info(for: entry.handle.pid)

            let workspaceName = controller.workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

            items.append(WindowFinderItem(
                id: entry.handle.id,
                handle: entry.handle,
                title: title,
                appName: appInfo?.name ?? "Unknown",
                appIcon: appInfo?.icon,
                workspaceName: workspaceName,
                workspaceId: entry.workspaceId
            ))
        }

        items.sort { ($0.appName, $0.title) < ($1.appName, $1.title) }

        WindowFinderController.shared.show(windows: items) { [weak self] item in
            self?.navigateToWindow(item)
        }
    }

    func openMenuAnywhere() {
        guard let controller else { return }
        guard controller.settings.menuAnywhereNativeEnabled else { return }
        MenuAnywhereController.shared.showNativeMenu(at: controller.settings.menuAnywherePosition)
    }

    func openMenuPalette() {
        guard let controller else { return }
        guard controller.settings.menuAnywherePaletteEnabled else { return }

        let ownBundleId = Bundle.main.bundleIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication

        let targetApp: NSRunningApplication
        if let fm = frontmost, fm.bundleIdentifier != ownBundleId {
            targetApp = fm
        } else if let stored = MenuPaletteController.shared.currentApp, !stored.isTerminated {
            targetApp = stored
        } else {
            return
        }

        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
        var windowValue: AnyObject?
        var targetWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success {
            targetWindow = (windowValue as! AXUIElement)
        }

        MenuPaletteController.shared.show(
            at: controller.settings.menuAnywherePosition,
            showShortcuts: controller.settings.menuAnywhereShowShortcuts,
            targetApp: targetApp,
            targetWindow: targetWindow
        )
    }

    func toggleOverview() {
        overviewController.toggle()
    }

    private func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.entry(for: handle) != nil else { return }
        navigateToWindowInternal(handle: handle, workspaceId: workspaceId)
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

        let allWindows = SkyLight.shared.queryAllVisibleWindows()

        let windowsOnMonitor = allWindows.filter { info in
            let center = ScreenCoordinateSpace.toAppKit(rect: info.frame).center
            return monitor.visibleFrame.contains(center)
        }

        let windowsByPid = Dictionary(grouping: windowsOnMonitor) { $0.pid }
        let windowIdSet = Set(windowsOnMonitor.map(\.id))

        var lastRaisedPid: pid_t?
        var lastRaisedWindowId: UInt32?
        var ownAppHasFloatingWindows = false
        let ownPid = ProcessInfo.processInfo.processIdentifier

        for (pid, _) in windowsByPid {
            guard let appInfo = controller.appInfoCache.info(for: pid),
                  appInfo.activationPolicy != .prohibited else { continue }

            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                guard let axRef = try? AXWindowRef(element: window),
                      windowIdSet.contains(UInt32(axRef.windowId)) else { continue }
                let windowId = axRef.windowId

                let hasAlwaysFloatRule = appInfo.bundleId.flatMap { controller.appRulesByBundleId[$0]?.alwaysFloat } == true
                let windowType = AXWindowService.windowType(
                    axRef,
                    appPolicy: appInfo.activationPolicy,
                    bundleId: appInfo.bundleId
                )
                guard windowType == .floating || hasAlwaysFloatRule else { continue }

                SkyLight.shared.orderWindow(UInt32(windowId), relativeTo: 0, order: .above)

                if pid == ownPid {
                    ownAppHasFloatingWindows = true
                } else {
                    lastRaisedPid = pid
                    lastRaisedWindowId = UInt32(windowId)
                }
            }
        }

        if let pid = lastRaisedPid,
           let windowId = lastRaisedWindowId,
           let app = NSRunningApplication(processIdentifier: pid)
        {
            app.activate()
            var psn = ProcessSerialNumber()
            if GetProcessForPID(app.processIdentifier, &psn) == noErr {
                _ = _SLPSSetFrontProcessWithOptions(&psn, windowId, kCPSUserGenerated)
                makeKeyWindow(psn: &psn, windowId: windowId)
            }
        }

        if ownAppHasFloatingWindows {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func navigateToWindow(_ item: WindowFinderItem) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: item.handle) else { return }
        navigateToWindowInternal(handle: item.handle, workspaceId: entry.workspaceId)
    }

    func navigateToWindowInternal(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }

        let currentWsId = controller.activeWorkspace()?.id

        if workspaceId != currentWsId {
            let wsName = controller.workspaceManager.descriptor(for: workspaceId)?.name ?? ""
            if let result = controller.workspaceManager.focusWorkspace(named: wsName) {
                controller.activeMonitorId = result.monitor.id
                controller.syncMonitorsToNiriEngine()
            }
        }

        if let niriWindow = engine.findNode(for: handle) {
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.selectedNodeId = niriWindow.id

                if let column = engine.findColumn(containing: niriWindow, in: workspaceId),
                   let colIdx = engine.columnIndex(of: column, in: workspaceId),
                   let monitor = controller.workspaceManager.monitor(for: workspaceId)
                {
                    engine.activateWindow(niriWindow.id)

                    let cols = engine.columns(in: workspaceId)
                    let gap = CGFloat(controller.workspaceManager.gaps)
                    state.snapToColumn(
                        colIdx,
                        columns: cols,
                        gap: gap,
                        viewportWidth: monitor.visibleFrame.width
                    )
                }
            }
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()

        controller.focusManager.setFocus(handle, in: workspaceId)
        controller.focusWindow(handle)
    }

    func focusWorkspaceFromBar(named name: String) {
        guard let controller else { return }
        if let currentWorkspace = controller.activeWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: name) else { return }

        let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            controller.previousMonitorId = currentMonitorId
        }
        controller.activeMonitorId = result.monitor.id

        controller.resolveAndSetWorkspaceFocus(for: result.workspace.id)

        controller.layoutRefreshController.refreshWindowsAndLayout()
        if let handle = controller.focusedHandle {
            controller.focusWindow(handle)
        }
    }

    func focusWindowFromBar(windowId: Int) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(forWindowId: windowId) else { return }
        navigateToWindowInternal(handle: entry.handle, workspaceId: entry.workspaceId)
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
