// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Observation

@MainActor @Observable
final class AppBootstrapState {
    var runtime: WMRuntime? {
        didSet {
            settings = runtime?.settings
            controller = runtime?.controller
        }
    }
    var settings: SettingsStore?
    var controller: WMController?
    var updateCoordinator: (any AppUpdateCoordinating)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static weak var sharedBootstrap: AppBootstrapState?
    static var ipcServerFactoryForTests: ((WMController) -> IPCServerLifecycle)?
    static var updateCoordinatorFactoryForTests:
        ((SettingsStore, WMController, RuntimeStateStore) -> any AppUpdateCoordinating)?
    private static let desktopAndDockSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    )!
    private static let systemSettingsAppURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    private enum SeparateSpacesModalAction {
        case openSystemSettings
        case quit
    }

    private var statusBarController: StatusBarController?
    private var ipcServer: IPCServerLifecycle?
    private var cliManager: AppCLIManager?
    private var updateCoordinator: (any AppUpdateCoordinating)?
    private var runtimeStateStore: RuntimeStateStore?
    private var runtime: WMRuntime?

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        bootstrapApplication()
    }

    func applicationWillTerminate(_: Notification) {
        runtime?.flushState()
        runtimeStateStore?.flushNow()
        stopIPCServer()
    }

    func bootstrapApplication(
        configurationDirectory: URL = SettingsFilePersistence.defaultDirectoryURL,
        spacesRequirement: DisplaysHaveSeparateSpacesRequirement = .init()
    ) {
        switch AppBootstrapPlanner.decision(spacesRequirement: spacesRequirement) {
        case .boot:
            finishBootstrap(configurationDirectory: configurationDirectory)
        case .requireDisplaysHaveSeparateSpacesDisabled:
            runDisplaysHaveSeparateSpacesGate()
        }
    }

    func finishBootstrap(
        configurationDirectory: URL = SettingsFilePersistence.defaultDirectoryURL
    ) {

        let persistence = SettingsFilePersistence(directory: configurationDirectory)
        let runtimeState = RuntimeStateStore(directory: configurationDirectory)
        runtimeStateStore = runtimeState

        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: runtimeState
        )
        let runtime = WMRuntime(settings: settings)
        runtime.start()
        let controller = runtime.controller
        let cliManager = AppCLIManager()
        let updateCoordinator = Self.updateCoordinatorFactoryForTests?(settings, controller, runtimeState)
            ?? UpdateCoordinator(settings: settings, runtimeState: runtimeState)
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator
        self.runtime = runtime

        AppDelegate.sharedBootstrap?.runtime = runtime
        AppDelegate.sharedBootstrap?.updateCoordinator = updateCoordinator

        statusBarController = StatusBarController(
            settings: settings,
            controller: controller,
            hiddenBarController: runtime.hiddenBarController,
            cliManager: cliManager,
            updateCoordinator: updateCoordinator
        )
        controller.statusBarController = statusBarController
        settings.onExternalSettingsReloaded = { [weak self, weak runtime] in
            guard let runtime else { return }
            runtime.applyCurrentConfiguration()
            self?.statusBarController?.refreshMenu()
        }
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

    private func runDisplaysHaveSeparateSpacesGate() {
        switch presentDisplaysHaveSeparateSpacesModal() {
        case .openSystemSettings:
            openDesktopAndDockSettings()
            NSApplication.shared.terminate(nil)
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func presentDisplaysHaveSeparateSpacesModal() -> SeparateSpacesModalAction {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Turn off Displays have separate Spaces before launching OmniWM"
        alert.informativeText =
            "OmniWM requires shared Spaces across displays. " +
            "Open System Settings > Desktop & Dock > Mission Control, " +
            "turn off \"Displays have separate Spaces\", " +
            "then log out of macOS and log back in before launching OmniWM again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        NSApplication.shared.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .openSystemSettings
        default:
            return .quit
        }
    }

    private func openDesktopAndDockSettings() {
        if NSWorkspace.shared.open(Self.desktopAndDockSettingsURL) {
            return
        }

        _ = NSWorkspace.shared.open(Self.systemSettingsAppURL)
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
