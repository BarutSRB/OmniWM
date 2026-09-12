// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Window Borders") {
                Toggle("Enable Borders", isOn: Binding(
                    get: { [settings] in settings.borders.enabled },
                    set: { [settings] in settings.setBordersEnabled($0) }
                ))
                .onChange(of: settings.borders.enabled) { _, _ in
                    controller.borderSettingsChanged()
                }

                if settings.borders.enabled {
                    SettingsSliderRow(
                        label: "Border Width",
                        value: Binding(
                            get: { [settings] in settings.borders.width },
                            set: { [settings] in settings.setBorderWidth($0) }
                        ),
                        range: 1 ... 12,
                        step: 0.5,
                        valueText: String(format: "%.1f px", settings.borders.width),
                        valueWidth: 56
                    )
                    .onChange(of: settings.borders.width) { _, _ in
                        controller.borderSettingsChanged()
                    }

                    ColorPicker("Border Color", selection: colorBinding, supportsOpacity: true)
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
            get: { [settings] in
                Color(
                    red: settings.borders.color.red,
                    green: settings.borders.color.green,
                    blue: settings.borders.color.blue,
                    opacity: settings.borders.color.alpha
                )
            },
            set: { [settings, controller] newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                settings.setBorderColor(converted)
                controller.borderSettingsChanged()
            }
        )
    }
}
