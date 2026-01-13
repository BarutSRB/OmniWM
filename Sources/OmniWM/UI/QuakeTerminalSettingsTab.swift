import SwiftUI

struct QuakeTerminalSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Quake Terminal") {
                Toggle("Enable Quake Terminal", isOn: $settings.quakeTerminalEnabled)
                    .onChange(of: settings.quakeTerminalEnabled) { _, newValue in
                        controller.setQuakeTerminalEnabled(newValue)
                    }
            }

            if settings.quakeTerminalEnabled {
                Section("Position & Size") {
                    Picker("Position", selection: $settings.quakeTerminalPosition) {
                        ForEach(QuakeTerminalPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Width: \(Int(settings.quakeTerminalWidthPercent))%")
                        Slider(value: $settings.quakeTerminalWidthPercent, in: 10...100, step: 5)
                    }

                    VStack(alignment: .leading) {
                        Text("Height: \(Int(settings.quakeTerminalHeightPercent))%")
                        Slider(value: $settings.quakeTerminalHeightPercent, in: 10...100, step: 5)
                    }
                }

                Section("Behavior") {
                    VStack(alignment: .leading) {
                        Text("Animation Duration: \(String(format: "%.1f", settings.quakeTerminalAnimationDuration))s")
                        Slider(value: $settings.quakeTerminalAnimationDuration, in: 0...1, step: 0.1)
                    }

                    Toggle("Auto-hide on Focus Loss", isOn: $settings.quakeTerminalAutoHide)
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quake Terminal provides a drop-down terminal that can be toggled with a hotkey, similar to the console in Quake-style games.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

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
