// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarMenuGuardTests: XCTestCase {
    private let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    func testPopUpWindowOwnedByMenuOwnerDetected() {
        XCTAssertTrue(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [(layer: popUpLevel, ownerPID: 500, title: nil)],
                menuOwnerPIDs: [500]
            )
        )
    }

    func testOwnPopUpWindowsIgnored() {
        XCTAssertFalse(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [
                    (layer: popUpLevel, ownerPID: 42, title: nil),
                    (layer: popUpLevel, ownerPID: 42, title: nil)
                ],
                menuOwnerPIDs: [500]
            )
        )
    }

    func testStatusAndNormalLayersIgnored() {
        XCTAssertFalse(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [
                    (layer: 25, ownerPID: 500, title: nil),
                    (layer: 0, ownerPID: 500, title: nil)
                ],
                menuOwnerPIDs: [500]
            )
        )
    }

    func testLevelBelowPopUpDetected() {
        XCTAssertTrue(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [(layer: popUpLevel - 1, ownerPID: 500, title: nil)],
                menuOwnerPIDs: [500]
            )
        )
    }

    func testTitledPopUpWindowIgnored() {
        XCTAssertFalse(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [(layer: popUpLevel, ownerPID: 500, title: "Item-0")],
                menuOwnerPIDs: [500]
            )
        )
    }

    func testEmptyTitleCountsAsCandidate() {
        XCTAssertTrue(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [(layer: popUpLevel, ownerPID: 500, title: "")],
                menuOwnerPIDs: [500]
            )
        )
    }

    func testEmptyOwnerSetShortCircuits() {
        XCTAssertFalse(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [(layer: popUpLevel, ownerPID: 500, title: nil)],
                menuOwnerPIDs: []
            )
        )
    }

    func testMixedWindowsAnyMatchWins() {
        XCTAssertTrue(
            HiddenBarMenuGuard.isMenuOpen(
                windows: [
                    (layer: popUpLevel, ownerPID: 42, title: nil),
                    (layer: popUpLevel, ownerPID: 500, title: nil)
                ],
                menuOwnerPIDs: [500]
            )
        )
    }
}
