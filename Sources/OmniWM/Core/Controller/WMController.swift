// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct WindowFocusOperations {
    let activateApp: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let raiseWindow: (AXUIElement) -> Void

    static let live = WMPlatform.live.windowFocusOperations
}

enum NativeFullscreenRestoreSeedPath: String {
    case manualCapture = "manual_capture"
    case commandDrivenEnter = "command_driven_enter"
    case commandExitSetFailure = "command_exit_set_failure"
    case directActivationEnter = "direct_activation_enter"
    case fullRescanExistingEntryFullscreen = "full_rescan_existing_entry_fullscreen"
    case fullRescanNativeFullscreenRestore = "full_rescan_native_fullscreen_restore"
    case delayedSameTokenFullscreenReappearance = "delayed_same_token_fullscreen_reappearance"
    case delayedReplacementTokenFullscreenReappearance = "delayed_replacement_token_fullscreen_reappearance"
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
    private(set) var desiredEnabled: Bool = true
    private(set) var desiredHotkeysEnabled: Bool = true
    private(set) var accessibilityPermissionGranted = AccessibilityPermissionMonitor.shared.isGranted
    private(set) var focusFollowsMouseEnabled: Bool = false
    private(set) var moveMouseToFocusedWindowEnabled: Bool = false

    let settings: SettingsStore
    let workspaceManager: WorkspaceManager
    let platform: WMPlatform
    private let hotkeys = HotkeyCenter()
    let secureInputMonitor = SecureInputMonitor()
    let lockScreenObserver = LockScreenObserver()
    var isLockScreenActive: Bool = false
    let axManager = AXManager()
    let appInfoCache = AppInfoCache()
    let focusBridge: FocusBridgeCoordinator
    let focusPolicyEngine: FocusPolicyEngine
    private let restorePlanner = RestorePlanner()
    @ObservationIgnored
    private var managedRestoreFastPathIdentitiesByWindowId: [Int: ManagedRestoreFastPathIdentity] =
        [:]

    private struct LastKnownNiriStateCacheEntry {
        var state: ManagedWindowRestoreSnapshot.NiriState
        var workspaceId: WorkspaceDescriptor.ID
        var topologyProfile: TopologyProfile
    }

    // Last-known Niri column context per managed token. Survives temporary
    // Niri-tree absence (e.g. when a macOS native fullscreen transition removes
    // the window from the tree before the AX fullscreen-enter observation
    // resolves its restore seed). Written from `captureNiriRestoreState` on
    // success, retained across destroy, migrated on rekey, and overwritten on
    // any later successful capture. Reads are validated against the current
    // workspace and topology before restore code trusts cached membership.
    @ObservationIgnored
    private var lastKnownNiriStateByToken: [WindowToken: LastKnownNiriStateCacheEntry] =
        [:]
    let windowRuleEngine = WindowRuleEngine()

    var niriEngine: NiriLayoutEngine?
    var dwindleEngine: DwindleLayoutEngine?

    let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    lazy var borderManager: BorderManager = .init()
    @ObservationIgnored
    private lazy var workspaceBarManager: WorkspaceBarManager = .init(motionPolicy: motionPolicy)
    @ObservationIgnored
    private var workspaceBarRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var pendingWorkspaceBarRefreshGeneration: UInt64?
    @ObservationIgnored
    private var hiddenWorkspaceBarMonitorIds: Set<Monitor.ID> = []
    @ObservationIgnored
    private let hiddenBarController: HiddenBarController
    @ObservationIgnored
    private lazy var quakeTerminalController: QuakeTerminalController = .init(
        settings: settings,
        motionPolicy: motionPolicy,
        captureRestoreTarget: { [weak self] in
            guard let self else { return nil }
            return self.captureQuakeTerminalRestoreTarget()
        },
        restoreFocusTarget: { [weak self] target in
            self?.restoreQuakeTerminalFocus(to: target)
        }
    )
    @ObservationIgnored
    private lazy var commandPaletteController: CommandPaletteController = .init(motionPolicy: motionPolicy)
    @ObservationIgnored
    private lazy var sponsorsWindowController: SponsorsWindowController = .init(
        motionPolicy: motionPolicy,
        ownedWindowRegistry: ownedWindowRegistry
    )

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
    @ObservationIgnored
    weak var runtime: WMRuntime?
    @ObservationIgnored
    private var isApplyingRuntimeConfiguration = false

    let animationClock = AnimationClock()
    let motionPolicy: MotionPolicy
    private let windowFocusOperations: WindowFocusOperations
    weak var statusBarController: StatusBarController?

    init(
        settings: SettingsStore,
        workspaceManager: WorkspaceManager? = nil,
        hiddenBarController: HiddenBarController? = nil,
        platform: WMPlatform = .live,
        windowFocusOperations: WindowFocusOperations? = nil
    ) {
        self.settings = settings
        self.platform = platform
        motionPolicy = MotionPolicy(animationsEnabled: settings.animationsEnabled)
        self.hiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.windowFocusOperations = windowFocusOperations ?? platform.windowFocusOperations
        self.workspaceManager = workspaceManager ?? WorkspaceManager(settings: settings)
        focusBridge = FocusBridgeCoordinator()
        focusPolicyEngine = FocusPolicyEngine()
        self.workspaceManager.updateAnimationClock(animationClock)
        hotkeys.onCommand = { [weak self] command in
            self?.commandHandler.handleCommand(command)
        }
        self.workspaceManager.onWindowRemoved = { [weak self] token in
            self?.invalidateManagedRestoreFastPathIdentity(forWindowId: token.windowId)
        }
        self.workspaceManager.onWindowRekeyed = { [weak self] oldToken, newToken in
            self?.invalidateManagedRestoreFastPathIdentityForRekey(
                from: oldToken,
                to: newToken
            )
        }
        tabbedOverlayManager.onSelect = { [weak self] workspaceId, columnId, visualIndex in
            self?.layoutRefreshController.selectTabInNiri(
                workspaceId: workspaceId,
                columnId: columnId,
                visualIndex: visualIndex
            )
        }
        self.workspaceManager.onSessionStateChanged = { [weak self] in
            self?.handleSessionStateChanged()
        }
        axManager.onFrameConfirmed = { [weak self] pid, windowId, frame, frameConfirmResult in
            self?.recordManagedRestoreGeometry(
                for: WindowToken(pid: pid, windowId: windowId),
                frame: frame,
                reason: .frameConfirmed,
                frameConfirmResult: frameConfirmResult
            )
        }
        focusPolicyEngine.onLeaseChanged = { [weak self] lease in
            self?.submitRuntimeEvent(
                .focusLeaseChanged(
                    lease: lease,
                    source: .focusPolicy
                )
            )
        }
        MenuAnywhereController.shared.onMenuTrackingChanged = { [weak self] isTracking in
            guard let self else { return }
            if isTracking {
                self.focusPolicyEngine.beginLease(
                    owner: .nativeMenu,
                    reason: "menu_anywhere",
                    suppressesFocusFollowsMouse: true,
                    duration: nil
                )
            } else {
                self.focusPolicyEngine.endLease(owner: .nativeMenu)
            }
        }
    }

    func applyPersistedSettings(_ settings: SettingsStore) {
        if let runtime, runtime.settings === settings {
            runtime.applyConfiguration(WMRuntimeConfiguration(settings: settings))
            return
        }
        applyConfiguration(WMRuntimeConfiguration(settings: settings))
    }

    private func routeConfigurationMutationThroughRuntime() -> Bool {
        guard let runtime, !isApplyingRuntimeConfiguration else { return false }
        runtime.applyCurrentConfiguration()
        return true
    }

