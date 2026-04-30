// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import OSLog

private let statusBarRecoveryLog = Logger(
    subsystem: "com.omniwm",
    category: "StatusBar.Recovery"
)

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
    private let cliManager: AppCLIManager?
    private let updateCoordinator: (any AppUpdateCoordinating)?
    private weak var controller: WMController?

    init(
        settings: SettingsStore,
        controller: WMController,
        hiddenBarController: HiddenBarController,
        defaults: UserDefaults = .standard,
        cliManager: AppCLIManager? = nil,
        updateCoordinator: (any AppUpdateCoordinating)? = nil
    ) {
        self.defaults = defaults
        self.hiddenBarController = hiddenBarController
        self.settings = settings
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator
        self.controller = controller
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }
        installOwnedStatusItems()
    }

    @discardableResult
    nonisolated static func clearInvalidOwnedPreferredPositions(
        defaults: UserDefaults = .standard,
        screenFrames: [CGRect]
    ) -> Bool {
        let ownedObjects = [
            defaults.object(forKey: preferredPositionKey(for: mainAutosaveName)),
            defaults.object(forKey: preferredPositionKey(for: HiddenBarController.separatorAutosaveName))
        ]

        guard ownedObjects.contains(where: {
            !storedPreferredPositionIsVisible($0, screenFrames: screenFrames)
        }) else {
            return false
        }

        clearOwnedPreferredPositions(defaults: defaults)
        return true
    }

    nonisolated static func clearOwnedPreferredPositions(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: preferredPositionKey(for: mainAutosaveName))
        defaults.removeObject(forKey: preferredPositionKey(for: HiddenBarController.separatorAutosaveName))
    }

    nonisolated static func storedPreferredPositionIsVisible(
        _ storedValue: Any?,
        screenFrames: [CGRect]
    ) -> Bool {
        guard !screenFrames.isEmpty else { return true }
        guard let storedValue else { return true }
        guard let positionX = preferredPositionX(from: storedValue) else { return false }
        return preferredPositionXIsVisible(positionX, screenFrames: screenFrames)
    }

    nonisolated static func preferredPositionXIsVisible(
        _ positionX: CGFloat,
        screenFrames: [CGRect]
    ) -> Bool {
        guard positionX.isFinite else { return false }

        let validRanges = screenFrames.compactMap(Self.validScreenXRange)
        guard !validRanges.isEmpty else { return true }

        return validRanges.contains { $0.contains(positionX) }
    }

    private nonisolated static func preferredPositionKey(for autosaveName: String) -> String {
        // AppKit stores `NSStatusItem.autosaveName` positions under this exact key.
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    static let maxStatusBarAppNameLength = 15

    private func installOwnedStatusItems() {
        guard statusItem == nil, let controller else { return }

        clearInvalidOwnedPreferredPositionsBeforeInstall()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "o.circle", accessibilityDescription: "OmniWM")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem?.autosaveName = Self.mainAutosaveName

        let menuBuilder = StatusBarMenuBuilder(settings: settings, controller: controller)
        menuBuilder.ipcMenuEnabled = cliManager != nil
        menuBuilder.cliManager = cliManager
        menuBuilder.updateCoordinator = updateCoordinator
        menuBuilder.checkForUpdatesAction = { [weak self] in
            self?.updateCoordinator?.checkForUpdatesManually()
        }
        self.menuBuilder = menuBuilder
        rebuildMenu()

        hiddenBarController.bind(
            omniButton: button,
            onUnsafeOrderingDetected: { [weak self] in
                self?.rebuildOwnedStatusItemsAfterUnsafeOrdering()
            }
        )
        hiddenBarController.setup()
        refreshWorkspaces()
    }

    @objc private func handleClick(_: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            handleRightClick()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        if menu == nil {
            rebuildMenu()
        } else {
            menuBuilder?.updateToggles()
        }
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

    static func truncatedStatusBarAppName(_ appName: String) -> String {
        guard appName.count > maxStatusBarAppNameLength else { return appName }
        return String(appName.prefix(maxStatusBarAppNameLength)) + "\u{2026}"
    }

    static func statusButtonTitle(workspaceLabel: String, focusedAppName: String?) -> String {
        var title = " \(workspaceLabel)"
        if let focusedAppName, !focusedAppName.isEmpty {
            title += " \u{2013} \(truncatedStatusBarAppName(focusedAppName))"
        }
        return title
    }

    func refreshWorkspaces() {
        guard let button = statusItem?.button else { return }

        if button.image == nil {
            button.image = NSImage(systemSymbolName: "o.circle", accessibilityDescription: "OmniWM")
            button.image?.isTemplate = true
        }

        guard settings.statusBarShowWorkspaceName,
              let summary = controller?.activeStatusBarWorkspaceSummary()
        else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }

        let workspaceLabel = settings.statusBarUseWorkspaceId ? summary.workspaceRawName : summary.workspaceLabel
        let focusedAppName = settings.statusBarShowAppNames ? summary.focusedAppName : nil
        button.title = Self.statusButtonTitle(workspaceLabel: workspaceLabel, focusedAppName: focusedAppName)
        button.imagePosition = .imageLeft
    }

    func statusButtonTitleForTests() -> String {
        statusItem?.button?.title ?? ""
    }

    func statusButtonImagePositionForTests() -> NSControl.ImagePosition? {
        statusItem?.button?.imagePosition
    }

    func statusItemAutosaveNameForTests() -> String? {
        statusItem?.autosaveName
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

    private func clearInvalidOwnedPreferredPositionsBeforeInstall() {
        let didClear = Self.clearInvalidOwnedPreferredPositions(
            defaults: defaults,
            screenFrames: NSScreen.screens.map(\.frame)
        )
        if didClear {
            statusBarRecoveryLog.notice(
                "Cleared invalid OmniWM status item preferred positions before install"
            )
        }
    }

    private nonisolated static func preferredPositionX(from storedValue: Any) -> CGFloat? {
        guard let number = storedValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return CGFloat(value)
    }

    private nonisolated static func validScreenXRange(_ frame: CGRect) -> Range<CGFloat>? {
        guard frame.width > 0,
              frame.minX.isFinite,
              frame.maxX.isFinite,
              frame.minX < frame.maxX
        else {
            return nil
        }
        return frame.minX ..< frame.maxX
    }
}
