// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

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
                        controller.borderSettingsChanged()
                    }

                    ColorPicker("Border Color", selection: colorBinding, supportsOpacity: true)

                    Toggle("Gradient Border", isOn: gradientEnabledBinding)
                    if settings.borderGradient?.enabled == true {
                        Picker("Gradient Direction", selection: gradientDirectionBinding) {
                            ForEach(BorderGradientDirection.allCases, id: \.self) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }
                        ColorPicker("Gradient Start", selection: gradientStartBinding, supportsOpacity: true)
                        ColorPicker("Gradient End", selection: gradientEndBinding, supportsOpacity: true)
                    }

                    Toggle("Glow", isOn: glowEnabledBinding)
                    if settings.borderGlow?.enabled == true {
                        SettingsSliderRow(
                            label: "Glow Radius",
                            value: glowRadiusBinding,
                            range: 0 ... 32,
                            step: 1,
                            valueText: String(format: "%.0f pt", settings.borderGlow?.radius ?? 0),
                            valueWidth: 56
                        )
                        SettingsSliderRow(
                            label: "Glow Opacity",
                            value: glowOpacityBinding,
                            range: 0 ... 1,
                            step: 0.05,
                            valueText: String(format: "%.0f%%", (settings.borderGlow?.opacity ?? 0) * 100),
                            valueWidth: 56
                        )
                    }
                }
            }

            Section("About") {
                Text("Borders are displayed around the currently focused window.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("Gradient and glow are visual effects. Glow does not change layout gaps or window size.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var gradientEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.borderGradient?.enabled == true },
            set: { enabled in
                var gradient = settings.borderGradient ?? .default
                gradient.enabled = enabled
                settings.borderGradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    private var gradientDirectionBinding: Binding<BorderGradientDirection> {
        Binding(
            get: { settings.borderGradient?.direction ?? .topLeftToBottomRight },
            set: { direction in
                var gradient = settings.borderGradient ?? .default
                gradient.direction = direction
                settings.borderGradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    private var gradientStartBinding: Binding<Color> {
        Binding(
            get: { swiftUIColor(settings.borderGradient?.start ?? BorderGradient.default.start) },
            set: { newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                var gradient = settings.borderGradient ?? .default
                gradient.start = converted
                settings.borderGradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    private var gradientEndBinding: Binding<Color> {
        Binding(
            get: { swiftUIColor(settings.borderGradient?.end ?? BorderGradient.default.end) },
            set: { newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                var gradient = settings.borderGradient ?? .default
                gradient.end = converted
                settings.borderGradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    private var glowEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.borderGlow?.enabled == true },
            set: { enabled in
                var glow = settings.borderGlow ?? .default
                glow.enabled = enabled
                settings.borderGlow = glow
                controller.borderSettingsChanged()
            }
        )
    }

    private var glowRadiusBinding: Binding<Double> {
        Binding(
            get: { settings.borderGlow?.radius ?? BorderGlow.default.radius },
            set: { radius in
                var glow = settings.borderGlow ?? .default
                glow.radius = radius
                settings.borderGlow = glow
                controller.borderSettingsChanged()
            }
        )
    }

    private var glowOpacityBinding: Binding<Double> {
        Binding(
            get: { settings.borderGlow?.opacity ?? BorderGlow.default.opacity },
            set: { opacity in
                var glow = settings.borderGlow ?? .default
                glow.opacity = opacity
                settings.borderGlow = glow
                controller.borderSettingsChanged()
            }
        )
    }

    private func swiftUIColor(_ color: SettingsColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
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
                settings.borderColor = converted
                controller.borderSettingsChanged()
            }
        )
    }
}

private extension BorderGradientDirection {
    var label: String {
        switch self {
        case .topLeftToBottomRight:
            return "Top Left → Bottom Right"
        case .topRightToBottomLeft:
            return "Top Right → Bottom Left"
        }
    }
}
