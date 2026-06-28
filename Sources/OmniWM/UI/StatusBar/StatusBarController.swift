// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
final class StatusBarController: NSObject {
    nonisolated static let mainAutosaveName = StatusItemPersistence.OwnedItem.main.autosaveName

    private var statusItem: NSStatusItem?
    private var menuBuilder: StatusBarMenuBuilder?
    private var menu: NSMenu?
    private var isRebuildingOwnedItems = false

    private let hiddenBarController: HiddenBarController
    private let settings: SettingsStore
    private let cliManager: AppCLIManager?
    private let updateCoordinator: (any AppUpdateCoordinating)?
    private let statusItemDefaults: UserDefaults
    private let recordingPulseKey = "omniwm.recordingPulse"
    private weak var controller: WMController?

    init(
        settings: SettingsStore,
        controller: WMController,
        hiddenBarController: HiddenBarController,
        cliManager: AppCLIManager? = nil,
        updateCoordinator: (any AppUpdateCoordinating)? = nil,
        statusItemDefaults: UserDefaults = .standard
    ) {
        self.hiddenBarController = hiddenBarController
        self.settings = settings
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator
        self.statusItemDefaults = statusItemDefaults
        self.controller = controller
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }
        installOwnedStatusItems()
    }

    static let maxStatusBarAppNameLength = 15

    private func installOwnedStatusItems() {
        guard statusItem == nil, let controller else { return }

        StatusItemPersistence.repairOwnedRestoreState(
            defaults: statusItemDefaults,
            screenFrames: NSScreen.screens.map(\.frame)
        )

        let ownedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        StatusItemPersistence.configureMandatoryItem(ownedStatusItem, as: .main)
        statusItem = ownedStatusItem

        guard let button = statusItem?.button else { return }
        button.image = OmniWMBrandMark.statusItemImage(pointSize: 18)
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

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

    func handleTraceCaptureStateChange() {
        updateButtonAppearance()
        rebuildMenu()
    }

    func updateButtonAppearance() {
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        if controller?.isTraceCaptureActive == true {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: "OmniWM, recording diagnostics"
            )?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.contentTintColor = nil
            button.toolTip = "OmniWM — recording diagnostics (auto-stops in 10 min)"
            applyRecordingPulse(to: button)
        } else {
            button.layer?.removeAnimation(forKey: recordingPulseKey)
            button.layer?.opacity = 1
            button.image = OmniWMBrandMark.statusItemImage(pointSize: 18)
            button.contentTintColor = nil
            button.toolTip = nil
        }
    }

    private func applyRecordingPulse(to button: NSStatusBarButton) {
        guard controller?.motionPolicy.animationsEnabled != false else {
            button.layer?.removeAnimation(forKey: recordingPulseKey)
            button.layer?.opacity = 1
            return
        }
        guard button.layer?.animation(forKey: recordingPulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: recordingPulseKey)
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

        updateButtonAppearance()

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
        cleanupOwnedStatusItems()
        StatusItemPersistence.clearOwnedRestoreState(defaults: statusItemDefaults)
        installOwnedStatusItems()
    }
}
