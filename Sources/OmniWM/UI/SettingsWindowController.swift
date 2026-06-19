// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

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

        let hosting = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "OmniWM Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 760, height: 560)
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

    func isPointInside(_ point: CGPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(point)
    }
}
