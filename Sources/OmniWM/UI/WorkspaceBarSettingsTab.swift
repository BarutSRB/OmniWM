// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

struct WorkspaceBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Configuration Scope")

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Configure settings for:", selection: $selectedMonitor) {
                        Text("Global Defaults").tag(nil as Monitor.ID?)
                        if !connectedMonitors.isEmpty {
                            Divider()
                            ForEach(connectedMonitors, id: \.id) { monitor in
                                HStack {
                                    Text(monitor.name)
                                    if monitor.isMain {
                                        Text("(Main)")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .tag(monitor.id as Monitor.ID?)
                            }
                        }
                    }

                    if let monitorId = selectedMonitor,
                       let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                    {
                        HStack {
                            if settings.barSettings(for: monitor) != nil {
                                Text("Has custom overrides")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Using global defaults")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Reset to Global") {
                                settings.removeBarSettings(for: monitor)
                                controller.updateWorkspaceBarSettings()
                            }
                            .disabled(settings.barSettings(for: monitor) == nil)
                        }
                    }
                }

                Divider()

                if let monitorId = selectedMonitor,
                   let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                {
                    MonitorBarSettingsSection(
                        settings: settings,
                        controller: controller,
                        monitor: monitor
                    )
                } else {
                    GlobalBarSettingsSection(
                        settings: settings,
                        controller: controller
                    )
                }
        }
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }
}

