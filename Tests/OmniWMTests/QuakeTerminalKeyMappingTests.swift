// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalKeyMappingTests: XCTestCase {
    func testEveryDigitKeyCodeSelectsItsTab() {
        let expectedTabIndexByKeyCode: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8
        ]
        for (keyCode, expectedIndex) in expectedTabIndexByKeyCode {
            XCTAssertEqual(
                QuakeTerminalWindow.tabIndex(forDigitKeyCode: keyCode),
                expectedIndex,
                "keyCode \(keyCode) should select tab \(expectedIndex)"
            )
        }
    }

    func testMappingCoversExactlyNineDigits() {
        let mappedKeyCodes = (UInt16(0) ... 127).filter { QuakeTerminalWindow.tabIndex(forDigitKeyCode: $0) != nil }
        XCTAssertEqual(mappedKeyCodes.count, 9)

        let mappedIndexes = mappedKeyCodes.compactMap { QuakeTerminalWindow.tabIndex(forDigitKeyCode: $0) }
        XCTAssertEqual(mappedIndexes.sorted(), Array(0 ... 8))
    }

    func testEqualsKeyCodeSelectsNoTab() {
        XCTAssertNil(QuakeTerminalWindow.tabIndex(forDigitKeyCode: 24))
    }

    func testUnmappedKeyCodesSelectNoTab() {
        XCTAssertNil(QuakeTerminalWindow.tabIndex(forDigitKeyCode: 17))
        XCTAssertNil(QuakeTerminalWindow.tabIndex(forDigitKeyCode: 29))
    }
}