    func applyConfiguration(_ configuration: WMRuntimeConfiguration) {
        isApplyingRuntimeConfiguration = true
        defer { isApplyingRuntimeConfiguration = false }

        setAnimationsEnabled(configuration.animationsEnabled, persist: false)
        applyAppearanceMode(configuration.appearanceMode)

        updateHotkeyBindings(configuration.hotkeyBindings)
        setHotkeysEnabled(configuration.hotkeysEnabled)

        setGapSize(configuration.layout.gapSize)
        setOuterGaps(
            left: configuration.layout.outerGaps.left,
            right: configuration.layout.outerGaps.right,
            top: configuration.layout.outerGaps.top,
            bottom: configuration.layout.outerGaps.bottom
        )

        if niriEngine == nil {
            enableNiriLayout(
                maxWindowsPerColumn: configuration.layout.niri.maxWindowsPerColumn,
                centerFocusedColumn: configuration.layout.niri.centerFocusedColumn,
                alwaysCenterSingleColumn: configuration.layout.niri.alwaysCenterSingleColumn
            )
        }
        updateNiriConfig(
            maxWindowsPerColumn: configuration.layout.niri.maxWindowsPerColumn,
            maxVisibleColumns: configuration.layout.niri.maxVisibleColumns,
            infiniteLoop: configuration.layout.niri.infiniteLoop,
            centerFocusedColumn: configuration.layout.niri.centerFocusedColumn,
            alwaysCenterSingleColumn: configuration.layout.niri.alwaysCenterSingleColumn,
            singleWindowAspectRatio: configuration.layout.niri.singleWindowAspectRatio,
            columnWidthPresets: configuration.layout.niri.columnWidthPresets,
            defaultColumnWidth: configuration.layout.niri.defaultColumnWidth
        )

        if dwindleEngine == nil {
            enableDwindleLayout()
        }
        updateDwindleConfig(
            smartSplit: configuration.layout.dwindle.smartSplit,
            defaultSplitRatio: configuration.layout.dwindle.defaultSplitRatio,
            splitWidthMultiplier: configuration.layout.dwindle.splitWidthMultiplier,
            singleWindowAspectRatio: configuration.layout.dwindle.singleWindowAspectRatio
        )

        updateWorkspaceConfig()
        updateMonitorOrientations()
        updateMonitorNiriSettings()
        updateMonitorDwindleSettings()
        updateAppRules()

        setBordersEnabled(configuration.borderConfig.enabled)
        updateBorderConfig(configuration.borderConfig)

        setFocusFollowsMouse(configuration.focusFollowsMouse)
        setMoveMouseToFocusedWindow(configuration.moveMouseToFocusedWindow)

        setWorkspaceBarEnabled(configuration.workspaceBarEnabled)
        setPreventSleepEnabled(configuration.preventSleepEnabled)
        setQuakeTerminalEnabled(configuration.quakeTerminalEnabled)

        setEnabled(true)
        refreshStatusBar()
    }

    @discardableResult
    func submitRuntimeEvent(_ event: WMEvent) -> ReconcileTxn {
        runtime?.submit(event) ?? workspaceManager.recordReconcileEvent(event)
    }

    func setAnimationsEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist, settings.animationsEnabled != enabled {
            settings.animationsEnabled = enabled
        }
        if persist, routeConfigurationMutationThroughRuntime() {
            return
        }

        guard motionPolicy.animationsEnabled != enabled else {
            statusBarController?.rebuildMenu()
            return
        }

