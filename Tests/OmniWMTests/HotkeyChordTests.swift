import AppKit
import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

final class HotkeyChordTests: XCTestCase {
    func testHotkeyTriggerRejectsSequenceText() {
        XCTAssertNil(HotkeyTrigger.fromHumanReadable("Option+A, B"))
        XCTAssertNil(HotkeyTrigger.fromHumanReadable("Leader, A"))
    }

    func testHotkeyTriggerRoundTripsChordEncoding() throws {
        let trigger = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)

        XCTAssertEqual(decoded, trigger)
    }

    func testChordConflictDetectionUsesOnlyChordBindings() {
        let lhs = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
        let same = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
        let different = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey)))

        XCTAssertTrue(lhs.conflicts(with: same))
        XCTAssertFalse(lhs.conflicts(with: different))
        XCTAssertFalse(lhs.conflicts(with: .unassigned))
    }

    func testHyperDisplaySugarRoundTrips() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: KeySymbolMapper.hyperModifiers)

        XCTAssertEqual(binding.humanReadableString, "Hyper+1")
        XCTAssertEqual(binding.displayString, "Hyper+1")
        XCTAssertEqual(KeySymbolMapper.fromHumanReadable("Hyper+1"), binding)
    }

    func testHyperAliasEqualsLiteralFourModifiers() {
        XCTAssertEqual(
            KeySymbolMapper.fromHumanReadable("Control+Option+Shift+Command+1"),
            KeySymbolMapper.fromHumanReadable("Hyper+1")
        )
    }

    func testKeyBindingConflictRequiresIdenticalKeyAndModifiers() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let same = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let otherModifiers = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))
        let otherKey = KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey))

        XCTAssertTrue(binding.conflicts(with: same))
        XCTAssertFalse(binding.conflicts(with: otherModifiers))
        XCTAssertFalse(binding.conflicts(with: otherKey))
        XCTAssertFalse(binding.conflicts(with: .unassigned))
    }

    func testRegistrationPlanMarksDuplicateChordBindings() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let bindings = [
            HotkeyBinding(id: "focus.left", command: .focus(.left), binding: binding),
            HotkeyBinding(id: "focus.right", command: .focus(.right), binding: binding)
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(plan.failures[.focus(.left)], .duplicateBinding)
        XCTAssertEqual(plan.failures[.focus(.right)], .duplicateBinding)
        XCTAssertTrue(plan.registrations.isEmpty)
    }

    func testRegistrationPlanRegistersHyperBindingLiterally() {
        let hyperBinding = KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: KeySymbolMapper.hyperModifiers)
        let bindings = [
            HotkeyBinding(id: "focus.right", command: .focus(.right), binding: hyperBinding)
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(
            plan.registrations,
            [HotkeyPlannedRegistration(binding: hyperBinding, command: .focus(.right))]
        )
        XCTAssertTrue(plan.failures.isEmpty)
    }

    func testSystemHyperTriggerCodableRoundTrips() throws {
        for trigger in [SystemHyperTrigger.none, .key(UInt32(kVK_CapsLock)), .mouseButton(4)] {
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(SystemHyperTrigger.self, from: data)
            XCTAssertEqual(decoded, trigger)
        }
    }

    func testSystemHyperTriggerHumanReadableNames() {
        XCTAssertEqual(SystemHyperTrigger.none.humanReadableString, "None")
        XCTAssertEqual(SystemHyperTrigger.key(UInt32(kVK_CapsLock)).humanReadableString, "Caps Lock")
        XCTAssertEqual(SystemHyperTrigger.mouseButton(4).humanReadableString, "MouseButton4")
    }

    func testSystemHyperTriggerParsing() {
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("None"), SystemHyperTrigger.none)
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable(""), SystemHyperTrigger.none)
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("Caps Lock"), .key(UInt32(kVK_CapsLock)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("F13"), .key(UInt32(kVK_F13)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("MouseButton4"), .mouseButton(4))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("A"))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("Space"))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("MouseButton2"))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("not a key"))
    }

    func testSystemHyperTriggerSupportUsesSelectableSets() {
        XCTAssertTrue(SystemHyperTrigger.none.isSupported)
        for keyCode in SystemHyperTrigger.selectableKeyCodes {
            XCTAssertTrue(SystemHyperTrigger.key(keyCode).isSupported)
        }
        for button in SystemHyperTrigger.selectableMouseButtons {
            XCTAssertTrue(SystemHyperTrigger.mouseButton(button).isSupported)
        }

        XCTAssertFalse(SystemHyperTrigger.key(UInt32(kVK_ANSI_A)).isSupported)
        XCTAssertFalse(SystemHyperTrigger.key(UInt32(kVK_Space)).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(0).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(1).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(2).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(6).isSupported)
    }

    func testSystemHyperTriggerDirectDecodeRejectsUnsupportedValues() {
        XCTAssertThrowsError(try JSONDecoder().decode(SystemHyperTrigger.self, from: Data(#""A""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(SystemHyperTrigger.self, from: Data(#""MouseButton2""#.utf8)))
    }

    func testSystemHyperTriggerProperties() {
        XCTAssertFalse(SystemHyperTrigger.none.isEnabled)
        XCTAssertTrue(SystemHyperTrigger.key(UInt32(kVK_F13)).isEnabled)
        XCTAssertTrue(SystemHyperTrigger.key(UInt32(kVK_CapsLock)).requiresCapsLockRemap)
        XCTAssertFalse(SystemHyperTrigger.key(UInt32(kVK_F13)).requiresCapsLockRemap)
        XCTAssertEqual(SystemHyperTrigger.mouseButton(4).mouseButtonNumber, 4)
    }

    func testHyperTriggerStateMachineHandlesKeyTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_F13)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F13)), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .inject)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_F13)), .suppress)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .passThrough)
    }

    func testHyperTriggerStateMachineHandlesCapsLockRemap() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_CapsLock)), .passThrough)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode), .suppress)
        XCTAssertTrue(trigger.isActive)
    }

    func testHyperTriggerStateMachineTogglesCapsLockOnQuickTap() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 1.0), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyUp(CapsLockHyperMapping.f18KeyCode, timestamp: 1.1), .toggleCapsLock)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A), timestamp: 1.2), .passThrough)
    }

    func testHyperTriggerStateMachineCapsLockWithKeyDoesNotToggleOnRelease() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 2.0), .suppress)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_K), timestamp: 2.1), .inject)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_ANSI_K), timestamp: 2.2), .inject)
        XCTAssertEqual(trigger.handleKeyUp(CapsLockHyperMapping.f18KeyCode, timestamp: 2.3), .suppress)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineLongCapsLockHoldDoesNotToggle() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 3.0), .suppress)
        XCTAssertEqual(
            trigger.handleKeyUp(
                CapsLockHyperMapping.f18KeyCode,
                timestamp: 3.0 + HyperTriggerStateMachine.capsLockTapTimeout + 0.01
            ),
            .suppress
        )
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineCapsLockWithMouseDoesNotToggleOnRelease() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 4.0), .suppress)
        XCTAssertEqual(trigger.handleMouseDown(4), .inject)
        XCTAssertEqual(trigger.handleMouseUp(4), .inject)
        XCTAssertEqual(trigger.handleKeyUp(CapsLockHyperMapping.f18KeyCode, timestamp: 4.1), .suppress)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineRealF18NeverTogglesCapsLock() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_F18)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F18), timestamp: 5.0), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_K), timestamp: 5.1), .inject)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_F18), timestamp: 5.2), .suppress)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineHandlesRightSideModifierTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_RightOption)), capsLockRemapped: false)

        XCTAssertEqual(
            trigger.handleFlagsChanged(
                keyCode: UInt32(kVK_RightOption),
                rawFlags: UInt64(NX_DEVICERALTKEYMASK)
            ),
            .suppress
        )
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .inject)
        XCTAssertEqual(
            trigger.handleFlagsChanged(keyCode: UInt32(kVK_RightOption), rawFlags: 0),
            .suppress
        )
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineHandlesMouseTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .mouseButton(4), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleMouseDown(4), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .inject)
        XCTAssertEqual(trigger.handleMouseUp(4), .suppress)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleMouseDown(3), .passThrough)
    }

    func testHyperTriggerStateMachineResetClearsActiveState() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_F13)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F13)), .suppress)
        XCTAssertTrue(trigger.isActive)
        trigger.reset()
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .passThrough)
    }

    func testHyperTriggerStateMachineNonePassesThrough() {
        var trigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F13)), .passThrough)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_F13)), .passThrough)
        XCTAssertEqual(
            trigger.handleFlagsChanged(
                keyCode: UInt32(kVK_RightOption),
                rawFlags: UInt64(NX_DEVICERALTKEYMASK)
            ),
            .passThrough
        )
        XCTAssertEqual(trigger.handleMouseDown(4), .passThrough)
        XCTAssertEqual(trigger.handleMouseUp(4), .passThrough)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineIgnoresUnsupportedTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_ANSI_A)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .passThrough)
        XCTAssertFalse(trigger.isActive)
    }

    func testCapsLockHyperMappingPreservesUnrelatedMappingsWhenApplying() {
        let unrelated = HIDKeyboardModifierMapping(source: 100, destination: 200)
        let existingCapsLock = HIDKeyboardModifierMapping(
            source: CapsLockHyperMapping.capsLockSource,
            destination: 300
        )

        let mappings = CapsLockHyperMapping.applying(to: [unrelated, existingCapsLock])

        XCTAssertEqual(mappings, [unrelated, CapsLockHyperMapping.omniMapping])
    }

    func testCapsLockHyperMappingRestoresOnlyOmniMapping() {
        let unrelated = HIDKeyboardModifierMapping(source: 100, destination: 200)
        let originalCapsLock = HIDKeyboardModifierMapping(
            source: CapsLockHyperMapping.capsLockSource,
            destination: 300
        )

        let mappings = CapsLockHyperMapping.restoring(
            current: [unrelated, CapsLockHyperMapping.omniMapping],
            original: [originalCapsLock]
        )

        XCTAssertEqual(mappings, [unrelated, originalCapsLock])
    }

    func testCapsLockHyperMappingKeepsExternalCapsLockChangeOnRestore() {
        let externalCapsLock = HIDKeyboardModifierMapping(
            source: CapsLockHyperMapping.capsLockSource,
            destination: 400
        )

        let mappings = CapsLockHyperMapping.restoring(
            current: [CapsLockHyperMapping.omniMapping, externalCapsLock],
            original: []
        )

        XCTAssertEqual(mappings, [externalCapsLock])
    }

    func testKeyRecorderBindingResolverRecordsHyperModifiedKey() {
        XCTAssertEqual(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: 0,
                hyperActive: true,
                allowsBareKeys: false
            ),
            KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: KeySymbolMapper.hyperModifiers)
        )
    }

    func testKeyRecorderBindingResolverIgnoresBareHyperTriggerKey() {
        XCTAssertNil(
            KeyRecorderBindingResolver.binding(
                keyCode: CapsLockHyperMapping.f18KeyCode,
                modifiers: 0,
                hyperActive: true,
                allowsBareKeys: false
            )
        )
        XCTAssertNil(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_CapsLock),
                modifiers: 0,
                hyperActive: true,
                allowsBareKeys: false
            )
        )
    }

    func testKeyRecorderBindingResolverKeepsExistingInactiveBehavior() {
        XCTAssertNil(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: 0,
                hyperActive: false,
                allowsBareKeys: false
            )
        )
        XCTAssertEqual(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(optionKey),
                hyperActive: false,
                allowsBareKeys: false
            ),
            KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey))
        )
        XCTAssertEqual(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_F13),
                modifiers: 0,
                hyperActive: false,
                allowsBareKeys: false
            ),
            KeyBinding(keyCode: UInt32(kVK_F13), modifiers: 0)
        )
    }

    func testSettingsTOMLDoesNotEmitLeaderOrSequenceTimeout() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(toml.contains("leaderKey"))
        XCTAssertFalse(toml.contains("sequenceTimeoutMilliseconds"))
    }
}
