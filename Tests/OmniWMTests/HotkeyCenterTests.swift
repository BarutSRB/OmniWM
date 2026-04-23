// SPDX-License-Identifier: GPL-2.0-only
import Testing

@testable import OmniWM

@Suite struct HotkeyCenterTests {
    @Test func duplicateBindingsAcrossCommandsFailClosedWithDuplicateReason() {
        let shared = KeyBinding(keyCode: 1, modifiers: 2)
        let unique = KeyBinding(keyCode: 3, modifiers: 4)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "move.left", command: .move(.left), binding: shared),
                HotkeyBinding(id: "move.right", command: .move(.right), binding: shared),
                HotkeyBinding(id: "focus.left", command: .focus(.left), binding: unique),
            ]
        )

        #expect(plan.failures == [
            .move(.left): .duplicateBinding,
            .move(.right): .duplicateBinding,
        ])
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: unique, command: .focus(.left))
        ])
    }

    @Test func unassignedBindingsAreIgnoredByRegistrationPlan() {
        let unique = KeyBinding(keyCode: 31, modifiers: 41)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "move.left", command: .move(.left), binding: .unassigned),
                HotkeyBinding(id: "move.right", command: .move(.right), binding: unique),
            ]
        )

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: unique, command: .move(.right))
        ])
    }
}
