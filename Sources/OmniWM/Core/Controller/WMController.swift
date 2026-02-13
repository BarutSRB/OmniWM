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
    private var isLockScreenActive: Bool = false
    private let axManager = AXManager()
    let appInfoCache = AppInfoCache()
    private var focusedHandle: WindowHandle? {
        didSet {
            updateActiveMonitorFromFocusedHandle(focusedHandle)
            notifyFocusChangesIfNeeded()
        }
    }
    private var isNonManagedFocusActive: Bool = false
    private var isAppFullscreenActive: Bool = false
    private var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] = [:]

    private var activeMonitorId: Monitor.ID? {
        didSet {
            notifyFocusChangesIfNeeded()
        }
    }
    private var previousMonitorId: Monitor.ID?
    private var suppressActiveMonitorUpdate: Bool = false

    private var lastNotifiedWorkspaceId: WorkspaceDescriptor.ID?
    private var lastNotifiedMonitorId: Monitor.ID?
    private var lastNotifiedFocusedHandleId: UUID?
    private var lastNotifiedFocusedWindowId: Int?

    private var niriEngine: NiriLayoutEngine?
    private var dwindleEngine: DwindleLayoutEngine?

    private var displayObserver: DisplayConfigurationObserver?

    private let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    private lazy var borderManager: BorderManager = .init()
    @ObservationIgnored
    private lazy var workspaceBarManager: WorkspaceBarManager = .init()
    @ObservationIgnored
    private lazy var hiddenBarController: HiddenBarController = .init(settings: settings)
    @ObservationIgnored
    private lazy var quakeTerminalController: QuakeTerminalController = .init(settings: settings)
    @ObservationIgnored
    private lazy var overviewController: OverviewController = {
        let controller = OverviewController(wmController: self)
        controller.onActivateWindow = { [weak self] handle, workspaceId in
            self?.activateWindowFromOverview(handle: handle, workspaceId: workspaceId)
        }
        controller.onCloseWindow = { [weak self] handle in
            self?.closeWindowFromOverview(handle: handle)
        }
        return controller
    }()

    private var appActivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?

    private var hiddenAppPIDs: Set<pid_t> = []

    private var appRulesByBundleId: [String: AppRule] = [:]

    private var mouseEventHandler: MouseEventHandler?
    private var mouseWarpHandler: MouseWarpHandler?
    private var commandHandler: CommandHandler?
    private var workspaceNavigationHandler: WorkspaceNavigationHandler?
    private var axEventHandler: AXEventHandler?
    private var layoutRefreshController: LayoutRefreshController?
    private var hasStartedServices = false
    private var permissionCheckerTask: Task<Void, Never>?

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

    func setHiddenBarEnabled(_ enabled: Bool) {
        if enabled {
            hiddenBarController.setup()
        } else {
            hiddenBarController.cleanup()
        }
    }

    func toggleHiddenBar() {
        guard settings.hiddenBarEnabled else { return }
        hiddenBarController.toggle()
    }

    func setQuakeTerminalEnabled(_ enabled: Bool) {
        if enabled {
            quakeTerminalController.setup()
        } else {
            quakeTerminalController.cleanup()
        }
    }

    func toggleQuakeTerminal() {
        guard settings.quakeTerminalEnabled else { return }
        quakeTerminalController.toggle()
    }

    func reloadQuakeTerminalOpacity() {
        quakeTerminalController.reloadOpacityConfig()
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

    func updateMonitorDwindleSettings() {
        guard let engine = dwindleEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedDwindleSettings(for: monitor.name)
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
            let useLayoutOrder = !(orderMap?.isEmpty ?? true)
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
                let appName = appInfoCache.name(for: entry.handle.pid) ?? "Unknown"

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
                    icon: appInfo?.icon,
                    isFocused: anyFocused,
                    windowCount: appEntries.count,
                    allWindows: windowInfos
                )
            }
        }

        let groupedByApp = Dictionary(grouping: entries) { entry -> String in
            appInfoCache.name(for: entry.handle.pid) ?? "Unknown"
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
                icon: appInfo?.icon,
                isFocused: anyFocused,
                windowCount: appEntries.count,
                allWindows: windowInfos
            )
        }.sorted { $0.appName < $1.appName }
    }

    private func createIndividualWindowItems(entries: [WindowModel.Entry]) -> [WorkspaceBarWindowItem] {
        entries.map { entry in
            let appInfo = appInfoCache.info(for: entry.handle.pid)
            let appName = appInfo?.name ?? "Unknown"
            let title = getWindowTitle(for: entry) ?? appName

            return WorkspaceBarWindowItem(
                id: entry.handle.id,
                windowId: entry.windowId,
                appName: appName,
                icon: appInfo?.icon,
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
        guard let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
              !title.isEmpty else { return nil }
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

        focusedHandle = resolveWorkspaceFocus(for: result.workspace.id)

        layoutRefreshController?.refreshWindowsAndLayout()
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func focusWindowFromBar(windowId: Int) {
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
        navigateToWindowInternal(handle: entry.handle, workspaceId: entry.workspaceId)
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func setMouseWarpEnabled(_ enabled: Bool) {
        if enabled {
            mouseWarpHandler?.setup()
        } else {
            mouseWarpHandler?.cleanup()
        }
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
        return insetWorkingFrame(from: monitor.visibleFrame, scale: scale)
    }

    func insetWorkingFrame(from frame: CGRect, scale: CGFloat = 2.0) -> CGRect {
        let outer = workspaceManager.outerGaps
        let struts = Struts(
            left: outer.left,
            right: outer.right,
            top: outer.top,
            bottom: outer.bottom
        )
        return computeWorkingArea(
            parentArea: frame,
            scale: scale,
            struts: struts
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
        permissionCheckerTask?.cancel()
        permissionCheckerTask = Task { @MainActor [weak self] in
            for await granted in AccessibilityPermissionMonitor.shared.stream(initial: true) {
                guard let self, !Task.isCancelled else { return }

                if granted {
                    if !hasStartedServices {
                        startServices()
                    }
                } else {
                    _ = axManager.requestPermission()
                    isEnabled = false
                    hotkeysEnabled = false
                    hotkeys.stop()
                }
            }
        }
    }

    private func startServices() {
        guard !hasStartedServices else {
            return
        }
        hasStartedServices = true
        layoutRefreshController = LayoutRefreshController(controller: self)
        axEventHandler = AXEventHandler(controller: self)
        mouseEventHandler = MouseEventHandler(controller: self)
        mouseWarpHandler = MouseWarpHandler(controller: self)
        workspaceNavigationHandler = WorkspaceNavigationHandler(controller: self)
        commandHandler = CommandHandler(controller: self)

        if hotkeysEnabled {
            hotkeys.start()
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
            workspaceManager.removeWindowsForApp(pid: pid)
            layoutRefreshController?.refreshWindowsAndLayout()
        }
        AppAXContext.onWindowDestroyed = { [weak self] pid, windowId in
            guard let self else { return }
            axEventHandler?.handleRemoved(pid: pid, winId: windowId)
        }
        AppAXContext.onWindowDestroyedUnknown = { [weak self] in
            self?.layoutRefreshController?.refreshWindowsAndLayout()
        }
        AppAXContext.onFocusedWindowChanged = { [weak self] pid in
            self?.axEventHandler?.handleAppActivation(pid: pid)
        }
        setupWorkspaceObservation()
        mouseEventHandler?.setup()
        if settings.mouseWarpEnabled {
            mouseWarpHandler?.setup()
        }
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppHideObservers()
        workspaceManager.onGapsChanged = { [weak self] in
            self?.layoutRefreshController?.refreshWindowsAndLayout()
        }

        layoutRefreshController?.refreshWindowsAndLayout()
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
        displayObserver?.setEventHandler { [weak self] event in
            Task { @MainActor in
                self?.handleDisplayEvent(event)
            }
        }
    }

    private func handleDisplayEvent(_ event: DisplayConfigurationObserver.DisplayEvent) {
        switch event {
        case let .disconnected(monitorId, outputId):
            handleMonitorDisconnect(monitorId: monitorId, outputId: outputId)
        case .connected, .reconfigured:
            break
        }
        handleMonitorConfigurationChanged()
    }

    private func handleMonitorDisconnect(monitorId: Monitor.ID, outputId: OutputId) {
        layoutRefreshController?.cleanupForMonitorDisconnect(displayId: outputId.displayId, migrateAnimations: false)

        if activeMonitorId == monitorId {
            activeMonitorId = workspaceManager.monitors.first?.id
        }
        if previousMonitorId == monitorId {
            previousMonitorId = nil
        }

        niriEngine?.cleanupRemovedMonitor(monitorId)
        dwindleEngine?.cleanupRemovedMonitor(monitorId)
    }

    private func handleMonitorConfigurationChanged() {
        workspaceManager.updateMonitors(Monitor.current())
        workspaceManager.reconcileAfterMonitorChange()
        syncMonitorsToNiriEngine()

        if let activeMonitorId, !workspaceManager.monitors.contains(where: { $0.id == activeMonitorId }) {
            self.activeMonitorId = workspaceManager.monitors.first?.id
        }
        if let previousMonitorId, !workspaceManager.monitors.contains(where: { $0.id == previousMonitorId }) {
            self.previousMonitorId = nil
        }

        let focusedWsId = focusedHandle.flatMap { workspaceManager.workspace(for: $0) }
        workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWsId)

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
        hasStartedServices = false
        commandHandler = nil

        layoutRefreshController?.resetState()
        layoutRefreshController = nil

        mouseEventHandler?.cleanup()
        mouseEventHandler = nil

        mouseWarpHandler?.cleanup()
        mouseWarpHandler = nil

        workspaceNavigationHandler = nil
        axEventHandler = nil

        tabbedOverlayManager.removeAll()
        borderManager.cleanup()
        workspaceBarManager.cleanup()
        hiddenBarController.cleanup()

        axManager.cleanup()

        displayObserver = nil

        secureInputMonitor.stop()
        SecureInputIndicatorController.shared.hide()
        lockScreenObserver.stop()
        hotkeys.stop()
        permissionCheckerTask?.cancel()
        permissionCheckerTask = nil
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
        engine.renderStyle.tabIndicatorWidth = TabbedColumnOverlayManager.tabIndicatorWidth
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
        animationsEnabled: Bool? = nil,
        columnWidthPresets: [Double]? = nil
    ) {
        niriEngine?.updateConfiguration(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            animationsEnabled: animationsEnabled,
            presetColumnWidths: columnWidthPresets?.map { .proportion($0) }
        )
        workspaceManager.updateAnimationSettings(animationsEnabled: animationsEnabled)
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    func enableDwindleLayout() {
        let engine = DwindleLayoutEngine()
        engine.animationClock = animationClock
        dwindleEngine = engine
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    func updateDwindleConfig(
        smartSplit: Bool? = nil,
        defaultSplitRatio: CGFloat? = nil,
        splitWidthMultiplier: CGFloat? = nil,
        singleWindowAspectRatio: CGSize? = nil,
        innerGap: CGFloat? = nil,
        outerGapTop: CGFloat? = nil,
        outerGapBottom: CGFloat? = nil,
        outerGapLeft: CGFloat? = nil,
        outerGapRight: CGFloat? = nil
    ) {
        guard let engine = dwindleEngine else { return }
        if let v = smartSplit { engine.settings.smartSplit = v }
        if let v = defaultSplitRatio { engine.settings.defaultSplitRatio = v }
        if let v = splitWidthMultiplier { engine.settings.splitWidthMultiplier = v }
        if let v = singleWindowAspectRatio { engine.settings.singleWindowAspectRatio = v }
        if let v = innerGap { engine.settings.innerGap = v }
        if let v = outerGapTop { engine.settings.outerGapTop = v }
        if let v = outerGapBottom { engine.settings.outerGapBottom = v }
        if let v = outerGapLeft { engine.settings.outerGapLeft = v }
        if let v = outerGapRight { engine.settings.outerGapRight = v }
        layoutRefreshController?.refreshWindowsAndLayout()
    }

    private func postNotificationIfChanged<T: Equatable>(
        name: Notification.Name,
        current: T?,
        last: inout T?,
        info: [AnyHashable: Any]
    ) {
        guard current != last else { return }
        NotificationCenter.default.post(
            name: name,
            object: self,
            userInfo: info.isEmpty ? nil : info
        )
        last = current
    }

    private func notifyFocusChangesIfNeeded() {
        let currentWorkspaceId = focusedHandle
            .flatMap { workspaceManager.workspace(for: $0) }
            ?? activeWorkspace()?.id
        let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id

        let currentHandleId = focusedHandle?.id
        let currentWindowId = focusedHandle.flatMap { workspaceManager.entry(for: $0)?.windowId }

        if currentHandleId != lastNotifiedFocusedHandleId || currentWindowId != lastNotifiedFocusedWindowId {
            var info: [AnyHashable: Any] = [:]
            if let oldHandleId = lastNotifiedFocusedHandleId { info[OmniWMFocusNotificationKey.oldHandleId] = oldHandleId }
            if let newHandleId = currentHandleId { info[OmniWMFocusNotificationKey.newHandleId] = newHandleId }
            if let oldWindowId = lastNotifiedFocusedWindowId { info[OmniWMFocusNotificationKey.oldWindowId] = oldWindowId }
            if let newWindowId = currentWindowId { info[OmniWMFocusNotificationKey.newWindowId] = newWindowId }

            NotificationCenter.default.post(name: .omniwmFocusChanged, object: self, userInfo: info.isEmpty ? nil : info)
            lastNotifiedFocusedHandleId = currentHandleId
            lastNotifiedFocusedWindowId = currentWindowId
        }

        var workspaceInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceId] = oldId
            if let name = workspaceManager.descriptor(for: oldId)?.name { workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceName] = name }
        }
        if let newId = currentWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceId] = newId
            if let name = workspaceManager.descriptor(for: newId)?.name { workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceName] = name }
        }
        postNotificationIfChanged(name: .omniwmFocusedWorkspaceChanged, current: currentWorkspaceId, last: &lastNotifiedWorkspaceId, info: workspaceInfo)

        var monitorInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.oldMonitorIndex] = oldId.displayId
            if let name = workspaceManager.monitors.first(where: { $0.id == oldId })?.name { monitorInfo[OmniWMFocusNotificationKey.oldMonitorName] = name }
        }
        if let newId = currentMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.newMonitorIndex] = newId.displayId
            if let name = workspaceManager.monitors.first(where: { $0.id == newId })?.name { monitorInfo[OmniWMFocusNotificationKey.newMonitorName] = name }
        }
        postNotificationIfChanged(name: .omniwmFocusedMonitorChanged, current: currentMonitorId, last: &lastNotifiedMonitorId, info: monitorInfo)
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

    private func updateActiveMonitorFromFocusedHandle(_ handle: WindowHandle?) {
        guard !suppressActiveMonitorUpdate else { return }
        guard let handle,
              let workspaceId = workspaceManager.workspace(for: handle),
              let monitorId = workspaceManager.monitor(for: workspaceId)?.id
        else {
            return
        }

        if let currentId = activeMonitorId, currentId != monitorId {
            previousMonitorId = currentId
        }
        if activeMonitorId != monitorId {
            activeMonitorId = monitorId
        }
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

        if let monitor = monitorForInteraction(),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return workspace.id
        }

        if let frame = AXWindowService.framePreferFast(axRef) {
            let center = frame.center
            if let monitor = center.monitorApproximation(in: workspaceManager.monitors),
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

            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) ?? ""

            let appInfo = appInfoCache.info(for: entry.handle.pid)

            let workspaceName = workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

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

    func toggleOverview() {
        overviewController.toggle()
    }

    private func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard workspaceManager.entry(for: handle) != nil else { return }
        navigateToWindowInternal(handle: handle, workspaceId: workspaceId)
    }

    private func closeWindowFromOverview(handle: WindowHandle) {
        guard let entry = workspaceManager.entry(for: handle) else { return }

        let element = entry.axRef.element
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        var closeButton: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success {
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        }
    }

    func raiseAllFloatingWindows() {
        guard let monitor = monitorForInteraction() else { return }

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
            guard let appInfo = appInfoCache.info(for: pid),
                  appInfo.activationPolicy != .prohibited else { continue }

            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                guard let axRef = try? AXWindowRef(element: window),
                      windowIdSet.contains(UInt32(axRef.windowId)) else { continue }
                let windowId = axRef.windowId

                let hasAlwaysFloatRule = appInfo.bundleId.flatMap { appRulesByBundleId[$0]?.alwaysFloat } == true
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
        guard let entry = workspaceManager.entry(for: item.handle) else { return }
        navigateToWindowInternal(handle: item.handle, workspaceId: entry.workspaceId)
    }

    private func setFocus(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) {
        focusedHandle = handle
        lastFocusedByWorkspace[workspaceId] = handle
    }

    private func resolveWorkspaceFocus(for workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        lastFocusedByWorkspace[workspaceId]
            ?? workspaceManager.entries(in: workspaceId).first?.handle
    }

    private func navigateToWindowInternal(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let engine = niriEngine else { return }

        let currentWsId = activeWorkspace()?.id

        if workspaceId != currentWsId {
            let wsName = workspaceManager.descriptor(for: workspaceId)?.name ?? ""
            if let result = workspaceManager.focusWorkspace(named: wsName) {
                activeMonitorId = result.monitor.id
                syncMonitorsToNiriEngine()
            }
        }

        if let niriWindow = engine.findNode(for: handle) {
            var state = workspaceManager.niriViewportState(for: workspaceId)
            state.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: workspaceId),
               let colIdx = engine.columnIndex(of: column, in: workspaceId),
               let monitor = workspaceManager.monitor(for: workspaceId)
            {
                engine.activateWindow(niriWindow.id)

                let cols = engine.columns(in: workspaceId)
                let gap = CGFloat(workspaceManager.gaps)
                state.snapToColumn(
                    colIdx,
                    columns: cols,
                    gap: gap,
                    viewportWidth: monitor.visibleFrame.width
                )
            }

            workspaceManager.updateNiriViewportState(state, for: workspaceId)
        }

        layoutRefreshController?.refreshWindowsAndLayout()

        setFocus(handle, in: workspaceId)
        focusWindow(handle)
    }

    func moveMouseToWindow(_ handle: WindowHandle) {
        guard let entry = workspaceManager.entry(for: handle) else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }

        let center = frame.center

        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return }

        CGWarpMouseCursorPosition(center)
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let cachedInfo = appInfoCache.info(for: entry.handle.pid)
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

