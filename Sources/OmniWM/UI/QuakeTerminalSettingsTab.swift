// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct QuakeTerminalSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    private var blurValueText: String {
        settings.quakeTerminal.backgroundBlurRadius == QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
            ? "Off"
            : "\(settings.quakeTerminal.backgroundBlurRadius)"
    }

    var body: some View {
        Form {
            Section("Quake Terminal") {
                Toggle("Enable Quake Terminal", isOn: Binding(
                    get: { [settings] in settings.quakeTerminal.enabled },
                    set: { [settings] in settings.setQuakeTerminalEnabled($0) }
                ))
                .onChange(of: settings.quakeTerminal.enabled) { _, newValue in
                    controller.setQuakeTerminalEnabled(newValue)
                }
            }

            if settings.quakeTerminal.enabled {
                Section("Position & Size") {
                    Picker("Position", selection: Binding(
                        get: { [settings] in settings.quakeTerminal.position },
                        set: { [settings] in settings.setQuakeTerminalPosition($0) }
                    )) {
                        ForEach(QuakeTerminalPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }

                    Picker("Show On", selection: Binding(
                        get: { [settings] in settings.quakeTerminal.monitorMode },
                        set: { [settings] in settings.setQuakeTerminalMonitorMode($0) }
                    )) {
                        ForEach(QuakeTerminalMonitorMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    SettingsSliderRow(
                        label: "Width",
                        value: Binding(
                            get: { [settings] in settings.quakeTerminal.widthPercent },
                            set: { [settings] in settings.setQuakeTerminalWidthPercent($0) }
                        ),
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminal.widthPercent))%"
                    )

                    SettingsSliderRow(
                        label: "Height",
                        value: Binding(
                            get: { [settings] in settings.quakeTerminal.heightPercent },
                            set: { [settings] in settings.setQuakeTerminalHeightPercent($0) }
                        ),
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminal.heightPercent))%"
                    )

                    if settings.quakeTerminalUseCustomFrame {
                        Button("Reset to Default Position") {
                            settings.resetQuakeTerminalCustomFrame()
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Background Effect", selection: Binding(
                        get: { [settings] in settings.quakeTerminal.backgroundEffect },
                        set: { [settings] in settings.setQuakeTerminalBackgroundEffect($0) }
                    )) {
                        ForEach(QuakeTerminalBackgroundEffect.allCases, id: \.self) { effect in
                            Text(effect.displayName).tag(effect)
                        }
                    }
                    .onChange(of: settings.quakeTerminal.backgroundEffect) { _, _ in
                        controller.reloadQuakeTerminalBackgroundEffect()
                    }

                    SettingsSliderRow(
                        label: "Quake Background Opacity",
                        value: Binding(
                            get: { [settings] in settings.quakeTerminal.opacity },
                            set: { [settings] in settings.setQuakeTerminalOpacity($0) }
                        ),
                        range: 0.1 ... 1.0,
                        step: 0.05,
                        valueText: "\(Int(settings.quakeTerminal.opacity * 100))%"
                    )
                    .onChange(of: settings.quakeTerminal.opacity) { _, _ in
                        controller.reloadQuakeTerminalOpacity()
                    }

                    SettingsSliderRow(
                        label: "Background Blur",
                        value: Binding(
                            get: { [settings] in Double(settings.quakeTerminal.backgroundBlurRadius) },
                            set: { [settings] in settings.setQuakeTerminalBackgroundBlurRadius(Int($0.rounded())) }
                        ),
                        range: Double(QuakeTerminalAppearancePolicy.minimumBackgroundBlurRadius)
                            ... Double(QuakeTerminalAppearancePolicy.maximumBackgroundBlurRadius),
                        step: 5,
                        valueText: blurValueText
                    )
                    .onChange(of: settings.quakeTerminal.backgroundBlurRadius) { _, _ in
                        controller.reloadQuakeTerminalBackgroundBlur()
                    }
                    .disabled(settings.quakeTerminal.backgroundEffect != .standardBlur)

                    if settings.quakeTerminal.backgroundEffect != .standardBlur {
                        SettingsCaption(
                            "The saved Standard Blur radius is preserved and becomes active again when Standard Blur is selected."
                        )
                    } else if QuakeTerminalAppearancePolicy.backgroundBlurIsHiddenByOpaqueBackground(
                        radius: settings.quakeTerminal.backgroundBlurRadius,
                        opacity: settings.quakeTerminal.opacity
                    ) {
                        SettingsCaption("Blur only shows through a translucent terminal - lower the opacity to see it.")
                    }
                }

                Section("Behavior") {
                    SettingsSliderRow(
                        label: "Animation Duration",
                        value: Binding(
                            get: { [settings] in settings.quakeTerminal.animationDuration },
                            set: { [settings] in settings.setQuakeTerminalAnimationDuration($0) }
                        ),
                        range: 0 ... 1,
                        step: 0.1,
                        valueText: "\(String(format: "%.1f", settings.quakeTerminal.animationDuration))s"
                    )
                    .disabled(!controller.motionPolicy.animationsEnabled)

                    if !controller.motionPolicy.animationsEnabled {
                        SettingsCaption("Ignored while global animations are disabled.")
                    }

                    Toggle("Auto-hide on Focus Loss", isOn: Binding(
                        get: { [settings] in settings.quakeTerminal.autoHide },
                        set: { [settings] in settings.setQuakeTerminalAutoHide($0) }
                    ))
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsCaption(
                        "Quake Terminal provides a drop-down terminal that can be toggled with a hotkey, similar to the console in Quake-style games."
                    )

                    Label("Default hotkey: Option + ` (backtick)", systemImage: "keyboard")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Label("Configure hotkey in Hotkeys settings", systemImage: "gearshape")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