private struct GlobalBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Workspace Bar")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable Workspace Bar", isOn: $settings.workspaceBarEnabled)
                    .onChange(of: settings.workspaceBarEnabled) { _, newValue in
                        controller.setWorkspaceBarEnabled(newValue)
                    }

                if settings.workspaceBarEnabled {
                    Toggle("Show Workspace Labels", isOn: $settings.workspaceBarShowLabels)
                        .onChange(of: settings.workspaceBarShowLabels) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }

                    Toggle("Show Floating Windows", isOn: $settings.workspaceBarShowFloatingWindows)
                        .onChange(of: settings.workspaceBarShowFloatingWindows) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }

                    Toggle("Deduplicate App Icons", isOn: $settings.workspaceBarDeduplicateAppIcons)
                        .onChange(of: settings.workspaceBarDeduplicateAppIcons) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }
                        .help("Group windows by app with badge count")

                    Toggle("Hide Empty Workspaces", isOn: $settings.workspaceBarHideEmptyWorkspaces)
                        .onChange(of: settings.workspaceBarHideEmptyWorkspaces) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }

                    Toggle("Reserve Space for Workspace Bar", isOn: $settings.workspaceBarReserveLayoutSpace)
                        .onChange(of: settings.workspaceBarReserveLayoutSpace) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }
                        .help(
                            "Reserve tiled layout space for the workspace bar. " +
                            "Overlapping Menu Bar uses the configured bar height; " +
                            "bars placed below the menu bar use the rendered bar height."
                        )

                    Toggle("Notch-Aware Positioning", isOn: $settings.workspaceBarNotchAware)
                        .onChange(of: settings.workspaceBarNotchAware) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }
                        .help("Shift bar to the right of the notch on MacBook Pro")
                }
            }

            if settings.workspaceBarEnabled {
                Divider()

                SectionHeader("Position & Level")
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Position", selection: $settings.workspaceBarPosition) {
                        ForEach(WorkspaceBarPosition.allCases) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .onChange(of: settings.workspaceBarPosition) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                    Picker("Window Level", selection: $settings.workspaceBarWindowLevel) {
                        ForEach(WorkspaceBarWindowLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .onChange(of: settings.workspaceBarWindowLevel) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                }

                Divider()

                SectionHeader("Position Offset")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("X Offset")
                        Spacer()
                        HStack(spacing: 4) {
                            Button {
                                settings.workspaceBarXOffset = max(-500, settings.workspaceBarXOffset - 10)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(.bordered)

                            TextField("", value: $settings.workspaceBarXOffset, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.center)

                            Button {
                                settings.workspaceBarXOffset = min(500, settings.workspaceBarXOffset + 10)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("\(Int(settings.workspaceBarXOffset)) px")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    .onChange(of: settings.workspaceBarXOffset) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                    HStack {
                        Text("Y Offset")
                        Spacer()
                        HStack(spacing: 4) {
                            Button {
                                settings.workspaceBarYOffset = max(-500, settings.workspaceBarYOffset - 10)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(.bordered)

                            TextField("", value: $settings.workspaceBarYOffset, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.center)

                            Button {
                                settings.workspaceBarYOffset = min(500, settings.workspaceBarYOffset + 10)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("\(Int(settings.workspaceBarYOffset)) px")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    .onChange(of: settings.workspaceBarYOffset) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                }

                Divider()

                SectionHeader("Appearance")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bar Height")
                        Slider(value: $settings.workspaceBarHeight, in: 20 ... 40, step: 2)
                        Text("\(Int(settings.workspaceBarHeight)) px")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    .onChange(of: settings.workspaceBarHeight) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                    HStack {
                        Text("Background Opacity")
                        Slider(value: $settings.workspaceBarBackgroundOpacity, in: 0 ... 0.5, step: 0.05)
                        Text("\(Int(settings.workspaceBarBackgroundOpacity * 100))%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    .onChange(of: settings.workspaceBarBackgroundOpacity) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                }

                Divider()

                SectionHeader("Theme")
                VStack(alignment: .leading, spacing: 8) {
                    WorkspaceBarAccentColorPicker(settings: settings, controller: controller)
                    WorkspaceBarTextColorPicker(settings: settings, controller: controller)

                    HStack {
                        Text("Label Font Size")
                        Slider(value: $settings.workspaceBarLabelFontSize, in: 10 ... 16, step: 1)
                        Text("\(Int(settings.workspaceBarLabelFontSize)) pt")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    .onChange(of: settings.workspaceBarLabelFontSize) { _, _ in
                        controller.updateWorkspaceBarAppearance()
                    }

                    Text("Theme settings apply globally to every workspace bar. Per-monitor overrides only affect layout and visibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

}

private struct WorkspaceBarAccentColorPicker: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    private var useCustomAccent: Bool {
        settings.workspaceBarAccentColorRed >= 0
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: {
                guard settings.workspaceBarAccentColorRed >= 0 else { return .accentColor }
                return Color(
                    red: settings.workspaceBarAccentColorRed,
                    green: settings.workspaceBarAccentColorGreen,
                    blue: settings.workspaceBarAccentColorBlue,
                    opacity: settings.workspaceBarAccentColorAlpha
                )
            },
            set: { newColor in
                if let components = NSColor(newColor).usingColorSpace(.sRGB) {
                    settings.workspaceBarAccentColorRed = Double(components.redComponent)
                    settings.workspaceBarAccentColorGreen = Double(components.greenComponent)
                    settings.workspaceBarAccentColorBlue = Double(components.blueComponent)
                    settings.workspaceBarAccentColorAlpha = Double(components.alphaComponent)
                    controller.updateWorkspaceBarAppearance()
                }
            }
        )
    }

    var body: some View {
        HStack {
            Toggle("Custom Accent Color", isOn: Binding(
                get: { useCustomAccent },
                set: { enabled in
                    if enabled {
                        let ns = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .blue
                        settings.workspaceBarAccentColorRed = Double(ns.redComponent)
                        settings.workspaceBarAccentColorGreen = Double(ns.greenComponent)
                        settings.workspaceBarAccentColorBlue = Double(ns.blueComponent)
                        settings.workspaceBarAccentColorAlpha = Double(ns.alphaComponent)
                    } else {
                        settings.workspaceBarAccentColorRed = -1
                        settings.workspaceBarAccentColorGreen = -1
                        settings.workspaceBarAccentColorBlue = -1
                        settings.workspaceBarAccentColorAlpha = 1
                    }
                    controller.updateWorkspaceBarAppearance()
                }
            ))
            Spacer()
            if useCustomAccent {
                ColorPicker("", selection: accentBinding, supportsOpacity: true)
                    .labelsHidden()
            }
        }
    }
}

private struct WorkspaceBarTextColorPicker: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    private var useCustomText: Bool {
        settings.workspaceBarTextColorRed >= 0
    }

    private var textBinding: Binding<Color> {
        Binding(
            get: {
                guard settings.workspaceBarTextColorRed >= 0 else { return .primary }
                return Color(
                    red: settings.workspaceBarTextColorRed,
                    green: settings.workspaceBarTextColorGreen,
                    blue: settings.workspaceBarTextColorBlue,
                    opacity: settings.workspaceBarTextColorAlpha
                )
            },
            set: { newColor in
                if let components = NSColor(newColor).usingColorSpace(.sRGB) {
                    settings.workspaceBarTextColorRed = Double(components.redComponent)
                    settings.workspaceBarTextColorGreen = Double(components.greenComponent)
                    settings.workspaceBarTextColorBlue = Double(components.blueComponent)
                    settings.workspaceBarTextColorAlpha = Double(components.alphaComponent)
                    controller.updateWorkspaceBarAppearance()
                }
            }
        )
    }

    var body: some View {
        HStack {
            Toggle("Custom Text Color", isOn: Binding(
                get: { useCustomText },
                set: { enabled in
                    if enabled {
                        let ns = NSColor.labelColor.usingColorSpace(.sRGB) ?? .white
                        settings.workspaceBarTextColorRed = Double(ns.redComponent)
                        settings.workspaceBarTextColorGreen = Double(ns.greenComponent)
                        settings.workspaceBarTextColorBlue = Double(ns.blueComponent)
                        settings.workspaceBarTextColorAlpha = Double(ns.alphaComponent)
                    } else {
                        settings.workspaceBarTextColorRed = -1
                        settings.workspaceBarTextColorGreen = -1
                        settings.workspaceBarTextColorBlue = -1
                        settings.workspaceBarTextColorAlpha = 1
                    }
                    controller.updateWorkspaceBarAppearance()
                }
            ))
            Spacer()
            if useCustomText {
                ColorPicker("", selection: textBinding, supportsOpacity: true)
                    .labelsHidden()
            }
        }
    }
}

private struct MonitorBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorBarSettings {
        settings.barSettings(for: monitor) ?? MonitorBarSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId
        )
    }

    private func updateSetting(_ update: (inout MonitorBarSettings) -> Void) {
        var ms = monitorSettings
        ms.monitorName = monitor.name
        ms.monitorDisplayId = monitor.displayId
        update(&ms)
        settings.updateBarSettings(ms)
        controller.updateWorkspaceBarSettings()
    }

    var body: some View {
        let ms = monitorSettings

        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Workspace Bar")
            VStack(alignment: .leading, spacing: 8) {
                OverridableToggle(
                    label: "Enable Workspace Bar",
                    value: ms.enabled,
                    globalValue: settings.workspaceBarEnabled,
                    onChange: { newValue in updateSetting { $0.enabled = newValue } },
                    onReset: { updateSetting { $0.enabled = nil } }
                )

                OverridableToggle(
                    label: "Show Workspace Labels",
                    value: ms.showLabels,
                    globalValue: settings.workspaceBarShowLabels,
                    onChange: { newValue in updateSetting { $0.showLabels = newValue } },
                    onReset: { updateSetting { $0.showLabels = nil } }
                )

                OverridableToggle(
                    label: "Show Floating Windows",
                    value: ms.showFloatingWindows,
                    globalValue: settings.workspaceBarShowFloatingWindows,
                    onChange: { newValue in updateSetting { $0.showFloatingWindows = newValue } },
                    onReset: { updateSetting { $0.showFloatingWindows = nil } }
                )

                OverridableToggle(
                    label: "Deduplicate App Icons",
                    value: ms.deduplicateAppIcons,
                    globalValue: settings.workspaceBarDeduplicateAppIcons,
                    onChange: { newValue in updateSetting { $0.deduplicateAppIcons = newValue } },
                    onReset: { updateSetting { $0.deduplicateAppIcons = nil } }
                )
                .help("Group windows by app with badge count")

                OverridableToggle(
                    label: "Hide Empty Workspaces",
                    value: ms.hideEmptyWorkspaces,
                    globalValue: settings.workspaceBarHideEmptyWorkspaces,
                    onChange: { newValue in updateSetting { $0.hideEmptyWorkspaces = newValue } },
                    onReset: { updateSetting { $0.hideEmptyWorkspaces = nil } }
                )

                OverridableToggle(
                    label: "Reserve Space for Workspace Bar",
                    value: ms.reserveLayoutSpace,
                    globalValue: settings.workspaceBarReserveLayoutSpace,
                    onChange: { newValue in updateSetting { $0.reserveLayoutSpace = newValue } },
                    onReset: { updateSetting { $0.reserveLayoutSpace = nil } }
                )
                .help(
                    "Reserve tiled layout space for the workspace bar. " +
                    "Overlapping Menu Bar uses the configured bar height; " +
                    "bars placed below the menu bar use the rendered bar height."
                )

                OverridableToggle(
                    label: "Notch-Aware Positioning",
                    value: ms.notchAware,
                    globalValue: settings.workspaceBarNotchAware,
                    onChange: { newValue in updateSetting { $0.notchAware = newValue } },
                    onReset: { updateSetting { $0.notchAware = nil } }
                )
                .help("Shift bar to the right of the notch on MacBook Pro")
            }

            Divider()

            SectionHeader("Position & Level")
            VStack(alignment: .leading, spacing: 8) {
                OverridablePicker(
                    label: "Position",
                    value: ms.position,
                    globalValue: settings.workspaceBarPosition,
                    options: WorkspaceBarPosition.allCases,
                    displayName: { $0.displayName },
                    onChange: { newValue in updateSetting { $0.position = newValue } },
                    onReset: { updateSetting { $0.position = nil } }
                )

                OverridablePicker(
                    label: "Window Level",
                    value: ms.windowLevel,
                    globalValue: settings.workspaceBarWindowLevel,
                    options: WorkspaceBarWindowLevel.allCases,
                    displayName: { $0.displayName },
                    onChange: { newValue in updateSetting { $0.windowLevel = newValue } },
                    onReset: { updateSetting { $0.windowLevel = nil } }
                )
            }

            Divider()

            SectionHeader("Position Offset")
            VStack(alignment: .leading, spacing: 8) {
                OverridableStepper(
                    label: "X Offset",
                    value: ms.xOffset,
                    globalValue: settings.workspaceBarXOffset,
                    range: -500 ... 500,
                    step: 10,
                    formatter: { "\(Int($0)) px" },
                    onChange: { newValue in updateSetting { $0.xOffset = newValue } },
                    onReset: { updateSetting { $0.xOffset = nil } }
                )
                .help("Horizontal offset (negative = left, positive = right)")

                OverridableStepper(
                    label: "Y Offset",
                    value: ms.yOffset,
                    globalValue: settings.workspaceBarYOffset,
                    range: -500 ... 500,
                    step: 10,
                    formatter: { "\(Int($0)) px" },
                    onChange: { newValue in updateSetting { $0.yOffset = newValue } },
                    onReset: { updateSetting { $0.yOffset = nil } }
                )
                .help("Vertical offset (negative = down, positive = up)")
            }

            Divider()

            SectionHeader("Appearance")
            VStack(alignment: .leading, spacing: 8) {
                OverridableSlider(
                    label: "Bar Height",
                    value: ms.height,
                    globalValue: settings.workspaceBarHeight,
                    range: 20 ... 40,
                    step: 2,
                    formatter: { "\(Int($0)) px" },
                    onChange: { newValue in updateSetting { $0.height = newValue } },
                    onReset: { updateSetting { $0.height = nil } }
                )

                OverridableSlider(
                    label: "Background Opacity",
                    value: ms.backgroundOpacity,
                    globalValue: settings.workspaceBarBackgroundOpacity,
                    range: 0 ... 0.5,
                    step: 0.05,
                    formatter: { "\(Int($0 * 100))%" },
                    onChange: { newValue in updateSetting { $0.backgroundOpacity = newValue } },
                    onReset: { updateSetting { $0.backgroundOpacity = nil } }
                )
            }
        }
    }
}
