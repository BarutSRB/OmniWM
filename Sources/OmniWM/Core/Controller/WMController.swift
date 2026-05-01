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
    var nativeFullscreenStateProviderForCommand: ((AXWindowRef) -> Bool)?
    @ObservationIgnored
    var nativeFullscreenSetterForCommand: ((AXWindowRef, Bool) -> Bool)?
    @ObservationIgnored
    var frontmostAppPidProviderForCommand: (() -> pid_t?)?
    @ObservationIgnored
    var frontmostFocusedWindowTokenProviderForCommand: (() -> WindowToken?)?
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
            guard let self else { return }
            guard let runtime = self.runtime else {
                preconditionFailure("WMController.hotkeys.onCommand requires WMRuntime to be attached")
            }
            // ExecPlan 03 TX-CMD-01g: route hotkey input through the
            // unified `dispatchHotkey` path so the controller gates
            // (`isEnabled`, `!isOverviewOpen`, layout-compat) apply
            // uniformly with IPC and test paths.
            _ = runtime.dispatchHotkey(command, source: .keyboard)
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
        axManager.onFrameConfirmed = { [weak self] pid, windowId, frame, frameConfirmResult, requestId in
            guard let self else { return }
            let token = WindowToken(pid: pid, windowId: windowId)
            guard let runtime = self.runtime else { return }
            let originatingEpoch = runtime.observedFrameOriginEpoch(
                for: token,
                requestId: requestId,
                source: .ax
            )
            let accepted = runtime.submit(
                WMEffectConfirmation.observedFrame(
                    token: token,
                    frame: frame,
                    source: .ax,
                    originatingTransactionEpoch: originatingEpoch
                )
            )
            guard accepted else { return }
            self.recordManagedRestoreGeometry(
                for: token,
                frame: frame,
                reason: .frameConfirmed,
                frameConfirmResult: frameConfirmResult
            )
        }
        axManager.onFramePending = { [weak self] pid, windowId, frame, requestId in
            guard let self, let runtime = self.runtime else { return }
            let token = WindowToken(pid: pid, windowId: windowId)
            _ = runtime.recordPendingFrameWrite(
                frame: .init(rect: frame, space: .appKit, isVisibleFrame: true),
                requestId: requestId,
                for: token
            )
        }
        axManager.onFrameFailed = { [weak self] pid, windowId, _, failureReason, requestId in
            guard let self, let runtime = self.runtime else { return }
            let token = WindowToken(pid: pid, windowId: windowId)
            _ = runtime.submitAXFrameWriteOutcome(
                for: token,
                requestId: requestId,
                axFailure: failureReason,
                source: .ax
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
        let currentConfiguration = WMRuntimeConfiguration(settings: settings)
        guard runtime.configuration != currentConfiguration else { return false }
        runtime.applyConfiguration(currentConfiguration)
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
    func submitRuntimeEvent(_ event: WMEvent) -> Transaction {
        guard let runtime else {
            preconditionFailure("WMController.submitRuntimeEvent requires WMRuntime to be attached")
        }
        return runtime.submit(event)
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
        guard let runtime else {
            preconditionFailure("WMController.updateWorkspaceConfig requires WMRuntime to be attached")
        }
        runtime.applyWorkspaceSettings(source: .config)
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

    var hotkeyRegistrationFailures: [InputBindingTrigger: HotkeyRegistrationFailureReason] {
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
        resolveWorkspacePlacement(
            workspaceName: workspaceName,
            axRef: axRef,
            pid: pid,
            existingEntry: nil,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: .automatic
        )
    }

    private func resolveWorkspacePlacement(
        workspaceName: String?,
        axRef: AXWindowRef,
        pid: pid_t?,
        existingEntry: WindowModel.Entry?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        context: WindowRuleReevaluationContext
    ) -> WorkspaceDescriptor.ID {
        if context == .automatic, let existingEntry {
            return existingEntry.workspaceId
        }

        if context == .automatic,
           existingEntry == nil,
           let pid,
           let siblingWorkspaceId = workspaceForNewSiblingWindow(
               pid: pid,
               fallbackWorkspaceId: fallbackWorkspaceId
           )
        {
            return siblingWorkspaceId
        }

        if let workspaceName,
           let workspaceId = workspaceManager.workspaceId(for: workspaceName, createIfMissing: false)
        {
            return workspaceId
        }

        if let existingEntry {
            return existingEntry.workspaceId
        }

        return defaultWorkspaceId(for: axRef, fallbackWorkspaceId: fallbackWorkspaceId)
    }

    private func workspaceForNewSiblingWindow(
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID? {
        let entries = workspaceManager.entries(forPid: pid)
        guard !entries.isEmpty else { return nil }

        if let focusedToken = workspaceManager.focusedToken,
           let focusedEntry = entries.first(where: { $0.token == focusedToken })
        {
            return focusedEntry.workspaceId
        }

        if let fallbackWorkspaceId,
           entries.contains(where: { $0.workspaceId == fallbackWorkspaceId })
        {
            return fallbackWorkspaceId
        }

        let workspaceIds = Set(entries.map(\.workspaceId))
        return workspaceIds.count == 1 ? entries[0].workspaceId : nil
    }

    private func defaultWorkspaceId(
        for axRef: AXWindowRef,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
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
        guard let runtime else {
            preconditionFailure("WMController.captureFloatingGeometry requires WMRuntime to be attached")
        }
        runtime.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true,
            source: .command
        )
    }

    func focusedOrFrontmostWindowTokenForAutomation(
        preferFrontmostWhenNonManagedFocusActive: Bool = false
    ) -> WindowToken? {
        let focusedToken = workspaceManager.focusedToken
        let frontmostPid = frontmostAppPidProviderForCommand?()
            ?? FrontmostApplicationState.shared.snapshot?.pid
        let frontmostToken = frontmostFocusedWindowTokenProviderForCommand?()
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
        preferredMonitor: Monitor? = nil,
        source: WMEventSource = .command
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
        guard let runtime else {
            preconditionFailure("WMController.captureVisibleFloatingGeometry requires WMRuntime to be attached")
        }
        runtime.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true,
            source: source
        )
        return frame
    }

    @discardableResult
    private func prepareWindowForScratchpadAssignment(
        _ token: WindowToken,
        preferredMonitor: Monitor? = nil,
        source: WMEventSource = .command
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        guard let runtime else {
            preconditionFailure("WMController.prepareWindowForScratchpadAssignment requires WMRuntime to be attached")
        }
        if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
            runtime.setManualLayoutOverride(.forceFloat, for: token, source: source)
        }

        if entry.mode == .floating {
            return captureVisibleFloatingGeometry(
                for: token,
                preferredMonitor: preferredMonitor,
                source: source
            ) != nil
                || workspaceManager.floatingState(for: token) != nil
        }

        guard let frame = liveFrame(for: entry) else { return false }
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        _ = runtime.setWindowMode(.floating, for: token, source: source)
        runtime.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true,
            source: source
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

        let graph = workspaceManager.workspaceGraphSnapshot()
        let tiledEntries = graph.tiledMembership(in: workspaceId).compactMap {
            workspaceManager.entry(for: $0.token)
        }
        if let tiledEntry = tiledEntries.first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.handle)
        }) {
            return tiledEntry.token
        }

        let floatingEntries = graph.floatingMembership(in: workspaceId).compactMap {
            workspaceManager.entry(for: $0.token)
        }
        return floatingEntries.first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.handle)
        })?.token
    }

    private func recoverFocusAfterScratchpadHide(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding token: WindowToken,
        on monitorId: Monitor.ID?,
        source: WMEventSource
    ) {
        guard let runtime else {
            preconditionFailure("WMController.scratchpadHideCleanup requires WMRuntime to be attached")
        }

        let registry = workspaceManager.logicalWindowRegistry
        let hiddenLogicalId = registry.lookup(token: token).liveLogicalId ?? .invalid
        let wasFocused = workspaceManager.focusedLogicalId == hiddenLogicalId

        let recoveryToken = visibleFocusRecoveryToken(in: workspaceId, excluding: token)
        let recoveryLogicalId = recoveryToken.flatMap { registry.lookup(token: $0).liveLogicalId }

        let action = runtime.reduceScratchpadHide(
            hiddenLogicalId: hiddenLogicalId,
            wasFocused: wasFocused,
            recoveryCandidate: recoveryLogicalId,
            workspaceId: workspaceId,
            monitorId: monitorId
        )

        applyFocusRecoveryAction(action, source: source)
    }

    private func applyFocusRecoveryAction(
        _ action: FocusReducer.RecommendedAction?,
        source: WMEventSource
    ) {
        guard let runtime else { return }
        switch action {
        case let .requestFocus(logicalId, _):
            if let recoveryToken = workspaceManager.logicalWindowRegistry.currentToken(for: logicalId) {
                focusWindow(recoveryToken, source: source)
            } else {
                hideKeyboardFocusBorder(
                    source: .focusClear,
                    reason: "scratchpad hide: recovery target retired"
                )
            }

        case .clearBorder:
            hideKeyboardFocusBorder(
                source: .focusClear,
                reason: "scratchpad hide cleared focused token"
            )

        case let .resolveWorkspaceLastFocused(workspaceId, monitorId):
            _ = runtime.resolveAndSetWorkspaceFocusToken(
                in: workspaceId,
                onMonitor: monitorId,
                source: source
            )
            if workspaceManager.focusedToken == nil {
                hideKeyboardFocusBorder(
                    source: .focusClear,
                    reason: "scratchpad hide: workspace had no remembered focus"
                )
            }

        case nil:
            break
        }
    }

    private func hideScratchpadWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        source: WMEventSource
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
            on: monitor.id,
            source: source
        )
    }

    private func showScratchpadWindow(
        _ entry: WindowModel.Entry,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        source: WMEventSource
    ) {
        if entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId, source: source)
        }
        axManager.markWindowActive(entry.windowId)

        if let hiddenState = workspaceManager.hiddenState(for: entry.token) {
            let focusOnRevealSuccess: LayoutRefreshController.PostLayoutAction = { [weak self] in
                self?.focusWindow(entry.token, source: source)
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

        focusWindow(entry.token, source: source)
    }

    @discardableResult
    func transitionWindowMode(
        for token: WindowToken,
        to targetMode: TrackedWindowMode,
        preferredMonitor: Monitor? = nil,
        applyFloatingFrame: Bool? = nil,
        source: WMEventSource = .command
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

        guard let runtime else {
            preconditionFailure("WMController.transitionWindowMode requires WMRuntime to be attached")
        }
        switch (currentMode, targetMode) {
        case (.tiling, .floating):
            let targetFrame = targetFloatingFrame(
                for: entry,
                preferredMonitor: referenceMonitor
            )
            _ = runtime.setWindowMode(.floating, for: token, source: source)
            if let targetFrame {
                runtime.updateFloatingGeometry(
                    frame: targetFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true,
                    source: source
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
                runtime.updateFloatingGeometry(
                    frame: currentFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true,
                    source: source
                )
            } else if var floatingState = workspaceManager.floatingState(for: token) {
                floatingState.restoreToFloating = true
                runtime.setFloatingState(floatingState, for: token, source: source)
            }
            _ = runtime.setWindowMode(.tiling, for: token, source: source)
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
        existingEntry: WindowModel.Entry?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        context: WindowRuleReevaluationContext = .automatic
    ) -> WorkspaceDescriptor.ID {
        resolveWorkspacePlacement(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: evaluation.token.pid,
            existingEntry: existingEntry,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: context
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
        guard let runtime else {
            preconditionFailure("WMController.clearManualWindowOverride requires WMRuntime to be attached")
        }
        runtime.setManualLayoutOverride(nil, for: token, source: .command)
    }

    private func resolveAXWindowRef(for token: WindowToken) -> AXWindowRef? {
        workspaceManager.entry(for: token)?.axRef
            ?? axEventHandler.axWindowRefProvider?(UInt32(token.windowId), token.pid)
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
    }

    @discardableResult
    func reevaluateWindowRules(
        for targets: Set<WindowRuleReevaluationTarget>,
        context: WindowRuleReevaluationContext = .automatic
    ) async -> WindowRuleReevaluationOutcome {
        guard !targets.isEmpty else { return .none }
        guard let runtime else {
            preconditionFailure("WMController.reevaluateWindowRules requires WMRuntime to be attached")
        }

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
                    _ = runtime.removeWindow(
                        pid: token.pid,
                        windowId: token.windowId,
                        source: .ax
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
                existingEntry: existingEntry,
                fallbackWorkspaceId: activeWorkspace()?.id,
                context: context
            )

            _ = runtime.admitWindow(
                axRef,
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId,
                mode: oldMode ?? trackedMode,
                ruleEffects: evaluation.decision.ruleEffects,
                source: .ax
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
                let metadata = ManagedReplacementMetadata(
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
                _ = runtime.setManagedReplacementMetadata(metadata, for: token, source: .ax)
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

    func toggleFocusedWindowFloating(source: WMEventSource = .command) {
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

        applyManagedWindowOverride(nextOverride, for: token, entry: entry, source: source)
    }

    func assignFocusedWindowToScratchpad(source: WMEventSource = .command) {
        guard let token = focusedManagedTokenForCommand(),
              let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token)
        else {
            return
        }

        guard let runtime else {
            preconditionFailure("WMController.assignFocusedWindowToScratchpad requires WMRuntime to be attached")
        }
        if workspaceManager.isScratchpadToken(token) {
            guard !workspaceManager.isHiddenInCorner(token) else { return }
            _ = runtime.clearScratchpadIfMatches(token, source: source)
            applyManagedWindowOverride(.forceTile, for: token, entry: entry, source: source)
            return
        }

        if let existingScratchpadToken = workspaceManager.scratchpadToken() {
            if workspaceManager.entry(for: existingScratchpadToken) == nil {
                _ = runtime.clearScratchpadIfMatches(existingScratchpadToken, source: source)
            } else {
                return
            }
        }

        let preferredMonitor = monitorForInteraction() ?? workspaceManager.monitor(for: entry.workspaceId)
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(
            token,
            preferredMonitor: preferredMonitor,
            source: source
        ) else {
            return
        }

        _ = runtime.setScratchpadToken(token, source: source)

        guard let updatedEntry = workspaceManager.entry(for: token),
              let hideMonitor = workspaceManager.monitor(for: updatedEntry.workspaceId) ?? preferredMonitor
        else {
            return
        }

        hideScratchpadWindow(updatedEntry, monitor: hideMonitor, source: source)

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
        entry: WindowModel.Entry,
        source: WMEventSource = .command
    ) {
        guard let runtime else {
            preconditionFailure("WMController.applyManagedWindowOverride requires WMRuntime to be attached")
        }
        runtime.setManualLayoutOverride(override, for: token, source: source)
        let evaluation = evaluateWindowDisposition(
            axRef: entry.axRef,
            pid: token.pid
        )
        guard let trackedMode = trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: entry
        ) else {
            layoutRefreshController.discardHiddenTracking(for: token)
            _ = runtime.removeWindow(
                pid: token.pid,
                windowId: token.windowId,
                source: source
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
            applyFloatingFrame: true,
            source: source
        )
        layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    func toggleScratchpadWindow(source: WMEventSource = .command) {
        guard let scratchpadToken = workspaceManager.scratchpadToken() else { return }
        guard let runtime else {
            preconditionFailure("WMController.toggleScratchpadWindow requires WMRuntime to be attached")
        }
        guard let entry = workspaceManager.entry(for: scratchpadToken) else {
            _ = runtime.clearScratchpadIfMatches(scratchpadToken, source: source)
            return
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(scratchpadToken) else { return }
        guard let target = currentScratchpadTarget() else { return }

        if let hiddenState = workspaceManager.hiddenState(for: scratchpadToken) {
            let updatedEntry = workspaceManager.entry(for: scratchpadToken) ?? entry
            if hiddenState.isScratchpad || hiddenState.workspaceInactive {
                showScratchpadWindow(
                    updatedEntry,
                    on: target.workspaceId,
                    monitor: target.monitor,
                    source: source
                )
            }
            return
        }

        let hasCapturedGeometry = captureVisibleFloatingGeometry(
            for: scratchpadToken,
            preferredMonitor: target.monitor,
            source: source
        ) != nil || workspaceManager.floatingState(for: scratchpadToken) != nil
        guard hasCapturedGeometry else { return }

        if entry.workspaceId == target.workspaceId,
           isManagedWindowDisplayable(entry.handle)
        {
            hideScratchpadWindow(entry, monitor: target.monitor, source: source)
            return
        }

        showScratchpadWindow(entry, on: target.workspaceId, monitor: target.monitor, source: source)
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
    func rescueOffscreenWindows(source: WMEventSource = .command) -> Int {
        guard !isLockScreenActive else { return 0 }

        var candidates: [RestorePlanner.FloatingRescueCandidate] = []
        let visibleWorkspaceIds = workspaceManager.visibleWorkspaceIds()
        let workspaceGraph = workspaceManager.workspaceGraphSnapshot()

        for workspaceId in workspaceGraph.workspaceOrder where visibleWorkspaceIds.contains(workspaceId) {
            for graphEntry in workspaceGraph.floatingMembership(in: workspaceId) {
                guard let entry = workspaceManager.entry(for: graphEntry.token) else { continue }
                guard entry.layoutReason == .standard else { continue }
                guard let targetMonitor = workspaceManager.monitor(for: entry.workspaceId)
                    ?? monitorForInteraction()
                    ?? workspaceManager.monitors.first
                , let floatingState = graphEntry.floatingState ?? workspaceManager.floatingState(for: entry.token)
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
        }

        let rescuePlan = restorePlanner.planFloatingRescue(candidates)
        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        var rescuedEntries: [WindowModel.Entry] = []

        guard let runtime else {
            preconditionFailure("WMController.rescueOffscreenWindows requires WMRuntime to be attached")
        }
        for operation in rescuePlan.operations {
            guard let entry = workspaceManager.entry(for: operation.token) else { continue }
            runtime.updateFloatingGeometry(
                frame: operation.targetFrame,
                for: operation.token,
                referenceMonitor: operation.targetMonitor,
                restoreToFloating: true,
                source: source
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
    func resolveAndSetWorkspaceFocusToken(
        for workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .focusPolicy
    ) -> WindowToken? {
        guard let runtime else {
            preconditionFailure("WMController.resolveAndSetWorkspaceFocusToken requires WMRuntime to be attached")
        }
        return runtime.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId),
            source: source
        )
    }

    func reassignManagedWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        guard let runtime else {
            preconditionFailure("WMController.reassignManagedWindow requires WMRuntime to be attached")
        }
        runtime.setWorkspace(for: token, to: workspaceId, source: source)
        recordManagedRestoreGeometryIfMaterialStateChanged(
            for: CGWindowID(token.windowId),
            reason: .workspaceMoved,
            source: source
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
        guard let runtime else {
            preconditionFailure("WMController.recoverSourceFocusAfterMove requires WMRuntime to be attached")
        }

        if let engine = niriEngine,
           let preferredNodeId,
           let node = engine.findNode(by: preferredNodeId) as? NiriWindow
        {
            _ = runtime.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitorId,
                source: .focusPolicy
            )
            return
        }

        _ = runtime.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: monitorId,
            source: .focusPolicy
        )
    }

    func ensureFocusedTokenValid(in workspaceId: WorkspaceDescriptor.ID) {
        guard let runtime else {
            preconditionFailure("WMController.ensureFocusedTokenValid requires WMRuntime to be attached")
        }

        let pendingForWorkspace = workspaceManager.pendingFocusedWorkspaceId == workspaceId
            ? workspaceManager.pendingFocusedToken
            : nil
        let observedForWorkspace: WindowToken? = {
            guard let token = workspaceManager.focusedToken,
                  workspaceManager.entry(for: token)?.workspaceId == workspaceId
            else {
                return nil
            }
            return token
        }()

        let inputs = EnsureWorkspaceFocusPolicy.Inputs(
            workspaceId: workspaceId,
            pendingFocusedToken: pendingForWorkspace,
            pendingHasLayoutNode: pendingForWorkspace.flatMap { niriEngine?.findNode(for: $0) } != nil,
            observedFocusedToken: observedForWorkspace,
            observedHasLayoutNode: observedForWorkspace.flatMap { niriEngine?.findNode(for: $0) } != nil,
            nativeFullscreenSuppressionActive: workspaceManager.hasPendingNativeFullscreenTransition,
            managedFocusRecoverySuppressed: shouldSuppressManagedFocusRecovery
        )

        applyEnsureFocusedTokenValidAction(
            EnsureWorkspaceFocusPolicy.decide(inputs),
            in: workspaceId,
            runtime: runtime
        )
    }

    private func applyEnsureFocusedTokenValidAction(
        _ action: EnsureWorkspaceFocusPolicy.Action,
        in workspaceId: WorkspaceDescriptor.ID,
        runtime: WMRuntime
    ) {
        switch action {
        case .suppressed:
            return

        case let .keepPendingFocus(token, commitLayoutSelection),
             let .keepObservedFocus(token, commitLayoutSelection):
            if commitLayoutSelection,
               let engine = niriEngine,
               let node = engine.findNode(for: token)
            {
                _ = runtime.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: token,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId),
                    source: .focusPolicy
                )
            } else {
                let patch = WorkspaceSessionPatch(
                    workspaceId: workspaceId,
                    viewportState: nil,
                    rememberedFocusToken: token
                )
                _ = runtime.applySessionPatch(patch, source: .focusPolicy)
            }

        case .resolveRememberedFocus:
            let nextFocusToken = runtime.resolveAndSetWorkspaceFocusToken(
                in: workspaceId,
                onMonitor: workspaceManager.monitorId(for: workspaceId),
                source: .focusPolicy
            )
            guard let nextFocusToken else { return }

            if let engine = niriEngine,
               let node = engine.findNode(for: nextFocusToken)
            {
                _ = runtime.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: nextFocusToken,
                    in: workspaceId,
                    source: .focusPolicy
                )
            }
            focusWindow(nextFocusToken, source: .focusPolicy)
        }
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
            focusWindow(token, source: .focusPolicy)

        case let .external(target):
            if workspaceManager.entry(for: target.token) != nil {
                focusWindow(target.token, source: .focusPolicy)
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

    func focusWindow(
        _ token: WindowToken,
        source: WMEventSource
    ) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(token) else { return }
        guard let runtime else {
            preconditionFailure("WMController.focusWindow requires WMRuntime to be attached")
        }
        _ = runtime.requestManagedFocus(
            token: token,
            workspaceId: entry.workspaceId,
            source: source
        )
    }

    func applyRuntimeFocusRequestResult(
        _ result: OrchestrationResult,
        source: WMEventSource
    ) {
        focusBridge.applyOrchestrationState(
            nextManagedRequestId: result.snapshot.focus.nextManagedRequestId,
            activeManagedRequest: result.snapshot.focus.activeManagedRequest
        )
        guard let runtime else {
            preconditionFailure("WMController.applyRuntimeFocusRequestResult requires WMRuntime to be attached")
        }
        _ = runtime.applyOrchestrationFocusState(result.snapshot.focus, source: source)

        for action in result.plan.actions {
            switch action {
            case let .beginManagedFocusRequest(requestId, token, workspaceId):
                let beginResult = runtime.beginManagedFocusRequestTransaction(
                    token,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId),
                    source: source
                )
                let request = focusBridge.activeManagedRequest(requestId: requestId)
                assert(request?.token == token, "Unexpected focus request id drift for \(token)")
                if request != nil {
                    focusBridge.recordOriginTransactionEpoch(
                        beginResult.transactionEpoch,
                        for: requestId
                    )
                }
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
                        self.focusWindow(deferred, source: source)
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

    func focusWindow(
        _ handle: WindowHandle,
        source: WMEventSource
    ) {
        focusWindow(handle.id, source: source)
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
        if let lastAppliedFrame = axManager.lastAppliedFrame(for: token.windowId) {
            return lastAppliedFrame
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
        let columnWindowMembers: [LogicalWindowId]
        let columnSizing: ManagedWindowRestoreSnapshot.NiriState.ColumnSizing
        let windowSizing: ManagedWindowRestoreSnapshot.NiriState.WindowSizing

        func matches(_ snapshot: ManagedWindowRestoreSnapshot.NiriState?) -> Bool {
            guard let snapshot else { return false }
            guard snapshot.nodeId == nodeId,
                  snapshot.tileIndex == tileIndex,
                  snapshot.columnWindowMembers == columnWindowMembers,
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
        reason: ManagedRestoreTriggerReason,
        source: WMEventSource = .command
    ) {
        guard let entry = workspaceManager.entry(forWindowId: Int(windowId)) else { return }
        guard let frame = resolveManagedRestoreMaterialStateFrame(for: entry.token) else { return }
        _ = persistManagedRestoreSnapshotIfNeeded(
            for: entry.token,
            frame: frame,
            reason: reason,
            source: source
        )
    }

    @discardableResult
    private func persistManagedRestoreSnapshotIfNeeded(
        for token: WindowToken,
        frame: CGRect,
        reason: ManagedRestoreTriggerReason = .frameConfirmed,
        frameConfirmResult: FrameConfirmResult? = nil,
        source: WMEventSource = .command
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

        guard let runtime else {
            preconditionFailure("WMController.recordManagedRestoreGeometry requires WMRuntime to be attached")
        }
        let didStoreSnapshot = runtime.setManagedRestoreSnapshot(snapshot, for: token, source: source)
        guard didStoreSnapshot else {
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
        lastKnownNiriStateByToken[newToken] = cacheEntry
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
        let registry = workspaceManager.logicalWindowRegistry
        let columnWindowMembers = columnWindowTokens.compactMap { siblingToken in
            registry.resolveForWrite(token: siblingToken)
        }
        let niriState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: node.id,
            columnIndex: columnIndex,
            tileIndex: tileIndex,
            columnWindowMembers: columnWindowMembers,
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
        let registry = workspaceManager.logicalWindowRegistry
        let columnWindowMembers = columnWindowTokens.compactMap { siblingToken in
            registry.resolveForWrite(token: siblingToken)
        }
        return ManagedRestoreFastPathNiriState(
            nodeId: node.id,
            columnId: column.id,
            workspaceColumnIds: workspaceColumns.map(\.id),
            tileIndex: tileIndex,
            columnWindowMembers: columnWindowMembers,
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
            if snapshot.niriState != nil {
                guard let runtime else {
                    preconditionFailure("WMController.ensureNativeFullscreenRestoreSnapshot requires WMRuntime to be attached")
                }
                _ = runtime.setManagedRestoreSnapshot(snapshot, for: token, source: .command)
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
            let effectiveNiriState = cachedNiriState ?? managedSnapshot.niriState
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
        guard let runtime else {
            preconditionFailure("WMController.seedNativeFullscreenRestoreSnapshot requires WMRuntime to be attached")
        }
        return runtime.seedNativeFullscreenRestoreSnapshot(
            snapshot,
            for: token,
            source: .command
        )
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
        guard let runtime else {
            preconditionFailure("WMController.requestManagedNativeFullscreenEnter requires WMRuntime to be attached")
        }
        return runtime.requestNativeFullscreenEnter(
            token,
            in: workspaceId,
            restoreSnapshot: seed.restoreSnapshot,
            restoreFailure: seed.restoreFailure,
            source: .command
        )
    }

    @discardableResult
    func suspendManagedWindowForNativeFullscreen(
        _ token: WindowToken,
        path: NativeFullscreenRestoreSeedPath
    ) -> Bool {
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
        let eventSource: WMEventSource = switch path {
        case .commandDrivenEnter, .commandExitSetFailure:
            .command
        case .manualCapture,
             .directActivationEnter,
             .fullRescanExistingEntryFullscreen,
             .fullRescanNativeFullscreenRestore,
             .delayedSameTokenFullscreenReappearance,
             .delayedReplacementTokenFullscreenReappearance:
            .ax
        }
        guard let runtime else {
            preconditionFailure("WMController.suspendManagedWindowForNativeFullscreen requires WMRuntime to be attached")
        }
        return runtime.markNativeFullscreenSuspended(
            token,
            restoreSnapshot: seed.restoreSnapshot,
            restoreFailure: seed.restoreFailure,
            source: eventSource
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
        return borderCoordinator.hideBorder(
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


    @discardableResult
    func routeBeginNativeFullscreenRestore(
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> WorkspaceManager.NativeFullscreenRecord? {
        guard let runtime else {
            preconditionFailure("WMController.routeBeginNativeFullscreenRestore requires WMRuntime to be attached")
        }
        return runtime.beginNativeFullscreenRestore(for: token, source: source)
    }

    @discardableResult
    func routeRestoreNativeFullscreenRecord(
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> ParentKind? {
        guard let runtime else {
            preconditionFailure("WMController.routeRestoreNativeFullscreenRecord requires WMRuntime to be attached")
        }
        return runtime.restoreNativeFullscreenRecord(for: token, source: source)
    }
}
