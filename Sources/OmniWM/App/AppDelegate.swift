import AppKit
import Observation

@MainActor @Observable
final class AppBootstrapState {
    var settings: SettingsStore?
    var controller: WMController?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static weak var sharedBootstrap: AppBootstrapState?
    private static let desktopAndDockSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    )!
    private static let systemSettingsAppURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    private enum StartupModalAction {
        case exportBackup
        case reset
        case quit
    }

    private enum SeparateSpacesModalAction {
        case openSystemSettings
        case quit
    }

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        bootstrapApplication()
    }

    private func bootstrapApplication(
        defaults: UserDefaults = .standard,
        spacesRequirement: DisplaysHaveSeparateSpacesRequirement = .init()
    ) {
        switch AppBootstrapPlanner.decision(appDefaults: defaults, spacesRequirement: spacesRequirement) {
        case .boot:
            finishBootstrap(defaults: defaults)
        case let .requireSettingsReset(storedEpoch):
            runStartupResetGate(storedEpoch: storedEpoch, defaults: defaults)
        case .requireDisplaysHaveSeparateSpacesDisabled:
            runDisplaysHaveSeparateSpacesGate()
        }
    }

    private func finishBootstrap(defaults: UserDefaults) {
        SettingsMigration.persistCurrentEpoch(defaults: defaults)

        let settings = SettingsStore(defaults: defaults)
        let hiddenBarController = HiddenBarController(settings: settings)
        let controller = WMController(settings: settings, hiddenBarController: hiddenBarController)
        controller.applyPersistedSettings(settings)

        AppDelegate.sharedBootstrap?.settings = settings
        AppDelegate.sharedBootstrap?.controller = controller

        statusBarController = StatusBarController(
            settings: settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            defaults: defaults
        )
        statusBarController?.setup()
        controller.statusBarController = statusBarController
    }

    private func runStartupResetGate(storedEpoch: Int?, defaults: UserDefaults) {
        while true {
            switch presentStartupResetModal(storedEpoch: storedEpoch) {
            case .exportBackup:
                do {
                    let backupURL = try SettingsMigration.exportRawBackup(defaults: defaults)
                    presentInfoAlert(
                        title: "Backup Saved",
                        message: backupURL.path
                    )
                } catch {
                    presentInfoAlert(
                        title: "Backup Failed",
                        message: error.localizedDescription
                    )
                }
            case .reset:
                SettingsMigration.resetOwnedSettings(defaults: defaults)
                finishBootstrap(defaults: defaults)
                return
            case .quit:
                NSApplication.shared.terminate(nil)
                return
            }
        }
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

    private func presentStartupResetModal(storedEpoch: Int?) -> StartupModalAction {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "OmniWM needs to reset stale settings"
        if let storedEpoch {
            alert.informativeText =
                "This build expects settings epoch \(SettingsMigration.currentSettingsEpoch), but found epoch \(storedEpoch). " +
                "You can export a raw backup, reset to defaults, or quit."
        } else {
            alert.informativeText =
                "This build expects settings epoch \(SettingsMigration.currentSettingsEpoch), but found older persisted settings with no epoch marker. " +
                "You can export a raw backup, reset to defaults, or quit."
        }
        alert.addButton(withTitle: "Export Backup")
        alert.addButton(withTitle: "Reset to Defaults")
        alert.addButton(withTitle: "Quit")

        NSApplication.shared.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .exportBackup
        case .alertSecondButtonReturn:
            return .reset
        default:
            return .quit
        }
    }

    private func presentDisplaysHaveSeparateSpacesModal() -> SeparateSpacesModalAction {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Turn off Displays have separate Spaces before launching OmniWM"
        alert.informativeText =
            "OmniWM requires shared Spaces across displays. Open System Settings > Desktop & Dock > Mission Control, " +
            "turn off \"Displays have separate Spaces\", then log out of macOS and log back in before launching OmniWM again."
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
