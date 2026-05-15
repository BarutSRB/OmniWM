import AppKit
import Observation

@MainActor @Observable
final class AppBootstrapState {
    var settings: SettingsStore?
    var controller: WMController?
    var updateCoordinator: (any AppUpdateCoordinating)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) weak static var sharedBootstrap: AppBootstrapState?
    static var ipcServerFactoryForTests: ((WMController) -> IPCServerLifecycle)?
    static var updateCoordinatorFactoryForTests: ((SettingsStore, WMController, RuntimeStateStore)
        -> any AppUpdateCoordinating)?

    private var statusBarController: StatusBarController?
    private var ipcServer: IPCServerLifecycle?
    private var cliManager: AppCLIManager?
    private var updateCoordinator: (any AppUpdateCoordinating)?
    private var runtimeStateStore: RuntimeStateStore?
    private var isCompletingTermination = false

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        bootstrapApplication()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isCompletingTermination else { return .terminateNow }
        isCompletingTermination = true
        Task { @MainActor in
            await AppDelegate.sharedBootstrap?.controller?.flushClipboardHistoryForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        AppDelegate.sharedBootstrap?.controller?.workspaceManager.flushPersistedWindowRestoreCatalogNow()
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
        // Settings-migration epoch persistence deleted under clean-break (PURGE-02);
        // settings.toml IS the source of truth.

        let configurationDirectory = SettingsFilePersistence.defaultDirectoryURL
        let runtimeState = RuntimeStateStore(directory: configurationDirectory)
        self.runtimeStateStore = runtimeState

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: configurationDirectory),
            runtimeState: runtimeState
        )
        let hiddenBarController = HiddenBarController(settings: settings)
        let controller = WMController(settings: settings, hiddenBarController: hiddenBarController)
        controller.applyPersistedSettings(settings)
        let cliManager = AppCLIManager()
        let updateCoordinator = Self.updateCoordinatorFactoryForTests?(settings, controller, runtimeState)
            ?? UpdateCoordinator(settings: settings, runtimeState: runtimeState)
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator

        AppDelegate.sharedBootstrap?.settings = settings
        AppDelegate.sharedBootstrap?.controller = controller
        AppDelegate.sharedBootstrap?.updateCoordinator = updateCoordinator

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
            self.statusBarController?.refreshMenu()
        }
        settings.onExternalSettingsReloaded = { [weak controller, weak self] in
            guard let controller else { return }
            controller.applyPersistedSettings(settings)
            self?.statusBarController?.refreshMenu()
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
    }

    func startIPCServer(controller: WMController) throws {
        if ipcServer != nil {
            stopIPCServer()
        }
        let server = Self.ipcServerFactoryForTests?(controller) ?? IPCServer(controller: controller)
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
