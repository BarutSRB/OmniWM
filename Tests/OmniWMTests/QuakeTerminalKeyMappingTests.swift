// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalKeyMappingTests: XCTestCase {
    private let nonDigitBindings: [(NSEvent.ModifierFlags, UInt16, QuakeTerminalShortcut)] = [
        (.command, 2, .splitPane(.horizontal)),
        (.command, 13, .closeTab),
        (.command, 17, .newTab),
        ([.command, .option], 123, .navigatePane(.left)),
        ([.command, .option], 124, .navigatePane(.right)),
        ([.command, .option], 125, .navigatePane(.down)),
        ([.command, .option], 126, .navigatePane(.up)),
        ([.command, .shift], 30, .nextTab),
        ([.command, .shift], 33, .previousTab),
        ([.command, .shift], 2, .splitPane(.vertical)),
        ([.command, .shift], 13, .closePane),
        ([.command, .shift], 24, .equalizeSplits),
        (.control, 48, .nextTab),
        ([.control, .shift], 48, .previousTab)
    ]

    func testEveryDigitKeyCodeSelectsItsTab() {
        let expectedTabIndexByKeyCode: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8
        ]
        for (keyCode, expectedIndex) in expectedTabIndexByKeyCode {
            XCTAssertEqual(
                QuakeTerminalShortcut.tabIndex(forDigitKeyCode: keyCode),
                expectedIndex,
                "keyCode \(keyCode) should select tab \(expectedIndex)"
            )
            XCTAssertEqual(
                QuakeTerminalShortcut.decode(keyCode: keyCode, modifiers: .command),
                .selectTab(expectedIndex)
            )
        }
    }

    func testMappingCoversExactlyNineDigits() {
        let mappedKeyCodes = (UInt16(0) ... 127).filter { QuakeTerminalShortcut.tabIndex(forDigitKeyCode: $0) != nil }
        XCTAssertEqual(mappedKeyCodes.count, 9)

        let mappedIndexes = mappedKeyCodes.compactMap { QuakeTerminalShortcut.tabIndex(forDigitKeyCode: $0) }
        XCTAssertEqual(mappedIndexes.sorted(), Array(0 ... 8))
    }

    func testEqualsKeyCodeSelectsNoTab() {
        XCTAssertNil(QuakeTerminalShortcut.tabIndex(forDigitKeyCode: 24))
    }

    func testUnmappedKeyCodesSelectNoTab() {
        XCTAssertNil(QuakeTerminalShortcut.tabIndex(forDigitKeyCode: 17))
        XCTAssertNil(QuakeTerminalShortcut.tabIndex(forDigitKeyCode: 29))
    }

    func testEveryNonDigitShortcutDecodesToItsAction() {
        for (modifiers, keyCode, expected) in nonDigitBindings {
            XCTAssertEqual(QuakeTerminalShortcut.decode(keyCode: keyCode, modifiers: modifiers), expected)
        }
    }

    func testKeyCodesOutsideEachModifierGroupRemainUnmapped() {
        let modifierGroups: [NSEvent.ModifierFlags] = [
            .command, [.command, .option], [.command, .shift], .control, [.control, .shift]
        ]
        let digitKeys: Set<UInt16> = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for modifiers in modifierGroups {
            let groupKeys = Set(nonDigitBindings.filter { $0.0 == modifiers }.map { $0.1 })
            for keyCode in UInt16(0) ... 127 {
                if groupKeys.contains(keyCode) || (modifiers == .command && digitKeys.contains(keyCode)) {
                    continue
                }
                XCTAssertNil(QuakeTerminalShortcut.decode(keyCode: keyCode, modifiers: modifiers))
            }
        }
    }

    func testAdditionalDeviceIndependentModifiersRejectRecognizedBindings() {
        let extras: [NSEvent.ModifierFlags] = [.capsLock, .numericPad, .help, .function]
        for (modifiers, keyCode, _) in nonDigitBindings {
            for extra in extras {
                XCTAssertNil(QuakeTerminalShortcut.decode(keyCode: keyCode, modifiers: modifiers.union(extra)))
            }
        }
        for extra in extras {
            XCTAssertNil(QuakeTerminalShortcut.decode(keyCode: 18, modifiers: [.command, extra]))
        }
    }

    func testRecognizedBindingsAreConsumedWithoutATabController() throws {
        let window = makeWindow()
        XCTAssertNil(window.tabController)
        for (modifiers, keyCode, _) in nonDigitBindings {
            XCTAssertTrue(window.performKeyEquivalent(with: try event(keyCode: keyCode, modifiers: modifiers)))
        }
        for keyCode: UInt16 in [18, 19, 20, 21, 23, 22, 26, 28, 25] {
            XCTAssertTrue(window.performKeyEquivalent(with: try event(keyCode: keyCode, modifiers: .command)))
        }
        XCTAssertFalse(window.isVisible)
    }

    func testDeviceDependentModifierBitsAreIgnoredBeforeDecoding() throws {
        let window = makeWindow()
        let deviceSpecific = NSEvent.ModifierFlags(rawValue: 1)
        let modifiedEvent = try event(keyCode: 18, modifiers: [.command, deviceSpecific])

        XCTAssertEqual(modifiedEvent.modifierFlags.intersection(.deviceIndependentFlagsMask), .command)
        XCTAssertTrue(window.performKeyEquivalent(with: modifiedEvent))
        XCTAssertFalse(window.isVisible)
    }

    private func makeWindow() -> QuakeTerminalWindow {
        QuakeTerminalWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
    }

    private func event(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
