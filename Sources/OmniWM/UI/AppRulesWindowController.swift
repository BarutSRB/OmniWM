// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

@MainActor
final class AppRulesWindowController {
    static let shared = AppRulesWindowController()

    private var window: NSWindow?
    private let ownedWindowRegistry = OwnedWindowRegistry.shared

    func show(settings: SettingsStore, controller: WMController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let appRulesView = AppRulesView(settings: settings, controller: controller)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)

        let hosting = NSHostingController(rootView: appRulesView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "App Rules"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 620, height: 480))
        window.minSize = NSSize(width: 520, height: 380)
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
