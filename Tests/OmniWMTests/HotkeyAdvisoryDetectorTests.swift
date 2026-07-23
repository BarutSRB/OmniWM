// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
@testable import OmniWM
import XCTest

final class HotkeyAdvisoryDetectorTests: XCTestCase {
    private let advisoryID = "hotkey-advisory:openCommandPalette"

    @MainActor
    func testAdvisoryFiresOnDefaultChord() {
        let defaults = HotkeyBindingRegistry.defaults()
        let issues = HotkeyAdvisoryDetector.issues(currentBindings: defaults, defaults: defaults)
        XCTAssertTrue(issues.contains { $0.id == advisoryID })
    }

    @MainActor
    func testAdvisorySuppressedWhenUnassigned() {
        let defaults = HotkeyBindingRegistry.defaults()
        var current = defaults
        if let index = current.firstIndex(where: { $0.id == "openCommandPalette" }) {
            current[index].binding = .unassigned
        }
        let issues = HotkeyAdvisoryDetector.issues(currentBindings: current, defaults: defaults)
        XCTAssertFalse(issues.contains { $0.id == advisoryID })
    }

    @MainActor
    func testAdvisorySuppressedWhenAssignedDifferentChord() {
        let defaults = HotkeyBindingRegistry.defaults()
        var current = defaults
        if let index = current.firstIndex(where: { $0.id == "openCommandPalette" }) {
            current[index].binding = .chord(
                KeyBinding(
                    keyCode: UInt32(kVK_ANSI_P),
                    modifiers: UInt32(controlKey | optionKey)
                )
            )
        }
        let issues = HotkeyAdvisoryDetector.issues(currentBindings: current, defaults: defaults)
        XCTAssertFalse(issues.contains { $0.id == advisoryID })
    }

    @MainActor
    func testNoBindingsNoAdvisory() {
        let issues = HotkeyAdvisoryDetector.issues(currentBindings: [], defaults: HotkeyBindingRegistry.defaults())
        XCTAssertTrue(issues.isEmpty)
    }
}
