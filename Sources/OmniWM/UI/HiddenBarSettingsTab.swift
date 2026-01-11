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

                if settings.hiddenBarEnabled {
                    Toggle("Enable Always Hidden Section", isOn: $settings.hiddenBarAlwaysHiddenEnabled)
                        .onChange(of: settings.hiddenBarAlwaysHiddenEnabled) { _, _ in
                            controller.internalHiddenBarController.updateAlwaysHiddenSection()
                        }

                    Text("Add a second separator for icons that should never be shown")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            if settings.hiddenBarEnabled {
                Section("Usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Click the chevron button to expand/collapse", systemImage: "chevron.left")
                        Label("Drag icons between chevron and separator to hide them", systemImage: "line.diagonal")
                        Label("Configure a hotkey in Hotkeys settings for quick toggle", systemImage: "keyboard")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }

            Section("About") {
                Text("Hidden Bar adds a collapsible section to your menu bar. Drag menu bar icons between the toggle button and separator line to choose which icons get hidden when collapsed.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
