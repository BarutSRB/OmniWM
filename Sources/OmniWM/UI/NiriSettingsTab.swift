// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct NiriSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.niriSettings(for: $0) != nil },
                reset: { monitor in
                    settings.removeNiriSettings(for: monitor)
                    controller.updateMonitorNiriSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorNiriSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalNiriSettingsSection(
                    settings: settings,
                    controller: controller
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }
}

private struct GlobalNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        let useAutoDefaultContainerPrimarySpan = Binding(
            get: { settings.niriDefaultContainerPrimarySpan == nil },
            set: { useAuto in
                settings
                    .niriDefaultContainerPrimarySpan = useAuto ? nil : (settings.niriDefaultContainerPrimarySpan ?? 0.5)
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan)
                controller.balanceNiriSizesAllWorkspaces()
            }
        )
        let defaultContainerPrimarySpanPercent = Binding(
            get: { Int((settings.niriDefaultContainerPrimarySpan ?? 0.5) * 100) },
            set: { newPercent in
                settings.niriDefaultContainerPrimarySpan = Double(min(100, max(5, newPercent))) / 100.0
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan)
                controller.balanceNiriSizesAllWorkspaces()
            }
        )
        let presets = settings.niriContainerPrimarySpanPresets

        Section("Niri Layout") {
            SettingsSliderRow(
                label: "Visible Containers",
                value: Binding(
                    get: { Double(settings.niriVisibleContainerCount) },
                    set: { settings.niriVisibleContainerCount = Int($0) }
                ),
                range: 1 ... 5,
                step: 1,
                valueText: "\(settings.niriVisibleContainerCount)",
                valueWidth: 32
            )
            .onChange(of: settings.niriVisibleContainerCount) { _, newValue in
                settings.niriDefaultContainerPrimarySpan = nil
                controller.updateNiriConfig(
                    visibleContainerCount: newValue,
                    defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan
                )
                controller.balanceNiriSizesAllWorkspaces()
            }

            Toggle("Infinite Loop Navigation", isOn: $settings.niriInfiniteLoop)
                .onChange(of: settings.niriInfiniteLoop) { _, newValue in
                    controller.updateNiriConfig(infiniteLoop: newValue)
                }

            Picker("Center Focused Column", selection: $settings.niriCenterFocusedColumn) {
                ForEach(CenterFocusedColumn.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: settings.niriCenterFocusedColumn) { _, newValue in
                controller.updateNiriConfig(centerFocusedColumn: newValue)
            }

            Toggle("Always Center Single Column", isOn: $settings.niriAlwaysCenterSingleColumn)
                .onChange(of: settings.niriAlwaysCenterSingleColumn) { _, newValue in
                    controller.updateNiriConfig(alwaysCenterSingleColumn: newValue)
                }

            SingleWindowFitControls(
                label: "Single Window",
                fit: settings.niriSingleWindowFit,
                modes: SingleWindowFit.niriModes,
                onChange: { newValue in
                    settings.niriSingleWindowFit = newValue
                    controller.updateNiriConfig(singleWindowFit: newValue)
                }
            )
            SettingsCaption(
                "How a lone window is sized: Full Screen fills the work area; "
                    + "Custom uses a fixed width × height; Container Primary Span keeps the configured primary span."
            )
        }

        Section("Default New Container Primary Span") {
            Picker("Span Mode", selection: useAutoDefaultContainerPrimarySpan) {
                Text("Auto").tag(true)
                Text("Custom").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            if settings.niriDefaultContainerPrimarySpan != nil {
                LabeledContent("Custom Span") {
                    HStack {
                        TextField("Custom Span", value: defaultContainerPrimarySpanPercent, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCaption(
                settings.niriDefaultContainerPrimarySpan == nil
                    ? "Auto divides the primary axis by the Visible Containers setting."
                    : "New or claimed containers start at this primary span until you resize them."
            )
        }

        Section("Container Primary Span Presets") {
            ForEach(presets.indices, id: \.self) { index in
                LabeledContent("Preset \(index + 1)") {
                    HStack {
                        TextField("Preset \(index + 1)", value: Binding(
                            get: { Int(presets[index] * 100) },
                            set: { newPercent in
                                var current = settings.niriContainerPrimarySpanPresets
                                current[index] = Double(min(100, max(5, newPercent))) / 100.0
                                settings.niriContainerPrimarySpanPresets = current
                                controller
                                    .updateNiriConfig(containerPrimarySpanPresets: settings
                                        .niriContainerPrimarySpanPresets)
                            }
                        ), format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Preset \(index + 1) primary span")
                        Text("%")
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            var presets = settings.niriContainerPrimarySpanPresets
                            presets.remove(at: index)
                            settings.niriContainerPrimarySpanPresets = presets
                            controller
                                .updateNiriConfig(containerPrimarySpanPresets: settings.niriContainerPrimarySpanPresets)
                        } label: {
                            Label("Remove preset \(index + 1)", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove preset \(index + 1)")
                        .disabled(settings.niriContainerPrimarySpanPresets.count <= 2)
                    }
                }
            }

            HStack {
                Button("Add Preset") {
                    var presets = settings.niriContainerPrimarySpanPresets
                    presets.append(0.5)
                    settings.niriContainerPrimarySpanPresets = presets
                    controller.updateNiriConfig(containerPrimarySpanPresets: settings.niriContainerPrimarySpanPresets)
                }
                Button("Reset Cycle Presets") {
                    settings.niriContainerPrimarySpanPresets = SettingsStore.defaultContainerPrimarySpanPresets
                    controller.updateNiriConfig(containerPrimarySpanPresets: settings.niriContainerPrimarySpanPresets)
                }
            }
            SettingsCaption("Resize commands cycle through these presets in order. Duplicates are allowed.")
        }
        .id(settings.niriContainerPrimarySpanPresets.count)
    }
}

private struct MonitorNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorNiriSettings {
        settings.niriSettings(for: monitor) ?? MonitorNiriSettings(
            monitorName: monitor.name
        )
    }

    private func updateSetting(_ update: (inout MonitorNiriSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.updateNiriSettings(ms, for: monitor)
        controller.updateMonitorNiriSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Niri Layout") {
            OverridableSlider(
                label: "Visible Containers",
                value: ms.visibleContainerCount.map { Double($0) },
                globalValue: Double(settings.niriVisibleContainerCount),
                range: 1 ... 5,
                step: 1,
                formatter: { "\(Int($0))" },
                onChange: { newValue in
                    updateSetting { $0.visibleContainerCount = Int(newValue) }
                    settings.niriDefaultContainerPrimarySpan = nil
                    controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan)
                    controller.balanceNiriSizesAllWorkspaces()
                },
                onReset: { updateSetting { $0.visibleContainerCount = nil } }
            )

            OverridableToggle(
                label: "Infinite Loop Navigation",
                value: ms.infiniteLoop,
                globalValue: settings.niriInfiniteLoop,
                onChange: { newValue in updateSetting { $0.infiniteLoop = newValue } },
                onReset: { updateSetting { $0.infiniteLoop = nil } }
            )

            OverridablePicker(
                label: "Center Focused Column",
                value: ms.centerFocusedColumn,
                globalValue: settings.niriCenterFocusedColumn,
                options: CenterFocusedColumn.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.centerFocusedColumn = newValue } },
                onReset: { updateSetting { $0.centerFocusedColumn = nil } }
            )

            OverridableToggle(
                label: "Always Center Single Column",
                value: ms.alwaysCenterSingleColumn,
                globalValue: settings.niriAlwaysCenterSingleColumn,
                onChange: { newValue in updateSetting { $0.alwaysCenterSingleColumn = newValue } },
                onReset: { updateSetting { $0.alwaysCenterSingleColumn = nil } }
            )

            SingleWindowFitControls(
                label: "Single Window",
                fit: ms.singleWindowFit ?? settings.niriSingleWindowFit,
                modes: SingleWindowFit.niriModes,
                isOverridden: ms.singleWindowFit != nil,
                onChange: { newValue in updateSetting { $0.singleWindowFit = newValue } },
                onReset: { updateSetting { $0.singleWindowFit = nil } }
            )
        }
    }
}
