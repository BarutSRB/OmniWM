import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selectedSection)
        } detail: {
            SettingsDetailView(
                section: selectedSection,
                settings: settings,
                controller: controller
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 500)
    }
}

struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var exportStatus: ExportStatus?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.appearanceMode) { _, newValue in
                    newValue.apply()
                }

                Text("Controls the appearance of menus and workspace bar")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Layout") {
                HStack {
                    Text("Inner Gaps")
                    Slider(value: $settings.gapSize, in: 0 ... 32, step: 1)
                    Text("\(Int(settings.gapSize)) px")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                }
                .onChange(of: settings.gapSize) { _, newValue in
                    controller.setGapSize(newValue)
                }

                Divider()
                Text("Outer Margins").font(.subheadline).foregroundColor(.secondary)

                HStack {
                    Text("Left")
                    Slider(value: $settings.outerGapLeft, in: 0 ... 64, step: 1)
                    Text("\(Int(settings.outerGapLeft)) px")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                }
                .onChange(of: settings.outerGapLeft) { _, _ in
                    syncOuterGaps()
                }

                HStack {
                    Text("Right")
                    Slider(value: $settings.outerGapRight, in: 0 ... 64, step: 1)
                    Text("\(Int(settings.outerGapRight)) px")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                }
                .onChange(of: settings.outerGapRight) { _, _ in
                    syncOuterGaps()
                }

                HStack {
                    Text("Top")
                    Slider(value: $settings.outerGapTop, in: 0 ... 64, step: 1)
                    Text("\(Int(settings.outerGapTop)) px")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                }
                .onChange(of: settings.outerGapTop) { _, _ in
                    syncOuterGaps()
                }

                HStack {
                    Text("Bottom")
                    Slider(value: $settings.outerGapBottom, in: 0 ... 64, step: 1)
                    Text("\(Int(settings.outerGapBottom)) px")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                }
                .onChange(of: settings.outerGapBottom) { _, _ in
                    syncOuterGaps()
                }

                Divider()
                Text("Animations").font(.subheadline).foregroundColor(.secondary)

                Toggle("Enable Animations", isOn: $settings.animationsEnabled)
                    .onChange(of: settings.animationsEnabled) { _, newValue in
                        controller.updateNiriConfig(animationsEnabled: newValue)
                    }

                Divider()
                Text("Scroll Gestures").font(.subheadline).foregroundColor(.secondary)

                Toggle("Enable Scroll Gestures", isOn: $settings.scrollGestureEnabled)

                HStack {
                    Text("Scroll Sensitivity")
                    Slider(value: $settings.scrollSensitivity, in: 0.1 ... 100.0, step: 0.1)
                    Text(String(format: "%.1f", settings.scrollSensitivity) + "x")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }

                Picker("Trackpad Gesture Fingers", selection: $settings.gestureFingerCount) {
                    ForEach(GestureFingerCount.allCases, id: \.self) { count in
                        Text(count.displayName).tag(count)
                    }
                }
                .disabled(!settings.scrollGestureEnabled)

                Toggle("Invert Direction (Natural)", isOn: $settings.gestureInvertDirection)
                    .disabled(!settings.scrollGestureEnabled)

                Text(settings.gestureInvertDirection ? "Swipe right = scroll right" : "Swipe right = scroll left")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Picker("Mouse Scroll Modifier", selection: $settings.scrollModifierKey) {
                    ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .disabled(!settings.scrollGestureEnabled)

                Text("Hold this key + scroll wheel to navigate workspaces")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Settings Backup") {
                HStack {
                    Button("Export Settings") {
                        do {
                            try settings.exportSettings()
                            exportStatus = .exported
                        } catch {
                            exportStatus = .error(error.localizedDescription)
                        }
                    }

                    Button("Import Settings") {
                        do {
                            try settings.importSettings()
                            exportStatus = .imported
                        } catch {
                            exportStatus = .error(error.localizedDescription)
                        }
                    }
                    .disabled(!settings.settingsFileExists)
                }

                Text("~/.config/omniwm/settings.json")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                if let status = exportStatus {
                    Label(status.message, systemImage: status.icon)
                        .foregroundColor(status.color)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func syncOuterGaps() {
        controller.setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom
        )
    }
}

