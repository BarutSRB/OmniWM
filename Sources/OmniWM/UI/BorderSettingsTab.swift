// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    /// Renders controls for solid, gradient, and glow border appearance.
    var body: some View {
        Form {
            Section("Window Borders") {
                Toggle("Enable Borders", isOn: Bindable(settings.borders).enabled)
                    .onChange(of: settings.borders.enabled) { _, _ in
                        controller.borderSettingsChanged()
                    }

                if settings.borders.enabled {
                    SettingsSliderRow(
                        label: "Border Width",
                        value: Bindable(settings.borders).width,
                        range: 1 ... 12,
                        step: 0.5,
                        valueText: String(format: "%.1f px", settings.borders.width),
                        valueWidth: 56
                    )
                    .onChange(of: settings.borders.width) { _, _ in
                        controller.borderSettingsChanged()
                    }

                    ColorPicker("Border Color", selection: colorBinding, supportsOpacity: true)
                    ColorPicker("Dark Mode Border Color", selection: darkColorBinding, supportsOpacity: true)

                    Toggle("Gradient Border", isOn: gradientEnabledBinding)
                    if settings.borders.gradient?.enabled == true {
                        Picker("Gradient Direction", selection: gradientDirectionBinding) {
                            ForEach(BorderGradientDirection.allCases, id: \.self) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }
                        ColorPicker("Gradient Start", selection: gradientStartBinding, supportsOpacity: true)
                        ColorPicker("Gradient End", selection: gradientEndBinding, supportsOpacity: true)
                        ColorPicker(
                            "Dark Mode Gradient Start",
                            selection: gradientDarkStartBinding,
                            supportsOpacity: true
                        )
                        ColorPicker("Dark Mode Gradient End", selection: gradientDarkEndBinding, supportsOpacity: true)
                    }

                    Toggle("Glow", isOn: glowEnabledBinding)
                    if settings.borders.glow?.enabled == true {
                        SettingsSliderRow(
                            label: "Glow Radius",
                            value: glowRadiusBinding,
                            range: 0 ... 32,
                            step: 1,
                            valueText: String(format: "%.0f pt", settings.borders.glow?.radius ?? 0),
                            valueWidth: 56
                        )
                        SettingsSliderRow(
                            label: "Glow Opacity",
                            value: glowOpacityBinding,
                            range: 0 ... 1,
                            step: 0.05,
                            valueText: String(format: "%.0f%%", (settings.borders.glow?.opacity ?? 0) * 100),
                            valueWidth: 56
                        )
                    }
                }
            }

            Section("About") {
                Text("Borders are displayed around the currently focused window.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(
                    "Gradient and glow are visual effects. Glow does not change layout gaps or window size."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
                Text(
                    "Dark Mode colors apply when macOS uses the dark appearance. Unset dark colors fall back to the light values."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Converts a persisted settings color into a SwiftUI color.
    private func swiftUIColor(_ color: SettingsColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    /// Binds the solid border color to validated settings.
    private var colorBinding: Binding<Color> {
        Binding(
            get: { [settings] in
                swiftUIColor(settings.borders.color)
            },
            set: { [settings, controller] newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                settings.borders.color = converted
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds the dark-appearance solid border color to validated settings.
    private var darkColorBinding: Binding<Color> {
        Binding(
            get: { [settings] in
                swiftUIColor(settings.borders.darkColor ?? settings.borders.color)
            },
            set: { [settings, controller] newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                settings.borders.darkColor = converted
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds gradient enablement to the live settings model.
    private var gradientEnabledBinding: Binding<Bool> {
        Binding(
            get: { [settings] in settings.borders.gradient?.enabled == true },
            set: { [settings, controller] enabled in
                var gradient = settings.borders.gradient ?? .default
                gradient.enabled = enabled
                settings.borders.gradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds the selected gradient direction to the live settings model.
    private var gradientDirectionBinding: Binding<BorderGradientDirection> {
        Binding(
            get: { [settings] in settings.borders.gradient?.direction ?? .topLeftToBottomRight },
            set: { [settings, controller] direction in
                var gradient = settings.borders.gradient ?? .default
                gradient.direction = direction
                settings.borders.gradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds the gradient start color to validated settings.
    private var gradientStartBinding: Binding<Color> {
        Binding(
            get: { [settings] in
                swiftUIColor(settings.borders.gradient?.start ?? BorderGradient.default.start)
            },
            set: { [settings, controller] newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                var gradient = settings.borders.gradient ?? .default
                gradient.start = converted
                settings.borders.gradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds the gradient end color to validated settings.
    private var gradientEndBinding: Binding<Color> {
        Binding(
            get: { [settings] in
                swiftUIColor(settings.borders.gradient?.end ?? BorderGradient.default.end)
            },
            set: { [settings, controller] newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                var gradient = settings.borders.gradient ?? .default
                gradient.end = converted
                settings.borders.gradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds the dark-appearance gradient start color to validated settings.
    private var gradientDarkStartBinding: Binding<Color> {
        Binding(
            get: { [settings] in
                let gradient = settings.borders.gradient
                return swiftUIColor(gradient?.dark?.start ?? gradient?.start ?? BorderGradient.default.start)
            },
            set: { [settings, controller] newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                var gradient = settings.borders.gradient ?? .default
                var dark = gradient.dark ?? BorderGradientColors(start: gradient.start, end: gradient.end)
                dark.start = converted
                gradient.dark = dark
                settings.borders.gradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds the dark-appearance gradient end color to validated settings.
    private var gradientDarkEndBinding: Binding<Color> {
        Binding(
            get: { [settings] in
                let gradient = settings.borders.gradient
                return swiftUIColor(gradient?.dark?.end ?? gradient?.end ?? BorderGradient.default.end)
            },
            set: { [settings, controller] newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                var gradient = settings.borders.gradient ?? .default
                var dark = gradient.dark ?? BorderGradientColors(start: gradient.start, end: gradient.end)
                dark.end = converted
                gradient.dark = dark
                settings.borders.gradient = gradient
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds glow enablement to the live settings model.
    private var glowEnabledBinding: Binding<Bool> {
        Binding(
            get: { [settings] in settings.borders.glow?.enabled == true },
            set: { [settings, controller] enabled in
                var glow = settings.borders.glow ?? .default
                glow.enabled = enabled
                settings.borders.glow = glow
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds glow radius changes to the live settings model.
    private var glowRadiusBinding: Binding<Double> {
        Binding(
            get: { [settings] in settings.borders.glow?.radius ?? BorderGlow.default.radius },
            set: { [settings, controller] radius in
                var glow = settings.borders.glow ?? .default
                glow.radius = radius
                settings.borders.glow = glow
                controller.borderSettingsChanged()
            }
        )
    }

    /// Binds glow opacity changes to the live settings model.
    private var glowOpacityBinding: Binding<Double> {
        Binding(
            get: { [settings] in settings.borders.glow?.opacity ?? BorderGlow.default.opacity },
            set: { [settings, controller] opacity in
                var glow = settings.borders.glow ?? .default
                glow.opacity = opacity
                settings.borders.glow = glow
                controller.borderSettingsChanged()
            }
        )
    }
}

private extension BorderGradientDirection {
    /// Provides the user-facing label for a gradient direction.
    var label: String {
        switch self {
        case .topLeftToBottomRight:
            return "Top Left \u{2192} Bottom Right"
        case .topRightToBottomLeft:
            return "Top Right \u{2192} Bottom Left"
        }
    }
}
