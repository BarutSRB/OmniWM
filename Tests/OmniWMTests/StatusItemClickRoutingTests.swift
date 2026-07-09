// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class StatusItemClickRoutingTests: XCTestCase {
    func testRightClickOpensHiddenIconsBar() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: true, optionHeld: false), .hiddenIconsBar)
    }

    func testOptionLeftClickOpensHiddenIconsBar() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: false, optionHeld: true), .hiddenIconsBar)
    }

    func testOptionRightClickOpensHiddenIconsBar() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: true, optionHeld: true), .hiddenIconsBar)
    }

    func testPlainLeftClickOpensMenu() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: false, optionHeld: false), .menu)
    }

    func testAccessibilityValueIncludesWorkspaceAppAndRecordingState() {
        XCTAssertEqual(
            StatusBarController.statusButtonAccessibilityValue(
                workspaceLabel: "Code",
                focusedAppName: "Xcode",
                isRecording: true
            ),
            "Recording diagnostics, Workspace Code, Focused app Xcode"
        )
    }

    func testAccessibilityValueHasStableFallback() {
        XCTAssertEqual(
            StatusBarController.statusButtonAccessibilityValue(
                workspaceLabel: nil,
                focusedAppName: nil,
                isRecording: false
            ),
            "Window manager controls"
        )
    }
}
