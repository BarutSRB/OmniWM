// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Observation
import OmniWMIPC

@MainActor @Observable
public final class AppBootstrapState {
    var settings: SettingsStore?
    var controller: WMController?
    var updateCoordinator: (any AppUpdateCoordinating)?

    public init() {}

    public var isReady: Bool {
        settings != nil && controller != nil
    }

    public func registerRedirectWindow(_ window: NSWindow) {
        OwnedWindowRegistry.shared.register(window)
    }

    public func unregisterRedirectWindow(_ window: NSWindow) {
        OwnedWindowRegistry.shared.unregister(window)
    }

    public func showSettingsAndCloseRedirectWindow(_ window: NSWindow?) {
        guard let settings, let controller else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator
        )
        guard let window else { return }
        unregisterRedirectWindow(window)
        DispatchQueue.main.async {
            window.close()
        }
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public nonisolated(unsafe) weak static var sharedBootstrap: AppBootstrapState?

    override public init() {
        super.init()
    }

    private var statusBarController: StatusBarController?
    private var ipcServer: IPCServerLifecycle?
    private var cliManager: AppCLIManager?
    private var updateCoordinator: (any AppUpdateCoordinating)?
    private var runtimeStateStore: RuntimeStateStore?
    private var launchOverlayController: LaunchOverlayController?

    public func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        bootstrapApplication()
    }

    public func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    public func applicationWillTerminate(_: Notification) {
        if let controller = AppDelegate.sharedBootstrap?.controller {
            controller.serviceLifecycleManager.stop()
            controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        }
        AppDelegate.sharedBootstrap?.settings?.flushNow()
        stopIPCServer()
        runtimeStateStore?.flushNow()
    }

    func bootstrapApplication() {
        switch AppBootstrapPlanner.decision() {
        case .boot:
            finishBootstrap()
        }
    }

    func finishBootstrap() {
        let storagePaths = OmniWMStoragePaths.live
        let runtimeState = RuntimeStateStore(directory: storagePaths.stateDirectory)
        self.runtimeStateStore = runtimeState

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: storagePaths.configDirectory),
            runtimeState: runtimeState
        )
        let hiddenBarController = HiddenBarController(settings: settings)
        let controller = WMController(
            settings: settings,
            hiddenBarController: hiddenBarController,
            clipboardHistoryDirectory: storagePaths.stateDirectory
        )
        controller.applyPersistedSettings(settings)
        let cliManager = AppCLIManager()
        let updateCoordinator = UpdateCoordinator(settings: settings, runtimeState: runtimeState)
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator

        AppDelegate.sharedBootstrap?.settings = settings
        AppDelegate.sharedBootstrap?.controller = controller
        AppDelegate.sharedBootstrap?.updateCoordinator = updateCoordinator

        FatalCapture.install(controllerProvider: { AppDelegate.sharedBootstrap?.controller })
        controller.pendingCrashReport = FatalCapture.consumePending()

        statusBarController = StatusBarController(
            settings: settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            cliManager: cliManager,
            updateCoordinator: updateCoordinator
        )
        controller.statusBarController = statusBarController
        settings.onIPCEnabledChanged = { [weak self, weak controller] isEnabled in
            guard let self, let controller else { return }
            do {
                try self.setIPCEnabled(isEnabled, controller: controller)
            } catch {
                self.presentInfoAlert(
                    title: "IPC Failed to Start",
                    message: error.localizedDescription
                )
                if isEnabled {
                    settings.ipcEnabled = false
                }
            }
        }
        settings.onExternalSettingsReloaded = { [weak controller] in
            guard let controller else { return }
            controller.applyPersistedSettings(settings)
        }
        statusBarController?.setup()
        do {
            try setIPCEnabled(settings.ipcEnabled, controller: controller)
        } catch {
            presentInfoAlert(
                title: "IPC Failed to Start",
                message: error.localizedDescription
            )
            settings.ipcEnabled = false
        }
        updateCoordinator.startAutomaticChecks()

        let overlay = LaunchOverlayController()
        launchOverlayController = overlay
        overlay.play { [weak self] in self?.launchOverlayController = nil }
    }

    func startIPCServer(controller: WMController) throws {
        if ipcServer != nil {
            stopIPCServer()
        }
        let server = IPCServer(controller: controller)
        try server.start()
        ipcServer = server
    }

    func setIPCEnabled(_ enabled: Bool, controller: WMController) throws {
        if enabled {
            try startIPCServer(controller: controller)
        } else {
            stopIPCServer()
        }
    }

    private func stopIPCServer() {
        ipcServer?.stop()
        ipcServer = nil
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }
}
