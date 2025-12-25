import AppKit
import SwiftUI

@MainActor
final class AppRulesWindowController {
    static let shared = AppRulesWindowController()

    private var window: NSWindow?

    func show(settings: SettingsStore, controller: WMController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AppRulesView(settings: settings, controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "App Rules"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default
            .addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.window = nil
                }
            }
        self.window = window
    }
}
