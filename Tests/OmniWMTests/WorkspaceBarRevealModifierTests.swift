// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

final class WorkspaceBarRevealModifierTests: XCTestCase {
    private let leftOption = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
    private let rightOption = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK)
    private let control = CGEventFlags.maskControl.rawValue
    private let command = CGEventFlags.maskCommand.rawValue
    private let shift = CGEventFlags.maskShift.rawValue

    func testOffNeverHeld() {
        XCTAssertFalse(WorkspaceBarRevealModifier.off.isHeld(inRawFlags: 0))
        XCTAssertFalse(WorkspaceBarRevealModifier.off.isHeld(inRawFlags: leftOption))
    }

    func testNoModifierHeldIsNeverDetected() {
        for modifier in WorkspaceBarRevealModifier.allCases {
            XCTAssertFalse(modifier.isHeld(inRawFlags: 0), "\(modifier) should not be held with no flags")
        }
    }

    func testSingleModifierMatchesEitherSideIndependentFlag() {
        XCTAssertTrue(WorkspaceBarRevealModifier.option.isHeld(inRawFlags: leftOption))
        XCTAssertTrue(WorkspaceBarRevealModifier.option.isHeld(inRawFlags: rightOption))
        XCTAssertTrue(WorkspaceBarRevealModifier.control.isHeld(inRawFlags: control))
        XCTAssertTrue(WorkspaceBarRevealModifier.command.isHeld(inRawFlags: command))
        XCTAssertTrue(WorkspaceBarRevealModifier.shift.isHeld(inRawFlags: shift))
    }

    func testComboRequiresAllMembers() {
        let combo = WorkspaceBarRevealModifier.controlOptionCommand
        XCTAssertFalse(combo.isHeld(inRawFlags: control | leftOption))
        XCTAssertFalse(combo.isHeld(inRawFlags: control | command))
        XCTAssertFalse(combo.isHeld(inRawFlags: leftOption | command))
        XCTAssertTrue(combo.isHeld(inRawFlags: control | leftOption | command))
    }

    func testSupersetModifiersRemainHeld() {
        XCTAssertTrue(
            WorkspaceBarRevealModifier.controlOptionCommand.isHeld(inRawFlags: control | leftOption | command | shift)
        )
        XCTAssertTrue(WorkspaceBarRevealModifier.option.isHeld(inRawFlags: leftOption | shift))
    }

    func testRawValueRoundTrip() {
        for modifier in WorkspaceBarRevealModifier.allCases {
            XCTAssertEqual(WorkspaceBarRevealModifier(rawValue: modifier.rawValue), modifier)
        }
        XCTAssertEqual(WorkspaceBarRevealModifier.off.rawValue, "off")
        XCTAssertEqual(WorkspaceBarRevealModifier.controlOptionCommand.rawValue, "controlOptionCommand")
    }

    func testInvalidRawValueIsNil() {
        XCTAssertNil(WorkspaceBarRevealModifier(rawValue: "garbage"))
        XCTAssertEqual(WorkspaceBarRevealModifier(rawValue: "garbage") ?? .off, .off)
    }
}
