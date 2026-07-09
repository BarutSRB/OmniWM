// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Observation
import SwiftUI

struct ToggleTileSpec: Identifiable {
    let id: String
    let icon: String
    let label: String
    let accessibilityName: String
    let isOn: Binding<Bool>
}

@MainActor
@Observable
final class StatusMenuModel {
    let settings: SettingsStore
    private(set) weak var controller: WMController?
    var cliManager: AppCLIManager?
    var updateCoordinator: (any AppUpdateCoordinating)?
    var checkForUpdatesAction: (() -> Void)?
    var ipcMenuEnabled = false
    var infoAlertPresenter: (String, String) -> Void
    var confirmationAlertPresenter: (String, String, String, String) -> Bool
    var settingsFileActionPerformer: (SettingsFileAction, SettingsStore) throws -> SettingsFileStatus
    private(set) var cliStatus: AppCLIExposureStatus?

    init(settings: SettingsStore, controller: WMController) {
        self.settings = settings
        self.controller = controller
        infoAlertPresenter = { title, message in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = alert.runModal()
        }
        confirmationAlertPresenter = { title, message, confirmTitle, cancelTitle in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: cancelTitle)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
        settingsFileActionPerformer = { action, settings in
            try SettingsFileWorkflow.perform(
                action,
                settings: settings
            )
        }
    }

    var diagnosticsIssues: [DiagnosticsIssue] {
        controller?.diagnosticsIssues ?? []
    }

    var displaySpacesMode: DisplaySpacesMode {
        controller?.displaySpacesMode ?? .enabled
    }

    var isTraceCaptureActive: Bool {
        controller?.isTraceCaptureActive ?? false
    }

    var canShowHiddenIcons: Bool {
        settings.hiddenBarEnabled && controller?.isHiddenBarHidingAvailable == true
    }

    func menuWillOpen() {
        controller?.refreshDiagnosticsIssues()
        cliStatus = cliManager?.exposureStatus()
    }

    var toggleTiles: [ToggleTileSpec] {
        let settings = settings
        weak let controller = controller
        var tiles: [ToggleTileSpec] = [
            ToggleTileSpec(
                id: "bordersEnabled",
                icon: "square.dashed",
                label: "Borders",
                accessibilityName: "Window Borders",
                isOn: Binding(
                    get: { settings.bordersEnabled },
                    set: {
                        settings.bordersEnabled = $0
                        controller?.borderSettingsChanged()
                    }
                )
            ),
            ToggleTileSpec(
                id: "workspaceBarEnabled",
                icon: "menubar.rectangle",
                label: "Workspace Bar",
                accessibilityName: "Workspace Bar",
                isOn: Binding(
                    get: { settings.workspaceBarEnabled },
                    set: {
                        settings.workspaceBarEnabled = $0
                        controller?.setWorkspaceBarEnabled($0)
                    }
                )
            ),
            ToggleTileSpec(
                id: "preventSleepEnabled",
                icon: "moon.zzz",
                label: "Keep Awake",
                accessibilityName: "Keep Awake",
                isOn: Binding(
                    get: { settings.preventSleepEnabled },
                    set: {
                        settings.preventSleepEnabled = $0
                        controller?.setPreventSleepEnabled($0)
                    }
                )
            ),
            ToggleTileSpec(
                id: "focusFollowsMouse",
                icon: "cursorarrow.motionlines",
                label: "Focus Mouse",
                accessibilityName: "Focus Follows Mouse",
                isOn: Binding(
                    get: { settings.focusFollowsMouse },
                    set: {
                        settings.focusFollowsMouse = $0
                        controller?.setFocusFollowsMouse($0)
                    }
                )
            ),
            ToggleTileSpec(
                id: "focusCrossesMonitorAtEdge",
                icon: "display.2",
                label: "Focus Edge",
                accessibilityName: "Focus Across Monitor at Edge",
                isOn: Binding(
                    get: { settings.focusCrossesMonitorAtEdge },
                    set: { settings.focusCrossesMonitorAtEdge = $0 }
                )
            ),
            ToggleTileSpec(
                id: "moveMouseToFocusedWindow",
                icon: "arrow.up.left.and.down.right.magnifyingglass",
                label: "Mouse to Focused",
                accessibilityName: "Mouse to Focused",
                isOn: Binding(
                    get: { settings.moveMouseToFocusedWindow },
                    set: {
                        settings.moveMouseToFocusedWindow = $0
                        controller?.setMoveMouseToFocusedWindow($0)
                    }
                )
            ),
            ToggleTileSpec(
                id: "focusFollowsWindowToMonitor",
                icon: "arrow.right.square",
                label: "Follow Monitor",
                accessibilityName: "Follow Window to Monitor",
                isOn: Binding(
                    get: { settings.focusFollowsWindowToMonitor },
                    set: { settings.focusFollowsWindowToMonitor = $0 }
                )
            ),
            ToggleTileSpec(
                id: "moveCrossesMonitorAtEdge",
                icon: "macwindow.on.rectangle",
                label: "Move Edge",
                accessibilityName: "Move Window Across Monitor at Edge",
                isOn: Binding(
                    get: { settings.moveCrossesMonitorAtEdge },
                    set: { settings.moveCrossesMonitorAtEdge = $0 }
                )
            ),
            ToggleTileSpec(
                id: "mouseWarpEnabled",
                icon: "arrow.left.arrow.right",
                label: "Mouse Warp",
                accessibilityName: "Mouse Warp",
                isOn: Binding(
                    get: { settings.mouseWarpEnabled },
                    set: { settings.mouseWarpEnabled = $0 }
                )
            )
        ]
        if controller?.isHiddenBarHidingAvailable == true {
            tiles.append(
                ToggleTileSpec(
                    id: "hiddenBarEnabled",
                    icon: "eye.slash",
                    label: "Hide Menu Icons",
                    accessibilityName: "Hide Menu Bar Icons",
                    isOn: Binding(
                        get: { settings.hiddenBarEnabled },
                        set: { controller?.setHiddenBarEnabled($0) }
                    )
                )
            )
        }
        return tiles
    }

