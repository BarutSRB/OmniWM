// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

@MainActor
final class SponsorsWindowController {
    private var window: NSWindow?
    private var hostingController: NSHostingController<SponsorsView>?
    private let motionPolicy: MotionPolicy
    private let ownedWindowRegistry: OwnedWindowRegistry

    init(
        motionPolicy: MotionPolicy,
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.motionPolicy = motionPolicy
        self.ownedWindowRegistry = ownedWindowRegistry
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: makeSponsorsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Omni Sponsors"
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 700, height: 400))
        window.center()
        window.isReleasedWhenClosed = false
        ownedWindowRegistry.register(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default
            .addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ownedWindowRegistry.unregister(window)
                    self?.hostingController = nil
                    self?.window = nil
                }
            }
        hostingController = hosting
        self.window = window
    }

    var windowForTests: NSWindow? {
        window
    }

    func isPointInside(_ point: CGPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(point)
    }

    private func makeSponsorsView() -> SponsorsView {
        SponsorsView(
            motionPolicy: motionPolicy,
            onClose: { [weak self] in
                self?.window?.close()
            }
        )
    }
}