        motionPolicy.animationsEnabled = enabled
        statusBarController?.rebuildMenu()
    }

    func applyCurrentAppearanceMode() {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        applyAppearanceMode(settings.appearanceMode)
    }

    func applyAppearanceMode(_ appearanceMode: AppearanceMode) {
        appearanceMode.apply()
        workspaceBarManager.updateSettings()
        statusBarController?.rebuildMenu()
    }

    func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        if enabled {
            serviceLifecycleManager.start()
        } else {
            serviceLifecycleManager.stop()
        }
        reconcileEnabledAndHotkeysState()
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        desiredHotkeysEnabled = enabled
        reconcileEnabledAndHotkeysState()
    }

    func updateAccessibilityPermissionGranted(_ granted: Bool) {
        accessibilityPermissionGranted = granted
        reconcileEnabledAndHotkeysState()
    }

    func reconcileEnabledAndHotkeysState() {
        isEnabled = desiredEnabled && accessibilityPermissionGranted

        let shouldEnableHotkeys = desiredHotkeysEnabled
            && isEnabled
            && hasStartedServices
            && !serviceLifecycleManager.isSecureInputActive
        hotkeysEnabled = shouldEnableHotkeys
        shouldEnableHotkeys ? hotkeys.start() : hotkeys.stop()
    }

    func setGapSize(_ size: Double) {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        workspaceManager.setGaps(to: size)
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        workspaceManager.setOuterGaps(left: left, right: right, top: top, bottom: bottom)
    }

    func setBordersEnabled(_ enabled: Bool) {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        if !enabled {
            _ = borderCoordinator.hideBorder(
                source: .cleanup,
                reason: "borders disabled"
            )
        }
        borderManager.setEnabled(enabled)
    }

    func updateBorderConfig(_ config: BorderConfig) {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        if !config.enabled {
            _ = borderCoordinator.hideBorder(
                source: .cleanup,
                reason: "border config disabled"
            )
        }
        borderManager.updateConfig(config)
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if settings.workspaceBarEnabled != enabled {
            settings.workspaceBarEnabled = enabled
        }
        if routeConfigurationMutationThroughRuntime() {
            return
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
        if routeConfigurationMutationThroughRuntime() {
            return
        }
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
        if routeConfigurationMutationThroughRuntime() {
            return
        }
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
        if routeConfigurationMutationThroughRuntime() {
            return
        }
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
              let workspace = workspaceManager.currentActiveWorkspace(on: monitor.id)
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
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        pruneHiddenWorkspaceBarMonitorIds()
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.updateSettings()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateWorkspaceBarAppearance() {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        pruneHiddenWorkspaceBarMonitorIds()
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.update()
    }

    func updateMonitorOrientations() {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        let monitors = workspaceManager.monitors
        for monitor in monitors {
            let orientation = settings.effectiveOrientation(for: monitor)
            niriEngine?.monitors[monitor.id]?.updateOrientation(orientation)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorNiriSettings() {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        guard niriEngine != nil else { return }
        niriLayoutHandler.refreshResolvedMonitorSettings()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorDwindleSettings() {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        guard dwindleEngine != nil else { return }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func workspaceBarItems(
        for monitor: Monitor,
        projection options: WorkspaceBarProjectionOptions
    ) -> [WorkspaceBarItem] {
        WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: options,
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
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
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
        let scale = layoutRefreshController.backingScale(for: monitor)
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
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        layoutRefreshController.requestFullRescan(reason: .workspaceConfigChanged)
    }

    func rebuildAppRulesCache() {
        windowRuleEngine.rebuild(rules: settings.appRules)
    }

    func updateAppRules() {
        if routeConfigurationMutationThroughRuntime() {
            return
        }
        rebuildAppRulesCache()
        layoutRefreshController.requestFullRescan(reason: .appRulesChanged)
    }

    var hotkeyRegistrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] {
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

    func workspaceBarHostingViewIdentifierForTests(on monitorId: Monitor.ID) -> ObjectIdentifier? {
        workspaceBarManager.hostingViewIdentifierForTests(on: monitorId)
    }

    func workspaceBarLastAppliedFrameForTests(on monitorId: Monitor.ID) -> CGRect? {
        workspaceBarManager.lastAppliedFrameForTests(on: monitorId)
    }

    func workspaceBarSnapshotForTests(on monitorId: Monitor.ID) -> WorkspaceBarSnapshot? {
        workspaceBarManager.snapshotForTests(on: monitorId)
    }

    func isWorkspaceBarRuntimeHiddenForTests(on monitorId: Monitor.ID) -> Bool {
        hiddenWorkspaceBarMonitorIds.contains(monitorId)
    }

    func managedRestoreFastPathCacheWindowIdsForTests() -> Set<Int> {
        Set(managedRestoreFastPathIdentitiesByWindowId.keys)
    }

    func lastKnownNiriStateForTests(
        token: WindowToken
    ) -> ManagedWindowRestoreSnapshot.NiriState? {
        lastKnownNiriStateByToken[token]?.state
    }

    func setLastKnownNiriStateForTests(
        _ state: ManagedWindowRestoreSnapshot.NiriState,
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        topologyProfile: TopologyProfile? = nil
    ) {
        guard let cacheWorkspaceId = workspaceId ?? workspaceManager.workspace(for: token) else {
            return
        }
        lastKnownNiriStateByToken[token] = LastKnownNiriStateCacheEntry(
            state: state,
            workspaceId: cacheWorkspaceId,
            topologyProfile: topologyProfile ?? workspaceManager.topologyProfile
        )
    }

    func configureWorkspaceBarManagerForTests(
        monitors: [Monitor],
        panelFactory: (@MainActor @Sendable () -> WorkspaceBarPanel)? = nil,
        frameApplier: (@MainActor @Sendable (WorkspaceBarPanel, NSRect) -> Void)? = nil
    ) {
        workspaceBarManager.monitorProvider = { monitors }
        workspaceBarManager.screenProvider = { _ in nil }
        if let panelFactory {
            workspaceBarManager.panelFactory = panelFactory
        }
        if let frameApplier {
            workspaceBarManager.frameApplier = frameApplier
        }
    }

    func configureQuakeTransitionForTests(
        visible: Bool,
        isTransitioning: Bool
    ) {
        quakeTerminalController.configureTransitionStateForTests(
            visible: visible,
            isTransitioning: isTransitioning
        )
    }

    func quakeTerminalIsTransitioningForTests() -> Bool {
        quakeTerminalController.isTransitioningForTests
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
            ?? FrontmostApplicationState.shared.snapshot?.pid
        let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        if preferFrontmostWhenNonManagedFocusActive, workspaceManager.isNonManagedFocusActive {
            return frontmostToken ?? focusedToken
        }
        return focusedToken ?? frontmostToken
    }

    func captureQuakeTerminalRestoreTarget() -> QuakeTerminalRestoreTarget? {
        if let target = currentKeyboardFocusTargetForRendering() {
            return target.isManaged ? .managed(target.token) : .external(target)
        }

        guard let frontmostToken = focusedOrFrontmostWindowTokenForAutomation(
            preferFrontmostWhenNonManagedFocusActive: true
        ) else {
            return nil
        }

        if workspaceManager.entry(for: frontmostToken) != nil {
            return .managed(frontmostToken)
        }

        guard let axRef = axEventHandler.axWindowRefProvider?(UInt32(frontmostToken.windowId), frontmostToken.pid)
            ?? AXWindowService.axWindowRef(for: UInt32(frontmostToken.windowId), pid: frontmostToken.pid)
        else {
            return nil
        }

        return .external(
            KeyboardFocusTarget(
                token: frontmostToken,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            )
        )
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
            hideKeyboardFocusBorder(
                source: .focusClear,
                reason: "scratchpad hide cleared focused token"
            )
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
            let focusOnRevealSuccess: LayoutRefreshController.PostLayoutAction = { [weak self] in
                self?.focusWindow(entry.token)
            }
            if hiddenState.isScratchpad {
                layoutRefreshController.restoreScratchpadWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: focusOnRevealSuccess
                )
            } else {
                layoutRefreshController.unhideWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: focusOnRevealSuccess
                )
            }
            return
        }

        if let frame = workspaceManager.resolvedFloatingFrame(
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
                            policy: .coordinated,
                            source: .replacementSettle
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

            // Same guard as in the full-rescan path: when CGS just
            // destroyed this windowId, the stale AX ref we still hold
            // shouldn't be used to re-admit the window under a
            // synthetic entry. Let `trackPreparedCreate` admit the
            // genuine replacement when it arrives.
            if existingEntry == nil,
               axEventHandler.isWindowRecentlyDestroyed(windowId: token.windowId)
            {
                continue
            }

            evaluatedAnyWindow = true
            let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)

            guard let trackedMode = trackedModeForLifecycle(
                decision: evaluation.decision,
                existingEntry: existingEntry
            ) else {
                if let existingEntry {
                    affectedWorkspaceIds.insert(existingEntry.workspaceId)
                    layoutRefreshController.discardHiddenTracking(for: existingEntry.token)
                    _ = workspaceManager.removeWindow(
                        pid: token.pid,
                        windowId: token.windowId
                    )
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
                _ = workspaceManager.setManagedReplacementMetadata(
                    ManagedReplacementMetadata(
                        bundleId: evaluation.facts.ax.bundleId ?? updatedEntry.managedReplacementMetadata?.bundleId,
                        workspaceId: updatedEntry.workspaceId,
                        mode: updatedEntry.mode,
                        role: evaluation.facts.ax.role ?? updatedEntry.managedReplacementMetadata?.role,
                        subrole: evaluation.facts.ax.subrole ?? updatedEntry.managedReplacementMetadata?.subrole,
                        title: evaluation.facts.ax.title ?? updatedEntry.managedReplacementMetadata?.title,
                        windowLevel: evaluation.facts.windowServer?.level ?? updatedEntry.managedReplacementMetadata?.windowLevel,
                        parentWindowId: evaluation.facts.windowServer?.parentId ?? updatedEntry.managedReplacementMetadata?.parentWindowId,
                        frame: evaluation.facts.windowServer?.frame ?? updatedEntry.managedReplacementMetadata?.frame
                    ),
                    for: token
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
            layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [updatedEntry.workspaceId]
            )
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
            layoutRefreshController.discardHiddenTracking(for: token)
            _ = workspaceManager.removeWindow(
                pid: token.pid,
                windowId: token.windowId
            )
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

    func openCommandPalette() { commandPaletteController.toggle(wmController: self) }
    func openSponsorsWindow() { sponsorsWindowController.show() }
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
    @discardableResult
    func rescueOffscreenWindows() -> Int {
        guard !isLockScreenActive else { return 0 }

        var candidates: [RestorePlanner.FloatingRescueCandidate] = []
        let visibleWorkspaceIds = workspaceManager.visibleWorkspaceIds()

        for entry in workspaceManager.allFloatingEntries() {
            guard entry.layoutReason == .standard else { continue }
            guard visibleWorkspaceIds.contains(entry.workspaceId) else { continue }
            guard let targetMonitor = workspaceManager.monitor(for: entry.workspaceId)
                ?? monitorForInteraction()
                ?? workspaceManager.monitors.first
            , let floatingState = workspaceManager.floatingState(for: entry.token)
            else {
                continue
            }

            candidates.append(
                .init(
                    token: entry.token,
                    pid: entry.pid,
                    windowId: entry.windowId,
                    workspaceId: entry.workspaceId,
                    targetMonitor: targetMonitor,
                    currentFrame: liveFrame(for: entry),
                    floatingFrame: floatingState.lastFrame,
                    normalizedOrigin: floatingState.normalizedOrigin,
                    referenceMonitorId: floatingState.referenceMonitorId,
                    isScratchpadHidden: workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true,
                    isWorkspaceInactiveHidden: workspaceManager.hiddenState(for: entry.token)?.workspaceInactive == true
                )
            )
        }

        let rescuePlan = restorePlanner.planFloatingRescue(candidates)
        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        var rescuedEntries: [WindowModel.Entry] = []

        for operation in rescuePlan.operations {
            guard let entry = workspaceManager.entry(for: operation.token) else { continue }
            workspaceManager.updateFloatingGeometry(
                frame: operation.targetFrame,
                for: operation.token,
                referenceMonitor: operation.targetMonitor,
                restoreToFloating: true
            )
            axManager.forceApplyNextFrame(for: operation.windowId)
            frameUpdates.append((operation.pid, operation.windowId, operation.targetFrame))
            rescuedEntries.append(entry)
        }

        if !frameUpdates.isEmpty {
            axManager.applyFramesParallel(frameUpdates)
            for entry in rescuedEntries {
                windowFocusOperations.raiseWindow(entry.axRef.element)
            }
        }

        return rescuePlan.rescuedCount
    }
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
        recordManagedRestoreGeometryIfMaterialStateChanged(
            for: CGWindowID(token.windowId),
            reason: .workspaceMoved
        )
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
        guard !isCursorAutomationSuppressed else { return }
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
    var isCursorAutomationSuppressed: Bool {
        isLockScreenActive || isFrontmostAppLockScreen()
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
        ownedWindowRegistry.contains(point: point)
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

    func orchestrationSnapshot(
        refresh: RefreshOrchestrationSnapshot
    ) -> OrchestrationSnapshot {
        if let runtime {
            return runtime.orchestrationSnapshot
        }
        return OrchestrationSnapshot(
            refresh: refresh,
            focus: .init(
                nextManagedRequestId: focusBridge.nextManagedRequestId,
                activeManagedRequest: focusBridge.activeManagedRequest,
                pendingFocusedToken: workspaceManager.pendingFocusedToken,
                pendingFocusedWorkspaceId: workspaceManager.pendingFocusedWorkspaceId,
                isNonManagedFocusActive: workspaceManager.isNonManagedFocusActive,
                isAppFullscreenActive: workspaceManager.isAppFullscreenActive
            )
        )
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

    func restoreQuakeTerminalFocus(to target: QuakeTerminalRestoreTarget) {
        switch target {
        case let .managed(token):
            guard workspaceManager.entry(for: token) != nil else { return }
            focusWindow(token)

        case let .external(target):
            if workspaceManager.entry(for: target.token) != nil {
                focusWindow(target.token)
                return
            }
            guard !isLockScreenActive else { return }
            if hasStartedServices {
                guard !isFrontmostAppLockScreen() else { return }
            }

            let pid = target.pid
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated
            else {
                return
            }

            if let axRef = axEventHandler.axWindowRefProvider?(UInt32(target.windowId), pid)
                ?? AXWindowService.axWindowRef(for: UInt32(target.windowId), pid: pid)
            {
                performWindowFronting(
                    pid: pid,
                    windowId: target.windowId,
                    axRef: axRef
                )
            } else {
                windowFocusOperations.activateApp(pid)
            }
        }
    }

    func focusWindow(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(token) else { return }
        if let runtime {
            _ = runtime.requestManagedFocus(
                token: token,
                workspaceId: entry.workspaceId
            )
            return
        }

        let result = OrchestrationCore.step(
            snapshot: orchestrationSnapshot(
                refresh: .init(
                    activeRefresh: layoutRefreshController.layoutState.activeRefresh,
                    pendingRefresh: layoutRefreshController.layoutState.pendingRefresh
                )
            ),
            event: .focusRequested(
                .init(
                    token: token,
                    workspaceId: entry.workspaceId
                )
            )
        )
        applyRuntimeFocusRequestResult(result)
    }

    func applyRuntimeFocusRequestResult(_ result: OrchestrationResult) {
        focusBridge.applyOrchestrationState(
            nextManagedRequestId: result.snapshot.focus.nextManagedRequestId,
            activeManagedRequest: result.snapshot.focus.activeManagedRequest
        )
        _ = workspaceManager.applyOrchestrationFocusState(result.snapshot.focus)

        for action in result.plan.actions {
            switch action {
            case let .beginManagedFocusRequest(requestId, token, workspaceId):
                _ = workspaceManager.beginManagedFocusRequest(
                    token,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId)
                )
                let request = focusBridge.activeManagedRequest(requestId: requestId)
                assert(request?.token == token, "Unexpected focus request id drift for \(token)")
            case let .clearManagedFocusState(requestId, token, workspaceId):
                axEventHandler.clearManagedFocusStateForOrchestration(
                    requestId: requestId,
                    matching: token,
                    workspaceId: workspaceId
                )
            case let .frontManagedWindow(token, workspaceId):
                guard let deferredEntry = workspaceManager.entry(for: token) else { continue }
                let axRef = deferredEntry.axRef
                let pid = deferredEntry.pid
                let windowId = deferredEntry.windowId
                focusBridge.focusWindow(
                    token,
                    performFocus: {
                        self.performWindowFronting(pid: pid, windowId: windowId, axRef: axRef)
                        self.axEventHandler.probeFocusedWindowAfterFronting(
                            expectedToken: token,
                            workspaceId: workspaceId
                        )
                    },
                    onDeferredFocus: { [weak self] deferred in
                        guard let self, self.workspaceManager.entry(for: deferred) != nil else { return }
                        self.focusWindow(deferred)
                    }
                )
            case .beginNativeFullscreenRestoreActivation,
                 .cancelActivationRetry,
                 .cancelActiveRefresh,
                 .confirmManagedActivation,
                 .continueManagedFocusRequest,
                 .discardPostLayoutAttachments,
                 .enterNonManagedFallback,
                 .enterOwnedApplicationFallback,
                 .performVisibilitySideEffects,
                 .requestWorkspaceBarRefresh,
                 .runPostLayoutAttachments,
                 .startRefresh:
                continue
            }
        }
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

    private enum NativeFullscreenRestoreSeedStrategy {
        case preTransitionCapture
        case fullscreenDetectedManagedGeometryOnly
    }

    private struct NativeFullscreenRestoreSeedResolution {
        let restoreSnapshot: WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot?
        let restoreFailure: WorkspaceManager.NativeFullscreenRecord.RestoreFailure?
    }

    private struct ManagedRestoreFastPathNiriState: Equatable {
        let nodeId: NodeId
        let columnId: NodeId
        let workspaceColumnIds: [NodeId]
        let tileIndex: Int?
        let columnWindowTokens: [WindowToken]
        let columnSizing: ManagedWindowRestoreSnapshot.NiriState.ColumnSizing
        let windowSizing: ManagedWindowRestoreSnapshot.NiriState.WindowSizing

        func matches(_ snapshot: ManagedWindowRestoreSnapshot.NiriState?) -> Bool {
            guard let snapshot else { return false }
            guard snapshot.nodeId == nodeId,
                  snapshot.tileIndex == tileIndex,
                  snapshot.columnWindowTokens == columnWindowTokens,
                  snapshot.columnSizing == columnSizing,
                  snapshot.windowSizing == windowSizing,
                  let snapshotColumnIndex = snapshot.columnIndex,
                  workspaceColumnIds.indices.contains(snapshotColumnIndex)
            else {
                return false
            }
            return workspaceColumnIds[snapshotColumnIndex] == columnId
        }
    }

    private struct ManagedRestoreFastPathIdentity: Equatable {
        let workspaceId: WorkspaceDescriptor.ID
        let frame: ManagedWindowRestoreSnapshot.SemanticIdentity.QuantizedFrame
        let topologyProfile: TopologyProfile
        let niriState: ManagedRestoreFastPathNiriState?
        let replacementRestoreIdentity: ManagedReplacementMetadata.RestoreIdentity

        func matches(_ snapshot: ManagedWindowRestoreSnapshot) -> Bool {
            guard workspaceId == snapshot.workspaceId,
                  frame == snapshot.semanticIdentity(frameTolerance: 0.5).frame,
                  topologyProfile == snapshot.topologyProfile,
                  replacementRestoreIdentity == snapshot.replacementMetadata?.restoreIdentity
            else {
                return false
            }

            switch (niriState, snapshot.niriState) {
            case (nil, nil):
                return true
            case let (current?, snapshotState?):
                return current.matches(snapshotState)
            default:
                return false
            }
        }
    }

    private struct ManagedRestoreSnapshotPreview {
        let token: WindowToken
        let entry: WindowModel.Entry
        let frame: CGRect
        let topologyProfile: TopologyProfile
        let niriState: ManagedWindowRestoreSnapshot.NiriState?
        let provisionalMetadata: ManagedReplacementMetadata
        let needsFactRefresh: Bool

        var provisionalSnapshot: ManagedWindowRestoreSnapshot {
            ManagedWindowRestoreSnapshot(
                token: token,
                workspaceId: entry.workspaceId,
                frame: frame,
                topologyProfile: topologyProfile,
                niriState: niriState,
                replacementMetadata: provisionalMetadata
            )
        }
    }

    func recordManagedRestoreGeometry(
        for token: WindowToken,
        frame: CGRect,
        reason: ManagedRestoreTriggerReason = .frameConfirmed,
        frameConfirmResult: FrameConfirmResult? = nil
    ) {
        _ = persistManagedRestoreSnapshotIfNeeded(
            for: token,
            frame: frame,
            reason: reason,
            frameConfirmResult: frameConfirmResult
        )
    }

    func recordManagedRestoreGeometryIfMaterialStateChanged(
        for windowId: CGWindowID,
        reason: ManagedRestoreTriggerReason
    ) {
        guard let entry = workspaceManager.entry(forWindowId: Int(windowId)) else { return }
        guard let frame = resolveManagedRestoreMaterialStateFrame(for: entry.token) else { return }
        _ = persistManagedRestoreSnapshotIfNeeded(
            for: entry.token,
            frame: frame,
            reason: reason
        )
    }

    @discardableResult
    private func persistManagedRestoreSnapshotIfNeeded(
        for token: WindowToken,
        frame: CGRect,
        reason: ManagedRestoreTriggerReason = .frameConfirmed,
        frameConfirmResult: FrameConfirmResult? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        guard workspaceManager.layoutReason(for: token) != .nativeFullscreen else { return false }
        if shouldShortCircuitManagedRestoreSnapshot(for: entry, frame: frame) {
            return false
        }
        guard let preview = makeManagedRestoreSnapshotPreview(for: entry, frame: frame) else {
            return false
        }

        if !preview.needsFactRefresh,
           !workspaceManager.shouldPersistManagedRestoreSnapshot(
               preview.provisionalSnapshot,
               for: preview.token
           )
        {
            return false
        }

        let snapshot = makeManagedWindowRestoreSnapshot(from: preview)
        guard workspaceManager.shouldPersistManagedRestoreSnapshot(snapshot, for: token) else {
            return false
        }

        guard workspaceManager.setManagedRestoreSnapshot(snapshot, for: token) else {
            return false
        }
        cacheManagedRestoreFastPathIdentity(
            for: entry,
            frame: frame,
            topologyProfile: snapshot.topologyProfile,
            replacementMetadata: snapshot.replacementMetadata
        )
        return true
    }

    private func makeManagedRestoreSnapshotPreview(
        for entry: WindowModel.Entry,
        frame: CGRect
    ) -> ManagedRestoreSnapshotPreview? {
        let niriState = captureNiriRestoreState(for: entry.token, workspaceId: entry.workspaceId)
        let provisionalMetadata = provisionalManagedRestoreReplacementMetadata(
            for: entry,
            frame: frame
        )
        return ManagedRestoreSnapshotPreview(
            token: entry.token,
            entry: entry,
            frame: frame,
            topologyProfile: workspaceManager.topologyProfile,
            niriState: niriState,
            provisionalMetadata: provisionalMetadata,
            needsFactRefresh: managedRestoreMetadataNeedsAXFactRefresh(
                provisionalMetadata: provisionalMetadata
            )
        )
    }

    private func makeManagedWindowRestoreSnapshot(
        for token: WindowToken,
        frame: CGRect
    ) -> ManagedWindowRestoreSnapshot? {
        guard let entry = workspaceManager.entry(for: token) else { return nil }
        if shouldShortCircuitManagedRestoreSnapshot(for: entry, frame: frame) {
            return nil
        }
        guard let preview = makeManagedRestoreSnapshotPreview(for: entry, frame: frame) else {
            return nil
        }
        if !preview.needsFactRefresh,
           !workspaceManager.shouldPersistManagedRestoreSnapshot(
               preview.provisionalSnapshot,
               for: preview.token
           )
        {
            return nil
        }
        return makeManagedWindowRestoreSnapshot(from: preview)
    }

    private func makeManagedWindowRestoreSnapshot(
        from preview: ManagedRestoreSnapshotPreview
    ) -> ManagedWindowRestoreSnapshot {
        let replacementMetadata = finalizedManagedRestoreReplacementMetadata(
            for: preview.entry,
            frame: preview.frame,
            provisionalMetadata: preview.provisionalMetadata,
            needsFactRefresh: preview.needsFactRefresh
        )
        return ManagedWindowRestoreSnapshot(
            token: preview.token,
            workspaceId: preview.entry.workspaceId,
            frame: preview.frame,
            topologyProfile: preview.topologyProfile,
            niriState: preview.niriState,
            replacementMetadata: replacementMetadata
        )
    }

    private func shouldShortCircuitManagedRestoreSnapshot(
        for entry: WindowModel.Entry,
        frame: CGRect
    ) -> Bool {
        guard let previousSnapshot = workspaceManager.managedRestoreSnapshot(for: entry.token),
              let currentIdentity = captureManagedRestoreFastPathIdentity(
                  for: entry,
                  frame: frame
              )
        else {
            return false
        }

        if let cachedIdentity = managedRestoreFastPathIdentitiesByWindowId[entry.windowId],
           cachedIdentity.matches(previousSnapshot),
           cachedIdentity == currentIdentity
        {
            managedRestoreFastPathIdentitiesByWindowId[entry.windowId] = currentIdentity
            return true
        }

        guard currentIdentity.matches(previousSnapshot) else { return false }
        managedRestoreFastPathIdentitiesByWindowId[entry.windowId] = currentIdentity
        return true
    }

    private func captureManagedRestoreFastPathIdentity(
        for entry: WindowModel.Entry,
        frame: CGRect,
        topologyProfile: TopologyProfile? = nil,
        replacementMetadata: ManagedReplacementMetadata? = nil
    ) -> ManagedRestoreFastPathIdentity? {
        let resolvedReplacementMetadata = replacementMetadata
            ?? fastManagedRestoreReplacementMetadata(for: entry, frame: frame)
        guard resolvedReplacementMetadata.bundleId != nil,
              !managedRestoreMetadataNeedsAXFactRefresh(
                  provisionalMetadata: resolvedReplacementMetadata
              )
        else {
            return nil
        }

        return ManagedRestoreFastPathIdentity(
            workspaceId: entry.workspaceId,
            frame: .init(
                frame: frame,
                tolerance: WorkspaceManager.managedRestoreSnapshotFrameTolerance
            ),
            topologyProfile: topologyProfile ?? workspaceManager.topologyProfile,
            niriState: captureManagedRestoreFastPathNiriState(
                for: entry.token,
                workspaceId: entry.workspaceId
            ),
            replacementRestoreIdentity: resolvedReplacementMetadata.restoreIdentity
        )
    }

    private func cacheManagedRestoreFastPathIdentity(
        for entry: WindowModel.Entry,
        frame: CGRect,
        topologyProfile: TopologyProfile,
        replacementMetadata: ManagedReplacementMetadata?
    ) {
        managedRestoreFastPathIdentitiesByWindowId[entry.windowId] =
            captureManagedRestoreFastPathIdentity(
                for: entry,
                frame: frame,
                topologyProfile: topologyProfile,
                replacementMetadata: replacementMetadata
            )
    }

    private func invalidateManagedRestoreFastPathIdentity(forWindowId windowId: Int) {
        managedRestoreFastPathIdentitiesByWindowId.removeValue(forKey: windowId)
        // `lastKnownNiriStateByToken` is intentionally NOT cleared here. Its
        // whole reason to exist is to survive transient Niri-tree absence
        // during a macOS native fullscreen transition — if a brief
        // removal/re-add cycle fires on the token between "capture succeeded
        // pre-fullscreen" and "suspend resolves the restore seed", dropping
        // the entry on removal would defeat the cache. Stale entries are
        // overwritten on any future successful capture.
    }

    private func invalidateManagedRestoreFastPathIdentityForRekey(
        from oldToken: WindowToken,
        to newToken: WindowToken
    ) {
        managedRestoreFastPathIdentitiesByWindowId.removeValue(forKey: oldToken.windowId)
        guard newToken != oldToken else { return }
        managedRestoreFastPathIdentitiesByWindowId.removeValue(forKey: newToken.windowId)
        migrateLastKnownNiriState(from: oldToken, to: newToken)
    }

    private func migrateLastKnownNiriState(
        from oldToken: WindowToken,
        to newToken: WindowToken
    ) {
        guard let cacheEntry = lastKnownNiriStateByToken.removeValue(forKey: oldToken) else {
            return
        }
        let state = cacheEntry.state
        let migratedState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: state.nodeId,
            columnIndex: state.columnIndex,
            tileIndex: state.tileIndex,
            columnWindowTokens: state.columnWindowTokens.map { member in
                member == oldToken ? newToken : member
            },
            columnSizing: state.columnSizing,
            windowSizing: state.windowSizing
        )
        lastKnownNiriStateByToken[newToken] = LastKnownNiriStateCacheEntry(
            state: migratedState,
            workspaceId: cacheEntry.workspaceId,
            topologyProfile: cacheEntry.topologyProfile
        )
    }

    private func lastKnownNiriState(
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        topologyProfile: TopologyProfile? = nil
    ) -> ManagedWindowRestoreSnapshot.NiriState? {
        guard let cacheEntry = lastKnownNiriStateByToken[token] else { return nil }
        let expectedWorkspaceId = workspaceId ?? workspaceManager.workspace(for: token)
        let expectedTopologyProfile = topologyProfile ?? workspaceManager.topologyProfile
        guard let expectedWorkspaceId,
              cacheEntry.workspaceId == expectedWorkspaceId,
              cacheEntry.topologyProfile == expectedTopologyProfile
        else {
            return nil
        }
        return cacheEntry.state
    }

    private func provisionalManagedRestoreReplacementMetadata(
        for entry: WindowModel.Entry,
        frame: CGRect
    ) -> ManagedReplacementMetadata {
        var metadata = ManagedReplacementMetadata(
            bundleId: appInfoCache.bundleId(for: entry.pid)
                ?? NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )
        if let restoreMetadata = workspaceManager.managedRestoreSnapshot(for: entry.token)?.replacementMetadata {
            metadata = metadata.mergingNonNilValues(from: restoreMetadata)
        }
        if let liveMetadata = workspaceManager.managedReplacementMetadata(for: entry.token) {
            metadata = metadata.mergingNonNilValues(from: liveMetadata)
        }
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        metadata.frame = frame
        if metadata.title == nil, let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) {
            metadata.title = title
        }
        return metadata
    }

    private func fastManagedRestoreReplacementMetadata(
        for entry: WindowModel.Entry,
        frame: CGRect
    ) -> ManagedReplacementMetadata {
        var metadata = ManagedReplacementMetadata(
            bundleId: nil,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )
        if let restoreMetadata = workspaceManager.managedRestoreSnapshot(for: entry.token)?.replacementMetadata {
            metadata = metadata.mergingNonNilValues(from: restoreMetadata)
        }
        if let liveMetadata = workspaceManager.managedReplacementMetadata(for: entry.token) {
            metadata = metadata.mergingNonNilValues(from: liveMetadata)
        }
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        metadata.frame = frame
        return metadata
    }

    private func managedRestoreMetadataNeedsAXFactRefresh(
        provisionalMetadata metadata: ManagedReplacementMetadata
    ) -> Bool {
        let canResolveWindowServerInfo = axEventHandler.windowInfoProvider != nil
        return metadata.role == nil
            || metadata.subrole == nil
            || metadata.title == nil
            || (canResolveWindowServerInfo && metadata.windowLevel == nil)
    }

    private func finalizedManagedRestoreReplacementMetadata(
        for entry: WindowModel.Entry,
        frame: CGRect,
        provisionalMetadata: ManagedReplacementMetadata,
        needsFactRefresh: Bool
    ) -> ManagedReplacementMetadata {
        var metadata = provisionalMetadata
        if needsFactRefresh {
            let appInfo = resolvedAppInfo(for: entry.pid)
            let facts = axEventHandler.windowFactsProvider?(entry.axRef, entry.pid) ?? WindowRuleFacts(
                appName: appInfo?.name,
                ax: AXWindowService.collectWindowFacts(
                    entry.axRef,
                    appPolicy: appInfo?.activationPolicy,
                    bundleId: metadata.bundleId ?? appInfo?.bundleId,
                    includeTitle: true
                ),
                sizeConstraints: nil,
                windowServer: UInt32(exactly: entry.windowId).flatMap {
                    axEventHandler.windowInfoProvider?($0)
                }
            )
            metadata.bundleId = metadata.bundleId ?? facts.ax.bundleId
            metadata.role = metadata.role ?? facts.ax.role
            metadata.subrole = metadata.subrole ?? facts.ax.subrole
            metadata.title = metadata.title ?? facts.ax.title
            metadata.windowLevel = metadata.windowLevel ?? facts.windowServer?.level
            metadata.parentWindowId = metadata.parentWindowId ?? facts.windowServer?.parentId
        }
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        metadata.frame = frame
        return metadata
    }

    private func captureNiriRestoreState(
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedWindowRestoreSnapshot.NiriState? {
        guard let engine = niriEngine,
              let node = engine.findNode(for: token),
              let column = engine.column(of: node)
        else {
            return nil
        }

        guard column.findRoot()?.workspaceId == workspaceId else {
            return nil
        }

        let columnWindowTokens = column.windowNodes.map(\.token)
        let tileIndex = columnWindowTokens.firstIndex(of: token)
        let columnIndex = engine.columnIndex(of: column, in: workspaceId)
        let niriState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: node.id,
            columnIndex: columnIndex,
            tileIndex: tileIndex,
            columnWindowTokens: columnWindowTokens,
            columnSizing: ManagedWindowRestoreSnapshot.NiriState.ColumnSizing(
                width: column.width,
                cachedWidth: column.cachedWidth,
                presetWidthIdx: column.presetWidthIdx,
                isFullWidth: column.isFullWidth,
                savedWidth: column.savedWidth,
                hasManualSingleWindowWidthOverride: column.hasManualSingleWindowWidthOverride,
                height: column.height,
                cachedHeight: column.cachedHeight,
                isFullHeight: column.isFullHeight,
                savedHeight: column.savedHeight
            ),
            windowSizing: ManagedWindowRestoreSnapshot.NiriState.WindowSizing(
                height: node.height,
                savedHeight: node.savedHeight,
                windowWidth: node.windowWidth,
                sizingMode: node.sizingMode
            )
        )
        let previous = lastKnownNiriStateByToken[token]
        let topologyProfile = workspaceManager.topologyProfile
        // Gate cache writes on a tolerance-aware comparison:
        // niri's kernel re-derives cached widths and tile weights every
        // animation tick, which structural `==` would report as "changed"
        // on every frame. The tolerance here must stay below the minimum
        // delta of a deliberate user resize.
        let isEquivalentToPrevious = previous?.workspaceId == workspaceId
            && previous?.topologyProfile == topologyProfile
            && ManagedWindowRestoreSnapshot.NiriState.isSemanticallyEquivalent(
                previous?.state,
                niriState,
                frameTolerance: WorkspaceManager.managedRestoreSnapshotFrameTolerance
        )
        if !isEquivalentToPrevious {
            lastKnownNiriStateByToken[token] = LastKnownNiriStateCacheEntry(
                state: niriState,
                workspaceId: workspaceId,
                topologyProfile: topologyProfile
            )
        }
        return niriState
    }

    private func captureManagedRestoreFastPathNiriState(
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedRestoreFastPathNiriState? {
        guard let engine = niriEngine,
              let node = engine.findNode(for: token),
              let column = engine.column(of: node)
        else {
            return nil
        }
        guard column.findRoot()?.workspaceId == workspaceId else {
            return nil
        }

        let workspaceColumns = engine.columns(in: workspaceId)
        let columnWindowTokens = column.windowNodes.map(\.token)
        let tileIndex = columnWindowTokens.firstIndex(of: token)
        return ManagedRestoreFastPathNiriState(
            nodeId: node.id,
            columnId: column.id,
            workspaceColumnIds: workspaceColumns.map(\.id),
            tileIndex: tileIndex,
            columnWindowTokens: columnWindowTokens,
            columnSizing: ManagedWindowRestoreSnapshot.NiriState.ColumnSizing(
                width: column.width,
                cachedWidth: column.cachedWidth,
                presetWidthIdx: column.presetWidthIdx,
                isFullWidth: column.isFullWidth,
                savedWidth: column.savedWidth,
                hasManualSingleWindowWidthOverride: column.hasManualSingleWindowWidthOverride,
                height: column.height,
                cachedHeight: column.cachedHeight,
                isFullHeight: column.isFullHeight,
                savedHeight: column.savedHeight
            ),
            windowSizing: ManagedWindowRestoreSnapshot.NiriState.WindowSizing(
                height: node.height,
                savedHeight: node.savedHeight,
                windowWidth: node.windowWidth,
                sizingMode: node.sizingMode
            )
        )
    }

    private func nativeFullscreenRestoreSnapshot(
        from snapshot: ManagedWindowRestoreSnapshot
    ) -> WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot {
        WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: snapshot.frame,
            topologyProfile: snapshot.topologyProfile,
            niriState: snapshot.niriState,
            replacementMetadata: snapshot.replacementMetadata
        )
    }

    // Tolerance used when checking whether a managed restore snapshot's frame
    // matches the window's display bounds (i.e. the snapshot was captured
    // after the window had already entered macOS native fullscreen). Values
    // within 1pt cover typical rounding between AX frames and screen bounds
    // without producing false positives for legitimate full-tile columns.
    private static let managedSnapshotDisplayBoundsMatchTolerance: CGFloat = 1.0

    private func frameMatchesTokenDisplayBounds(
        _ frame: CGRect,
        token: WindowToken
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token),
              let monitor = workspaceManager.monitor(for: entry.workspaceId)
        else {
            return false
        }
        let tolerance = Self.managedSnapshotDisplayBoundsMatchTolerance
        return frame.approximatelyEqual(to: monitor.frame, tolerance: tolerance)
            || frame.approximatelyEqual(to: monitor.visibleFrame, tolerance: tolerance)
    }

    private func preservedManagedGeometryFrame(
        for token: WindowToken
    ) -> CGRect? {
        if let node = niriEngine?.findNode(for: token) {
            if let renderedFrame = node.renderedFrame {
                return renderedFrame
            }
            if let frame = node.frame {
                return frame
            }
        }
        if let node = dwindleEngine?.findNode(for: token),
           let cachedFrame = node.cachedFrame
        {
            return cachedFrame
        }
        if let floatingFrame = workspaceManager.floatingState(for: token)?.lastFrame {
            return floatingFrame
        }
        if let appliedFrame = axManager.lastAppliedFrame(for: token.windowId) {
            return appliedFrame
        }
        return nil
    }

    private func resolveManagedRestoreMaterialStateFrame(
        for token: WindowToken
    ) -> CGRect? {
        canonicalManagedRestoreMaterialStateFrame(for: token)
            ?? workspaceManager.managedRestoreSnapshot(for: token)?.frame
    }

    private func currentAXRestoreFrame(
        for token: WindowToken
    ) -> CGRect? {
        guard let entry = workspaceManager.entry(for: token) else { return nil }
        if let frame = AXWindowService.framePreferFast(entry.axRef) {
            return frame
        }
        if let frame = try? AXWindowService.frame(entry.axRef) {
            return frame
        }
        return nil
    }

    private func canonicalManagedRestoreMaterialStateFrame(
        for token: WindowToken
    ) -> CGRect? {
        if let node = niriEngine?.findNode(for: token) {
            let workspaceId = workspaceManager.workspace(for: token)
            let useCanonicalFrame = workspaceId.map {
                niriLayoutHandler.hasScrollAnimationRunning(in: $0)
            } ?? false
            if useCanonicalFrame,
               let frame = node.frame {
                return frame
            }
            if let renderedFrame = node.renderedFrame {
                return renderedFrame
            }
            if let frame = node.frame {
                return frame
            }
        }
        if let node = dwindleEngine?.findNode(for: token),
           let cachedFrame = node.cachedFrame
        {
            return cachedFrame
        }
        if let floatingFrame = workspaceManager.floatingState(for: token)?.lastFrame {
            return floatingFrame
        }
        if let appliedFrame = axManager.lastAppliedFrame(for: token.windowId) {
            return appliedFrame
        }
        return nil
    }

    private func makeNativeFullscreenRestoreSnapshot(
        for token: WindowToken,
        frame: CGRect
    ) -> WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot {
        if let snapshot = makeManagedWindowRestoreSnapshot(for: token, frame: frame) {
            // Only persist if we captured a non-nil niriState. Persisting a
            // nil-niriState snapshot would pin that nil in place via
            // `shouldShortCircuitManagedRestoreSnapshot`, poisoning every
            // future fullscreen restore for this window.
            if snapshot.niriState != nil {
                _ = workspaceManager.setManagedRestoreSnapshot(snapshot, for: token)
            }
            let cachedNiriState = lastKnownNiriState(
                for: token,
                workspaceId: snapshot.workspaceId,
                topologyProfile: snapshot.topologyProfile
            )
            let effectiveNiriState = snapshot.niriState ?? cachedNiriState
            return WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
                frame: snapshot.frame,
                topologyProfile: snapshot.topologyProfile,
                niriState: effectiveNiriState,
                replacementMetadata: snapshot.replacementMetadata
            )
        }
        let effectiveNiriState = lastKnownNiriState(
            for: token
        )
        return WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: frame,
            topologyProfile: workspaceManager.topologyProfile,
            niriState: effectiveNiriState,
            replacementMetadata: workspaceManager.managedReplacementMetadata(for: token)
        )
    }

    private func nativeFullscreenRestoreFailure(
        path: NativeFullscreenRestoreSeedPath,
        detail: String
    ) -> WorkspaceManager.NativeFullscreenRecord.RestoreFailure {
        WorkspaceManager.NativeFullscreenRecord.RestoreFailure(
            path: path.rawValue,
            detail: detail
        )
    }

    private func resolveNativeFullscreenRestoreSeed(
        for token: WindowToken,
        path: NativeFullscreenRestoreSeedPath,
        strategy: NativeFullscreenRestoreSeedStrategy
    ) -> NativeFullscreenRestoreSeedResolution {
        if let existingSnapshot = workspaceManager.nativeFullscreenRecord(for: token)?.restoreSnapshot {
            return .init(restoreSnapshot: existingSnapshot, restoreFailure: nil)
        }

        let cachedNiriState = lastKnownNiriState(
            for: token
        )

        if let managedSnapshot = workspaceManager.managedRestoreSnapshot(for: token) {
            // The cache reflects the most recent successful Niri capture and
            // is strictly more recent than the persisted snapshot, so it wins
            // whenever it is available. If the persisted snapshot was saved
            // at a moment when `captureNiriRestoreState` returned nil (e.g. a
            // transient Niri-tree absence), managedSnapshot.niriState is nil
            // and the fast-path identity short-circuit can pin that nil in
            // place indefinitely — the cache is how we still recover.
            let effectiveNiriState = cachedNiriState ?? managedSnapshot.niriState
            // If the snapshot was first captured while the window was already
            // in macOS native fullscreen (app launched fullscreen, Space/Mission
            // Control handoff, etc.), `managedSnapshot.frame` was recorded as
            // the display rect — restoring to it later would be a no-op. In
            // that case, if the niri cache still says the column is not
            // full-width, prefer the niri-cache enrichment path below, which
            // reads the pre-fullscreen tile geometry from niri's layout engine.
            let managedFrameMatchesDisplayBounds =
                frameMatchesTokenDisplayBounds(managedSnapshot.frame, token: token)
            let niriIndicatesTiledColumn =
                effectiveNiriState.map { !$0.columnSizing.isFullWidth } ?? false
            if !(managedFrameMatchesDisplayBounds && niriIndicatesTiledColumn) {
                return .init(
                    restoreSnapshot: WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
                        frame: managedSnapshot.frame,
                        topologyProfile: managedSnapshot.topologyProfile,
                        niriState: effectiveNiriState,
                        replacementMetadata: managedSnapshot.replacementMetadata
                    ),
                    restoreFailure: nil
                )
            }
        }

        // The managed restore snapshot write can be gated off (e.g. when AX
        // facts for the app have not yet loaded), so we may have a last-known
        // Niri column context cached even though the full snapshot never made
        // it to disk. Pair it with any preserved managed geometry we can still
        // find so the fullscreen restore has column-membership information the
        // frame-only fallback would otherwise drop.
        if let cachedNiriState,
           let preservedFrame = preservedManagedGeometryFrame(for: token)
        {
            let snapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
                frame: preservedFrame,
                topologyProfile: workspaceManager.topologyProfile,
                niriState: cachedNiriState,
                replacementMetadata: workspaceManager.managedReplacementMetadata(for: token)
            )
            return .init(restoreSnapshot: snapshot, restoreFailure: nil)
        }

        if strategy == .preTransitionCapture,
           let axFrame = currentAXRestoreFrame(for: token)
        {
            return .init(
                restoreSnapshot: makeNativeFullscreenRestoreSnapshot(for: token, frame: axFrame),
                restoreFailure: nil
            )
        }

        if let preservedFrame = preservedManagedGeometryFrame(for: token) {
            return .init(
                restoreSnapshot: makeNativeFullscreenRestoreSnapshot(for: token, frame: preservedFrame),
                restoreFailure: nil
            )
        }

        if let existingFailure = workspaceManager.nativeFullscreenRecord(for: token)?.restoreFailure {
            return .init(restoreSnapshot: nil, restoreFailure: existingFailure)
        }

        let detail: String
        switch strategy {
        case .preTransitionCapture:
            detail =
                "missing restore geometry from niri renderedFrame/frame, dwindle cachedFrame, floating lastFrame, cached applied frame, and current AX frame"
        case .fullscreenDetectedManagedGeometryOnly:
            detail =
                "missing preserved managed geometry from niri renderedFrame/frame, dwindle cachedFrame, floating lastFrame, and cached applied frame; fullscreen AX geometry refused"
        }

        return .init(
            restoreSnapshot: nil,
            restoreFailure: nativeFullscreenRestoreFailure(
                path: path,
                detail: detail
            )
        )
    }

    @discardableResult
    func ensureNativeFullscreenRestoreSnapshot(
        for token: WindowToken,
        path: NativeFullscreenRestoreSeedPath
    ) -> Bool {
        if workspaceManager.nativeFullscreenRecord(for: token)?.restoreSnapshot != nil {
            return true
        }
        let seed = resolveNativeFullscreenRestoreSeed(
            for: token,
            path: path,
            strategy: .fullscreenDetectedManagedGeometryOnly
        )
        guard let snapshot = seed.restoreSnapshot else {
            return false
        }
        return workspaceManager.seedNativeFullscreenRestoreSnapshot(snapshot, for: token)
    }

    @discardableResult
    func requestManagedNativeFullscreenEnter(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        path: NativeFullscreenRestoreSeedPath
    ) -> Bool {
        let seed = resolveNativeFullscreenRestoreSeed(
            for: token,
            path: path,
            strategy: .preTransitionCapture
        )
        return workspaceManager.requestNativeFullscreenEnter(
            token,
            in: workspaceId,
            restoreSnapshot: seed.restoreSnapshot,
            restoreFailure: seed.restoreFailure
        )
    }

    @discardableResult
    func suspendManagedWindowForNativeFullscreen(
        _ token: WindowToken,
        path: NativeFullscreenRestoreSeedPath
    ) -> Bool {
        // The OS re-asserts fullscreen on every rescan cycle (and AX
        // notifications can fire more than once per transition), which
        // previously ran the seed-resolution / suspend pipeline in a tight
        // loop. Once the record is already `.suspended` with a seed snapshot
        // in place, there is nothing for a follow-up call to change.
        if let record = workspaceManager.nativeFullscreenRecord(for: token),
           record.transition == .suspended,
           record.restoreSnapshot != nil
        {
            return false
        }
        let seed = resolveNativeFullscreenRestoreSeed(
            for: token,
            path: path,
            strategy: .fullscreenDetectedManagedGeometryOnly
        )
        return workspaceManager.markNativeFullscreenSuspended(
            token,
            restoreSnapshot: seed.restoreSnapshot,
            restoreFailure: seed.restoreFailure
        )
    }

    func captureNativeFullscreenRestoreSnapshot(
        for token: WindowToken
    ) -> WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot? {
        resolveNativeFullscreenRestoreSeed(
            for: token,
            path: .manualCapture,
            strategy: .preTransitionCapture
        ).restoreSnapshot
    }

    @discardableResult
    func renderKeyboardFocusBorder(
        for target: KeyboardFocusTarget? = nil,
        preferredFrame: CGRect? = nil,
        policy: KeyboardFocusBorderRenderPolicy = .coordinated,
        source: BorderReconcileSource = .manualRender
    ) -> Bool {
        borderCoordinator.renderBorder(
            for: target ?? currentKeyboardFocusTargetForRendering(),
            preferredFrame: preferredFrame,
            policy: policy,
            source: source
        )
    }

    @discardableResult
    func hideKeyboardFocusBorder(
        source: BorderReconcileSource,
        reason: String,
        matchingToken: WindowToken? = nil,
        matchingPid: pid_t? = nil,
        matchingWindowId: Int? = nil
    ) -> Bool {
        borderCoordinator.hideBorder(
            source: source,
            reason: reason,
            matchingToken: matchingToken,
            matchingPid: matchingPid,
            matchingWindowId: matchingWindowId
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
        let source: BorderReconcileSource = switch phase {
        case .postLayout:
            .borderReapplyPostLayout
        case .animationSettled:
            .borderReapplyAnimationSettled
        case .retryExhaustedFallback:
            .borderReapplyRetryExhaustedFallback
        }
        return renderKeyboardFocusBorder(
            preferredFrame: preferredFrame,
            policy: policy,
            source: source
        )
    }

    func clearKeyboardFocusTarget(
        matching token: WindowToken? = nil,
        pid: pid_t? = nil,
        restoreCurrentBorder: Bool = false
    ) {
        focusBridge.clearFocusedTarget(matching: token, pid: pid)
        guard restoreCurrentBorder else { return }
        _ = renderKeyboardFocusBorder(
            policy: .direct,
            source: .focusClear
        )
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }

    var isInteractiveGestureActive: Bool {
        mouseEventHandler.isInteractiveGestureActive
    }
}