struct NodeActivationOptions {
    var activateWindow: Bool = true
    var ensureVisible: Bool = true
    var updateTimestamp: Bool = true
    var updateWorkspaceFocus: Bool = true
    var layoutRefresh: Bool = true
    var axFocus: Bool = true
    var startAnimation: Bool = true
}

extension WMController {
    func activateNode(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        options: NodeActivationOptions = NodeActivationOptions()
    ) {
        guard let engine = niriEngine else { return }

        state.selectedNodeId = node.id

        if options.activateWindow {
            engine.activateWindow(node.id)
        }

        if options.ensureVisible, let monitor = workspaceManager.monitor(for: workspaceId) {
            let gap = CGFloat(workspaceManager.gaps)
            let workingFrame = insetWorkingFrame(for: monitor)
            engine.ensureSelectionVisible(
                node: node,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
            )
        }

        workspaceManager.updateNiriViewportState(state, for: workspaceId)

        if let windowNode = node as? NiriWindow {
            if options.updateTimestamp {
                engine.updateFocusTimestamp(for: windowNode.id)
            }
            focusedHandle = windowNode.handle
            if options.updateWorkspaceFocus {
                lastFocusedByWorkspace[workspaceId] = windowNode.handle
            }
        }

        if options.layoutRefresh {
            layoutRefreshController?.executeLayoutRefreshImmediate()
        }

        if options.axFocus, let windowNode = node as? NiriWindow {
            focusWindow(windowNode.handle)
        }

        if options.startAnimation {
            let updatedState = workspaceManager.niriViewportState(for: workspaceId)
            if updatedState.viewOffsetPixels.isAnimating {
                layoutRefreshController?.startScrollAnimation(for: workspaceId)
            }
        }
    }

