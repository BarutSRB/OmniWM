import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct WindowFocusOperations {
    let activateApp: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let raiseWindow: (AXUIElement) -> Void

    static let live = WindowFocusOperations(
        activateApp: { pid in
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate(options: [])
            }
        },
        focusSpecificWindow: { pid, windowId, element in
            OmniWM.focusWindow(pid: pid, windowId: windowId, windowRef: element)
        },
        raiseWindow: { element in
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    )
}

@MainActor @Observable
final class WMController {
    struct WorkspaceBarRefreshDebugState {
        var requestCount: Int = 0
        var scheduledCount: Int = 0
        var executionCount: Int = 0
        var isQueued: Bool = false
    }

    struct StatusBarWorkspaceSummary: Equatable {
        let monitorId: Monitor.ID
        let workspaceLabel: String
        let workspaceRawName: String
        let focusedAppName: String?
    }

    struct WindowDecisionEvaluation {
        let token: WindowToken
        let facts: WindowRuleFacts
        let decision: WindowDecision
        let appFullscreen: Bool
        let manualOverride: ManualWindowOverride?
    }

    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private(set) var focusFollowsMouseEnabled: Bool = false
    private(set) var moveMouseToFocusedWindowEnabled: Bool = false

    let settings: SettingsStore
    let workspaceManager: WorkspaceManager
    private let hotkeys = HotkeyCenter()
    let secureInputMonitor = SecureInputMonitor()
    let lockScreenObserver = LockScreenObserver()
    var isLockScreenActive: Bool = false
    let axManager = AXManager()
    let appInfoCache = AppInfoCache()
    let focusBridge: FocusBridgeCoordinator
    let windowRuleEngine = WindowRuleEngine()

    var niriEngine: NiriLayoutEngine?
    var dwindleEngine: DwindleLayoutEngine?

    let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    lazy var borderManager: BorderManager = .init()
    @ObservationIgnored
    private lazy var workspaceBarManager: WorkspaceBarManager = .init()
    @ObservationIgnored
    private var workspaceBarRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var pendingWorkspaceBarRefreshGeneration: UInt64?
    @ObservationIgnored
    private var hiddenWorkspaceBarMonitorIds: Set<Monitor.ID> = []
    @ObservationIgnored
    private let hiddenBarController: HiddenBarController
    @ObservationIgnored
    private lazy var quakeTerminalController: QuakeTerminalController = .init(settings: settings)

    var isTransferringWindow: Bool = false
    var hiddenAppPIDs: Set<pid_t> = []

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
    @ObservationIgnored
    var hasStartedServices = false
    @ObservationIgnored
    private(set) var isMouseWarpPolicyEnabled = false
    @ObservationIgnored
    private let ownedWindowRegistry = OwnedWindowRegistry.shared
    @ObservationIgnored
    private(set) var workspaceBarRefreshDebugState = WorkspaceBarRefreshDebugState()
    @ObservationIgnored
    var workspaceBarRefreshExecutionHookForTests: (() -> Void)?
    @ObservationIgnored
    weak var ipcApplicationBridge: IPCApplicationBridge?

    let animationClock = AnimationClock()
    private let windowFocusOperations: WindowFocusOperations
    weak var statusBarController: StatusBarController?

    init(
        settings: SettingsStore,
        hiddenBarController: HiddenBarController? = nil,
        windowFocusOperations: WindowFocusOperations = .live
    ) {
        self.settings = settings
        self.hiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.windowFocusOperations = windowFocusOperations
        workspaceManager = WorkspaceManager(settings: settings)
        focusBridge = FocusBridgeCoordinator()
        workspaceManager.updateAnimationClock(animationClock)
        hotkeys.onCommand = { [weak self] command in
            self?.commandHandler.handleCommand(command)
        }
        tabbedOverlayManager.onSelect = { [weak self] workspaceId, columnId, visualIndex in
            self?.layoutRefreshController.selectTabInNiri(
                workspaceId: workspaceId,
                columnId: columnId,
                visualIndex: visualIndex
            )
        }
        workspaceManager.onSessionStateChanged = { [weak self] in
            self?.handleSessionStateChanged()
        }
    }

    func applyPersistedSettings(_ settings: SettingsStore) {
        applyCurrentAppearanceMode()

        updateHotkeyBindings(settings.hotkeyBindings)
        setHotkeysEnabled(settings.hotkeysEnabled)

        setGapSize(settings.gapSize)
        setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom
        )

        if niriEngine == nil {
            enableNiriLayout(
                maxWindowsPerColumn: settings.niriMaxWindowsPerColumn,
                centerFocusedColumn: settings.niriCenterFocusedColumn,
                alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn
            )
        }
        updateNiriConfig(
            maxWindowsPerColumn: settings.niriMaxWindowsPerColumn,
            maxVisibleColumns: settings.niriMaxVisibleColumns,
            infiniteLoop: settings.niriInfiniteLoop,
            centerFocusedColumn: settings.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: settings.niriSingleWindowAspectRatio,
            columnWidthPresets: settings.niriColumnWidthPresets,
            defaultColumnWidth: settings.niriDefaultColumnWidth
        )

        if dwindleEngine == nil {
            enableDwindleLayout()
        }
        updateDwindleConfig(
            smartSplit: settings.dwindleSmartSplit,
            defaultSplitRatio: settings.dwindleDefaultSplitRatio,
            splitWidthMultiplier: settings.dwindleSplitWidthMultiplier,
            singleWindowAspectRatio: settings.dwindleSingleWindowAspectRatio.size
        )

        updateWorkspaceConfig()
        updateMonitorOrientations()
        updateMonitorNiriSettings()
        updateMonitorDwindleSettings()
        updateAppRules()

        setBordersEnabled(settings.bordersEnabled)
        updateBorderConfig(BorderConfig.from(settings: settings))

        setFocusFollowsMouse(settings.focusFollowsMouse)
        setMoveMouseToFocusedWindow(settings.moveMouseToFocusedWindow)

        setWorkspaceBarEnabled(settings.workspaceBarEnabled)
        setPreventSleepEnabled(settings.preventSleepEnabled)
        setQuakeTerminalEnabled(settings.quakeTerminalEnabled)

