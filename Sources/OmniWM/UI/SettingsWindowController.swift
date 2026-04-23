// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let ownedWindowRegistry = OwnedWindowRegistry.shared

    func show(
        settings: SettingsStore,
        controller: WMController,
        updateCoordinator: (any AppUpdateCoordinating)? = nil
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator
        )
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)

        let hosting = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "OmniWM Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 720, height: 600))
        window.minSize = NSSize(width: 600, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        ownedWindowRegistry.register(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default
            .addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ownedWindowRegistry.unregister(window)
                    self?.window = nil
                }
            }
        self.window = window
    }

    var windowForTests: NSWindow? {
        window
    }

    func isPointInside(_ point: CGPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(point)
    }
}
