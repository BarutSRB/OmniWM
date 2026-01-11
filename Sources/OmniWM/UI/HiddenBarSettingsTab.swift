import SwiftUI

struct HiddenBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Hidden Bar") {
                Toggle("Enable Hidden Bar", isOn: $settings.hiddenBarEnabled)
                    .onChange(of: settings.hiddenBarEnabled) { _, newValue in
                        controller.setHiddenBarEnabled(newValue)
                    }
            }

            if settings.hiddenBarEnabled {
                Section("Usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Right-click the OmniWM icon to expand/collapse", systemImage: "o.circle")
                        Label("Drag icons between OmniWM icon and separator to hide them", systemImage: "line.diagonal")
                        Label("Configure a hotkey in Hotkeys settings for quick toggle", systemImage: "keyboard")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }

            Section("About") {
                Text("Hidden Bar adds a collapsible section to your menu bar. Drag menu bar icons between the OmniWM icon and the separator line to choose which icons get hidden when collapsed. Right-click the OmniWM icon to toggle.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