    @MainActor struct NiriOperationContext {
        let controller: WMController
        let engine: NiriLayoutEngine
        let wsId: WorkspaceDescriptor.ID
        let windowNode: NiriWindow
        let monitor: Monitor
        let workingFrame: CGRect
        let gaps: CGFloat

        func commitWithPredictedAnimation(
            state: ViewportState,
            oldFrames: [WindowHandle: CGRect]
        ) -> Bool {
            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
            let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
                .backingScaleFactor ?? 2.0
            let workingArea = WorkingAreaContext(
                workingFrame: workingFrame,
                viewFrame: monitor.frame,
                scale: scale
            )
            let layoutGaps = LayoutGaps(
                horizontal: gaps,
                vertical: gaps,
                outer: controller.internalWorkspaceManager.outerGaps
            )
            let animationTime = (engine.animationClock?.now() ?? CACurrentMediaTime()) + 2.0
            let newFrames = engine.calculateCombinedLayoutUsingPools(
                in: wsId,
                monitor: monitor,
                gaps: layoutGaps,
                state: state,
                workingArea: workingArea,
                animationTime: animationTime
            ).frames
            _ = engine.triggerMoveAnimations(in: wsId, oldFrames: oldFrames, newFrames: newFrames)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            return updatedState.viewOffsetPixels.isAnimating || engine.hasAnyWindowAnimationsRunning(in: wsId)
        }

