// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var pendingColorSync: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Window Borders") {
                Toggle("Enable Borders", isOn: $settings.bordersEnabled)
                    .onChange(of: settings.bordersEnabled) { _, _ in
                        controller.borderSettingsChanged()
                    }

                if settings.bordersEnabled {
                    SettingsSliderRow(
                        label: "Border Width",
                        value: $settings.borderWidth,
                        range: 1 ... 12,
                        step: 0.5,
                        valueText: String(format: "%.1f px", settings.borderWidth),
                        valueWidth: 56
                    )
                    .onChange(of: settings.borderWidth) { _, _ in
                        syncBorderConfig()
                    }

                    ColorPicker("Border Color", selection: colorBinding, supportsOpacity: true)
                        .onChange(of: settings.borderColorRed) { _, _ in debouncedColorSync() }
                        .onChange(of: settings.borderColorGreen) { _, _ in debouncedColorSync() }
                        .onChange(of: settings.borderColorBlue) { _, _ in debouncedColorSync() }
                        .onChange(of: settings.borderColorAlpha) { _, _ in debouncedColorSync() }
                }
            }

            Section("About") {
                Text("Borders are displayed around the currently focused window.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: settings.borderColorRed,
                    green: settings.borderColorGreen,
                    blue: settings.borderColorBlue,
                    opacity: settings.borderColorAlpha
                )
            },
            set: { newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                settings.borderColorRed = converted.red
                settings.borderColorGreen = converted.green
                settings.borderColorBlue = converted.blue
                settings.borderColorAlpha = converted.alpha
            }
        )
    }

    private func syncBorderConfig() {
        controller.borderSettingsChanged()
    }

    private func debouncedColorSync() {
        pendingColorSync?.cancel()
        pendingColorSync = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            syncBorderConfig()
        }
    }
}