struct NiriSettingsTab: View {
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
                        if settings.niriSettings(for: monitorName) != nil {
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
                            settings.removeNiriSettings(for: monitorName)
                            controller.updateMonitorNiriSettings()
                        }
                        .disabled(settings.niriSettings(for: monitorName) == nil)
                    }
                }
            }

            Divider()

            if let monitorName = selectedMonitor {
                MonitorNiriSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitorName: monitorName
                )
            } else {
                GlobalNiriSettingsSection(
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

private struct GlobalNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Niri Layout")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Windows per Column")
                    Slider(value: .init(
                        get: { Double(settings.niriMaxWindowsPerColumn) },
                        set: { settings.niriMaxWindowsPerColumn = Int($0) }
                    ), in: 1 ... 10, step: 1)
                    Text("\(settings.niriMaxWindowsPerColumn)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 24, alignment: .trailing)
                }
                .onChange(of: settings.niriMaxWindowsPerColumn) { _, newValue in
                    controller.updateNiriConfig(maxWindowsPerColumn: newValue)
                }

                HStack {
                    Text("Visible Columns")
                    Slider(value: .init(
                        get: { Double(settings.niriMaxVisibleColumns) },
                        set: { settings.niriMaxVisibleColumns = Int($0) }
                    ), in: 1 ... 5, step: 1)
                    Text("\(settings.niriMaxVisibleColumns)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 24, alignment: .trailing)
                }
                .onChange(of: settings.niriMaxVisibleColumns) { _, newValue in
                    controller.updateNiriConfig(maxVisibleColumns: newValue)
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

                Picker("Single Window Ratio", selection: $settings.niriSingleWindowAspectRatio) {
                    ForEach(SingleWindowAspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.displayName).tag(ratio)
                    }
                }
                .onChange(of: settings.niriSingleWindowAspectRatio) { _, newValue in
                    controller.updateNiriConfig(singleWindowAspectRatio: newValue)
                }
            }

            Divider()

            SectionHeader("Column Width Presets")
            let presets = settings.niriColumnWidthPresets
            VStack(alignment: .leading, spacing: 8) {
                ForEach(presets.indices, id: \.self) { index in
                    HStack {
                        TextField("", value: Binding(
                            get: { Int(presets[index] * 100) },
                            set: { newPercent in
                                var current = settings.niriColumnWidthPresets
                                current[index] = Double(min(100, max(5, newPercent))) / 100.0
                                settings.niriColumnWidthPresets = current.sorted()
                                controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                            }
                        ), format: .number)
                        .frame(width: 40)
                        .multilineTextAlignment(.trailing)
                        Text("%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Button(role: .destructive) {
                            var presets = settings.niriColumnWidthPresets
                            presets.remove(at: index)
                            settings.niriColumnWidthPresets = presets
                            controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(settings.niriColumnWidthPresets.count <= 2)
                    }
                }

                HStack {
                    Button("Add Preset") {
                        var presets = settings.niriColumnWidthPresets
                        presets.append(0.5)
                        settings.niriColumnWidthPresets = presets.sorted()
                        controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                    }
                    Button("Reset to Default") {
                        settings.niriColumnWidthPresets = SettingsStore.defaultColumnWidthPresets
                        controller.updateNiriConfig(columnWidthPresets: settings.niriColumnWidthPresets)
                    }
                }
            }
            .id(settings.niriColumnWidthPresets.count)
        }
    }
}

private struct MonitorNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitorName: String

    private var monitorSettings: MonitorNiriSettings {
        settings.niriSettings(for: monitorName) ?? MonitorNiriSettings(monitorName: monitorName)
    }

    private func updateSetting(_ update: (inout MonitorNiriSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.updateNiriSettings(ms)
        controller.updateMonitorNiriSettings()
    }

    var body: some View {
        let ms = monitorSettings

        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Niri Layout")
            VStack(alignment: .leading, spacing: 8) {
                OverridableSlider(
                    label: "Windows per Column",
                    value: ms.maxWindowsPerColumn.map { Double($0) },
                    globalValue: Double(settings.niriMaxWindowsPerColumn),
                    range: 1 ... 10,
                    step: 1,
                    formatter: { "\(Int($0))" },
                    onChange: { newValue in updateSetting { $0.maxWindowsPerColumn = Int(newValue) } },
                    onReset: { updateSetting { $0.maxWindowsPerColumn = nil } }
                )

                OverridableSlider(
                    label: "Visible Columns",
                    value: ms.maxVisibleColumns.map { Double($0) },
                    globalValue: Double(settings.niriMaxVisibleColumns),
                    range: 1 ... 5,
                    step: 1,
                    formatter: { "\(Int($0))" },
                    onChange: { newValue in updateSetting { $0.maxVisibleColumns = Int(newValue) } },
                    onReset: { updateSetting { $0.maxVisibleColumns = nil } }
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

                OverridablePicker(
                    label: "Single Window Ratio",
                    value: ms.singleWindowAspectRatio,
                    globalValue: settings.niriSingleWindowAspectRatio,
                    options: SingleWindowAspectRatio.allCases,
                    displayName: { $0.displayName },
                    onChange: { newValue in updateSetting { $0.singleWindowAspectRatio = newValue } },
                    onReset: { updateSetting { $0.singleWindowAspectRatio = nil } }
                )
            }
        }
    }
}

struct MenuAnywhereSettingsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Menu Anywhere") {
                Toggle("Enable Native Menu Popup", isOn: $settings.menuAnywhereNativeEnabled)
                Text("Shows the frontmost app's menu bar as a popup at your cursor")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Enable Menu Palette", isOn: $settings.menuAnywherePaletteEnabled)
                Text("Shows a searchable command palette with all menu items")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Popup Position", selection: $settings.menuAnywherePosition) {
                    ForEach(MenuAnywherePosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }

                Toggle("Show Keyboard Shortcuts", isOn: $settings.menuAnywhereShowShortcuts)
                Text("Display keyboard shortcuts in the menu palette")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private enum ExportStatus {
    case exported
    case imported
    case error(String)

    var message: String {
        switch self {
        case .exported: "Settings exported"
        case .imported: "Settings imported"
        case .error(let msg): "Error: \(msg)"
        }
    }

    var icon: String {
        switch self {
        case .exported, .imported: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .exported, .imported: .green
        case .error: .red
        }
    }
}
