// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

enum HotkeyCaptureResult {
    case applied
    case conflict(ConflictAlert)
}

@MainActor enum HotkeyBindingEditor {
    static func capture(
        _ newBinding: KeyBinding,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        let conflicts = settings.findConflicts(for: newBinding, excluding: actionId)
        guard conflicts.isEmpty else {
            return .conflict(
                ConflictAlert(
                    targetActionId: actionId,
                    newBinding: newBinding,
                    conflictingCommands: conflicts.map(\.command.displayName)
                )
            )
        }

        settings.updateBinding(for: actionId, newBinding: newBinding)
        return .applied
    }

    static func applyConflictResolution(_ alert: ConflictAlert, settings: SettingsStore) {
        let conflicts = settings.findConflicts(for: alert.newBinding, excluding: alert.targetActionId)
        for conflict in conflicts {
            settings.clearBinding(for: conflict.id)
        }
        settings.updateBinding(for: alert.targetActionId, newBinding: alert.newBinding)
    }
}

struct HotkeySettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var recordingActionId: String?
    @State private var conflictAlert: ConflictAlert?
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hotkey Bindings")
                    .font(.headline)
                Spacer()
                Button("Reset to Defaults") {
                    settings.resetHotkeysToDefaults()
                    controller.updateHotkeyBindings(settings.hotkeyBindings)
                }
                .buttonStyle(.link)
            }
            .padding(.bottom, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search hotkeys...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    })
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(HotkeyCategory.allCases, id: \.self) { category in
                        let actions = actionsForCategory(category)
                        if !actions.isEmpty {
                            HotkeyCategorySection(
                                category: category,
                                bindings: actions,
                                motionPolicy: controller.motionPolicy,
                                recordingActionId: $recordingActionId,
                                registrationFailures: controller.hotkeyRegistrationFailures,
                                onStartRecording: startRecording,
                                onBindingCaptured: handleBindingCaptured,
                                onClearBinding: clearBinding,
                                onResetBindings: resetBindings
                            )
                        }
                    }
                }
            }
        }
        .onChange(of: recordingActionId) { _, newValue in
            syncHotkeyRecordingState(newValue)
        }
        .onDisappear {
            guard recordingActionId != nil else { return }
            controller.setHotkeysEnabled(settings.hotkeysEnabled)
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("Hotkey Conflict"),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Replace")) {
                    HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)
                    controller.updateHotkeyBindings(settings.hotkeyBindings)
                    recordingActionId = nil
                },
                secondaryButton: .cancel {
                    recordingActionId = nil
                }
            )
        }
    }

    private func actionsForCategory(_ category: HotkeyCategory) -> [HotkeyBinding] {
        settings.hotkeyBindings.filter { binding in
            binding.category == category && ActionCatalog.matchesSearch(searchText, binding: binding)
        }
    }

    private func startRecording(for actionId: String) {
        recordingActionId = actionId
    }

    private func handleBindingCaptured(actionId: String, newBinding: KeyBinding) {
        switch HotkeyBindingEditor.capture(newBinding, for: actionId, settings: settings) {
        case .applied:
            controller.updateHotkeyBindings(settings.hotkeyBindings)
            recordingActionId = nil
        case let .conflict(alert):
            conflictAlert = alert
            recordingActionId = nil
        }
    }

    private func clearBinding(actionId: String) {
        settings.clearBinding(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        recordingActionId = nil
    }

    private func resetBindings(actionId: String) {
        settings.resetBindings(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        recordingActionId = nil
    }

    private func syncHotkeyRecordingState(_ actionId: String?) {
        controller.setHotkeysEnabled(actionId == nil ? settings.hotkeysEnabled : false)
    }
}

struct ConflictAlert: Identifiable {
    let targetActionId: String
    let newBinding: KeyBinding
    let conflictingCommands: [String]

    var id: String {
        [
            targetActionId,
            String(newBinding.keyCode),
            String(newBinding.modifiers),
            conflictingCommands.joined(separator: "|"),
        ].joined(separator: ":")
    }

    var message: String {
        if conflictingCommands.count == 1 {
            return "This key combination is already used by \"\(conflictingCommands[0])\". Do you want to replace it?"
        } else {
            let commandList = conflictingCommands.joined(separator: ", ")
            return "This key combination is used by: \(commandList). Do you want to replace all?"
        }
    }
}

struct HotkeyCategorySection: View {
    let category: HotkeyCategory
    let bindings: [HotkeyBinding]
    let motionPolicy: MotionPolicy
    @Binding var recordingActionId: String?
    let registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason]
    let onStartRecording: (String) -> Void
    let onBindingCaptured: (String, KeyBinding) -> Void
    let onClearBinding: (String) -> Void
    let onResetBindings: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.rawValue)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)

            ForEach(bindings) { binding in
                HotkeyBindingRow(
                    binding: binding,
                    motionPolicy: motionPolicy,
                    recordingActionId: $recordingActionId,
                    failureReason: registrationFailures[binding.command],
                    onStartRecording: onStartRecording,
                    onBindingCaptured: onBindingCaptured,
                    onClearBinding: onClearBinding,
                    onResetBindings: onResetBindings
                )
            }
        }
    }
}

struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    let motionPolicy: MotionPolicy
    @Binding var recordingActionId: String?
    let failureReason: HotkeyRegistrationFailureReason?
    let onStartRecording: (String) -> Void
    let onBindingCaptured: (String, KeyBinding) -> Void
    let onClearBinding: (String) -> Void
    let onResetBindings: (String) -> Void

    @State private var showHotkeyHelp = false
    @State private var hotkeyHelpTask: Task<Void, Never>?

    private let hoverHelpDelayNs: UInt64 = 120_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 6) {
                    Text(binding.command.displayName)
                    if binding.command.layoutCompatibility != .shared {
                        Text(binding.command.layoutCompatibility.rawValue)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                binding.command.layoutCompatibility == .niri
                                    ? Color.blue.opacity(0.2)
                                    : Color.purple.opacity(0.2)
                            )
                            .foregroundColor(binding.command.layoutCompatibility == .niri ? .blue : .purple)
                            .cornerRadius(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let failureReason {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .help(failureMessage(for: failureReason))
                }

                Button("Reset") {
                    hideHotkeyHelp()
                    recordingActionId = nil
                    onResetBindings(binding.id)
                }
                .buttonStyle(.link)
            }

            HotkeyBindingChip(
                binding: binding.binding,
                isRecording: recordingActionId == binding.id,
                onStartRecording: {
                    hideHotkeyHelp()
                    onStartRecording(binding.id)
                },
                onCaptured: { newBinding in
                    onBindingCaptured(binding.id, newBinding)
                },
                onCancel: {
                    recordingActionId = nil
                },
                onRemove: {
                    hideHotkeyHelp()
                    onClearBinding(binding.id)
                },
                showHotkeyHelp: $showHotkeyHelp,
                hoverHelpDelayNs: hoverHelpDelayNs
            )
        }
        .padding(.vertical, 2)
        .zIndex(showHotkeyHelp ? 1 : 0)
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.1) : nil, value: showHotkeyHelp)
        .onDisappear {
            cancelHotkeyHelpTask()
        }
    }

    private func failureMessage(for reason: HotkeyRegistrationFailureReason) -> String {
        switch reason {
        case .duplicateBinding:
            return "Failed to register: this key combination is already assigned to another OmniWM command"
        case .systemReserved:
            return "Failed to register: this key combination may be reserved by the system"
        }
    }

    private func hideHotkeyHelp() {
        cancelHotkeyHelpTask()
        showHotkeyHelp = false
    }

    private func cancelHotkeyHelpTask() {
        hotkeyHelpTask?.cancel()
        hotkeyHelpTask = nil
    }
}

struct HotkeyBindingChip: View {
    let binding: KeyBinding
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (KeyBinding) -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    @Binding var showHotkeyHelp: Bool
    let hoverHelpDelayNs: UInt64

    @State private var hotkeyHelpTask: Task<Void, Never>?

    var body: some View {
        let helpText = binding.humanReadableString

        HStack(spacing: 6) {
            if isRecording {
                KeyRecorderView(onCapture: onCaptured, onCancel: onCancel)
                    .frame(width: 100, height: 24)
            } else {
                Button(action: {
                    hideHotkeyHelp()
                    onStartRecording()
                }, label: {
                    Text(binding.displayString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                })
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    if showHotkeyHelp {
                        HotkeyHoverTooltip(text: helpText)
                            .offset(y: -34)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                    }
                }
                .onHover(perform: updateHotkeyHover)

                if !binding.isUnassigned {
                    Button(action: {
                        hideHotkeyHelp()
                        onRemove()
                    }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    })
                    .buttonStyle(.plain)
                    .help("Clear this hotkey")
                }
            }
        }
        .onDisappear {
            cancelHotkeyHelpTask()
        }
    }

    private func updateHotkeyHover(_ hovering: Bool) {
        cancelHotkeyHelpTask()

        guard hovering else {
            showHotkeyHelp = false
            return
        }

        hotkeyHelpTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hoverHelpDelayNs)
            guard !Task.isCancelled else { return }
            showHotkeyHelp = true
        }
    }

    private func hideHotkeyHelp() {
        cancelHotkeyHelpTask()
        showHotkeyHelp = false
    }

    private func cancelHotkeyHelpTask() {
        hotkeyHelpTask?.cancel()
        hotkeyHelpTask = nil
    }
}

private struct HotkeyHoverTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
