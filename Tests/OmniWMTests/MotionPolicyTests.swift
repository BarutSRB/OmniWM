// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MotionPolicyTests: XCTestCase {
    func testSystemReduceMotionMasksUserToggleWithoutOverwritingIt() {
        let policy = MotionPolicy(animationsEnabled: true)
        XCTAssertTrue(policy.animationsEnabled)

        policy.systemReducesMotion = true
        XCTAssertFalse(policy.animationsEnabled)
        XCTAssertTrue(policy.userAnimationsEnabled)
        XCTAssertEqual(policy.snapshot(), .disabled)

        policy.animationsEnabled = false
        XCTAssertFalse(policy.userAnimationsEnabled)
        policy.animationsEnabled = true
        XCTAssertTrue(policy.userAnimationsEnabled)
        XCTAssertFalse(policy.animationsEnabled)

        policy.systemReducesMotion = false
        XCTAssertTrue(policy.animationsEnabled)
        XCTAssertEqual(policy.snapshot(), .enabled)
    }

    func testControllerPersistsUserPreferenceUnderSystemReduceMotion() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMotionPolicyTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.motionPolicy.systemReducesMotion = true

        controller.setAnimationsEnabled(false)
        XCTAssertFalse(settings.animationsEnabled)
        XCTAssertFalse(controller.motionPolicy.userAnimationsEnabled)

        controller.setAnimationsEnabled(true)
        XCTAssertTrue(settings.animationsEnabled)
        XCTAssertTrue(controller.motionPolicy.userAnimationsEnabled)
        XCTAssertFalse(controller.motionPolicy.animationsEnabled)

        controller.motionPolicy.systemReducesMotion = false
        XCTAssertTrue(controller.motionPolicy.animationsEnabled)
    }
}
