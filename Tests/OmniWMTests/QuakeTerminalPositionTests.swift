// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class QuakeTerminalPositionTests: XCTestCase {
    private let offsetVisibleFrame = CGRect(x: 200, y: 1000, width: 1000, height: 900)
    private let windowSize = CGSize(width: 500, height: 300)
    private let builtInVisibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1084)

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

    func testBuiltInDisplayHalfSizeConfigurationMatchesRegressionFixture() {
        let size = QuakeTerminalGeometryPolicy.configuredFrameSize(
            visibleFrame: builtInVisibleFrame,
            widthPercent: 50,
            heightPercent: 50
        )
        XCTAssertEqual(size, CGSize(width: 864, height: 542))
    }

    func testCenterFinalOriginUsesTargetSizeOnBuiltInDisplay() {
        let targetSize = CGSize(width: 864, height: 542)
        let staleSize = CGSize(width: 1280, height: 705)
        let targetOrigin = QuakeTerminalPosition.center.finalOrigin(
            visibleFrame: builtInVisibleFrame,
            windowSize: targetSize
        )
        let staleOrigin = QuakeTerminalPosition.center.finalOrigin(
            visibleFrame: builtInVisibleFrame,
            windowSize: staleSize
        )
        XCTAssertEqual(targetOrigin.x, 432)
        XCTAssertEqual(staleOrigin.x, 224)
    }
}
