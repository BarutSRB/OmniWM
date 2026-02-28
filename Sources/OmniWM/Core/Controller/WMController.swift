import AppKit
import Foundation

@MainActor @Observable
final class WMController {
    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private(set) var focusFollowsMouseEnabled: Bool = false
    private(set) var moveMouseToFocusedWindowEnabled: Bool = false
    private(set) var workspaceBarVersion: Int = 0

    let settings: SettingsStore
    let workspaceManager: WorkspaceManager
    private let hotkeys = HotkeyCenter()
    let secureInputMonitor = SecureInputMonitor()
    let lockScreenObserver = LockScreenObserver()
    var isLockScreenActive: Bool = false
    let axManager = AXManager()
    let appInfoCache = AppInfoCache()
    let focusManager = FocusManager()
    var focusedHandle: WindowHandle? {
        didSet {
            updateActiveMonitorFromFocusedHandle(focusedHandle)
            focusNotificationDispatcher.notifyFocusChangesIfNeeded()
        }
    }

    var activeMonitorId: Monitor.ID? {
        didSet {
            focusNotificationDispatcher.notifyFocusChangesIfNeeded()
        }
    }
    var previousMonitorId: Monitor.ID?
    private var suppressActiveMonitorUpdate: Bool = false

    var niriEngine: NiriLayoutEngine?
    var dwindleEngine: DwindleLayoutEngine?

    let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    lazy var borderManager: BorderManager = .init()
    @ObservationIgnored
    private lazy var workspaceBarManager: WorkspaceBarManager = .init()
    @ObservationIgnored
    private lazy var hiddenBarController: HiddenBarController = .init(settings: settings)
    @ObservationIgnored
    private lazy var quakeTerminalController: QuakeTerminalController = .init(settings: settings)

    var isTransferringWindow: Bool = false
    var hiddenAppPIDs: Set<pid_t> = []

    private(set) var appRulesByBundleId: [String: AppRule] = [:]

    @ObservationIgnored
    private(set) lazy var mouseEventHandler = MouseEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var mouseWarpHandler = MouseWarpHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var axEventHandler = AXEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var commandHandler = CommandHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceNavigationHandler = WorkspaceNavigationHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var layoutRefreshController = LayoutRefreshController(controller: self)
    var niriLayoutHandler: NiriLayoutHandler { layoutRefreshController.niriHandler }
    var dwindleLayoutHandler: DwindleLayoutHandler { layoutRefreshController.dwindleHandler }
    @ObservationIgnored
    private(set) lazy var serviceLifecycleManager = ServiceLifecycleManager(controller: self)
    @ObservationIgnored
    private(set) lazy var windowActionHandler = WindowActionHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var focusNotificationDispatcher = FocusNotificationDispatcher(controller: self)
    @ObservationIgnored
    private(set) lazy var borderCoordinator = BorderCoordinator(controller: self)
    var hasStartedServices = false

    let animationClock = AnimationClock()

    init(settings: SettingsStore) {
        self.settings = settings
        workspaceManager = WorkspaceManager(settings: settings)
        workspaceManager.updateAnimationClock(animationClock)
        hotkeys.onCommand = { [weak self] command in
            self?.commandHandler.handleCommand(command)
        }
        tabbedOverlayManager.onSelect = { [weak self] workspaceId, columnId, index in
            self?.layoutRefreshController.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, index: index)
        }
        focusManager.onFocusedHandleChanged = { [weak self] handle in
            self?.focusedHandle = handle
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            serviceLifecycleManager.start()
        } else {
            serviceLifecycleManager.stop()
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

    func cleanupUIOnStop() {
        workspaceBarManager.cleanup()
        hiddenBarController.cleanup()
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
        layoutRefreshController.refreshWindowsAndLayout()
    }

    func updateMonitorNiriSettings() {
        guard let engine = niriEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedNiriSettings(for: monitor)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
        layoutRefreshController.refreshWindowsAndLayout()
    }

    func updateMonitorDwindleSettings() {
        guard let engine = dwindleEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedDwindleSettings(for: monitor)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
        layoutRefreshController.refreshWindowsAndLayout()
    }

    func workspaceBarItems(for monitor: Monitor, deduplicate: Bool, hideEmpty: Bool) -> [WorkspaceBarItem] {
        WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            deduplicate: deduplicate,
            hideEmpty: hideEmpty,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            niriEngine: niriEngine,
            focusedHandle: focusedHandle,
            settings: settings
        )
    }

    func focusWorkspaceFromBar(named name: String) {
        windowActionHandler.focusWorkspaceFromBar(named: name)
    }

