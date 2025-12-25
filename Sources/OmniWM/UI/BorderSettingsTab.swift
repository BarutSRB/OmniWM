import AppKit
import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Window Borders") {
                Toggle("Enable Borders", isOn: $settings.bordersEnabled)
                    .onChange(of: settings.bordersEnabled) { _, newValue in
                        controller.setBordersEnabled(newValue)
                    }

                if settings.bordersEnabled {
                    HStack {
                        Text("Border Width")
                        Slider(value: $settings.borderWidth, in: 1 ... 12, step: 0.5)
                        Text("\(settings.borderWidth, specifier: "%.1f") px")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }
                    .onChange(of: settings.borderWidth) { _, _ in
                        syncBorderConfig()
                    }

                    Divider()

                    Text("Border Color").font(.subheadline).foregroundColor(.secondary)

                    ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
                        .onChange(of: settings.borderColorRed) { _, _ in syncBorderConfig() }
                        .onChange(of: settings.borderColorGreen) { _, _ in syncBorderConfig() }
                        .onChange(of: settings.borderColorBlue) { _, _ in syncBorderConfig() }
                        .onChange(of: settings.borderColorAlpha) { _, _ in syncBorderConfig() }
                }
            }

            Section("About") {
                Text("Borders are displayed around the currently focused window.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: settings.borderColorRed,
                    green: settings.borderColorGreen,
                    blue: settings.borderColorBlue,
                    opacity: settings.borderColorAlpha
                )
            },
            set: { newColor in
                if let cgColor = NSColor(newColor).usingColorSpace(.deviceRGB)?.cgColor,
                   let components = cgColor.components, components.count >= 3
                {
                    settings.borderColorRed = Double(components[0])
                    settings.borderColorGreen = Double(components[1])
                    settings.borderColorBlue = Double(components[2])
                    if components.count >= 4 {
                        settings.borderColorAlpha = Double(components[3])
                    }
                }
            }
        )
    }

    private func syncBorderConfig() {
        controller.updateBorderConfig(BorderConfig.from(settings: settings))
    }
}
