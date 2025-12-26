import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, controller: controller)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            NiriSettingsTab(settings: settings, controller: controller)
                .tabItem {
                    Label("Niri", systemImage: "scroll")
                }

            WorkspacesSettingsTab(settings: settings, controller: controller)
                .tabItem {
                    Label("Workspaces", systemImage: "rectangle.3.group")
                }

            BorderSettingsTab(settings: settings, controller: controller)
                .tabItem {
                    Label("Borders", systemImage: "square.dashed")
                }

            WorkspaceBarSettingsTab(settings: settings, controller: controller)
                .tabItem {
                    Label("Bar", systemImage: "menubar.rectangle")
                }

            HotkeySettingsView(settings: settings, controller: controller)
                .padding()
                .tabItem {
                    Label("Hotkeys", systemImage: "keyboard")
                }
        }
        .frame(minWidth: 480, minHeight: 500)
    }
}

struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
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
                Toggle("Fullscreen ignores gaps", isOn: $settings.fullscreenIgnoresGaps)

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
                Text("Scroll Gestures").font(.subheadline).foregroundColor(.secondary)

                Toggle("Enable Scroll Gestures", isOn: $settings.scrollGestureEnabled)

                HStack {
                    Text("Scroll Sensitivity")
                    Slider(value: $settings.scrollSensitivity, in: 0.1 ... 10.0, step: 0.1)
                    Text(String(format: "%.1f", settings.scrollSensitivity) + "x")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }

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
        }
        .padding()
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

    var body: some View {
        Form {
            Section("Niri Layout") {
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
        }
        .padding()
    }
}
