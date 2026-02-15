import SwiftUI

struct WorkspaceBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: String?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Configuration Scope")

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Configure settings for:", selection: $selectedMonitor) {
                        Text("Global Defaults").tag(nil as String?)
                        if !connectedMonitors.isEmpty {
                            Divider()
                            ForEach(connectedMonitors, id: \.name) { monitor in
                                HStack {
                                    Text(monitor.name)
                                    if monitor.isMain {
                                        Text("(Main)")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .tag(monitor.name as String?)
                            }
                        }
                    }

                    if let monitorName = selectedMonitor {
                        HStack {
                            if settings.barSettings(for: monitorName) != nil {
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
                                settings.removeBarSettings(for: monitorName)
                                controller.updateWorkspaceBarSettings()
                            }
                            .disabled(settings.barSettings(for: monitorName) == nil)
                        }
                    }
                }

                Divider()

                if let monitorName = selectedMonitor {
                    MonitorBarSettingsSection(
                        settings: settings,
                        controller: controller,
                        monitorName: monitorName
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

                    Toggle("Deduplicate App Icons", isOn: $settings.workspaceBarDeduplicateAppIcons)
                        .onChange(of: settings.workspaceBarDeduplicateAppIcons) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }
                        .help("Group windows by app with badge count")

                    Toggle("Hide Empty Workspaces", isOn: $settings.workspaceBarHideEmptyWorkspaces)
                        .onChange(of: settings.workspaceBarHideEmptyWorkspaces) { _, _ in
                            controller.updateWorkspaceBarSettings()
                        }

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
            }
        }
    }

}

private struct MonitorBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitorName: String

    private var monitorSettings: MonitorBarSettings {
        settings.barSettings(for: monitorName) ?? MonitorBarSettings(monitorName: monitorName)
    }

    private func updateSetting(_ update: (inout MonitorBarSettings) -> Void) {
        var ms = monitorSettings
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
