// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct OverviewSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var pendingUpdate: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Layout") {
                SettingsSliderRow(
                    label: "Default Zoom",
                    value: $settings.overviewZoom,
                    range: 0.5 ... 1.5,
                    step: 0.05,
                    valueText: "\(Int((settings.overviewZoom * 100).rounded()))%"
                )
                .onChange(of: settings.overviewZoom) { _, _ in
                    scheduleUpdate()
                }
            }

            Section("Appearance") {
                ColorPicker(
                    "Backdrop Color",
                    selection: colorBinding(\.overviewBackdropColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Normal Window Border",
                    selection: colorBinding(\.overviewNormalBorderColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Hovered Window Border",
                    selection: colorBinding(\.overviewHoveredBorderColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Selected Window Border",
                    selection: colorBinding(\.overviewSelectedBorderColor),
                    supportsOpacity: true
                )
            }
        }
        .formStyle(.grouped)
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, SettingsColor>) -> Binding<Color> {
        Binding(
            get: { settings[keyPath: keyPath].swiftUIColor },
            set: { color in
                guard let converted = SettingsColor(color: color) else { return }
                settings[keyPath: keyPath] = converted
                scheduleUpdate()
            }
        )
    }

    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            controller.updateOverviewSettings()
        }
    }
}