        func commitWithCapturedAnimation(
            state: ViewportState,
            oldFrames: [WindowHandle: CGRect]
        ) -> Bool {
            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            let newFrames = engine.captureWindowFrames(in: wsId)
            _ = engine.triggerMoveAnimations(in: wsId, oldFrames: oldFrames, newFrames: newFrames)
            let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            return updatedState.viewOffsetPixels.isAnimating || engine.hasAnyWindowAnimationsRunning(in: wsId)
        }

        func commitSimple(state: ViewportState) -> Bool {
            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            return updatedState.viewOffsetPixels.isAnimating
        }
    }

    func withNiriOperationContext(
        perform operation: (NiriOperationContext, inout ViewportState) -> Bool
    ) {
        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        layoutRefreshController?.runLightSession {
            guard let engine = niriEngine else { return }
            guard let wsId = activeWorkspace()?.id else { return }
            var state = workspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            guard let monitor = workspaceManager.monitor(for: wsId) else { return }
            let workingFrame = insetWorkingFrame(for: monitor)
            let gaps = CGFloat(workspaceManager.gaps)

            let ctx = NiriOperationContext(
                controller: self,
                engine: engine,
                wsId: wsId,
                windowNode: windowNode,
                monitor: monitor,
                workingFrame: workingFrame,
                gaps: gaps
            )

            if operation(ctx, &state) {
                animatingWorkspaceId = wsId
            }
        }

        if let wsId = animatingWorkspaceId {
            layoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    func withNiriWorkspaceContext(
        perform: (NiriLayoutEngine, WorkspaceDescriptor.ID, inout ViewportState, Monitor, CGRect, CGFloat) -> Void
    ) {
        layoutRefreshController?.runLightSession {
            guard let engine = niriEngine else { return }
            guard let wsId = activeWorkspace()?.id else { return }
            var state = workspaceManager.niriViewportState(for: wsId)
            guard let monitor = workspaceManager.monitor(for: wsId) else { return }
            let workingFrame = insetWorkingFrame(for: monitor)
            let gaps = CGFloat(workspaceManager.gaps)
            perform(engine, wsId, &state, monitor, workingFrame, gaps)
        }
    }

    func withDwindleContext(
        perform: (DwindleLayoutEngine, WorkspaceDescriptor.ID) -> Void
    ) {
        guard let engine = dwindleEngine,
              let wsId = activeWorkspace()?.id
        else { return }
        perform(engine, wsId)
    }

    var internalNiriEngine: NiriLayoutEngine? { niriEngine }
    var internalDwindleEngine: DwindleLayoutEngine? { dwindleEngine }
    var internalWorkspaceManager: WorkspaceManager { workspaceManager }
    var internalSettings: SettingsStore { settings }
    var internalAXManager: AXManager { axManager }
    var internalBorderManager: BorderManager { borderManager }
    var internalTabbedOverlayManager: TabbedColumnOverlayManager { tabbedOverlayManager }
    var internalLockScreenObserver: LockScreenObserver { lockScreenObserver }
    var internalAppRulesByBundleId: [String: AppRule] { appRulesByBundleId }

    var internalFocusedHandle: WindowHandle? {
        get { focusedHandle }
        set { focusedHandle = newValue }
    }

    var internalLastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] {
        get { lastFocusedByWorkspace }
        set { lastFocusedByWorkspace = newValue }
    }

    func internalSetFocus(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) {
        setFocus(handle, in: workspaceId)
    }

    func internalResolveWorkspaceFocus(for workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        resolveWorkspaceFocus(for: workspaceId)
    }

    var internalActiveMonitorId: Monitor.ID? {
        get { activeMonitorId }
        set { activeMonitorId = newValue }
    }

    var internalPreviousMonitorId: Monitor.ID? {
        get { previousMonitorId }
        set { previousMonitorId = newValue }
    }

    var internalSuppressActiveMonitorUpdate: Bool {
        get { suppressActiveMonitorUpdate }
        set { suppressActiveMonitorUpdate = newValue }
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

    var internalAnimationsEnabled: Bool { settings.animationsEnabled }

    var internalHiddenAppPIDs: Set<pid_t> {
        get { hiddenAppPIDs }
        set { hiddenAppPIDs = newValue }
    }

    var internalLayoutRefreshController: LayoutRefreshController? { layoutRefreshController }
    var internalWorkspaceNavigationHandler: WorkspaceNavigationHandler? { workspaceNavigationHandler }
    var internalAXEventHandler: AXEventHandler? { axEventHandler }

    func isPointInQuakeTerminal(_ point: CGPoint) -> Bool {
        guard settings.quakeTerminalEnabled,
              quakeTerminalController.visible,
              let window = quakeTerminalController.window else {
            return false
        }
        return window.frame.contains(point)
    }

    func isPointInOwnWindow(_ point: CGPoint) -> Bool {
        if isPointInQuakeTerminal(point) { return true }
        if SettingsWindowController.shared.isPointInside(point) { return true }
        if AppRulesWindowController.shared.isPointInside(point) { return true }
        if SponsorsWindowController.shared.isPointInside(point) { return true }
        return false
    }
}
