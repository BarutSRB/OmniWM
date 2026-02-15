import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var sharedSettings: SettingsStore?
    nonisolated(unsafe) static var sharedController: WMController?

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDelegate.sharedSettings?.appearanceMode.apply()

        if let settings = AppDelegate.sharedSettings,
           let controller = AppDelegate.sharedController
        {
            statusBarController = StatusBarController(settings: settings, controller: controller)
            statusBarController?.setup()
        }
    }
}
