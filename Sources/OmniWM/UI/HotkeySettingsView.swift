import SwiftUI

struct HotkeySettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var recordingBindingId: String?
    @State private var conflictAlert: ConflictAlert?

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

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(HotkeyCategory.allCases, id: \.self) { category in
                        HotkeyCategorySection(
                            category: category,
                            bindings: bindingsForCategory(category),
                            recordingBindingId: $recordingBindingId,
                            registrationFailures: controller.hotkeyRegistrationFailures,
                            onBindingChange: handleBindingChange,
                            onClear: clearBinding
                        )
                    }
                }
            }
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("Hotkey Conflict"),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Replace")) {
                    applyBinding(alert.newBinding, to: alert.bindingId, clearingConflicts: true)
                },
                secondaryButton: .cancel {
                    recordingBindingId = nil
                }
            )
        }
    }

    private func bindingsForCategory(_ category: HotkeyCategory) -> [HotkeyBinding] {
        settings.hotkeyBindings.filter { $0.category == category }
    }

    private func handleBindingChange(bindingId: String, newBinding: KeyBinding) {
        let conflicts = settings.findConflicts(for: newBinding, excluding: bindingId)
        if !conflicts.isEmpty {
            conflictAlert = ConflictAlert(
                bindingId: bindingId,
                newBinding: newBinding,
                conflictingCommands: conflicts.map(\.command.displayName)
            )
        } else {
            applyBinding(newBinding, to: bindingId, clearingConflicts: false)
        }
    }

    private func applyBinding(_ binding: KeyBinding, to bindingId: String, clearingConflicts: Bool) {
        if clearingConflicts {
            let conflicts = settings.findConflicts(for: binding, excluding: bindingId)
            for conflict in conflicts {
                settings.updateBinding(for: conflict.id, newBinding: .unassigned)
            }
        }
        settings.updateBinding(for: bindingId, newBinding: binding)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        recordingBindingId = nil
    }

    private func clearBinding(bindingId: String) {
        settings.updateBinding(for: bindingId, newBinding: .unassigned)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
    }
}

struct ConflictAlert: Identifiable {
    let id = UUID()
    let bindingId: String
    let newBinding: KeyBinding
    let conflictingCommands: [String]

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
    @Binding var recordingBindingId: String?
    let registrationFailures: Set<HotkeyCommand>
    let onBindingChange: (String, KeyBinding) -> Void
    let onClear: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.rawValue)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.red)

            ForEach(bindings) { binding in
                HotkeyBindingRow(
                    binding: binding,
                    isRecording: recordingBindingId == binding.id,
                    hasFailed: registrationFailures.contains(binding.command),
                    onStartRecording: { recordingBindingId = binding.id },
                    onBindingCaptured: { newBinding in
                        onBindingChange(binding.id, newBinding)
                    },
                    onCancel: { recordingBindingId = nil },
                    onClear: { onClear(binding.id) }
                )
            }
        }
    }
}

struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    let isRecording: Bool
    let hasFailed: Bool
    let onStartRecording: () -> Void
    let onBindingCaptured: (KeyBinding) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack {
            Text(binding.command.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("Failed to register: this key combination may be reserved by the system")
            }

            if isRecording {
                KeyRecorderView(onCapture: onBindingCaptured, onCancel: onCancel)
                    .frame(width: 100, height: 24)
            } else {
                Button(action: onStartRecording) {
                    Text(binding.binding.displayString)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                if !binding.binding.isUnassigned {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear this hotkey")
                }
            }
        }
        .padding(.vertical, 2)
    }
}
