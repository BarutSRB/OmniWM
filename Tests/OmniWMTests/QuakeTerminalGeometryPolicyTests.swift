// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class QuakeTerminalGeometryPolicyTests: XCTestCase {
    private let staleFrame = CGRect(x: 640, y: 353, width: 1280, height: 705)
    private let builtInFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let builtInVisibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1084)
    private let externalFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    func testStaleExternalFrameDoesNotFitBuiltInDisplay() {
        XCTAssertFalse(QuakeTerminalGeometryPolicy.customFrameFits(staleFrame, in: builtInFrame))
        XCTAssertFalse(QuakeTerminalGeometryPolicy.customFrameFits(staleFrame, in: builtInVisibleFrame))
    }

    func testStaleExternalFrameStillFitsOriginalExternalDisplay() {
        XCTAssertTrue(QuakeTerminalGeometryPolicy.customFrameFits(staleFrame, in: externalFrame))
    }

    func testFrameEqualToScreenFrameFits() {
        XCTAssertTrue(QuakeTerminalGeometryPolicy.customFrameFits(builtInFrame, in: builtInFrame))
    }

    func testEdgeTouchingMinimumFrameFits() {
        let frame = CGRect(x: 1528, y: 1017, width: 200, height: 100)
        XCTAssertTrue(QuakeTerminalGeometryPolicy.customFrameFits(frame, in: builtInFrame))
    }

    func testSubPointOverhangWithinToleranceFits() {
        let frame = CGRect(x: -0.5, y: 0, width: 200, height: 100)
        XCTAssertTrue(QuakeTerminalGeometryPolicy.customFrameFits(frame, in: builtInFrame))
    }

    func testOverhangBeyondToleranceIsRejected() {
        let rightOverhang = CGRect(x: 1529.5, y: 0, width: 200, height: 100)
        let leftOverhang = CGRect(x: -1.5, y: 0, width: 200, height: 100)
        XCTAssertFalse(QuakeTerminalGeometryPolicy.customFrameFits(rightOverhang, in: builtInFrame))
        XCTAssertFalse(QuakeTerminalGeometryPolicy.customFrameFits(leftOverhang, in: builtInFrame))
    }

    func testZeroSizeScreenRejectsFrame() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertFalse(QuakeTerminalGeometryPolicy.customFrameFits(frame, in: .zero))
    }

    func testFrameInsideNonTargetSecondDisplayIsRejectedAgainstTargetDisplay() {
        let frame = CGRect(x: 1728, y: 0, width: 200, height: 100)
        XCTAssertFalse(QuakeTerminalGeometryPolicy.customFrameFits(frame, in: builtInFrame))
    }

    func testChangedFrameReturnsNilForIdenticalFrames() {
        XCTAssertNil(QuakeTerminalGeometryPolicy.changedFrame(from: staleFrame, to: staleFrame))
    }

    func testChangedFrameReturnsMovedFrame() {
        let moved = staleFrame.offsetBy(dx: 10, dy: -5)
        XCTAssertEqual(QuakeTerminalGeometryPolicy.changedFrame(from: staleFrame, to: moved), moved)
    }

    func testChangedFrameReturnsResizedFrame() {
        let resized = CGRect(x: 640, y: 353, width: 1200, height: 700)
        XCTAssertEqual(QuakeTerminalGeometryPolicy.changedFrame(from: staleFrame, to: resized), resized)
    }
}
