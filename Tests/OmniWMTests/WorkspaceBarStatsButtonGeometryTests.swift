// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class WorkspaceBarStatsButtonGeometryTests: XCTestCase {
    func testStatsButtonAnchorUsesBottomCenterOfInlineButton() {
        let buttonFrame = CGRect(x: 628, y: 950, width: 22, height: 20)

        let anchor = WorkspaceBarGeometry.statsButtonAnchor(buttonFrame: buttonFrame)

        XCTAssertEqual(anchor, CGPoint(x: 639, y: 950))
    }

    func testStatsButtonAnchorTracksMovedInlineButton() {
        let first = WorkspaceBarGeometry.statsButtonAnchor(
            buttonFrame: CGRect(x: 628, y: 950, width: 22, height: 20)
        )
        let moved = WorkspaceBarGeometry.statsButtonAnchor(
            buttonFrame: CGRect(x: 700, y: 926, width: 22, height: 20)
        )

        XCTAssertEqual(moved.x - first.x, 72)
        XCTAssertEqual(moved.y, 926)
    }
}
