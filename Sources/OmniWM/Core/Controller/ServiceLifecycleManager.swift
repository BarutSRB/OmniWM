import AppKit
import Foundation

enum ActivationEventSource: String, Sendable {
    case focusedWindowChanged
    case workspaceDidActivateApplication
    case cgsFrontAppChanged

    var isAuthoritative: Bool {
        self == .focusedWindowChanged
    }
}

@MainActor
final class ServiceLifecycleManager {
    weak var controller: WMController?

    private var displayObserver: DisplayConfigurationObserver?
    private var appActivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var permissionCheckerTask: Task<Void, Never>?
    private(set) var isSecureInputActive = false
    var accessibilityPermissionStreamProviderForTests: ((Bool) -> AsyncStream<Bool>)?
    var accessibilityPermissionStateProviderForTests: (() -> Bool)?
    var accessibilityPermissionRequestHandlerForTests: (() -> Bool)?

    init(controller: WMController) {
        self.controller = controller
    }

    func start() {
        guard let controller else { return }
        let initialPermissionGranted = currentAccessibilityPermissionGranted()
        controller.updateAccessibilityPermissionGranted(initialPermissionGranted)
        if controller.desiredEnabled,
           initialPermissionGranted,
           !controller.hasStartedServices
        {
            startServices()
        }
        permissionCheckerTask?.cancel()
        permissionCheckerTask = Task { @MainActor [weak self, weak controller] in
            guard let self else { return }
            for await granted in self.accessibilityPermissionStream(initial: true) {
                guard let controller, !Task.isCancelled else { return }

                if granted {
                    controller.updateAccessibilityPermissionGranted(true)
                    if controller.desiredEnabled, !controller.hasStartedServices {
                        self.startServices()
                    }
                } else {
                    _ = self.requestAccessibilityPermission()
                    controller.updateAccessibilityPermissionGranted(false)
                }
            }
        }
    }

    private func startServices() {
        guard let controller, !controller.hasStartedServices else { return }
        controller.hasStartedServices = true
        controller.reconcileEnabledAndHotkeysState()
        controller.layoutRefreshController.setup()
        controller.axEventHandler.setup()
        controller.axManager.onAppLaunched = { [weak self] _ in
            self?.handleAppLaunched()
        }
        controller.axManager.onAppTerminated = { [weak self] pid in
            self?.handleAppTerminated(pid: pid)
        }
        AppAXContext.onWindowDestroyed = { [weak controller] pid, windowId in
            guard let controller else { return }
            controller.axEventHandler.handleRemoved(pid: pid, winId: windowId)
        }
        AppAXContext.onFocusedWindowChanged = { [weak controller] pid in
            controller?.axEventHandler.handleAppActivation(
                pid: pid,
                source: .focusedWindowChanged
            )
        }
        setupWorkspaceObservation()
        controller.mouseEventHandler.setup()
        controller.syncMouseWarpPolicy()
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppHideObservers()
        setupSleepWakeObservation()
        controller.workspaceManager.onGapsChanged = { [weak self] in
            self?.handleGapsChanged()
        }

        performStartupRefresh()
        startSecureInputMonitor()
        startLockScreenObserver()
    }

    private func startLockScreenObserver() {
        guard let controller else { return }
        controller.lockScreenObserver.onLockDetected = { [weak controller] in
            controller?.isLockScreenActive = true
        }
        controller.lockScreenObserver.onUnlockDetected = { [weak controller] in
            guard let controller else { return }
            controller.isLockScreenActive = false
            controller.serviceLifecycleManager.handleUnlockDetected()
        }
        controller.lockScreenObserver.start()
    }

    private func startSecureInputMonitor() {
        guard let controller else { return }
        controller.secureInputMonitor.start { [weak self] isSecure in
            self?.handleSecureInputChange(isSecure)
        }
    }

    private func handleSecureInputChange(_ isSecure: Bool) {
        guard let controller else { return }
        let didSuppressActiveHotkeys = isSecure && controller.hotkeysEnabled
        isSecureInputActive = isSecure
        controller.reconcileEnabledAndHotkeysState()
        if isSecure {
            if didSuppressActiveHotkeys {
                SecureInputIndicatorController.shared.show()
            }
        } else {
            SecureInputIndicatorController.shared.hide()
        }
    }

    func handleSecureInputChangeForTests(_ isSecure: Bool) {
        handleSecureInputChange(isSecure)
    }

