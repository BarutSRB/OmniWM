import SwiftUI

struct DwindleSettingsTab: View {
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
                        if settings.dwindleSettings(for: monitor) != nil {
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
                            settings.removeDwindleSettings(for: monitor)
                            controller.updateMonitorDwindleSettings()
                        }
                        .disabled(settings.dwindleSettings(for: monitor) == nil)
                    }
                }
            }

            Divider()

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorDwindleSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalDwindleSettingsSection(
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

private struct GlobalDwindleSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Dwindle Layout")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Smart Split", isOn: $settings.dwindleSmartSplit)
                    .onChange(of: settings.dwindleSmartSplit) { _, newValue in
                        controller.updateDwindleConfig(smartSplit: newValue)
                    }
                Text("Automatically choose split direction based on cursor position")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Move to Root: Stable", isOn: $settings.dwindleMoveToRootStable)
                Text("Keep window on same screen side when moving to root")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text("Default Split Ratio")
                    Slider(value: $settings.dwindleDefaultSplitRatio, in: 0.1 ... 1.9, step: 0.1)
                    Text(String(format: "%.1f", settings.dwindleDefaultSplitRatio))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
                .onChange(of: settings.dwindleDefaultSplitRatio) { _, newValue in
                    controller.updateDwindleConfig(defaultSplitRatio: CGFloat(newValue))
                }
                Text("1.0 = equal split, <1.0 = first smaller, >1.0 = first larger")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Split Width Multiplier")
                    Slider(value: $settings.dwindleSplitWidthMultiplier, in: 0.5 ... 2.0, step: 0.1)
                    Text(String(format: "%.1f", settings.dwindleSplitWidthMultiplier))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
                .onChange(of: settings.dwindleSplitWidthMultiplier) { _, newValue in
                    controller.updateDwindleConfig(splitWidthMultiplier: CGFloat(newValue))
                }
                Text("Affects when to prefer vertical vs horizontal splits")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Picker("Single Window Ratio", selection: $settings.dwindleSingleWindowAspectRatio) {
                    ForEach(DwindleSingleWindowAspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.displayName).tag(ratio)
                    }
                }
                .onChange(of: settings.dwindleSingleWindowAspectRatio) { _, newValue in
                    controller.updateDwindleConfig(singleWindowAspectRatio: newValue.size)
                }

                Divider()

                Toggle("Use Global Gap Settings", isOn: $settings.dwindleUseGlobalGaps)
                    .onChange(of: settings.dwindleUseGlobalGaps) { _, _ in
                        controller.updateDwindleConfig()
                    }
                Text("When enabled, uses the gap values from General settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct MonitorDwindleSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorDwindleSettings {
        settings.dwindleSettings(for: monitor) ?? MonitorDwindleSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId
        )
    }

    private func updateSetting(_ update: (inout MonitorDwindleSettings) -> Void) {
        var ms = monitorSettings
        ms.monitorName = monitor.name
        ms.monitorDisplayId = monitor.displayId
        update(&ms)
        settings.updateDwindleSettings(ms)
        controller.updateMonitorDwindleSettings()
    }

    var body: some View {
        let ms = monitorSettings

        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Dwindle Layout")
            VStack(alignment: .leading, spacing: 8) {
                OverridableToggle(
                    label: "Smart Split",
                    value: ms.smartSplit,
                    globalValue: settings.dwindleSmartSplit,
                    onChange: { newValue in updateSetting { $0.smartSplit = newValue } },
                    onReset: { updateSetting { $0.smartSplit = nil } }
                )
                Text("Automatically choose split direction based on cursor position")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                OverridableSlider(
                    label: "Default Split Ratio",
                    value: ms.defaultSplitRatio,
                    globalValue: settings.dwindleDefaultSplitRatio,
                    range: 0.1 ... 1.9,
                    step: 0.1,
                    formatter: { String(format: "%.1f", $0) },
                    onChange: { newValue in updateSetting { $0.defaultSplitRatio = newValue } },
                    onReset: { updateSetting { $0.defaultSplitRatio = nil } }
                )
                Text("1.0 = equal split, <1.0 = first smaller, >1.0 = first larger")
                    .font(.caption)
                    .foregroundColor(.secondary)

                OverridableSlider(
                    label: "Split Width Multiplier",
                    value: ms.splitWidthMultiplier,
                    globalValue: settings.dwindleSplitWidthMultiplier,
                    range: 0.5 ... 2.0,
                    step: 0.1,
                    formatter: { String(format: "%.1f", $0) },
                    onChange: { newValue in updateSetting { $0.splitWidthMultiplier = newValue } },
                    onReset: { updateSetting { $0.splitWidthMultiplier = nil } }
                )
                Text("Affects when to prefer vertical vs horizontal splits")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                OverridablePicker(
                    label: "Single Window Ratio",
                    value: ms.singleWindowAspectRatio,
                    globalValue: settings.dwindleSingleWindowAspectRatio,
                    options: DwindleSingleWindowAspectRatio.allCases,
                    displayName: { $0.displayName },
                    onChange: { newValue in updateSetting { $0.singleWindowAspectRatio = newValue } },
                    onReset: { updateSetting { $0.singleWindowAspectRatio = nil } }
                )

                Divider()

                OverridableToggle(
                    label: "Use Global Gap Settings",
                    value: ms.useGlobalGaps,
                    globalValue: settings.dwindleUseGlobalGaps,
                    onChange: { newValue in updateSetting { $0.useGlobalGaps = newValue } },
                    onReset: { updateSetting { $0.useGlobalGaps = nil } }
                )
                Text("When enabled, uses the gap values from General settings")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !(ms.useGlobalGaps ?? settings.dwindleUseGlobalGaps) {
                    Divider()

                    OverridableSlider(
                        label: "Inner Gap",
                        value: ms.innerGap,
                        globalValue: settings.gapSize,
                        range: 0 ... 32,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { newValue in updateSetting { $0.innerGap = newValue } },
                        onReset: { updateSetting { $0.innerGap = nil } }
                    )

                    Text("Outer Margins").font(.subheadline).foregroundColor(.secondary)

                    OverridableSlider(
                        label: "Left",
                        value: ms.outerGapLeft,
                        globalValue: settings.outerGapLeft,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { newValue in updateSetting { $0.outerGapLeft = newValue } },
                        onReset: { updateSetting { $0.outerGapLeft = nil } }
                    )

                    OverridableSlider(
                        label: "Right",
                        value: ms.outerGapRight,
                        globalValue: settings.outerGapRight,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { newValue in updateSetting { $0.outerGapRight = newValue } },
                        onReset: { updateSetting { $0.outerGapRight = nil } }
                    )

                    OverridableSlider(
                        label: "Top",
                        value: ms.outerGapTop,
                        globalValue: settings.outerGapTop,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { newValue in updateSetting { $0.outerGapTop = newValue } },
                        onReset: { updateSetting { $0.outerGapTop = nil } }
                    )

                    OverridableSlider(
                        label: "Bottom",
                        value: ms.outerGapBottom,
                        globalValue: settings.outerGapBottom,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { newValue in updateSetting { $0.outerGapBottom = newValue } },
                        onReset: { updateSetting { $0.outerGapBottom = nil } }
                    )
                }
            }
        }
    }
}
