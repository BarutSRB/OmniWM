import AppKit
import Foundation

@MainActor @Observable
final class WMController {
    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private var focusFollowsMouseEnabled: Bool = false
    private var moveMouseToFocusedWindowEnabled: Bool = false
    private(set) var workspaceBarVersion: Int = 0

    private let settings: SettingsStore
    private let workspaceManager: WorkspaceManager
    private let hotkeys = HotkeyCenter()
    private let secureInputMonitor = SecureInputMonitor()
    private var wasHotkeysEnabledBeforeSecureInput = true
    private let lockScreenObserver = LockScreenObserver()
    private let windowStateCache = WindowStateCache()
    private var isLockScreenActive: Bool = false
    private let axManager = AXManager()
    private var focusedHandle: WindowHandle?
    private var isNonManagedFocusActive: Bool = false
    private var isAppFullscreenActive: Bool = false
    private var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] = [:]

    private var activeMonitorId: Monitor.ID?
    private var previousMonitorId: Monitor.ID?

    private var niriEngine: NiriLayoutEngine?

    private var displayObserver: DisplayConfigurationObserver?

    private let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    private lazy var borderManager: BorderManager = .init()
    @ObservationIgnored
    private lazy var workspaceBarManager: WorkspaceBarManager = .init()

    private var appActivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?

    private var hiddenAppPIDs: Set<pid_t> = []

    private var appRulesByBundleId: [String: AppRule] = [:]
    private let appInfoCache = AppInfoCache()

    private var mouseEventHandler: MouseEventHandler?
    private var commandHandler: CommandHandler?
    private var workspaceNavigationHandler: WorkspaceNavigationHandler?
    private var axEventHandler: AXEventHandler?
    private var layoutRefreshController: LayoutRefreshController?

    let animationClock = AnimationClock()

    init(settings: SettingsStore) {
        self.settings = settings
        workspaceManager = WorkspaceManager(settings: settings)
        workspaceManager.updateAnimationClock(animationClock)
        hotkeys.onCommand = { [weak self] command in
            self?.commandHandler?.handle(command)
        }
        tabbedOverlayManager.onSelect = { [weak self] workspaceId, columnId, index in
            self?.layoutRefreshController?.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, index: index)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        hotkeysEnabled = enabled
        enabled ? hotkeys.start() : hotkeys.stop()
    }

    func setGapSize(_ size: Double) {
        workspaceManager.setGaps(to: size)
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        workspaceManager.setOuterGaps(left: left, right: right, top: top, bottom: bottom)
    }

    func setBordersEnabled(_ enabled: Bool) {
        borderManager.setEnabled(enabled)
    }

    func updateBorderConfig(_ config: BorderConfig) {
        borderManager.updateConfig(config)
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if enabled {
            workspaceBarManager.setup(controller: self, settings: settings)
        } else {
            workspaceBarManager.removeAllBars()
        }
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
        }
    }

    func updateWorkspaceBar() {
        workspaceBarVersion += 1
        workspaceBarManager.update()
    }

    func updateWorkspaceBarSettings() {
        workspaceBarManager.updateSettings()
    }

    func updateMonitorOrientations() {
        let monitors = workspaceManager.monitors
        for monitor in monitors {
            let orientation = settings.effectiveOrientation(for: monitor)
            niriEngine?.monitors[monitor.id]?.updateOrientation(orientation)
        }
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    func updateMonitorNiriSettings() {
        guard let engine = niriEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedNiriSettings(for: monitor.name)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    func workspaceBarItems(for monitor: Monitor, deduplicate: Bool, hideEmpty: Bool) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id)

        if hideEmpty {
            workspaces = workspaces.filter { !workspaceManager.entries(in: $0.id).isEmpty }
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id

        return workspaces.map { workspace in
            let entries = workspaceManager.entries(in: workspace.id)
            let orderMap = workspaceBarOrderMap(for: workspace.id)
            let orderedEntries = sortWorkspaceBarEntries(entries, orderMap: orderMap)
            let useLayoutOrder = orderMap?.isEmpty == false
            let windows: [WorkspaceBarWindowItem] = if deduplicate {
                createDedupedWindowItems(entries: orderedEntries, useLayoutOrder: useLayoutOrder)
            } else {
                createIndividualWindowItems(entries: orderedEntries)
            }

            return WorkspaceBarItem(
                id: workspace.id,
                name: settings.displayName(for: workspace.name),
                isFocused: workspace.id == activeWorkspaceId,
                windows: windows
            )
        }
    }

    private struct WorkspaceBarSortKey {
        let group: Int
        let primary: Int
        let secondary: Int
    }

    private func workspaceBarOrderMap(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> [WindowHandle: WorkspaceBarSortKey]? {
        guard let engine = niriEngine else { return nil }

        var order: [WindowHandle: WorkspaceBarSortKey] = [:]
        let columns = engine.columns(in: workspaceId)

        for (colIdx, column) in columns.enumerated() {
            for (rowIdx, window) in column.windowNodes.enumerated() {
                order[window.handle] = WorkspaceBarSortKey(group: 0, primary: colIdx, secondary: rowIdx)
            }
        }

        return order
    }

    private func sortWorkspaceBarEntries(
        _ entries: [WindowModel.Entry],
        orderMap: [WindowHandle: WorkspaceBarSortKey]?
    ) -> [WindowModel.Entry] {
        guard let orderMap else { return entries }
        let fallbackOrder = Dictionary(uniqueKeysWithValues: entries.enumerated()
            .map { ($0.element.handle, $0.offset) })

        return entries.sorted { lhs, rhs in
            let lhsKey = orderMap[lhs.handle] ?? WorkspaceBarSortKey(group: 2, primary: Int.max, secondary: Int.max)
            let rhsKey = orderMap[rhs.handle] ?? WorkspaceBarSortKey(group: 2, primary: Int.max, secondary: Int.max)

            if lhsKey.group != rhsKey.group { return lhsKey.group < rhsKey.group }
            if lhsKey.primary != rhsKey.primary { return lhsKey.primary < rhsKey.primary }
            if lhsKey.secondary != rhsKey.secondary { return lhsKey.secondary < rhsKey.secondary }

            let lhsFallback = fallbackOrder[lhs.handle] ?? 0
            let rhsFallback = fallbackOrder[rhs.handle] ?? 0
            return lhsFallback < rhsFallback
        }
    }

    private func createDedupedWindowItems(
        entries: [WindowModel.Entry],
        useLayoutOrder: Bool
    ) -> [WorkspaceBarWindowItem] {
        if useLayoutOrder {
            var groupedByApp: [String: [WindowModel.Entry]] = [:]
            var orderedAppNames: [String] = []

            for entry in entries {
                let appName = appInfoCache.name(for: entry.handle.pid)

                if groupedByApp[appName] == nil {
                    groupedByApp[appName] = []
                    orderedAppNames.append(appName)
                }

                groupedByApp[appName]?.append(entry)
            }

            return orderedAppNames.compactMap { appName in
                guard let appEntries = groupedByApp[appName], let firstEntry = appEntries.first else { return nil }
                let appInfo = appInfoCache.info(for: firstEntry.handle.pid)
                let anyFocused = appEntries.contains { $0.handle.id == focusedHandle?.id }

                let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: getWindowTitle(for: entry) ?? appName,
                        isFocused: entry.handle.id == focusedHandle?.id
                    )
                }

                return WorkspaceBarWindowItem(
                    id: firstEntry.handle.id,
                    windowId: firstEntry.windowId,
                    appName: appName,
                    icon: appInfo.icon,
                    isFocused: anyFocused,
                    windowCount: appEntries.count,
                    allWindows: windowInfos
                )
            }
        }

        let groupedByApp = Dictionary(grouping: entries) { entry -> String in
            appInfoCache.name(for: entry.handle.pid)
        }

        return groupedByApp.map { appName, appEntries -> WorkspaceBarWindowItem in
            let firstEntry = appEntries.first!
            let appInfo = appInfoCache.info(for: firstEntry.handle.pid)
            let anyFocused = appEntries.contains { $0.handle.id == focusedHandle?.id }

            let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                WorkspaceBarWindowInfo(
                    id: entry.handle.id,
                    windowId: entry.windowId,
                    title: getWindowTitle(for: entry) ?? appName,
                    isFocused: entry.handle.id == focusedHandle?.id
                )
            }

            return WorkspaceBarWindowItem(
                id: firstEntry.handle.id,
                windowId: firstEntry.windowId,
                appName: appName,
                icon: appInfo.icon,
                isFocused: anyFocused,
                windowCount: appEntries.count,
                allWindows: windowInfos
            )
        }.sorted { $0.appName < $1.appName }
    }

    private func createIndividualWindowItems(entries: [WindowModel.Entry]) -> [WorkspaceBarWindowItem] {
        entries.map { entry in
            let appInfo = appInfoCache.info(for: entry.handle.pid)
            let title = getWindowTitle(for: entry) ?? appInfo.name

            return WorkspaceBarWindowItem(
                id: entry.handle.id,
                windowId: entry.windowId,
                appName: appInfo.name,
                icon: appInfo.icon,
                isFocused: entry.handle.id == focusedHandle?.id,
                windowCount: 1,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.handle.id == focusedHandle?.id
                    )
                ]
            )
        }
    }

    private func getWindowTitle(for entry: WindowModel.Entry) -> String? {
        guard let title = try? AXWindowService.title(entry.axRef), !title.isEmpty else { return nil }
        return title
    }

    func focusWorkspaceFromBar(named name: String) {
        if let currentWorkspace = activeWorkspace() {
            workspaceNavigationHandler?.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = workspaceManager.focusWorkspace(named: name) else { return }

        let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            previousMonitorId = currentMonitorId
        }
        activeMonitorId = result.monitor.id

        focusedHandle = lastFocusedByWorkspace[result.workspace.id]
            ?? workspaceManager.entries(in: result.workspace.id).first?.handle

        layoutRefreshController?.refreshWindowsAndLayout()
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func focusWindowFromBar(windowId: Int) {
        guard let engine = niriEngine else { return }

        var foundEntry: WindowModel.Entry?
        for ws in workspaceManager.workspaces {
            for entry in workspaceManager.entries(in: ws.id) {
                if entry.windowId == windowId {
                    foundEntry = entry
                    break
                }
            }
            if foundEntry != nil { break }
        }

        guard let entry = foundEntry else { return }

        let currentWsId = activeWorkspace()?.id

        if entry.workspaceId != currentWsId {
            let wsName = workspaceManager.descriptor(for: entry.workspaceId)?.name ?? ""
            if let result = workspaceManager.focusWorkspace(named: wsName) {
                activeMonitorId = result.monitor.id
                syncMonitorsToNiriEngine()
            }
        }

        if let niriWindow = engine.findNode(for: entry.handle) {
            var state = workspaceManager.niriViewportState(for: entry.workspaceId)
            state.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: entry.workspaceId),
               let colIdx = engine.columnIndex(of: column, in: entry.workspaceId),
               let monitor = workspaceManager.monitor(for: entry.workspaceId)
            {
                let cols = engine.columns(in: entry.workspaceId)
                let gap = CGFloat(workspaceManager.gaps)
                state.snapToColumn(
                    colIdx,
                    columns: cols,
                    gap: gap,
                    viewportWidth: monitor.visibleFrame.width
                )
            }

            workspaceManager.updateNiriViewportState(state, for: entry.workspaceId)
        }

        layoutRefreshController?.refreshWindowsAndLayout()

        focusedHandle = entry.handle
        lastFocusedByWorkspace[entry.workspaceId] = entry.handle
        focusWindow(entry.handle)
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func insetWorkingFrame(from frame: CGRect) -> CGRect {
        let outer = workspaceManager.outerGaps
        let newWidth = max(0, frame.width - outer.left - outer.right)
        let newHeight = max(0, frame.height - outer.top - outer.bottom)
        return CGRect(
            x: frame.origin.x + outer.left,
            y: frame.origin.y + outer.bottom,
            width: newWidth,
            height: newHeight
        )
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding]) {
        hotkeys.updateBindings(bindings)
    }

    func updateWorkspaceConfig() {
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        layoutRefreshController?.refreshWindowsAndLayout()
        updateWorkspaceBar()
    }

    func rebuildAppRulesCache() {
        appRulesByBundleId = Dictionary(
            settings.appRules.map { ($0.bundleId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func updateAppRules() {
        rebuildAppRulesCache()
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    var hotkeyRegistrationFailures: Set<HotkeyCommand> {
        hotkeys.registrationFailures
    }

    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await axManager.ensurePermission()
            guard granted else {
                isEnabled = false
                hotkeysEnabled = false
                hotkeys.stop()
                return
            }
            startServices()
        }
    }

    private func startServices() {
        layoutRefreshController = LayoutRefreshController(controller: self)
        axEventHandler = AXEventHandler(controller: self)
        mouseEventHandler = MouseEventHandler(controller: self)
        workspaceNavigationHandler = WorkspaceNavigationHandler(controller: self)
        commandHandler = CommandHandler(controller: self)

        if hotkeysEnabled {
            hotkeys.start()
        }
        axManager.onWindowEvent = { [weak self] event in
            Task { @MainActor in
                self?.axEventHandler?.handleEvent(event)
            }
        }
        axManager.onAppLaunched = { [weak self] app in
            guard let self else { return }
            Task { @MainActor in
                _ = await self.axManager.windowsForApp(app)
                self.layoutRefreshController?.scheduleRefreshSession(.axWindowCreated)
            }
        }
        axManager.onAppTerminated = { [weak self] pid in
            guard let self else { return }
            self.workspaceManager.removeWindowsForApp(pid: pid)
            self.layoutRefreshController?.refreshWindowsAndLayout()
        }
        axManager.onWindowDestroyedUnknown = { [weak self] in
            self?.layoutRefreshController?.refreshWindowsAndLayout()
        }
        setupWorkspaceObservation()
        mouseEventHandler?.setup()
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppHideObservers()
        workspaceManager.onGapsChanged = { [weak self] in
            self?.layoutRefreshController?.refreshWindowsAndLayout()
        }

        layoutRefreshController?.refreshWindowsAndLayout()
        layoutRefreshController?.startRefreshTimer()
        startSecureInputMonitor()
        startLockScreenObserver()
    }

    private func startLockScreenObserver() {
        lockScreenObserver.onLockDetected = { [weak self] in
            self?.handleLockScreenDetected()
        }
        lockScreenObserver.onUnlockDetected = { [weak self] in
            self?.handleLockScreenEnded()
        }
        lockScreenObserver.start()
    }

    private func handleLockScreenDetected() {
        isLockScreenActive = true
        windowStateCache.captureState(
            workspaceManager: workspaceManager,
            niriEngine: niriEngine
        )
    }

    private func handleLockScreenEnded() {
        isLockScreenActive = false
        layoutRefreshController?.refreshWindowsAndLayout()
        workspaceBarManager.update()
    }

    private func startSecureInputMonitor() {
        secureInputMonitor.start { [weak self] isSecure in
            self?.handleSecureInputChange(isSecure)
        }
    }

    private func handleSecureInputChange(_ isSecure: Bool) {
        if isSecure {
            wasHotkeysEnabledBeforeSecureInput = hotkeysEnabled
            if hotkeysEnabled {
                hotkeys.stop()
                SecureInputIndicatorController.shared.show()
            }
        } else {
            SecureInputIndicatorController.shared.hide()
            if wasHotkeysEnabledBeforeSecureInput {
                hotkeys.start()
            }
        }
    }

    private func setupDisplayObserver() {
        displayObserver = DisplayConfigurationObserver()
        displayObserver?.setEventHandler { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayEvent()
            }
        }
    }

    private func handleDisplayEvent() {
        handleMonitorConfigurationChanged()
    }

    private func handleMonitorConfigurationChanged() {
        workspaceManager.updateMonitors(Monitor.current())
        syncMonitorsToNiriEngine()

        if let activeMonitorId, !workspaceManager.monitors.contains(where: { $0.id == activeMonitorId }) {
            self.activeMonitorId = workspaceManager.monitors.first?.id
        }
        if let previousMonitorId, !workspaceManager.monitors.contains(where: { $0.id == previousMonitorId }) {
            self.previousMonitorId = nil
        }

        layoutRefreshController?.refreshWindowsAndLayout()
    }

    private func setupWorkspaceObservation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func workspaceDidChange() {
        borderManager.hideBorder()
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    private func setupAppActivationObserver() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            Task { @MainActor in
                self?.axEventHandler?.handleAppActivation(pid: pid)
            }
        }
    }

    private func setupAppHideObservers() {
        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.axEventHandler?.handleAppHidden(pid: app.processIdentifier)
            }
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.axEventHandler?.handleAppUnhidden(pid: app.processIdentifier)
            }
        }
    }

    func stop() {
        commandHandler?.cleanup()
        commandHandler = nil

        layoutRefreshController?.resetState()
        layoutRefreshController?.stopRefreshTimer()
        layoutRefreshController = nil

        mouseEventHandler?.cleanup()
        mouseEventHandler = nil

        workspaceNavigationHandler = nil
        axEventHandler = nil

        tabbedOverlayManager.removeAll()
        borderManager.cleanup()
        workspaceBarManager.cleanup()

        axManager.cleanup()

        displayObserver = nil

        secureInputMonitor.stop()
        SecureInputIndicatorController.shared.hide()
        lockScreenObserver.stop()
        hotkeys.stop()
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func enableNiriLayout(
        maxWindowsPerColumn: Int = 3,
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: maxWindowsPerColumn)
        engine.centerFocusedColumn = centerFocusedColumn
        engine.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        engine.renderStyle.tabIndicatorHeight = TabbedColumnOverlayManager.tabIndicatorHeight
        engine.animationClock = animationClock
        niriEngine = engine

        syncMonitorsToNiriEngine()

        layoutRefreshController?.refreshWindowsAndLayout()
    }

    func syncMonitorsToNiriEngine() {
        guard let engine = niriEngine else { return }

        let currentMonitors = workspaceManager.monitors
        engine.updateMonitors(currentMonitors)

        for workspace in workspaceManager.workspaces {
            guard let monitor = workspaceManager.monitor(for: workspace.id) else { continue }
            engine.moveWorkspace(workspace.id, to: monitor.id, monitor: monitor)
        }

        for monitor in currentMonitors {
            let orderedWorkspaceIds = workspaceManager.workspaces(on: monitor.id).map(\.id)
            if let niriMonitor = engine.monitor(for: monitor.id) {
                niriMonitor.workspaceOrder = orderedWorkspaceIds
                niriMonitor.animationClock = animationClock
                if let activeWorkspace = workspaceManager.activeWorkspace(on: monitor.id) {
                    niriMonitor.activateWorkspace(activeWorkspace.id)
                }
            }
            let resolved = settings.resolvedNiriSettings(for: monitor.name)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
    }

    func updateNiriConfig(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        animationsEnabled: Bool? = nil
    ) {
        niriEngine?.updateConfiguration(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            animationsEnabled: animationsEnabled
        )
        workspaceManager.updateAnimationSettings(animationsEnabled: animationsEnabled)
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    func monitorForInteraction() -> Monitor? {
        if let focused = focusedHandle,
           let workspaceId = workspaceManager.workspace(for: focused),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    func activeWorkspace() -> WorkspaceDescriptor? {
        guard let monitor = monitorForInteraction() else { return nil }
        return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
    }

    func resolveWorkspaceForNewWindow(
        axRef: AXWindowRef,
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
        if let bundleId = appInfoCache.bundleId(for: pid),
           let rule = appRulesByBundleId[bundleId],
           let wsName = rule.assignToWorkspace,
           let wsId = workspaceManager.workspaceId(for: wsName, createIfMissing: true)
        {
            return wsId
        }

        if let frame = try? AXWindowService.frame(axRef) {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let monitor = workspaceManager.monitors.first(where: { $0.visibleFrame.contains(center) }),
               let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
            {
                return workspace.id
            }
        }
        if let fallbackWorkspaceId {
            return fallbackWorkspaceId
        }
        return workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first!.id
    }

    func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        for ws in workspaceManager.workspaces {
            let entries = workspaceManager.entries(in: ws.id)
            if entries.contains(where: { $0.windowId == windowId && $0.handle.pid == pid }) {
                return ws.id
            }
        }
        return nil
    }

    func focusWindow(_ handle: WindowHandle) {
        axEventHandler?.focusWindow(handle)
    }

    func ensureFocusedHandleValid(in workspaceId: WorkspaceDescriptor.ID) {
        axEventHandler?.ensureFocusedHandleValid(in: workspaceId)
    }

    func updateBorderIfAllowed(handle: WindowHandle, frame: CGRect, windowId: Int) {
        axEventHandler?.updateBorderIfAllowed(handle: handle, frame: frame, windowId: windowId)
    }

    func openWindowFinder() {
        let entries = workspaceManager.allEntries()
        var items: [WindowFinderItem] = []

        for entry in entries {
            guard entry.layoutReason == .standard else { continue }

            let title = (try? AXWindowService.title(entry.axRef)) ?? ""

            let appInfo = appInfoCache.info(for: entry.handle.pid)

            let workspaceName = workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

            items.append(WindowFinderItem(
                id: entry.handle.id,
                handle: entry.handle,
                title: title,
                appName: appInfo.name,
                appIcon: appInfo.icon,
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
        guard settings.menuAnywhereNativeEnabled else { return }
        MenuAnywhereController.shared.showNativeMenu(at: settings.menuAnywherePosition)
    }

    func openMenuPalette() {
        guard settings.menuAnywherePaletteEnabled else { return }

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
            at: settings.menuAnywherePosition,
            showShortcuts: settings.menuAnywhereShowShortcuts,
            targetApp: targetApp,
            targetWindow: targetWindow
        )
    }

    func raiseAllFloatingWindows() {
        guard let monitor = monitorForInteraction() else { return }

        var lastRaisedApp: NSRunningApplication?
        var lastRaisedWindow: AXUIElement?
        var ownAppHasFloatingWindows = false
        let ownPid = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                let axRef = AXWindowRef(id: UUID(), element: window)

                guard let windowFrame = try? AXWindowService.frame(axRef) else { continue }
                let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
                guard monitor.visibleFrame.contains(windowCenter) else { continue }

                let hasAlwaysFloatRule = app.bundleIdentifier.flatMap { appRulesByBundleId[$0]?.alwaysFloat } == true

                let windowType = AXWindowService.windowType(axRef, appPolicy: app.activationPolicy, bundleId: app.bundleIdentifier)
                guard windowType == .floating || hasAlwaysFloatRule else { continue }

                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)

                if app.processIdentifier == ownPid {
                    ownAppHasFloatingWindows = true
                } else {
                    lastRaisedApp = app
                    lastRaisedWindow = window
                }
            }
        }

        if let app = lastRaisedApp, let window = lastRaisedWindow {
            app.activate()
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            _ = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        }

        if ownAppHasFloatingWindows {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func navigateToWindow(_ item: WindowFinderItem) {
        guard let engine = niriEngine else { return }
        guard let entry = workspaceManager.entry(for: item.handle) else { return }

        let currentWsId = activeWorkspace()?.id

        if entry.workspaceId != currentWsId {
            let wsName = workspaceManager.descriptor(for: entry.workspaceId)?.name ?? ""
            if let result = workspaceManager.focusWorkspace(named: wsName) {
                activeMonitorId = result.monitor.id
                syncMonitorsToNiriEngine()
            }
        }

        if let niriWindow = engine.findNode(for: item.handle) {
            var state = workspaceManager.niriViewportState(for: entry.workspaceId)
            state.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: entry.workspaceId),
               let colIdx = engine.columnIndex(of: column, in: entry.workspaceId),
               let monitor = workspaceManager.monitor(for: entry.workspaceId)
            {
                let cols = engine.columns(in: entry.workspaceId)
                let gap = CGFloat(workspaceManager.gaps)
                state.snapToColumn(
                    colIdx,
                    columns: cols,
                    gap: gap,
                    viewportWidth: monitor.visibleFrame.width
                )
            }

            workspaceManager.updateNiriViewportState(state, for: entry.workspaceId)
        }

        layoutRefreshController?.refreshWindowsAndLayout()

        focusedHandle = item.handle
        lastFocusedByWorkspace[entry.workspaceId] = item.handle
        focusWindow(item.handle)
    }

    func moveMouseToWindow(_ handle: WindowHandle) {
        guard let entry = workspaceManager.entry(for: handle) else { return }

        let frame: CGRect
        let wsId = entry.workspaceId

        if let engine = niriEngine,
           let monitor = workspaceManager.monitor(for: wsId)
        {
            let state = workspaceManager.niriViewportState(for: wsId)
            let workingFrame = insetWorkingFrame(from: monitor.visibleFrame)
            let gaps = CGFloat(workspaceManager.gaps)
            guard let targetFrame = engine.targetFrameForWindow(handle, in: wsId, state: state, workingFrame: workingFrame, gaps: gaps) else {
                return
            }
            frame = targetFrame
        } else if let axFrame = try? AXWindowService.frame(entry.axRef) {
            frame = axFrame
        } else {
            return
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            let flippedY = screen.frame.height - center.y + screen.frame.origin.y
            CGWarpMouseCursorPosition(CGPoint(x: center.x, y: flippedY))
        } else {
            CGWarpMouseCursorPosition(center)
        }
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let appInfo = appInfoCache.info(for: entry.handle.pid)
            guard let bundleId = appInfo.bundleId else { continue }

            if appInfoMap[bundleId] != nil { continue }

            let frame = (try? AXWindowService.frame(entry.axRef)) ?? .zero

            appInfoMap[bundleId] = RunningAppInfo(
                id: bundleId,
                bundleId: bundleId,
                appName: appInfo.name,
                icon: appInfo.icon,
                windowSize: frame.size
            )
        }

        return appInfoMap.values.sorted { $0.appName < $1.appName }
    }
}

