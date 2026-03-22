import AppKit

@MainActor
final class StatusBarController: NSObject {
    nonisolated static let mainAutosaveName = "omniwm_main"

    private var statusItem: NSStatusItem?
    private var menuViewModel: StatusBarMenuViewModel?
    private var panelController: StatusBarPanelController?
    private var isRebuildingOwnedItems = false
    private var eventMonitor: Any?
    private var restoreApplication: NSRunningApplication?

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

        let menuViewModel = StatusBarMenuViewModel(settings: settings, controller: controller)
        let panelController = StatusBarPanelController()
        panelController.onDismiss = { [weak self] restoreFocus in
            self?.dismissMenu(restoreFocus: restoreFocus)
        }
        menuViewModel.setDismissHandler { [weak self] restoreFocus in
            self?.dismissMenu(restoreFocus: restoreFocus)
        }

        self.menuViewModel = menuViewModel
        self.panelController = panelController

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
        guard let button = statusItem?.button,
              let menuViewModel,
              let panelController
        else {
            return
        }

        if panelController.panel?.isVisible == true {
            dismissMenu(restoreFocus: true)
            return
        }

        restoreApplication = NSWorkspace.shared.frontmostApplication
        installEventMonitor()
        panelController.show(using: menuViewModel, anchoredTo: button)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleRightClick() {
        dismissMenu(restoreFocus: false)
        controller?.toggleHiddenBar()
    }

    func refreshMenu() {
        if panelController?.panel?.isVisible == true {
            menuViewModel?.resetFocus()
        }
    }

    func cleanup() {
        cleanupOwnedStatusItems()
    }

    private func cleanupOwnedStatusItems() {
        removeEventMonitor()
        panelController?.hideWithoutCallbacks()
        hiddenBarController.cleanup()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menuViewModel = nil
        panelController = nil
        restoreApplication = nil
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

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.panelController?.panel?.isVisible == true,
                  let menuViewModel
            else {
                return event
            }

            return menuViewModel.handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func dismissMenu(restoreFocus: Bool) {
        removeEventMonitor()
        panelController?.hideWithoutCallbacks()
        menuViewModel?.resetFocus()

        if restoreFocus {
            restorePreviousApplicationFocusIfNeeded()
        } else {
            restoreApplication = nil
        }
    }

    private func restorePreviousApplicationFocusIfNeeded() {
        defer { restoreApplication = nil }
        guard let restoreApplication,
              !restoreApplication.isTerminated,
              restoreApplication.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return
        }

        restoreApplication.activate(options: [])
    }
}
