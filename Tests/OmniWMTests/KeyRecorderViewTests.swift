// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Carbon
import Testing

@testable import OmniWM

@MainActor
private func makeKeyRecorderEvent(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String,
    charactersIgnoringModifiers: String
) -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        fatalError("Failed to create key recorder test event")
    }
    return event
}

@Suite(.serialized) @MainActor struct KeyRecorderViewTests {
    @Test func keyDownCapturesPhysicalTopRowKeyForCzechStyleCharacters() {
        let view = KeyRecorderNSView(frame: .zero)
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_1),
            modifierFlags: .command,
            characters: "+",
            charactersIgnoringModifiers: "+"
        )

        view.keyDown(with: event)

        #expect(captured == [
            KeyBinding(
                keyCode: UInt32(kVK_ANSI_1),
                modifiers: UInt32(cmdKey)
            )
        ])
    }

    @Test func performKeyEquivalentCapturesCommandBindingsBeforeAppKitSwallowsThem() {
        let view = KeyRecorderNSView(frame: .zero)
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_1),
            modifierFlags: .command,
            characters: "+",
            charactersIgnoringModifiers: "+"
        )

        let handled = view.performKeyEquivalent(with: event)

        #expect(handled == true)
        #expect(captured == [
            KeyBinding(
                keyCode: UInt32(kVK_ANSI_1),
                modifiers: UInt32(cmdKey)
            )
        ])
    }
}
