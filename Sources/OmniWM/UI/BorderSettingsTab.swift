// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

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
                    BorderColorOverrideRow(
                        title: "Dark Mode Border Color",
                        color: darkColorBinding,
                        initialColor: settings.borders.color,
                        inheritance: "Inherits Border Color"
                    )

                    Toggle("Gradient Border", isOn: gradientEnabledBinding)
                    if settings.borders.gradient?.enabled == true {
                        Picker("Gradient Direction", selection: gradientDirectionBinding) {
                            ForEach(BorderGradientDirection.allCases, id: \.self) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }
                        ColorPicker("Gradient Start", selection: gradientStartBinding, supportsOpacity: true)
                        ColorPicker("Gradient End", selection: gradientEndBinding, supportsOpacity: true)
                        BorderColorOverrideRow(
                            title: "Dark Mode Gradient Start",
                            color: gradientDarkColorBinding(\.start),
                            initialColor: settings.borders.gradient?.start ?? BorderGradient.default.start,
                            inheritance: "Inherits Gradient Start"
                        )
                        BorderColorOverrideRow(
                            title: "Dark Mode Gradient End",
                            color: gradientDarkColorBinding(\.end),
                            initialColor: settings.borders.gradient?.end ?? BorderGradient.default.end,
                            inheritance: "Inherits Gradient End"
                        )
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
                        BorderColorOverrideRow(
                            title: "Glow Color",
                            color: glowColorBinding(\.color),
                            initialColor: settings.borders.color,
                            inheritance: glowInheritance(isDark: false)
                        )
                        BorderColorOverrideRow(
                            title: "Dark Mode Glow Color",
                            color: glowColorBinding(\.darkColor),
                            initialColor: settings.borders.glow?.color
                                ?? settings.borders.darkColor ?? settings.borders.color,
                            inheritance: glowInheritance(isDark: true)
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
                    "Dark Mode colors follow the selected app appearance. Unset dark colors fall back to the light values."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func swiftUIColor(_ color: SettingsColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

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

    private var darkColorBinding: Binding<SettingsColor?> {
        Binding(
            get: { [settings] in settings.borders.darkColor },
            set: { [settings, controller] color in
                settings.borders.darkColor = color
                controller.borderSettingsChanged()
            }
        )
    }

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

    private func gradientDarkColorBinding(
        _ keyPath: WritableKeyPath<BorderGradientColors, SettingsColor?>
    ) -> Binding<SettingsColor?> {
        Binding(
            get: { [settings] in settings.borders.gradient?.dark?[keyPath: keyPath] },
            set: { [settings, controller] color in
                settings.borders.setDarkGradientColor(color, at: keyPath)
                controller.borderSettingsChanged()
            }
        )
    }

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

    private func glowColorBinding(
        _ keyPath: WritableKeyPath<BorderGlow, SettingsColor?>
    ) -> Binding<SettingsColor?> {
        Binding(
            get: { [settings] in settings.borders.glow?[keyPath: keyPath] },
            set: { [settings, controller] color in
                var glow = settings.borders.glow ?? .default
                glow[keyPath: keyPath] = color
                settings.borders.glow = glow
                controller.borderSettingsChanged()
            }
        )
    }

    private func glowInheritance(isDark: Bool) -> String {
        if isDark, settings.borders.glow?.color != nil {
            return "Inherits Glow Color"
        }
        if settings.borders.gradient?.enabled == true {
            return isDark ? "Inherits Dark Border Gradient" : "Inherits Border Gradient"
        }
        return isDark ? "Inherits Dark Border Color" : "Inherits Border Color"
    }
}

extension BorderGradientDirection {
    fileprivate var label: String {
        switch self {
        case .topLeftToBottomRight:
            return "Top Left \u{2192} Bottom Right"
        case .topRightToBottomLeft:
            return "Top Right \u{2192} Bottom Left"
        }
    }
}

private struct BorderColorOverrideRow: View {
    let title: String
    @Binding var color: SettingsColor?
    let initialColor: SettingsColor
    let inheritance: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if color != nil {
                ColorPicker(title, selection: colorBinding, supportsOpacity: true)
                    .labelsHidden()
                Button("Reset") { color = nil }
                    .accessibilityLabel("Reset \(title)")
            } else {
                Text(inheritance)
                    .foregroundStyle(.secondary)
                Button("Customize") { color = initialColor }
                    .accessibilityLabel("Customize \(title)")
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let value = color ?? initialColor
                return Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
            },
            set: { newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                color = converted
            }
        )
    }
}
