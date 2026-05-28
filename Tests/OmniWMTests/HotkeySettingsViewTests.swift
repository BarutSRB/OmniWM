import Carbon
import Foundation
@testable import OmniWM
import Testing

struct HotkeySettingsViewTests {
    @Test func inputMonitoringStatusDisplaysPermissionState() {
        #expect(HotkeyInputMonitoringStatus(granted: true) == .granted)
        #expect(HotkeyInputMonitoringStatus(granted: true).displayText == "Granted")
        #expect(HotkeyInputMonitoringStatus(granted: false) == .denied)
        #expect(HotkeyInputMonitoringStatus(granted: false).displayText == "Denied")
        #expect(HotkeySettingsDisplayModel.inputMonitoringStatus(
            preflightGranted: false,
            requestIfNeeded: true,
            requestGranted: true
        ) == .granted)
        #expect(HotkeySettingsDisplayModel.inputMonitoringStatus(
            preflightGranted: false,
            requestIfNeeded: true,
            requestGranted: false
        ) == .denied)
        #expect(HotkeySettingsDisplayModel.inputMonitoringStatus(
            preflightGranted: true,
            requestIfNeeded: false,
            requestGranted: false
        ) == .granted)
    }

    @MainActor
    @Test func presetConfirmationSelectionDoesNotMutateSettingsBeforeApply() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.omniwm.hotkey-settings-view.test.\(UUID().uuidString)")!)
        let originalBindings = settings.hotkeyBindings
        let proposedBindings = settings.hotkeyBindings(applyingPreset: HotkeyPreset.vimNavigation())
        let preview = HotkeyPresetConfirmation.vimNavigation.preview(settings: settings)

        #expect(HotkeyPresetConfirmation.vimNavigation.title == "Apply Vim Navigation?")
        #expect(preview.message.contains("Affected commands:"))
        #expect(proposedBindings != originalBindings)
        #expect(settings.hotkeyBindings == originalBindings)
    }

    @Test func hotkeyDisplayModelUsesOmniWMModifierTerminology() {
        let binding = KeyBinding.defaultLeader
        let trigger = HotkeyTrigger.sequence([.leader, .chord(binding)])

        #expect(binding.displayString == "Hyper+Space")
        #expect(binding.humanReadableString == "Hyper+Space")
        #expect(HotkeySettingsDisplayModel.displayString(for: binding) == "OmniWM+Space")
        #expect(HotkeySettingsDisplayModel.humanReadableString(for: binding) == "OmniWM modifier+Space")
        #expect(HotkeySettingsDisplayModel.displayString(for: trigger) == "Leader, OmniWM+Space")
        #expect(HotkeySettingsDisplayModel.humanReadableString(for: trigger) == "Leader, OmniWM modifier+Space")
    }

    @Test func hotkeyDisplayModelSearchMatchesVisibleOmniWMTerminology() {
        let binding = HotkeyBinding(
            id: "focusLeft",
            command: .focus(.left),
            binding: KeyBinding.defaultLeader
        )

        #expect(binding.binding.displayString == "Hyper+Space")
        #expect(HotkeySettingsDisplayModel.matchesSearch("OmniWM", binding: binding))
        #expect(HotkeySettingsDisplayModel.matchesSearch("OmniWM modifier", binding: binding))
        #expect(!HotkeySettingsDisplayModel.matchesSearch("Hyper", binding: binding))
    }

    @MainActor
    @Test func vimPresetPreviewReportsAffectedCommandsAndUnassignedConflicts() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.omniwm.hotkey-settings-view.test.\(UUID().uuidString)")!)
        settings.updateBinding(
            for: "toggleFullscreen",
            newBinding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        )

        let preview = HotkeyPresetConfirmation.vimNavigation.preview(settings: settings)

        #expect(preview.affectedCommands.contains("Focus Left"))
        #expect(preview.affectedCommands.contains("Move Left"))
        #expect(preview.unassignedCommands.contains("Toggle Fullscreen"))
        #expect(preview.message.contains("Will unassign conflicts: Toggle Fullscreen."))
    }

    @Test func advancedVisibilityModelControlsAdvancedBindingsAndSequenceControls() {
        let normal = HotkeyBinding(
            id: "focusLeft",
            command: .focus(.left),
            binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: 0, usesHyper: true)
        )
        let sequence = HotkeyBinding(
            id: "focusRight",
            command: .focus(.right),
            trigger: .sequence([.leader, .chord(KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: 0))])
        )

        #expect(HotkeySettingsDisplayModel.isVisible(bindingId: "focusLeft", showsAdvancedHotkeys: false))
        #expect(!HotkeySettingsDisplayModel.isVisible(
            bindingId: "moveWindowDownOrToWorkspaceDown",
            showsAdvancedHotkeys: false
        ))
        #expect(HotkeySettingsDisplayModel.isVisible(
            bindingId: "moveWindowDownOrToWorkspaceDown",
            showsAdvancedHotkeys: true
        ))
        #expect(!HotkeySettingsDisplayModel.isVisible(bindingId: "moveWindowUp", showsAdvancedHotkeys: true))
        #expect(!HotkeySettingsDisplayModel.showsSequenceControls(
            showsAdvancedHotkeys: false,
            isRecordingOrDrafting: false,
            bindings: [normal]
        ))
        #expect(HotkeySettingsDisplayModel.showsSequenceControls(
            showsAdvancedHotkeys: false,
            isRecordingOrDrafting: false,
            bindings: [normal, sequence]
        ))
        #expect(HotkeySettingsDisplayModel.showsSequenceControls(
            showsAdvancedHotkeys: true,
            isRecordingOrDrafting: false,
            bindings: [normal]
        ))
    }
}
