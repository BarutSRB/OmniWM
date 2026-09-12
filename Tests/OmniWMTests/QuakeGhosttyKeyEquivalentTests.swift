// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeGhosttyKeyEquivalentTests: XCTestCase {
    func testControlReturnAcceptsAdditionalModifiersWithoutChangingRetryTimestamp() throws {
        for flags: NSEvent.ModifierFlags in [.control, [.control, .shift, .command, .option]] {
            var timestamp: TimeInterval? = 9
            let event = try keyEvent(characters: "\r", modifiers: flags, timestamp: 0)

            XCTAssertEqual(characters(for: event, timestamp: &timestamp), "\r")
            XCTAssertEqual(timestamp, 9)
        }
    }

    func testReturnWithoutControlLeavesRetryTimestampUnchanged() throws {
        var timestamp: TimeInterval? = 9
        let event = try keyEvent(characters: "\r", modifiers: .command)

        XCTAssertNil(characters(for: event, timestamp: &timestamp))
        XCTAssertEqual(timestamp, 9)
    }

    func testControlSlashMapsToUnderscoreAndPreservesRetryTimestamp() throws {
        for flags: NSEvent.ModifierFlags in [.control, [.control, .capsLock]] {
            var timestamp: TimeInterval? = 9
            let event = try keyEvent(characters: "/", modifiers: flags, timestamp: 0)

            XCTAssertEqual(characters(for: event, timestamp: &timestamp), "_")
            XCTAssertEqual(timestamp, 9)
        }
    }

    func testSlashRejectsMissingControlOrAdditionalShortcutModifiers() throws {
        let modifiers: [NSEvent.ModifierFlags] = [
            [], .command, [.control, .shift], [.control, .command], [.control, .option]
        ]
        for flags in modifiers {
            var timestamp: TimeInterval? = 9
            let event = try keyEvent(characters: "/", modifiers: flags)

            XCTAssertNil(characters(for: event, timestamp: &timestamp))
            XCTAssertEqual(timestamp, 9)
        }
    }

    func testZeroTimestampDoesNotAlterPendingRetry() throws {
        for flags: NSEvent.ModifierFlags in [[], .command, .control] {
            var timestamp: TimeInterval? = 9
            let event = try keyEvent(characters: "a", modifiers: flags, timestamp: 0)

            XCTAssertNil(characters(for: event, timestamp: &timestamp))
            XCTAssertEqual(timestamp, 9)
        }
    }

    func testUnmodifiedKeyClearsPendingRetry() throws {
        for flags: NSEvent.ModifierFlags in [[], .shift, .option] {
            var timestamp: TimeInterval? = 9
            let event = try keyEvent(characters: "a", modifiers: flags)

            XCTAssertNil(characters(for: event, timestamp: &timestamp))
            XCTAssertNil(timestamp)
        }
    }

    func testModifiedKeyIsConsumedOnlyOnItsSecondPass() throws {
        for flags: NSEvent.ModifierFlags in [.command, .control, [.command, .control]] {
            var timestamp: TimeInterval?
            let event = try keyEvent(characters: "a", modifiers: flags, timestamp: 11)

            XCTAssertNil(characters(for: event, timestamp: &timestamp))
            XCTAssertEqual(timestamp, 11)
            XCTAssertEqual(characters(for: event, timestamp: &timestamp), "a")
            XCTAssertNil(timestamp)
            XCTAssertNil(characters(for: event, timestamp: &timestamp))
            XCTAssertEqual(timestamp, 11)
        }
    }

    func testDifferentModifiedKeyReplacesPendingRetry() throws {
        var timestamp: TimeInterval? = 9
        let event = try keyEvent(characters: "b", modifiers: .command, timestamp: 11)

        XCTAssertNil(characters(for: event, timestamp: &timestamp))
        XCTAssertEqual(timestamp, 11)
        XCTAssertEqual(characters(for: event, timestamp: &timestamp), "b")
        XCTAssertNil(timestamp)
    }

    func testEmptyCharactersRemainAnAcceptedSecondPass() throws {
        var timestamp: TimeInterval? = 11
        let event = try keyEvent(characters: "", modifiers: .command, timestamp: 11)

        XCTAssertEqual(characters(for: event, timestamp: &timestamp), "")
        XCTAssertNil(timestamp)
    }

    private func characters(for event: NSEvent, timestamp: inout TimeInterval?) -> String? {
        QuakeGhosttyInputBridge.keyEquivalentCharacters(for: event, lastPerformKeyEvent: &timestamp)
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        timestamp: TimeInterval = 11
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }
}
