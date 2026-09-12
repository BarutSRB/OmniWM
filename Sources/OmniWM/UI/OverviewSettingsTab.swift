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
                    value: Binding(
                        get: { [settings] in settings.overview.zoom },
                        set: { [settings] in settings.setOverviewZoom($0) }
                    ),
                    range: 0.5 ... 1.5,
                    step: 0.05,
                    valueText: "\(Int((settings.overview.zoom * 100).rounded()))%"
                )
                .onChange(of: settings.overview.zoom) { _, _ in
                    scheduleUpdate()
                }
            }

            Section("Appearance") {
                ColorPicker(
                    "Backdrop Color",
                    selection: colorBinding(\.backdropColor, set: settings.setOverviewBackdropColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Normal Window Border",
                    selection: colorBinding(\.normalBorderColor, set: settings.setOverviewNormalBorderColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Hovered Window Border",
                    selection: colorBinding(\.hoveredBorderColor, set: settings.setOverviewHoveredBorderColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Selected Window Border",
                    selection: colorBinding(\.selectedBorderColor, set: settings.setOverviewSelectedBorderColor),
                    supportsOpacity: true
                )
            }
        }
        .formStyle(.grouped)
    }

    private func colorBinding(
        _ keyPath: KeyPath<OverviewSettings, SettingsColor>,
        set: @escaping @MainActor (SettingsColor) -> Void
    ) -> Binding<Color> {
        Binding(
            get: { [settings] in settings.overview[keyPath: keyPath].swiftUIColor },
            set: { color in
                guard let converted = SettingsColor(color: color) else { return }
                set(converted)
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