        setEnabled(true)
        refreshStatusBar()
    }

    func applyCurrentAppearanceMode() {
        settings.appearanceMode.apply()
        workspaceBarManager.updateSettings()
        statusBarController?.rebuildMenu()
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
        if settings.workspaceBarEnabled != enabled {
            settings.workspaceBarEnabled = enabled
        }
        pruneHiddenWorkspaceBarMonitorIds()
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.setup(controller: self, settings: settings)
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func cleanupUIOnStop() {
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.cleanup()
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
        }
    }

    func toggleHiddenBar() {
        hiddenBarController.toggle()
    }

    @discardableResult
    func toggleWorkspaceBarVisibility() -> Bool {
        pruneHiddenWorkspaceBarMonitorIds()

        guard let monitor = monitorForInteraction() else { return false }
        let resolved = settings.resolvedBarSettings(for: monitor)
        guard resolved.enabled else { return false }

        if hiddenWorkspaceBarMonitorIds.contains(monitor.id) {
            hiddenWorkspaceBarMonitorIds.remove(monitor.id)
        } else {
            hiddenWorkspaceBarMonitorIds.insert(monitor.id)
        }

        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.setup(controller: self, settings: settings)
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        return true
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

    func requestWorkspaceBarRefresh() {
        workspaceBarRefreshDebugState.requestCount += 1

        guard hasWorkspaceBarRefreshConsumers else { return }
        guard pendingWorkspaceBarRefreshGeneration == nil else { return }

        let generation = workspaceBarRefreshGeneration
        pendingWorkspaceBarRefreshGeneration = generation
        workspaceBarRefreshDebugState.scheduledCount += 1
        workspaceBarRefreshDebugState.isQueued = true

        Task { @MainActor [weak self] in
            await Task.yield()
            await Task.yield()
            self?.flushRequestedWorkspaceBarRefresh(expectedGeneration: generation)
        }
    }

    func isManagedWindowDisplayable(_ handle: WindowHandle) -> Bool {
        guard workspaceManager.entry(for: handle) != nil else { return false }
        if hiddenAppPIDs.contains(handle.pid) {
            return false
        }
        if workspaceManager.layoutReason(for: handle.id) != .standard {
            return false
        }
        return !workspaceManager.isHiddenInCorner(handle.id)
    }

    func isManagedWindowSuspendedForNativeFullscreen(_ token: WindowToken) -> Bool {
        workspaceManager.isNativeFullscreenSuspended(token)
    }

    func refreshStatusBar() {
        statusBarController?.refreshWorkspaces()
    }

    func activeStatusBarWorkspaceSummary() -> StatusBarWorkspaceSummary? {
        guard let monitor = monitorForInteraction(),
              let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return nil
        }

        let focusedAppName: String? = if let focusedToken = workspaceManager.focusedToken,
                                          let entry = workspaceManager.entry(for: focusedToken),
                                          entry.workspaceId == workspace.id
        {
            resolvedAppInfo(for: entry.pid)?.name
        } else {
            nil
        }

        return StatusBarWorkspaceSummary(
            monitorId: monitor.id,
            workspaceLabel: settings.displayName(for: workspace.name),
            workspaceRawName: workspace.name,
            focusedAppName: focusedAppName
        )
    }

    func updateWorkspaceBarSettings() {
        pruneHiddenWorkspaceBarMonitorIds()
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.updateSettings()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorOrientations() {
        let monitors = workspaceManager.monitors
        for monitor in monitors {
            let orientation = settings.effectiveOrientation(for: monitor)
            niriEngine?.monitors[monitor.id]?.updateOrientation(orientation)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorNiriSettings() {
        guard let engine = niriEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedNiriSettings(for: monitor)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorDwindleSettings() {
        guard let engine = dwindleEngine else { return }
        for monitor in workspaceManager.monitors {
            let resolved = settings.resolvedDwindleSettings(for: monitor)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func workspaceBarItems(for monitor: Monitor, deduplicate: Bool, hideEmpty: Bool) -> [WorkspaceBarItem] {
        WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            deduplicate: deduplicate,
            hideEmpty: hideEmpty,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            niriEngine: niriEngine,
            focusedToken: workspaceManager.focusedToken,
            settings: settings
        )
    }

    func focusWorkspaceFromBar(named name: String) {
        windowActionHandler.focusWorkspaceFromBar(named: name)
    }

    func focusWindowFromBar(token: WindowToken) {
        windowActionHandler.focusWindowFromBar(token: token)
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func shouldUseMouseWarp(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        return effectiveMonitors.count > 1
    }

    @discardableResult
    func syncMouseWarpPolicy(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        let shouldEnable = shouldUseMouseWarp(for: effectiveMonitors)

        if shouldEnable {
            _ = settings.persistEffectiveMouseWarpMonitorOrder(for: effectiveMonitors)
        }

        guard shouldEnable != isMouseWarpPolicyEnabled else {
            return shouldEnable
        }

        if shouldEnable {
            mouseWarpHandler.setup()
        } else {
            mouseWarpHandler.cleanup()
        }

        isMouseWarpPolicyEnabled = shouldEnable
        return shouldEnable
    }

    func resetMouseWarpPolicy() {
        mouseWarpHandler.cleanup()
        isMouseWarpPolicyEnabled = false
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
        let resolved = settings.resolvedBarSettings(for: monitor)
        let reservedTopInset = WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved)
        ).reservedTopInset
        return insetWorkingFrame(from: monitor.visibleFrame, scale: scale, reservedTopInset: reservedTopInset)
    }

    func insetWorkingFrame(from frame: CGRect, scale: CGFloat = 2.0, reservedTopInset: CGFloat = 0) -> CGRect {
        let outer = workspaceManager.outerGaps
        let struts = Struts(
            left: outer.left,
            right: outer.right,
            top: outer.top + reservedTopInset,
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
        layoutRefreshController.requestFullRescan(reason: .workspaceConfigChanged)
    }

    func rebuildAppRulesCache() {
        windowRuleEngine.rebuild(rules: settings.appRules)
    }

    func updateAppRules() {
        rebuildAppRulesCache()
        layoutRefreshController.requestFullRescan(reason: .appRulesChanged)
    }

    var hotkeyRegistrationFailures: Set<HotkeyCommand> {
        hotkeys.registrationFailures
    }

    private var workspaceBarRefreshIsEnabled: Bool {
        settings.workspaceBarEnabled || settings.monitorBarSettings.contains(where: { $0.enabled == true })
    }

    private var statusBarRefreshIsEnabled: Bool {
        statusBarController != nil && settings.statusBarShowWorkspaceName
    }

    private var anyBarRefreshIsEnabled: Bool {
        workspaceBarRefreshIsEnabled || statusBarRefreshIsEnabled
    }

    private var hasWorkspaceBarRefreshConsumers: Bool {
        anyBarRefreshIsEnabled
            || ipcApplicationBridge?.hasSubscribers(for: .workspaceBar) == true
            || ipcApplicationBridge?.hasSubscribers(for: .windowsChanged) == true
            || ipcApplicationBridge?.hasSubscribers(for: .layoutChanged) == true
    }

    private func flushRequestedWorkspaceBarRefresh(expectedGeneration: UInt64) {
        guard pendingWorkspaceBarRefreshGeneration == expectedGeneration,
              workspaceBarRefreshGeneration == expectedGeneration
        else {
            return
        }

        pendingWorkspaceBarRefreshGeneration = nil
        workspaceBarRefreshDebugState.isQueued = false

        guard hasWorkspaceBarRefreshConsumers else { return }

        workspaceBarRefreshDebugState.executionCount += 1
        workspaceBarRefreshExecutionHookForTests?()
        if workspaceBarRefreshIsEnabled {
            workspaceBarManager.update()
        }
        if statusBarRefreshIsEnabled {
            refreshStatusBar()
        }
        if let ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.workspaceBar)
                await ipcApplicationBridge.publishEvent(.windowsChanged)
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
    }

    private func cancelPendingWorkspaceBarRefresh() {
        pendingWorkspaceBarRefreshGeneration = nil
        workspaceBarRefreshGeneration &+= 1
        workspaceBarRefreshDebugState.isQueued = false
    }

    func isWorkspaceBarVisible(on monitor: Monitor, resolved: ResolvedBarSettings? = nil) -> Bool {
        let effective = resolved ?? settings.resolvedBarSettings(for: monitor)
        return effective.enabled && !hiddenWorkspaceBarMonitorIds.contains(monitor.id)
    }

    private func pruneHiddenWorkspaceBarMonitorIds() {
        hiddenWorkspaceBarMonitorIds = hiddenWorkspaceBarMonitorIds.filter { monitorId in
            guard let monitor = workspaceManager.monitor(byId: monitorId) else { return false }
            return settings.resolvedBarSettings(for: monitor).enabled
        }
    }

    func waitForWorkspaceBarRefreshForTests() async {
        for _ in 0..<100 {
            await Task.yield()
            if !workspaceBarRefreshDebugState.isQueued {
                break
            }
        }
        await Task.yield()
    }

    func resetWorkspaceBarRefreshDebugStateForTests() {
        cancelPendingWorkspaceBarRefresh()
        workspaceBarRefreshDebugState = .init()
        workspaceBarRefreshExecutionHookForTests = nil
    }

    func activeWorkspaceBarCountForTests() -> Int {
        workspaceBarManager.activeBarCountForTests()
    }

    func isWorkspaceBarRuntimeHiddenForTests(on monitorId: Monitor.ID) -> Bool {
        hiddenWorkspaceBarMonitorIds.contains(monitorId)
    }

    func configureWorkspaceBarManagerForTests(monitors: [Monitor]) {
        workspaceBarManager.monitorProvider = { monitors }
        workspaceBarManager.screenProvider = { _ in nil }
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
        columnWidthPresets: [Double]? = nil,
        defaultColumnWidth: Double?? = nil
    ) {
        niriLayoutHandler.updateNiriConfig(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            columnWidthPresets: columnWidthPresets,
            defaultColumnWidth: defaultColumnWidth
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
        if let interactionMonitorId = workspaceManager.interactionMonitorId,
           let monitor = workspaceManager.monitor(byId: interactionMonitorId)
        {
            return monitor
        }
        if let focusedToken = workspaceManager.focusedToken,
           let workspaceId = workspaceManager.workspace(for: focusedToken),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    private func handleSessionStateChanged() {
        let changeSet = focusNotificationDispatcher.notifyFocusChangesIfNeeded()
        if statusBarRefreshIsEnabled {
            refreshStatusBar()
        }
        if let ipcApplicationBridge {
            Task {
                if changeSet.focusChanged {
                    await ipcApplicationBridge.publishEvent(.focus)
                }
                if changeSet.workspaceChanged || changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.activeWorkspace)
                }
                if changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.focusedMonitor)
                    await ipcApplicationBridge.publishEvent(.displayChanged)
                }
            }
        }
    }

    func activeWorkspace() -> WorkspaceDescriptor? {
        guard let monitor = monitorForInteraction() else { return nil }
        return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
    }

    func resolveWorkspaceForNewWindow(
        workspaceName: String? = nil,
        axRef: AXWindowRef,
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
        if let wsName = workspaceName,
           let wsId = workspaceManager.workspaceId(for: wsName, createIfMissing: false)
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
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: false) {
            return createdWorkspaceId
        }
        fatalError("resolveWorkspaceForNewWindow: no workspaces exist")
    }

    private func resolvedAppInfo(for pid: pid_t) -> AppInfoCache.AppInfo? {
        appInfoCache.info(for: pid) ?? NSRunningApplication(processIdentifier: pid).map {
            AppInfoCache.AppInfo(
                name: $0.localizedName,
                bundleId: $0.bundleIdentifier,
                icon: $0.icon,
                activationPolicy: $0.activationPolicy
            )
        }
    }

    private func evaluateSizeConstraints(
        for token: WindowToken,
        axRef: AXWindowRef
    ) -> WindowSizeConstraints {
        if let cached = workspaceManager.cachedConstraints(for: token) {
            return cached
        }

        let currentSize = AXWindowService.framePreferFast(axRef)?.size
            ?? axManager.lastAppliedFrame(for: token.windowId)?.size
        let resolved = AXWindowService.sizeConstraints(axRef, currentSize: currentSize)
        workspaceManager.setCachedConstraints(resolved, for: token)
        return resolved
    }

    private func decisionApplyingManualOverride(
        _ decision: WindowDecision,
        manualOverride: ManualWindowOverride?
    ) -> WindowDecision {
        guard let manualOverride, decision.disposition != .unmanaged else {
            return decision
        }

        return WindowDecision(
            disposition: manualOverride == .forceTile ? .managed : .floating,
            source: .manualOverride,
            layoutDecisionKind: .explicitLayout,
            workspaceName: decision.workspaceName,
            ruleEffects: decision.ruleEffects,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func liveFrame(for entry: WindowModel.Entry) -> CGRect? {
        AXWindowService.framePreferFast(entry.axRef)
            ?? axManager.lastAppliedFrame(for: entry.windowId)
            ?? (try? AXWindowService.frame(entry.axRef))
    }

    private func floatingPlacementMonitor(
        for entry: WindowModel.Entry,
        preferredMonitor: Monitor? = nil,
        frame: CGRect? = nil
    ) -> Monitor? {
        if let preferredMonitor {
            return preferredMonitor
        }
        if let interactionMonitor = monitorForInteraction() {
            return interactionMonitor
        }
        if let workspaceMonitor = workspaceManager.monitor(for: entry.workspaceId) {
            return workspaceMonitor
        }
        if let frame,
           let approximatedMonitor = frame.center.monitorApproximation(in: workspaceManager.monitors)
        {
            return approximatedMonitor
        }
        return workspaceManager.monitors.first
    }

    private func clampedFloatingFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGRect {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        let clampedX = min(max(frame.origin.x, visibleFrame.minX), max(maxX, visibleFrame.minX))
        let clampedY = min(max(frame.origin.y, visibleFrame.minY), max(maxY, visibleFrame.minY))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: frame.size)
    }

    private func initialFloatingFrame(
        for entry: WindowModel.Entry,
        preferredMonitor: Monitor?
    ) -> CGRect? {
        guard let frame = liveFrame(for: entry) else { return nil }
        let offsetFrame = frame.offsetBy(dx: 50, dy: 50)
        guard let monitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        ) else {
            return offsetFrame
        }
        return clampedFloatingFrame(offsetFrame, in: monitor.visibleFrame)
    }

    private func targetFloatingFrame(
        for entry: WindowModel.Entry,
        preferredMonitor: Monitor?
    ) -> CGRect? {
        if let floatingState = workspaceManager.floatingState(for: entry.token),
           floatingState.restoreToFloating,
           let restoredFrame = workspaceManager.resolvedFloatingFrame(
               for: entry.token,
               preferredMonitor: preferredMonitor
           )
        {
            return restoredFrame
        }
        return initialFloatingFrame(for: entry, preferredMonitor: preferredMonitor)
    }

    private func shouldApplyFloatingFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else { return false }
        return workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    func seedFloatingGeometryIfNeeded(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) {
        guard workspaceManager.floatingState(for: token) == nil,
              let entry = workspaceManager.entry(for: token),
              let frame = liveFrame(for: entry)
        else {
            return
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
    }

    func focusedOrFrontmostWindowTokenForAutomation(
        preferFrontmostWhenNonManagedFocusActive: Bool = false
    ) -> WindowToken? {
        let focusedToken = workspaceManager.focusedToken
        let frontmostPid = commandHandler.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        if preferFrontmostWhenNonManagedFocusActive, workspaceManager.isNonManagedFocusActive {
            return frontmostToken ?? focusedToken
        }
        return focusedToken ?? frontmostToken
    }

    private func focusedManagedTokenForCommand() -> WindowToken? {
        let token = focusedOrFrontmostWindowTokenForAutomation()
        guard let token, workspaceManager.entry(for: token) != nil else {
            return nil
        }
        return token
    }

    @discardableResult
    private func captureVisibleFloatingGeometry(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard !workspaceManager.isHiddenInCorner(token),
              let entry = workspaceManager.entry(for: token),
              let frame = liveFrame(for: entry)
        else {
            return nil
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        return frame
    }

    @discardableResult
    private func prepareWindowForScratchpadAssignment(
        _ token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
            workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        }

        if entry.mode == .floating {
            return captureVisibleFloatingGeometry(for: token, preferredMonitor: preferredMonitor) != nil
                || workspaceManager.floatingState(for: token) != nil
        }

        guard let frame = liveFrame(for: entry) else { return false }
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        _ = workspaceManager.setWindowMode(.floating, for: token)
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        return true
    }

    private func currentScratchpadTarget() -> (workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)? {
        guard let monitor = monitorForInteraction(),
              let workspaceId = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            return nil
        }
        return (workspaceId, monitor)
    }

    private func visibleFocusRecoveryToken(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedToken: WindowToken
    ) -> WindowToken? {
        let explicitCandidates = [
            workspaceManager.lastFocusedToken(in: workspaceId),
            workspaceManager.preferredFocusToken(in: workspaceId),
            workspaceManager.lastFloatingFocusedToken(in: workspaceId),
            workspaceManager.focusedToken
        ]

        for candidate in explicitCandidates {
            guard let candidate,
                  candidate != excludedToken,
                  let entry = workspaceManager.entry(for: candidate),
                  entry.workspaceId == workspaceId,
                  isManagedWindowDisplayable(entry.handle)
            else {
                continue
            }
            return candidate
        }

        if let tiledEntry = workspaceManager.tiledEntries(in: workspaceId).first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.handle)
        }) {
            return tiledEntry.token
        }

        return workspaceManager.floatingEntries(in: workspaceId).first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.handle)
        })?.token
    }

    private func recoverFocusAfterScratchpadHide(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding token: WindowToken,
        on monitorId: Monitor.ID?
    ) {
        if let nextFocusToken = visibleFocusRecoveryToken(in: workspaceId, excluding: token) {
            focusWindow(nextFocusToken)
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
        if workspaceManager.focusedToken == nil {
            borderManager.hideBorder()
        }
    }

    private func hideScratchpadWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor
    ) {
        let preferredSide = layoutRefreshController.preferredHideSide(for: monitor)
        layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: preferredSide,
            reason: .scratchpad
        )
        recoverFocusAfterScratchpadHide(
            in: entry.workspaceId,
            excluding: entry.token,
            on: monitor.id
        )
    }

    private func showScratchpadWindow(
        _ entry: WindowModel.Entry,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) {
        if entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId)
        }
        axManager.markWindowActive(entry.windowId)

        if let hiddenState = workspaceManager.hiddenState(for: entry.token) {
            if hiddenState.isScratchpad {
                layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)
            } else {
                layoutRefreshController.unhideWindow(entry, monitor: monitor)
            }
        } else if let frame = workspaceManager.resolvedFloatingFrame(
            for: entry.token,
            preferredMonitor: monitor
        ) {
            axManager.forceApplyNextFrame(for: entry.windowId)
            axManager.applyFramesParallel([(entry.pid, entry.windowId, frame)])
        }

        focusWindow(entry.token)
    }

    @discardableResult
    func transitionWindowMode(
        for token: WindowToken,
        to targetMode: TrackedWindowMode,
        preferredMonitor: Monitor? = nil,
        applyFloatingFrame: Bool? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        let currentMode = entry.mode
        guard currentMode != targetMode else { return false }

        let currentFrame = liveFrame(for: entry)
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: currentFrame
        )

        switch (currentMode, targetMode) {
        case (.tiling, .floating):
            let targetFrame = targetFloatingFrame(
                for: entry,
                preferredMonitor: referenceMonitor
            )
            _ = workspaceManager.setWindowMode(.floating, for: token)
            if let targetFrame {
                workspaceManager.updateFloatingGeometry(
                    frame: targetFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true
                )
                if applyFloatingFrame ?? shouldApplyFloatingFrameImmediately(for: entry.workspaceId) {
                    axManager.forceApplyNextFrame(for: entry.windowId)
                    axManager.applyFramesParallel([(entry.pid, entry.windowId, targetFrame)])
                    if currentKeyboardFocusTargetForRendering()?.token == token {
                        _ = renderKeyboardFocusBorder(
                            preferredFrame: targetFrame,
                            policy: .coordinated
                        )
                    }
                }
            }
            return true

        case (.floating, .tiling):
            if let currentFrame {
                workspaceManager.updateFloatingGeometry(
                    frame: currentFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true
                )
            } else if var floatingState = workspaceManager.floatingState(for: token) {
                floatingState.restoreToFloating = true
                workspaceManager.setFloatingState(floatingState, for: token)
            }
            _ = workspaceManager.setWindowMode(.tiling, for: token)
            return true

        case (.tiling, .tiling), (.floating, .floating):
            return false
        }
    }

    func trackedModeForLifecycle(
        decision: WindowDecision,
        existingEntry: WindowModel.Entry?
    ) -> TrackedWindowMode? {
        if let trackedMode = decision.trackedMode {
            return trackedMode
        }
        if decision.disposition == .undecided {
            return existingEntry?.mode
        }
        return nil
    }

    func resolvedWorkspaceId(
        for evaluation: WindowDecisionEvaluation,
        axRef: AXWindowRef,
        pid: pid_t,
        existingEntry: WindowModel.Entry?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
        if let workspaceName = evaluation.decision.workspaceName,
           let workspaceId = workspaceManager.workspaceId(for: workspaceName, createIfMissing: false)
        {
            return workspaceId
        }

        if let existingEntry {
            return existingEntry.workspaceId
        }

        return resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: pid,
            fallbackWorkspaceId: fallbackWorkspaceId
        )
    }

    func evaluateWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil,
        applyingManualOverride: Bool = true,
        windowInfo: WindowServerInfo? = nil
    ) -> WindowDecisionEvaluation {
        let token = WindowToken(pid: pid, windowId: axRef.windowId)
        let sizeConstraints = evaluateSizeConstraints(for: token, axRef: axRef)
        let appInfo = resolvedAppInfo(for: pid)
        let baseFacts = axEventHandler.windowFactsProvider?(axRef, pid) ?? WindowRuleFacts(
            appName: appInfo?.name,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: appInfo?.activationPolicy,
                bundleId: appInfo?.bundleId,
                includeTitle: windowRuleEngine.requiresTitle(for: appInfo?.bundleId)
            ),
            sizeConstraints: sizeConstraints,
            windowServer: nil
        )
        let resolvedWindowInfo = baseFacts.windowServer ?? resolveWindowServerInfoForDisposition(
            token: token,
            bundleId: baseFacts.ax.bundleId ?? appInfo?.bundleId,
            preferredWindowInfo: windowInfo
        )
        let facts = WindowRuleFacts(
            appName: baseFacts.appName,
            ax: baseFacts.ax,
            sizeConstraints: baseFacts.sizeConstraints,
            windowServer: resolvedWindowInfo
        )
        let fullscreen = appFullscreen ?? (axEventHandler.isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef))
        let manualOverride = workspaceManager.manualLayoutOverride(for: token)
        let baseDecision = windowRuleEngine.decision(
            for: facts,
            token: token,
            appFullscreen: fullscreen
        )
        let decision = applyingManualOverride
            ? decisionApplyingManualOverride(baseDecision, manualOverride: manualOverride)
            : baseDecision
        return WindowDecisionEvaluation(
            token: token,
            facts: facts,
            decision: decision,
            appFullscreen: fullscreen,
            manualOverride: manualOverride
        )
    }

    private func resolveWindowServerInfoForDisposition(
        token: WindowToken,
        bundleId: String?,
        preferredWindowInfo: WindowServerInfo?
    ) -> WindowServerInfo? {
        if let preferredWindowInfo {
            return preferredWindowInfo
        }

        guard bundleId == WindowRuleEngine.cleanShotBundleId,
              let windowId = UInt32(exactly: token.windowId)
        else {
            return nil
        }

        return axEventHandler.windowInfoProvider?(windowId) ?? SkyLight.shared.queryWindowInfo(windowId)
    }

    func decideWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil
    ) -> WindowDecision {
        evaluateWindowDisposition(
            axRef: axRef,
            pid: pid,
            appFullscreen: appFullscreen
        ).decision
    }

    func makeWindowDecisionDebugSnapshot(
        from evaluation: WindowDecisionEvaluation
    ) -> WindowDecisionDebugSnapshot {
        WindowDecisionDebugSnapshot(
            token: evaluation.token,
            appName: evaluation.facts.appName,
            bundleId: evaluation.facts.ax.bundleId,
            title: evaluation.facts.ax.title,
            axRole: evaluation.facts.ax.role,
            axSubrole: evaluation.facts.ax.subrole,
            appFullscreen: evaluation.appFullscreen,
            manualOverride: evaluation.manualOverride,
            disposition: evaluation.decision.disposition,
            source: evaluation.decision.source,
            layoutDecisionKind: evaluation.decision.layoutDecisionKind,
            deferredReason: evaluation.decision.deferredReason,
            admissionOutcome: evaluation.decision.admissionOutcome,
            workspaceName: evaluation.decision.workspaceName,
            minWidth: evaluation.decision.ruleEffects.minWidth,
            minHeight: evaluation.decision.ruleEffects.minHeight,
            matchedRuleId: evaluation.decision.ruleEffects.matchedRuleId,
            heuristicReasons: evaluation.decision.heuristicReasons,
            attributeFetchSucceeded: evaluation.facts.ax.attributeFetchSucceeded
        )
    }

    func windowDecisionDebugSnapshot(for token: WindowToken) -> WindowDecisionDebugSnapshot? {
        let axRef = workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
        guard let axRef else { return nil }
        let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)
        return makeWindowDecisionDebugSnapshot(from: evaluation)
    }

    func focusedWindowDecisionDebugSnapshot() -> WindowDecisionDebugSnapshot? {
        let token = focusedOrFrontmostWindowTokenForAutomation()
        guard let token else { return nil }
        return windowDecisionDebugSnapshot(for: token)
    }

    func copyDebugDump(_ snapshot: WindowDecisionDebugSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.formattedDump(), forType: .string)
    }

    func clearManualWindowOverride(for token: WindowToken) {
        workspaceManager.setManualLayoutOverride(nil, for: token)
    }

    private func resolveAXWindowRef(for token: WindowToken) -> AXWindowRef? {
        workspaceManager.entry(for: token)?.axRef
            ?? axEventHandler.axWindowRefProvider?(UInt32(token.windowId), token.pid)
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
    }

    @discardableResult
    func reevaluateWindowRules(
        for targets: Set<WindowRuleReevaluationTarget>
    ) async -> WindowRuleReevaluationOutcome {
        guard !targets.isEmpty else { return .none }

        var liveWindowsByToken: [WindowToken: AXWindowRef] = [:]
        var tokensToReevaluate: Set<WindowToken> = []
        var pidTargets: Set<pid_t> = []
        var resolvedAnyTarget = false

        for target in targets {
            switch target {
            case let .window(token):
                let existingEntry = workspaceManager.entry(for: token)
                if let axRef = resolveAXWindowRef(for: token) {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                } else if existingEntry != nil {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                }
            case let .pid(pid):
                pidTargets.insert(pid)
            }
        }

        for pid in pidTargets {
            let managedEntries = workspaceManager.entries(forPid: pid)
            if !managedEntries.isEmpty {
                resolvedAnyTarget = true
            }
            if let app = NSRunningApplication(processIdentifier: pid) {
                let windows = await axManager.windowsForApp(app)
                if !windows.isEmpty {
                    resolvedAnyTarget = true
                }
                for (axRef, _, windowId) in windows {
                    let token = WindowToken(pid: pid, windowId: windowId)
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                }
            }

            for entry in managedEntries {
                tokensToReevaluate.insert(entry.token)
            }
        }

        guard !tokensToReevaluate.isEmpty else {
            return WindowRuleReevaluationOutcome(
                resolvedAnyTarget: resolvedAnyTarget,
                evaluatedAnyWindow: false,
                relayoutNeeded: false
            )
        }

        var relayoutNeeded = false
        var evaluatedAnyWindow = false
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        for token in tokensToReevaluate.sorted(by: {
            if $0.pid == $1.pid {
                return $0.windowId < $1.windowId
            }
            return $0.pid < $1.pid
        }) {
            let existingEntry = workspaceManager.entry(for: token)
            let axRef = liveWindowsByToken[token] ?? existingEntry?.axRef
            guard let axRef else { continue }

            evaluatedAnyWindow = true
            let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)

            guard let trackedMode = trackedModeForLifecycle(
                decision: evaluation.decision,
                existingEntry: existingEntry
            ) else {
                if let existingEntry {
                    affectedWorkspaceIds.insert(existingEntry.workspaceId)
                    _ = workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
                    relayoutNeeded = true
                }
                continue
            }

            let oldEffects = existingEntry?.ruleEffects ?? .none
            let oldMode = existingEntry?.mode
            let oldWorkspaceId = existingEntry?.workspaceId
            let workspaceId = resolvedWorkspaceId(
                for: evaluation,
                axRef: axRef,
                pid: token.pid,
                existingEntry: existingEntry,
                fallbackWorkspaceId: activeWorkspace()?.id
            )

            _ = workspaceManager.addWindow(
                axRef,
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId,
                mode: oldMode ?? trackedMode,
                ruleEffects: evaluation.decision.ruleEffects
            )

            if let oldMode, oldMode != trackedMode {
                _ = transitionWindowMode(
                    for: token,
                    to: trackedMode,
                    preferredMonitor: workspaceManager.monitor(for: workspaceId)
                )
            } else if trackedMode == .floating {
                seedFloatingGeometryIfNeeded(
                    for: token,
                    preferredMonitor: workspaceManager.monitor(for: workspaceId)
                )
            }

            if let updatedEntry = workspaceManager.entry(for: token) {
                updatedEntry.managedReplacementMetadata = ManagedReplacementMetadata(
                    bundleId: evaluation.facts.ax.bundleId ?? updatedEntry.managedReplacementMetadata?.bundleId,
                    workspaceId: updatedEntry.workspaceId,
                    mode: updatedEntry.mode,
                    role: evaluation.facts.ax.role ?? updatedEntry.managedReplacementMetadata?.role,
                    subrole: evaluation.facts.ax.subrole ?? updatedEntry.managedReplacementMetadata?.subrole,
                    title: evaluation.facts.ax.title ?? updatedEntry.managedReplacementMetadata?.title,
                    windowLevel: evaluation.facts.windowServer?.level ?? updatedEntry.managedReplacementMetadata?.windowLevel,
                    parentWindowId: evaluation.facts.windowServer?.parentId ?? updatedEntry.managedReplacementMetadata?.parentWindowId,
                    frame: evaluation.facts.windowServer?.frame ?? updatedEntry.managedReplacementMetadata?.frame
                )
            }

            if existingEntry == nil
                || oldEffects != evaluation.decision.ruleEffects
                || oldWorkspaceId != workspaceId
                || oldMode != trackedMode
            {
                if let oldWorkspaceId {
                    affectedWorkspaceIds.insert(oldWorkspaceId)
                }
                affectedWorkspaceIds.insert(workspaceId)
                relayoutNeeded = true
            }
        }

        if relayoutNeeded {
            layoutRefreshController.requestRelayout(
                reason: .windowRuleReevaluation,
                affectedWorkspaceIds: affectedWorkspaceIds
            )
        }

        return WindowRuleReevaluationOutcome(
            resolvedAnyTarget: resolvedAnyTarget,
            evaluatedAnyWindow: evaluatedAnyWindow,
            relayoutNeeded: relayoutNeeded
        )
    }

    func toggleFocusedWindowFloating() {
        let token = focusedManagedTokenForCommand()
        guard let token,
              let entry = workspaceManager.entry(for: token)
        else {
            return
        }

        let nextOverride: ManualWindowOverride?
        if workspaceManager.manualLayoutOverride(for: token) != nil {
            nextOverride = nil
        } else {
            nextOverride = entry.mode == .tiling ? .forceFloat : .forceTile
        }

        applyManagedWindowOverride(nextOverride, for: token, entry: entry)
    }

    func assignFocusedWindowToScratchpad() {
        guard let token = focusedManagedTokenForCommand(),
              let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token)
        else {
            return
        }

        if workspaceManager.isScratchpadToken(token) {
            guard !workspaceManager.isHiddenInCorner(token) else { return }
            _ = workspaceManager.clearScratchpadIfMatches(token)
            applyManagedWindowOverride(.forceTile, for: token, entry: entry)
            return
        }

        if let existingScratchpadToken = workspaceManager.scratchpadToken() {
            if workspaceManager.entry(for: existingScratchpadToken) == nil {
                _ = workspaceManager.clearScratchpadIfMatches(existingScratchpadToken)
            } else {
                return
            }
        }

        let preferredMonitor = monitorForInteraction() ?? workspaceManager.monitor(for: entry.workspaceId)
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(token, preferredMonitor: preferredMonitor) else {
            return
        }

        _ = workspaceManager.setScratchpadToken(token)

        guard let updatedEntry = workspaceManager.entry(for: token),
              let hideMonitor = workspaceManager.monitor(for: updatedEntry.workspaceId) ?? preferredMonitor
        else {
            return
        }

        hideScratchpadWindow(updatedEntry, monitor: hideMonitor)

        if transitionedFromTiling {
            layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        }
    }

    private func applyManagedWindowOverride(
        _ override: ManualWindowOverride?,
        for token: WindowToken,
        entry: WindowModel.Entry
    ) {
        workspaceManager.setManualLayoutOverride(override, for: token)
        let evaluation = evaluateWindowDisposition(
            axRef: entry.axRef,
            pid: token.pid
        )
        guard let trackedMode = trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: entry
        ) else {
            _ = workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
            layoutRefreshController.requestRelayout(
                reason: .windowRuleReevaluation,
                affectedWorkspaceIds: [entry.workspaceId]
            )
            return
        }

        _ = transitionWindowMode(
            for: token,
            to: trackedMode,
            preferredMonitor: monitorForInteraction(),
            applyFloatingFrame: true
        )
        layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    func toggleScratchpadWindow() {
        guard let scratchpadToken = workspaceManager.scratchpadToken() else { return }
        guard let entry = workspaceManager.entry(for: scratchpadToken) else {
            _ = workspaceManager.clearScratchpadIfMatches(scratchpadToken)
            return
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(scratchpadToken) else { return }
        guard let target = currentScratchpadTarget() else { return }

        if let hiddenState = workspaceManager.hiddenState(for: scratchpadToken) {
            let updatedEntry = workspaceManager.entry(for: scratchpadToken) ?? entry
            if hiddenState.isScratchpad || hiddenState.workspaceInactive {
                showScratchpadWindow(updatedEntry, on: target.workspaceId, monitor: target.monitor)
            }
            return
        }

        let hasCapturedGeometry = captureVisibleFloatingGeometry(
            for: scratchpadToken,
            preferredMonitor: target.monitor
        ) != nil || workspaceManager.floatingState(for: scratchpadToken) != nil
        guard hasCapturedGeometry else { return }

        if entry.workspaceId == target.workspaceId,
           isManagedWindowDisplayable(entry.handle)
        {
            hideScratchpadWindow(entry, monitor: target.monitor)
            return
        }

        showScratchpadWindow(entry, on: target.workspaceId, monitor: target.monitor)
    }

    func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        workspaceManager.entry(forPid: pid, windowId: windowId)?.workspaceId
    }

    func openCommandPalette() { CommandPaletteController.shared.toggle(wmController: self) }
    func openMenuAnywhere() { windowActionHandler.openMenuAnywhere() }
    func navigateToCommandPaletteWindow(_ handle: WindowHandle) { windowActionHandler.navigateToWindow(handle: handle) }
    func summonCommandPaletteWindowRight(
        _ handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) {
        windowActionHandler.summonWindowRight(
            handle: handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }
    func toggleOverview() { windowActionHandler.toggleOverview() }
    func raiseAllFloatingWindows() { windowActionHandler.raiseAllFloatingWindows() }
    func isOverviewOpen() -> Bool { windowActionHandler.isOverviewOpen() }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(for workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        )
    }

    func reassignManagedWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID
    ) {
        workspaceManager.setWorkspace(for: token, to: workspaceId)
        guard let entry = workspaceManager.entry(for: token) else { return }
        focusBridge.updateFocusedTargetWorkspace(
            matching: token,
            axRef: entry.axRef,
            workspaceId: entry.workspaceId
        )
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId?
    ) {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        if let engine = niriEngine,
           let preferredNodeId,
           let node = engine.findNode(by: preferredNodeId) as? NiriWindow
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitorId
            )
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    func ensureFocusedTokenValid(in workspaceId: WorkspaceDescriptor.ID) {
        guard !shouldSuppressManagedFocusRecovery else { return }
        guard !workspaceManager.hasPendingNativeFullscreenTransition else { return }

        if let pendingFocusedToken = workspaceManager.pendingFocusedToken,
           workspaceManager.pendingFocusedWorkspaceId == workspaceId
        {
            if let engine = niriEngine,
               let node = engine.findNode(for: pendingFocusedToken)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: pendingFocusedToken,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId)
                )
            } else {
                _ = workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: workspaceId,
                        viewportState: nil,
                        rememberedFocusToken: pendingFocusedToken
                    )
                )
            }
            return
        }

        if let focusedToken = workspaceManager.focusedToken,
           workspaceManager.entry(for: focusedToken)?.workspaceId == workspaceId
        {
            if let engine = niriEngine,
               let node = engine.findNode(for: focusedToken)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: focusedToken,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId)
                )
            } else {
                _ = workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: workspaceId,
                        viewportState: nil,
                        rememberedFocusToken: focusedToken
                    )
                )
            }
            return
        }

        guard let nextFocusToken = workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        ) else {
            return
        }

        if let engine = niriEngine,
           let node = engine.findNode(for: nextFocusToken)
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: nextFocusToken,
                in: workspaceId
            )
        }
        focusWindow(nextFocusToken)
    }

    func moveMouseToWindow(_ handle: WindowHandle) {
        moveMouseToWindow(handle.id)
    }

    func moveMouseToWindow(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
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
        return ownedWindowRegistry.contains(point: point)
    }

    var hasFrontmostOwnedWindow: Bool {
        ownedWindowRegistry.hasFrontmostWindow
    }

    var hasVisibleOwnedWindow: Bool {
        ownedWindowRegistry.hasVisibleWindow
    }

    func isOwnedWindow(windowNumber: Int) -> Bool {
        ownedWindowRegistry.contains(windowNumber: windowNumber)
    }

    var shouldSuppressManagedFocusRecovery: Bool {
        workspaceManager.isNonManagedFocusActive && hasFrontmostOwnedWindow
    }

    func performWindowFronting(
        pid: pid_t,
        windowId: Int,
        axRef: AXWindowRef
    ) {
        windowFocusOperations.activateApp(pid)
        windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
        windowFocusOperations.raiseWindow(axRef.element)
    }

    func focusWindow(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(token) else { return }

        _ = workspaceManager.beginManagedFocusRequest(
            token,
            in: entry.workspaceId,
            onMonitor: workspaceManager.monitorId(for: entry.workspaceId)
        )
        let request = focusBridge.beginManagedRequest(
            token: token,
            workspaceId: entry.workspaceId
        )
        recordNiriCreateFocusTrace(
            .pendingFocusStarted(
                requestId: request.requestId,
                token: token,
                workspaceId: entry.workspaceId
            )
        )

        let axRef = entry.axRef
        let pid = entry.pid
        let windowId = entry.windowId

        focusBridge.focusWindow(
            token,
            performFocus: {
                self.performWindowFronting(pid: pid, windowId: windowId, axRef: axRef)
                self.axEventHandler.probeFocusedWindowAfterFronting(
                    expectedToken: token,
                    workspaceId: entry.workspaceId
                )
            },
            onDeferredFocus: { [weak self] deferred in
                guard let self, self.workspaceManager.entry(for: deferred) != nil else { return }
                self.focusWindow(deferred)
            }
        )
    }

    func focusWindow(_ handle: WindowHandle) {
        focusWindow(handle.id)
    }

    func keyboardFocusTarget(for token: WindowToken, axRef: AXWindowRef) -> KeyboardFocusTarget {
        if let entry = workspaceManager.entry(for: token) {
            return KeyboardFocusTarget(
                token: token,
                axRef: entry.axRef,
                workspaceId: entry.workspaceId,
                isManaged: true
            )
        }

        return KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: nil,
            isManaged: false
        )
    }

    func managedKeyboardFocusTarget(for token: WindowToken) -> KeyboardFocusTarget? {
        guard let entry = workspaceManager.entry(for: token) else { return nil }
        return KeyboardFocusTarget(
            token: token,
            axRef: entry.axRef,
            workspaceId: entry.workspaceId,
            isManaged: true
        )
    }

    func currentKeyboardFocusTargetForRendering() -> KeyboardFocusTarget? {
        if let focusedTarget = focusBridge.focusedTarget {
            return focusedTarget
        }

        guard !workspaceManager.isNonManagedFocusActive,
              let focusedToken = workspaceManager.focusedToken
        else {
            return nil
        }

        return managedKeyboardFocusTarget(for: focusedToken)
    }

    func preferredKeyboardFocusFrame(for token: WindowToken) -> CGRect? {
        if let node = niriEngine?.findNode(for: token) {
            return node.renderedFrame ?? node.frame
        }
        if let node = dwindleEngine?.findNode(for: token) {
            return node.cachedFrame
        }
        if let floatingState = workspaceManager.floatingState(for: token) {
            return floatingState.lastFrame
        }
        return nil
    }

    @discardableResult
    func renderKeyboardFocusBorder(
        for target: KeyboardFocusTarget? = nil,
        preferredFrame: CGRect? = nil,
        policy: KeyboardFocusBorderRenderPolicy = .coordinated
    ) -> Bool {
        borderCoordinator.renderBorder(
            for: target ?? currentKeyboardFocusTargetForRendering(),
            preferredFrame: preferredFrame,
            policy: policy
        )
    }

    @discardableResult
    func reapplyKeyboardFocusBorderIfMatching(
        token: WindowToken,
        preferredFrame: CGRect? = nil,
        phase: ManagedBorderReapplyPhase,
        policy: KeyboardFocusBorderRenderPolicy = .direct
    ) -> Bool {
        guard currentKeyboardFocusTargetForRendering()?.token == token else { return false }
        recordNiriCreateFocusTrace(.borderReapplied(token: token, phase: phase))
        return renderKeyboardFocusBorder(preferredFrame: preferredFrame, policy: policy)
    }

    func clearKeyboardFocusTarget(
        matching token: WindowToken? = nil,
        pid: pid_t? = nil,
        restoreCurrentBorder: Bool = false
    ) {
        focusBridge.clearFocusedTarget(matching: token, pid: pid)
        guard restoreCurrentBorder else { return }
        _ = renderKeyboardFocusBorder(policy: .direct)
    }

    func recordNiriCreateFocusTrace(_ kind: NiriCreateFocusTraceEvent.Kind) {
        axEventHandler.recordNiriCreateFocusTrace(.init(kind: kind))
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }

    var isInteractiveGestureActive: Bool {
        mouseEventHandler.isInteractiveGestureActive
    }
}
