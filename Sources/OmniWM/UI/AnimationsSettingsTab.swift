import SwiftUI

struct AnimationsSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section {
                    Toggle("Enable Animations", isOn: $settings.animationsEnabled)
                        .onChange(of: settings.animationsEnabled) { _, newValue in
                            controller.updateNiriConfig(animationsEnabled: newValue)
                        }

                    if !settings.animationsEnabled {
                        Text("All animations are disabled. Windows will snap instantly.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    SectionHeader(title: "General")
                }

                if settings.animationsEnabled {
                    AnimationTypeSection(
                        title: "Focus Change",
                        description: "When keyboard navigation moves focus between columns",
                        preset: $settings.focusChangeSpringPreset,
                        useCustom: $settings.focusChangeUseCustom,
                        stiffness: $settings.focusChangeCustomStiffness,
                        damping: $settings.focusChangeCustomDamping,
                        onUpdate: { updateFocusChangeConfig() }
                    )

                    AnimationTypeSection(
                        title: "Gesture Completion",
                        description: "When trackpad or scroll wheel gesture ends",
                        preset: $settings.gestureSpringPreset,
                        useCustom: $settings.gestureUseCustom,
                        stiffness: $settings.gestureCustomStiffness,
                        damping: $settings.gestureCustomDamping,
                        onUpdate: { updateGestureConfig() }
                    )

                    AnimationTypeSection(
                        title: "Column Reveal",
                        description: "When scrolling to bring a column into view",
                        preset: $settings.columnRevealSpringPreset,
                        useCustom: $settings.columnRevealUseCustom,
                        stiffness: $settings.columnRevealCustomStiffness,
                        damping: $settings.columnRevealCustomDamping,
                        onUpdate: { updateColumnRevealConfig() }
                    )
                }

                Section {
                    Text("Spring physics animations provide natural, velocity-aware motion. Higher stiffness = faster animation. Lower damping = more bounce.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    SectionHeader(title: "About")
                }
            }
            .padding()
        }
    }

    private func updateFocusChangeConfig() {
        let config = settings.focusChangeUseCustom
            ? SpringConfig(stiffness: settings.focusChangeCustomStiffness, dampingRatio: settings.focusChangeCustomDamping)
            : settings.focusChangeSpringPreset.config
        controller.updateNiriConfig(focusChangeSpringConfig: config)
    }

    private func updateGestureConfig() {
        let config = settings.gestureUseCustom
            ? SpringConfig(stiffness: settings.gestureCustomStiffness, dampingRatio: settings.gestureCustomDamping)
            : settings.gestureSpringPreset.config
        controller.updateNiriConfig(gestureSpringConfig: config)
    }

    private func updateColumnRevealConfig() {
        let config = settings.columnRevealUseCustom
            ? SpringConfig(stiffness: settings.columnRevealCustomStiffness, dampingRatio: settings.columnRevealCustomDamping)
            : settings.columnRevealSpringPreset.config
        controller.updateNiriConfig(columnRevealSpringConfig: config)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
    }
}

private struct AnimationTypeSection: View {
    let title: String
    let description: String
    @Binding var preset: AnimationSpringPreset
    @Binding var useCustom: Bool
    @Binding var stiffness: Double
    @Binding var damping: Double
    let onUpdate: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Use Custom Values", isOn: $useCustom)
                    .onChange(of: useCustom) { _, _ in onUpdate() }

                if useCustom {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Stiffness")
                            Slider(value: $stiffness, in: 100 ... 2000, step: 50)
                            Text("\(Int(stiffness))")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(width: 50, alignment: .trailing)
                        }
                        .onChange(of: stiffness) { _, _ in onUpdate() }

                        HStack {
                            Text("Damping")
                            Slider(value: $damping, in: 0.3 ... 1.5, step: 0.05)
                            Text(String(format: "%.2f", damping))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(width: 50, alignment: .trailing)
                        }
                        .onChange(of: damping) { _, _ in onUpdate() }

                        Text(damping < 1.0 ? "Bouncy" : (damping == 1.0 ? "Critically damped" : "Overdamped"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Picker("Preset", selection: $preset) {
                        ForEach(AnimationSpringPreset.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: preset) { _, _ in onUpdate() }

                    presetDescription(for: preset)
                }
            }
        } header: {
            SectionHeader(title: title)
        }
    }

    @ViewBuilder
    private func presetDescription(for preset: AnimationSpringPreset) -> some View {
        let (desc, details): (String, String) = switch preset {
        case .snappy: ("Fast and responsive, no bounce", "Stiffness: 1000 · Damping: 1.0")
        case .smooth: ("Slower, more relaxed motion", "Stiffness: 400 · Damping: 1.0")
        case .bouncy: ("Slight overshoot before settling", "Stiffness: 600 · Damping: 0.7")
        }

        VStack(alignment: .leading, spacing: 2) {
            Text(desc)
                .font(.caption)
                .foregroundColor(.primary)
            Text(details)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