extension WMController {
    var internalNiriEngine: NiriLayoutEngine? { niriEngine }
    var internalWorkspaceManager: WorkspaceManager { workspaceManager }
    var internalSettings: SettingsStore { settings }
    var internalAXManager: AXManager { axManager }
    var internalBorderManager: BorderManager { borderManager }
    var internalTabbedOverlayManager: TabbedColumnOverlayManager { tabbedOverlayManager }
    var internalWindowStateCache: WindowStateCache { windowStateCache }
    var internalLockScreenObserver: LockScreenObserver { lockScreenObserver }
    var internalAppRulesByBundleId: [String: AppRule] { appRulesByBundleId }
    var internalAppInfoCache: AppInfoCache { appInfoCache }

    var internalFocusedHandle: WindowHandle? {
        get { focusedHandle }
        set { focusedHandle = newValue }
    }

    var internalLastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] {
        get { lastFocusedByWorkspace }
        set { lastFocusedByWorkspace = newValue }
    }

    var internalActiveMonitorId: Monitor.ID? {
        get { activeMonitorId }
        set { activeMonitorId = newValue }
    }

    var internalPreviousMonitorId: Monitor.ID? {
        get { previousMonitorId }
        set { previousMonitorId = newValue }
    }

    var internalIsNonManagedFocusActive: Bool {
        get { isNonManagedFocusActive }
        set { isNonManagedFocusActive = newValue }
    }

    var internalIsAppFullscreenActive: Bool {
        get { isAppFullscreenActive }
        set { isAppFullscreenActive = newValue }
    }

    var internalIsLockScreenActive: Bool { isLockScreenActive }

    var internalFocusFollowsMouseEnabled: Bool { focusFollowsMouseEnabled }

    var internalMoveMouseToFocusedWindowEnabled: Bool { moveMouseToFocusedWindowEnabled }

    var internalHiddenAppPIDs: Set<pid_t> {
        get { hiddenAppPIDs }
        set { hiddenAppPIDs = newValue }
    }

    var internalLayoutRefreshController: LayoutRefreshController? { layoutRefreshController }
    var internalWorkspaceNavigationHandler: WorkspaceNavigationHandler? { workspaceNavigationHandler }
}