    func focusWindowFromBar(windowId: Int) {
        windowActionHandler.focusWindowFromBar(windowId: windowId)
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func setMouseWarpEnabled(_ enabled: Bool) {
        if enabled {
            mouseWarpHandler.setup()
        } else {
            mouseWarpHandler.cleanup()
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
        layoutRefreshController.refreshWindowsAndLayout()
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
        layoutRefreshController.refreshWindowsAndLayout()
    }

    var hotkeyRegistrationFailures: Set<HotkeyCommand> {
        hotkeys.registrationFailures
    }

    func enableNiriLayout(
        maxWindowsPerColumn: Int = 3,
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        niriLayoutHandler.enableNiriLayout(
            maxWindowsPerColumn: maxWindowsPerColumn,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }

    func syncMonitorsToNiriEngine() {
        niriLayoutHandler.syncMonitorsToNiriEngine()
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
        niriLayoutHandler.updateNiriConfig(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            animationsEnabled: animationsEnabled,
            columnWidthPresets: columnWidthPresets
        )
    }

    func enableDwindleLayout() {
        dwindleLayoutHandler.enableDwindleLayout()
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
        dwindleLayoutHandler.updateDwindleConfig(
            smartSplit: smartSplit,
            defaultSplitRatio: defaultSplitRatio,
            splitWidthMultiplier: splitWidthMultiplier,
            singleWindowAspectRatio: singleWindowAspectRatio,
            innerGap: innerGap,
            outerGapTop: outerGapTop,
            outerGapBottom: outerGapBottom,
            outerGapLeft: outerGapLeft,
            outerGapRight: outerGapRight
        )
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
        if let workspaceId = workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first?.id {
            return workspaceId
        }
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: true) {
            return createdWorkspaceId
        }
        fatalError("resolveWorkspaceForNewWindow: no workspaces exist")
    }

    func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        workspaceManager.entry(forPid: pid, windowId: windowId)?.workspaceId
    }

    func openWindowFinder() { windowActionHandler.openWindowFinder() }
    func openMenuAnywhere() { windowActionHandler.openMenuAnywhere() }
    func openMenuPalette() { windowActionHandler.openMenuPalette() }
    func toggleOverview() { windowActionHandler.toggleOverview() }
    func raiseAllFloatingWindows() { windowActionHandler.raiseAllFloatingWindows() }
    func isOverviewOpen() -> Bool { windowActionHandler.isOverviewOpen() }

    @discardableResult
    func resolveAndSetWorkspaceFocus(for workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        focusManager.resolveAndSetWorkspaceFocus(
            for: workspaceId,
            entries: workspaceManager.entries(in: workspaceId)
        )
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId?
    ) {
        focusManager.recoverSourceFocusAfterMove(
            in: workspaceId,
            preferredNodeId: preferredNodeId,
            engine: niriEngine,
            entries: workspaceManager.entries(in: workspaceId)
        )
    }

    func moveMouseToWindow(_ handle: WindowHandle) {
        guard let entry = workspaceManager.entry(for: handle) else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }

        let center = frame.center

        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return }

        CGWarpMouseCursorPosition(center)
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        windowActionHandler.runningAppsWithWindows()
    }
}

extension WMController {
    func withSuppressedMonitorUpdate(_ body: () -> Void) {
        suppressActiveMonitorUpdate = true
        defer { suppressActiveMonitorUpdate = false }
        body()
    }

    func isFrontmostAppLockScreen() -> Bool {
        lockScreenObserver.isFrontmostAppLockScreen()
    }

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
        if windowActionHandler.isPointInOverview(point) { return true }
        if SettingsWindowController.shared.isPointInside(point) { return true }
        if AppRulesWindowController.shared.isPointInside(point) { return true }
        if SponsorsWindowController.shared.isPointInside(point) { return true }
        return false
    }

    func focusWindow(_ handle: WindowHandle) {
        guard let entry = workspaceManager.entry(for: handle) else { return }
        focusManager.setNonManagedFocus(active: false)

        let axRef = entry.axRef
        let pid = handle.pid
        let windowId = entry.windowId
        let moveMouseEnabled = moveMouseToFocusedWindowEnabled
        let shouldRaiseWithAX = NSScreen.screensHaveSeparateSpaces && workspaceManager.monitors.count > 1

        focusManager.focusWindow(
            handle,
            workspaceId: entry.workspaceId,
            performFocus: { [weak self] in
                OmniWM.focusWindow(pid: pid, windowId: UInt32(windowId), windowRef: axRef.element)
                if shouldRaiseWithAX {
                    AXUIElementPerformAction(axRef.element, kAXRaiseAction as CFString)
                }

                if let runningApp = NSRunningApplication(processIdentifier: pid) {
                    runningApp.activate()
                }

                guard let self else { return }

                if moveMouseEnabled {
                    self.moveMouseToWindow(handle)
                }

                if let entry = self.workspaceManager.entry(for: handle) {
                    if let engine = self.niriEngine,
                       let node = engine.findNode(for: handle),
                       let frame = node.frame
                    {
                        self.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                    } else if let frame = try? AXWindowService.frame(entry.axRef) {
                        self.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                    }
                }
            },
            onDeferredFocus: { [weak self] deferred in
                guard let self, self.workspaceManager.entry(for: deferred) != nil else { return }
                self.focusWindow(deferred)
            }
        )
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }
}
