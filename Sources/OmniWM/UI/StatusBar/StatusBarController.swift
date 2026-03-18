import AppKit

@MainActor
final class StatusBarController: NSObject {
    nonisolated static let mainAutosaveName = "omniwm_main"

    private var statusItem: NSStatusItem?
    private var menuBuilder: StatusBarMenuBuilder?
    private var menu: NSMenu?
    private var isRebuildingOwnedItems = false

    private let defaults: UserDefaults
    private let hiddenBarController: HiddenBarController
    private let settings: SettingsStore
    private weak var controller: WMController?

    init(
        settings: SettingsStore,
        controller: WMController,
        hiddenBarController: HiddenBarController,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.hiddenBarController = hiddenBarController
        self.settings = settings
        self.controller = controller
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }
        installOwnedStatusItems()
    }

    nonisolated static func clearOwnedPreferredPositions(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: preferredPositionKey(for: mainAutosaveName))
        defaults.removeObject(forKey: preferredPositionKey(for: HiddenBarController.separatorAutosaveName))
    }

    private nonisolated static func preferredPositionKey(for autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    private func installOwnedStatusItems() {
        guard statusItem == nil, let controller else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "o.circle", accessibilityDescription: "OmniWM")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem?.autosaveName = Self.mainAutosaveName

        menuBuilder = StatusBarMenuBuilder(settings: settings, controller: controller)
        rebuildMenu()

        hiddenBarController.bind(
            omniButton: button,
            onUnsafeOrderingDetected: { [weak self] in
                self?.rebuildOwnedStatusItemsAfterUnsafeOrdering()
            }
        )
        hiddenBarController.setup()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            handleRightClick()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        rebuildMenu()
        guard let button = statusItem?.button, let menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private func handleRightClick() {
        controller?.toggleHiddenBar()
    }

    func refreshMenu() {
        menuBuilder?.updateToggles()
    }

    func rebuildMenu() {
        menu = menuBuilder?.buildMenu()
    }

    func refreshWorkspaces() {
        guard let controller else { return }

        // Gather workspace items from the first/primary monitor
        let monitors = controller.workspaceManager.monitors
        guard let monitor = monitors.first else { return }

        let items = controller.workspaceBarItems(for: monitor, deduplicate: true, hideEmpty: false)

        // Update button title to focused workspace name
        if let button = statusItem?.button {
            // Always keep the icon
            if button.image == nil {
                button.image = NSImage(systemSymbolName: "o.circle", accessibilityDescription: "OmniWM")
                button.image?.isTemplate = true
            }
            if settings.statusBarShowWorkspaceName,
               let focused = items.first(where: \.isFocused)
            {
                var title = " \(focused.name)"
                if settings.statusBarShowAppNames,
                   let focusedApp = focused.windows.first(where: \.isFocused)?.appName
                {
                    let appName = focusedApp.count > 15
                        ? String(focusedApp.prefix(15)) + "\u{2026}"
                        : focusedApp
                    title += " \u{2013} \(appName)"
                }
                button.title = title
                button.imagePosition = .imageLeft
            } else {
                button.title = ""
            }
        }
    }

    func cleanup() {
        cleanupOwnedStatusItems()
    }

    private func cleanupOwnedStatusItems() {
        hiddenBarController.cleanup()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menuBuilder = nil
        menu = nil
    }

    private func rebuildOwnedStatusItemsAfterUnsafeOrdering() {
        guard !isRebuildingOwnedItems else { return }
        isRebuildingOwnedItems = true
        defer { isRebuildingOwnedItems = false }

        settings.hiddenBarIsCollapsed = false
        Self.clearOwnedPreferredPositions(defaults: defaults)
        cleanupOwnedStatusItems()
        installOwnedStatusItems()
    }
}
