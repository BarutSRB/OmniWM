import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    private let settings: SettingsStore
    private weak var controller: WMController?

    init(settings: SettingsStore, controller: WMController) {
        self.settings = settings
        self.controller = controller
    }

    func setup() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "o.circle", accessibilityDescription: "OmniWM")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem?.autosaveName = "omniwm_main"
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            handleRightClick()
        } else {
            handleLeftClick()
        }
    }

    private func handleLeftClick() {
        togglePopover()
    }

    private func handleRightClick() {
        guard settings.hiddenBarEnabled else {
            togglePopover()
            return
        }
        controller?.toggleHiddenBar()
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }

        if popover == nil {
            createPopover()
        }

        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover?.close()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func createPopover() {
        guard let controller else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let settingsBinding = Binding<SettingsStore>(
            get: { [settings] in settings },
            set: { _ in }
        )

        let menuView = StatusBarMenuView(
            settings: settingsBinding,
            controller: controller
        )
        popover.contentViewController = NSHostingController(rootView: menuView)
        popover.contentSize = NSSize(width: 280, height: 500)

        self.popover = popover
    }

    func cleanup() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        closePopover()
        popover = nil
    }
}
