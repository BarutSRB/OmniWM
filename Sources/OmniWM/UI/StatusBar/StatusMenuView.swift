// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct StatusMenuPrimaryView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            MenuHeader()
            MenuDivider()
            if !model.diagnosticsIssues.isEmpty {
                MenuActionRow(
                    icon: "exclamationmark.triangle.fill",
                    label: "Issues Detected (\(model.diagnosticsIssues.count))",
                    showChevron: true
                ) {
                    model.openSettings(section: .diagnostics)
                }
                MenuDivider()
            }
            if model.displaySpacesMode != .enabled {
                MenuInfoRow(
                    icon: "exclamationmark.triangle.fill",
                    label: model.displaySpacesMode == .disabled
                        ? "Enable “Displays have separate Spaces”"
                        : "Could not verify display Spaces setting"
                )
                MenuDivider()
            }
            MenuSectionLabel(text: "CONTROLS")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(model.toggleTiles) { tile in
                    MenuToggleTile(
                        icon: tile.icon,
                        label: tile.label,
                        accessibilityName: tile.accessibilityName,
                        isOn: tile.isOn
                    )
                }
            }
            .padding(10)
            MenuDivider()
            MenuActionRow(icon: "gearshape", label: "Settings", showChevron: true) {
                model.openSettings()
            }
            MenuActionRow(icon: "ladybug", label: "Report a Bug…") {
                model.openReportIssue()
            }
            MenuActionRow(icon: "slider.horizontal.3", label: "App Rules", showChevron: true) {
                model.openAppRules()
            }
            if model.checkForUpdatesAction != nil {
                MenuActionRow(icon: "arrow.down.circle", label: "Check for Updates...") {
                    model.checkForUpdates()
                }
            }
            MenuDivider()
        }
    }
}

struct StatusMenuFooterView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            MenuDivider()
            MenuActionRow(icon: "sparkles", label: "Omni Sponsors") {
                model.openSponsors()
            }
            MenuDivider()
            MenuActionRow(icon: "power", label: "Quit OmniWM", isDestructive: true) {
                model.quit()
            }
        }
    }
}

struct StatusMenuAdvancedView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            if model.ipcMenuEnabled {
                MenuSectionLabel(text: "IPC / CLI")
                MenuToggleRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    label: "Enable IPC",
                    isOn: ipcEnabled
                )
                cliStatusRow
                MenuDivider()
            }
            MenuSectionLabel(text: "SETTINGS FILE")
            MenuActionRow(icon: "folder", label: "Reveal Settings File") {
                model.performSettingsFileAction(.reveal)
            }
            MenuActionRow(icon: "pencil", label: "Edit Settings File") {
                model.performSettingsFileAction(.open)
            }
        }
    }

    private var ipcEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.ipcEnabled },
            set: { model.settings.ipcEnabled = $0 }
        )
    }

    @ViewBuilder
    private var cliStatusRow: some View {
        if model.cliManager != nil, let status = model.cliStatus {
            switch status {
            case .appManaged:
                MenuActionRow(icon: "trash", label: "Remove CLI from PATH…") {
                    model.removeCLI()
                }
            case .conflict:
                MenuInfoRow(icon: "exclamationmark.triangle.fill", label: "CLI path is already occupied")
            case .homebrewManaged:
                MenuInfoRow(icon: "checkmark.circle.fill", label: "CLI available via Homebrew")
            case .notInstalled:
                MenuActionRow(icon: "terminal", label: "Install CLI to PATH…") {
                    model.installCLI()
                }
            }
        }
    }
}

struct StatusMenuDiagnosticsView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            MenuActionRow(
                icon: model.isTraceCaptureActive ? "stop.circle" : "record.circle",
                label: model.isTraceCaptureActive ? "Stop & Save Recording" : "Start Recording"
            ) {
                model.toggleTraceRecording()
            }
            MenuActionRow(icon: "stethoscope", label: "Open Troubleshooting…", showChevron: true) {
                model.openSettings(section: .diagnostics)
            }
        }
    }
}

struct StatusMenuHelpLinksView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            MenuActionRow(icon: "link", label: "GitHub", isExternal: true) {
                open("https://github.com/BarutSRB/OmniWM")
            }
            MenuActionRow(icon: "heart", label: "Sponsor on GitHub", isExternal: true) {
                open("https://github.com/sponsors/BarutSRB")
            }
            MenuActionRow(icon: "heart", label: "Sponsor on PayPal", isExternal: true) {
                open("https://paypal.me/beacon2024")
            }
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