    func openSettings(section: SettingsSection? = nil) {
        guard let controller else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator,
            section: section
        )
    }

    func showHiddenIcons() {
        guard canShowHiddenIcons else { return }
        controller?.toggleHiddenBarPanel()
    }

    func openAppRules() {
        guard let controller else { return }
        AppRulesWindowController.shared.show(settings: settings, controller: controller)
    }

    func openReportIssue() {
        openSettings(section: .reportIssue)
    }

    func checkForUpdates() {
        checkForUpdatesAction?()
    }

    func openSponsors() {
        controller?.openSponsorsWindow()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func toggleTraceRecording() {
        guard let controller else { return }
        let wasRecording = controller.isTraceCaptureActive
        switch controller.toggleTraceCaptureForUI(desiredState: .toggle) {
        case .noChange,
             .started:
            break
        case let .stopped(artifact):
            NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
        case let .writeFailed(reason):
            infoAlertPresenter(
                wasRecording ? "Recording could not be saved" : "Recording could not be started",
                reason
            )
        }
    }

    func performSettingsFileAction(_ action: SettingsFileAction) {
        do {
            _ = try settingsFileActionPerformer(
                action,
                settings
            )
        } catch {
            Log.config.error("settings file action failed: \(error.localizedDescription)")
        }
    }

    func installCLI() {
        guard let cliManager else { return }
        let status = cliManager.exposureStatus()
        guard case let .notInstalled(linkURL, directoryOnPath) = status else {
            cliStatus = status
            return
        }

        let directoryURL = linkURL.deletingLastPathComponent()
        var message =
            "OmniWM will create a symlink at \(linkURL.path) pointing to its bundled omniwmctl binary."
        if !directoryOnPath {
            message += "\n\n\(directoryURL.path) is not currently in your PATH, so Terminal may not find `omniwmctl` until you add that directory."
        }

        guard confirmationAlertPresenter(
            "Install CLI to PATH?",
            message,
            "Install",
            "Cancel"
        ) else {
            return
        }

        do {
            let result = try cliManager.installCLIToPATH()
            cliStatus = cliManager.exposureStatus()
            infoAlertPresenter("CLI Installed", installResultMessage(result))
        } catch {
            infoAlertPresenter("CLI Install Failed", error.localizedDescription)
        }
    }

    func removeCLI() {
        guard let cliManager else { return }
        guard confirmationAlertPresenter(
            "Remove CLI from PATH?",
            "OmniWM will remove the symlink it created for `omniwmctl`.",
            "Remove",
            "Cancel"
        ) else {
            return
        }

        do {
            let result = try cliManager.removeInstalledCLI()
            cliStatus = cliManager.exposureStatus()
            infoAlertPresenter("CLI Link Updated", installResultMessage(result))
        } catch {
            infoAlertPresenter("CLI Removal Failed", error.localizedDescription)
        }
    }

    func installResultMessage(_ result: AppCLIInstallResult) -> String {
        switch result {
        case let .installed(linkURL, directoryOnPath),
             let .alreadyInstalled(linkURL, directoryOnPath):
            let state = directoryOnPath
                ? "You can now run `omniwmctl` from Terminal."
                : "Add \(linkURL.deletingLastPathComponent().path) to PATH before using `omniwmctl` in Terminal."
            return "\(linkURL.path)\n\n\(state)"
        case let .homebrewManaged(linkURL):
            return "Homebrew already manages `omniwmctl` at \(linkURL.path)."
        case let .notInstalled(linkURL):
            return "No OmniWM-managed CLI symlink was found at \(linkURL.path)."
        case let .removed(linkURL):
            return "Removed OmniWM's CLI symlink at \(linkURL.path)."
        }
    }
}
