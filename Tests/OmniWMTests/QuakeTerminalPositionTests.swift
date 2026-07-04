// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class QuakeTerminalPositionTests: XCTestCase {
    private let offsetVisibleFrame = CGRect(x: 200, y: 1000, width: 1000, height: 900)
    private let windowSize = CGSize(width: 500, height: 300)

    func testBottomInitialOriginStartsBelowVisibleFrameOnOffsetMonitor() {
        let initial = QuakeTerminalPosition.bottom.initialOrigin(
            visibleFrame: offsetVisibleFrame,
            windowSize: windowSize
        )
        XCTAssertEqual(initial.y, offsetVisibleFrame.minY - windowSize.height)
    }

    func testCenterInitialOriginEqualsFinalOnOffsetMonitor() {
        let initial = QuakeTerminalPosition.center.initialOrigin(
            visibleFrame: offsetVisibleFrame,
            windowSize: windowSize
        )
        let final = QuakeTerminalPosition.center.finalOrigin(
            visibleFrame: offsetVisibleFrame,
            windowSize: windowSize
        )
        XCTAssertEqual(initial, final)
    }

    func testTopOriginsIncludeVisibleFrameOriginY() {
        let initial = QuakeTerminalPosition.top.initialOrigin(
            visibleFrame: offsetVisibleFrame,
            windowSize: windowSize
        )
        let final = QuakeTerminalPosition.top.finalOrigin(
            visibleFrame: offsetVisibleFrame,
            windowSize: windowSize
        )
        XCTAssertEqual(initial.y, offsetVisibleFrame.maxY)
        XCTAssertEqual(final.y, offsetVisibleFrame.maxY - windowSize.height)
    }

    func testSideOriginsAreVerticallyCenteredOnOffsetMonitor() {
        let expectedY = (
            offsetVisibleFrame.origin.y + (offsetVisibleFrame.height - windowSize.height) / 2
        ).rounded()
        for position in [QuakeTerminalPosition.left, .right] {
            XCTAssertEqual(
                position.initialOrigin(visibleFrame: offsetVisibleFrame, windowSize: windowSize).y,
                expectedY
            )
            XCTAssertEqual(
                position.finalOrigin(visibleFrame: offsetVisibleFrame, windowSize: windowSize).y,
                expectedY
            )
        }
    }
}
