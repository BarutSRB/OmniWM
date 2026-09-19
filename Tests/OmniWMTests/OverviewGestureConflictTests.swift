// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class OverviewGestureConflictTests: XCTestCase {
    func testOverlapsMatchEnabledMovementAndFingerCount() {
        for fingers in [3, 4] {
            var config = TrackpadGestureIntent.Config(
                columnScrollEnabled: true,
                columnScrollFingerCount: fingers,
                workspaceSwipeEnabled: false,
                workspaceSwipeFingerCount: fingers,
                workspaceSwipeAxis: .horizontal,
                overviewAction: .open,
                overviewFingerCount: fingers
            )
            XCTAssertNil(TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: nil))
            XCTAssertNil(TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: .horizontal))
            XCTAssertEqual(TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: .vertical), .columnScroll)

            config.workspaceSwipeEnabled = true
            XCTAssertNil(TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: nil))
            XCTAssertEqual(
                TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: .horizontal),
                .workspaceSwitch(axis: .vertical)
            )
            config.columnScrollEnabled = false
            XCTAssertNil(TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: .vertical))
            config.workspaceSwipeAxis = .vertical
            XCTAssertEqual(
                TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: nil),
                .workspaceSwitch(axis: .vertical)
            )
            config.overviewFingerCount = 7 - fingers
            XCTAssertNil(TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: .vertical))
            config.overviewFingerCount = fingers
            config.overviewAction = nil
            XCTAssertNil(TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: .vertical))
        }
    }

    func testSharedFingerAxesStayPerpendicularOnlyInColumnContext() {
        let config = TrackpadGestureIntent.Config(
            columnScrollEnabled: true,
            columnScrollFingerCount: 3,
            workspaceSwipeEnabled: true,
            workspaceSwipeFingerCount: 3,
            workspaceSwipeAxis: .horizontal
        )
        XCTAssertEqual(
            TrackpadGestureIntent.effectiveWorkspaceSwipeAxis(config, columnScrollAxis: .horizontal),
            .vertical
        )
        XCTAssertEqual(
            TrackpadGestureIntent.effectiveWorkspaceSwipeAxis(config, columnScrollAxis: .vertical),
            .horizontal
        )
        XCTAssertEqual(TrackpadGestureIntent.effectiveWorkspaceSwipeAxis(config, columnScrollAxis: nil), .horizontal)
    }
}
