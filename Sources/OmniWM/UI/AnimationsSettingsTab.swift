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
                    AnimationContextSection(
                        title: "Focus Change",
                        description: "When keyboard navigation moves focus between columns",
                        animationType: $settings.focusChangeAnimationType,
                        springPreset: $settings.focusChangeSpringPreset,
                        springUseCustom: $settings.focusChangeUseCustom,
                        springStiffness: $settings.focusChangeCustomStiffness,
                        springDamping: $settings.focusChangeCustomDamping,
                        easingCurve: $settings.focusChangeEasingCurve,
                        easingDuration: $settings.focusChangeEasingDuration,
                        onUpdate: { updateFocusChangeConfig() }
                    )

                    AnimationContextSection(
                        title: "Gesture Completion",
                        description: "When trackpad or scroll wheel gesture ends",
                        animationType: $settings.gestureAnimationType,
                        springPreset: $settings.gestureSpringPreset,
                        springUseCustom: $settings.gestureUseCustom,
                        springStiffness: $settings.gestureCustomStiffness,
                        springDamping: $settings.gestureCustomDamping,
                        easingCurve: $settings.gestureEasingCurve,
                        easingDuration: $settings.gestureEasingDuration,
                        onUpdate: { updateGestureConfig() }
                    )

                    AnimationContextSection(
                        title: "Column Reveal",
                        description: "When scrolling to bring a column into view",
                        animationType: $settings.columnRevealAnimationType,
                        springPreset: $settings.columnRevealSpringPreset,
                        springUseCustom: $settings.columnRevealUseCustom,
                        springStiffness: $settings.columnRevealCustomStiffness,
                        springDamping: $settings.columnRevealCustomDamping,
                        easingCurve: $settings.columnRevealEasingCurve,
                        easingDuration: $settings.columnRevealEasingDuration,
                        onUpdate: { updateColumnRevealConfig() }
                    )
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spring: Physics-based animations with natural, velocity-aware motion. Higher stiffness = faster. Lower damping = more bounce.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Text("Easing: Time-based animations with predictable duration. Choose curve shape to control acceleration.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    SectionHeader(title: "About")
                }
            }
            .padding()
        }
    }

    private func updateFocusChangeConfig() {
        let springConfig = settings.focusChangeUseCustom
            ? SpringConfig(stiffness: settings.focusChangeCustomStiffness, dampingRatio: settings.focusChangeCustomDamping)
            : settings.focusChangeSpringPreset.config
        controller.updateNiriConfig(
            focusChangeSpringConfig: springConfig,
            focusChangeAnimationType: settings.focusChangeAnimationType,
            focusChangeEasingCurve: settings.focusChangeEasingCurve,
            focusChangeEasingDuration: settings.focusChangeEasingDuration
        )
    }

    private func updateGestureConfig() {
        let springConfig = settings.gestureUseCustom
            ? SpringConfig(stiffness: settings.gestureCustomStiffness, dampingRatio: settings.gestureCustomDamping)
            : settings.gestureSpringPreset.config
        controller.updateNiriConfig(
            gestureSpringConfig: springConfig,
            gestureAnimationType: settings.gestureAnimationType,
            gestureEasingCurve: settings.gestureEasingCurve,
            gestureEasingDuration: settings.gestureEasingDuration
        )
    }

    private func updateColumnRevealConfig() {
        let springConfig = settings.columnRevealUseCustom
            ? SpringConfig(stiffness: settings.columnRevealCustomStiffness, dampingRatio: settings.columnRevealCustomDamping)
            : settings.columnRevealSpringPreset.config
        controller.updateNiriConfig(
            columnRevealSpringConfig: springConfig,
            columnRevealAnimationType: settings.columnRevealAnimationType,
            columnRevealEasingCurve: settings.columnRevealEasingCurve,
            columnRevealEasingDuration: settings.columnRevealEasingDuration
        )
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

private struct AnimationContextSection: View {
    let title: String
    let description: String
    @Binding var animationType: AnimationType
    @Binding var springPreset: AnimationSpringPreset
    @Binding var springUseCustom: Bool
    @Binding var springStiffness: Double
    @Binding var springDamping: Double
    @Binding var easingCurve: EasingCurve
    @Binding var easingDuration: Double
    let onUpdate: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Animation Type", selection: $animationType) {
                    ForEach(AnimationType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: animationType) { _, _ in onUpdate() }

                switch animationType {
                case .spring:
                    SpringOptionsView(
                        preset: $springPreset,
                        useCustom: $springUseCustom,
                        stiffness: $springStiffness,
                        damping: $springDamping,
                        onUpdate: onUpdate
                    )
                case .easing:
                    EasingOptionsView(
                        curve: $easingCurve,
                        duration: $easingDuration,
                        onUpdate: onUpdate
                    )
                }
            }
        } header: {
            SectionHeader(title: title)
        }
    }
}

private struct SpringOptionsView: View {
    @Binding var preset: AnimationSpringPreset
    @Binding var useCustom: Bool
    @Binding var stiffness: Double
    @Binding var damping: Double
    let onUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

                springPresetDescription(for: preset)
            }
        }
    }

    @ViewBuilder
    private func springPresetDescription(for preset: AnimationSpringPreset) -> some View {
        let (desc, details): (String, String) = switch preset {
        case .snappy: ("Fast and responsive, no bounce", "Stiffness: 800 · Damping: 1.0")
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

private struct EasingOptionsView: View {
    @Binding var curve: EasingCurve
    @Binding var duration: Double
    let onUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Curve", selection: $curve) {
                ForEach(EasingCurve.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .onChange(of: curve) { _, _ in onUpdate() }

            easingCurveDescription(for: curve)

            HStack {
                Text("Duration")
                Slider(value: $duration, in: 0.1 ... 1.0, step: 0.05)
                Text(String(format: "%.2fs", duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
            }
            .onChange(of: duration) { _, _ in onUpdate() }
        }
    }

    @ViewBuilder
    private func easingCurveDescription(for curve: EasingCurve) -> some View {
        let desc: String = switch curve {
        case .linear: "Constant speed throughout"
        case .easeInCubic: "Starts slow, accelerates"
        case .easeOutCubic: "Starts fast, decelerates"
        case .easeInOutCubic: "Slow start and end, fast middle"
        case .easeInExpo: "Very slow start, rapid acceleration"
        case .easeOutExpo: "Very fast start, gentle stop"
        case .easeInOutExpo: "Dramatic slow-fast-slow"
        }

        Text(desc)
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