    private func setupDisplayObserver() {
        displayObserver = DisplayConfigurationObserver()
        displayObserver?.setEventHandler { [weak self] event in
            self?.handleDisplayEvent(event)
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
        guard let controller else { return }
        controller.layoutRefreshController.cleanupForMonitorDisconnect(displayId: outputId.displayId, migrateAnimations: false)

        controller.niriEngine?.cleanupRemovedMonitor(monitorId)
        controller.dwindleEngine?.cleanupRemovedMonitor(monitorId)
    }

    private func handleMonitorConfigurationChanged() {
        applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
    }

    func applyMonitorConfigurationChanged(
        currentMonitors: [Monitor],
        performPostUpdateActions: Bool = true
    ) {
        guard let controller else { return }
        // Invalidate border cache so it gets fully recomputed after monitor change
        // (prevents stale geometry when display ID or coordinate space changes, e.g. KVM switch)
        controller.hideKeyboardFocusBorder(
            source: .monitorConfigurationChanged,
            reason: "monitor configuration changed"
        )
        guard !currentMonitors.isEmpty else { return }
        guard currentMonitors.allSatisfy({ $0.frame.width > 1 && $0.frame.height > 1 }) else { return }

        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        controller.syncMouseWarpPolicy(for: controller.workspaceManager.monitors)
        guard performPostUpdateActions else { return }

        controller.syncMonitorsToNiriEngine()

        let focusedWsId = controller.workspaceManager.focusedToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWsId)

        controller.layoutRefreshController.requestFullRescan(reason: .monitorConfigurationChanged)
    }

    func handleAppTerminated(pid: pid_t) {
        guard let controller else { return }
        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: pid)
        let affectedWorkspaces = controller.workspaceManager.removeWindowsForApp(pid: pid)
        for workspaceId in affectedWorkspaces {
            if let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
               controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
            {
                controller.ensureFocusedTokenValid(in: workspaceId)
            }
        }
        _ = controller.renderKeyboardFocusBorder(
            policy: .direct,
            source: .appTerminated
        )
        controller.appInfoCache.evict(pid: pid)
        controller.layoutRefreshController.requestFullRescan(reason: .appTerminated)
    }

    func handleGapsChanged() {
        controller?.layoutRefreshController.requestRelayout(reason: .gapsChanged)
    }

    func handleAppLaunched() {
        controller?.layoutRefreshController.requestFullRescan(reason: .appLaunched)
    }

    func handleUnlockDetected() {
        guard let controller else { return }
        controller.layoutRefreshController.requestFullRescan(reason: .unlock)
    }

    func performStartupRefresh() {
        controller?.layoutRefreshController.requestFullRescan(reason: .startup)
    }

    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        controller.hideKeyboardFocusBorder(
            source: .activeSpaceChanged,
            reason: "active space changed"
        )
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
    }

    private func setupWorkspaceObservation() {
        guard controller != nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceDidChange()
            }
        }
    }

    private func setupAppActivationObserver() {
        guard let controller else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppActivation(
                    pid: pid,
                    source: .workspaceDidActivateApplication
                )
            }
        }
    }

    private func setupAppHideObservers() {
        guard let controller else { return }
        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppHidden(pid: app.processIdentifier)
            }
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppUnhidden(pid: app.processIdentifier)
            }
        }
    }

    private func setupSleepWakeObservation() {
        guard controller != nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.controller?.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self?.controller else { return }
                _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))
                controller.layoutRefreshController.requestFullRescan(reason: .unlock)
            }
        }
    }

    func stop() {
        guard let controller else { return }
        controller.hasStartedServices = false

        AppAXContext.onWindowDestroyed = nil
        AppAXContext.onFocusedWindowChanged = nil
        controller.axManager.onAppLaunched = nil
        controller.axManager.onAppTerminated = nil
        controller.workspaceManager.onGapsChanged = nil

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        controller.resetMouseWarpPolicy()
        controller.axEventHandler.cleanup()

        controller.tabbedOverlayManager.removeAll()
        controller.borderCoordinator.cleanup()
        controller.cleanupUIOnStop()

        controller.axManager.cleanup()

        displayObserver = nil

        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        if let observer = appHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appHideObserver = nil
        }
        if let observer = appUnhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appUnhideObserver = nil
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }

        controller.secureInputMonitor.stop()
        isSecureInputActive = false
        SecureInputIndicatorController.shared.hide()
        controller.lockScreenObserver.stop()
        permissionCheckerTask?.cancel()
        permissionCheckerTask = nil
        controller.reconcileEnabledAndHotkeysState()
    }

    private func accessibilityPermissionStream(initial: Bool) -> AsyncStream<Bool> {
        accessibilityPermissionStreamProviderForTests?(initial)
            ?? AccessibilityPermissionMonitor.shared.stream(initial: initial)
    }

    private func currentAccessibilityPermissionGranted() -> Bool {
        accessibilityPermissionStateProviderForTests?() ?? AccessibilityPermissionMonitor.shared.isGranted
    }

    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        accessibilityPermissionRequestHandlerForTests?() ?? controller?.axManager.requestPermission() ?? false
    }
}
