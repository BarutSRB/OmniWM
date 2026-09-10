// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class TrackpadGestureIntentTests: XCTestCase {
    private func makeConfig(
        columnEnabled: Bool = true,
        columnFingers: Int = 3,
        workspaceEnabled: Bool = true,
        workspaceFingers: Int = 3,
        workspaceAxis: WorkspaceSwipeAxis = .vertical
    ) -> TrackpadGestureIntent.Config {
        TrackpadGestureIntent.Config(
            columnScrollEnabled: columnEnabled,
            columnScrollFingerCount: columnFingers,
            workspaceSwipeEnabled: workspaceEnabled,
            workspaceSwipeFingerCount: workspaceFingers,
            workspaceSwipeAxis: workspaceAxis
        )
    }

    func testGestureStartAllowedForEitherEnabledFingerCount() {
        let config = makeConfig(columnFingers: 3, workspaceFingers: 4)
        XCTAssertTrue(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 3))
        XCTAssertTrue(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 4))
        XCTAssertFalse(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 2))
    }

    func testGestureStartRejectedWhenBothGesturesDisabled() {
        let config = makeConfig(columnEnabled: false, workspaceEnabled: false)
        XCTAssertFalse(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 3))
    }

    func testGestureStartRespectsPerGestureEnablement() {
        let config = makeConfig(columnEnabled: false, columnFingers: 3, workspaceEnabled: true, workspaceFingers: 4)
        XCTAssertFalse(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 3))
        XCTAssertTrue(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 4))
    }

    func testCandidateModeRejectsColumnOnlyCountOverDwindleContext() {
        let config = makeConfig(workspaceEnabled: false)
        XCTAssertFalse(TrackpadGestureIntent.hasCandidateMode(config, fingerCount: 3, columnContextAvailable: false))
        XCTAssertTrue(TrackpadGestureIntent.hasCandidateMode(config, fingerCount: 3, columnContextAvailable: true))
    }

    func testCandidateModeAcceptsWorkspaceCountWithoutColumnContext() {
        let config = makeConfig(columnEnabled: false)
        XCTAssertTrue(TrackpadGestureIntent.hasCandidateMode(config, fingerCount: 3, columnContextAvailable: false))
    }

    func testResolveModePrefersColumnScrollForSharedCountHorizontalSwipe() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .columnScroll)
    }

    func testResolveModeResolvesWorkspaceSwitchForSharedCountVerticalSwipe() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 10, dy: 50),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeForcesVerticalForSharedCountEvenWithHorizontalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceAxis: .horizontal),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 10, dy: 50),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeReturnsNilForColumnCountVerticalSwipeWithDistinctCounts() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 10, dy: 50),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModeReturnsNilForWorkspaceCountOffAxisSwipe() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4, workspaceAxis: .vertical),
            fingerCount: 4,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModeResolvesWorkspaceSwitchWithoutColumnContext() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 10, dy: 50),
            columnScrollAxis: .horizontal,
            columnContextAvailable: false
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeReturnsNilForColumnSwipeWithoutColumnContext() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceEnabled: false),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .horizontal,
            columnContextAvailable: false
        )
        XCTAssertNil(mode)
    }

    func testResolveModeHonorsHorizontalAxisWhenCountsDiffer() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4, workspaceAxis: .horizontal),
            fingerCount: 4,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .horizontal))
    }

    func testAxisTieResolvesAsVertical() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 30, dy: 30),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeReturnsNilWithNoCandidates() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(columnEnabled: false, workspaceEnabled: false),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModePrefersColumnScrollForSharedCountVerticalSwipeOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 10, dy: 50),
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .columnScroll)
    }

    func testResolveModeResolvesHorizontalWorkspaceSwitchForSharedCountOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .horizontal))
    }

    func testResolveModeReturnsNilForColumnCountHorizontalSwipeWithDistinctCountsOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4),
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModeHonorsConfiguredWorkspaceAxisWithDistinctCountsOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4, workspaceAxis: .horizontal),
            fingerCount: 4,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .horizontal))
    }

    func testNaturalHorizontalSwipeLeftIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: -1, naturalDirection: true),
            true
        )
    }

    func testNaturalHorizontalSwipeRightIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: 1, naturalDirection: true),
            false
        )
    }

    func testInvertedHorizontalSwipeRightIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: 1, naturalDirection: false),
            true
        )
    }

    func testInvertedHorizontalSwipeLeftIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: -1, naturalDirection: false),
            false
        )
    }

    func testNaturalVerticalSwipeUpIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: 1, naturalDirection: true),
            true
        )
    }

    func testNaturalVerticalSwipeDownIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: -1, naturalDirection: true),
            false
        )
    }

    func testInvertedVerticalSwipeDownIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: -1, naturalDirection: false),
            true
        )
    }

    func testInvertedVerticalSwipeUpIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: 1, naturalDirection: false),
            false
        )
    }

    func testZeroDisplacementYieldsNoDirection() {
        XCTAssertNil(TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: 0, naturalDirection: true))
    }

    func testReleaseFlickFiresWhenVelocityExceedsFloor() {
        XCTAssertEqual(
            TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 60, velocity: 900),
            CGFloat(900)
        )
    }

    func testReleaseFlickRejectedBelowVelocityFloor() {
        XCTAssertNil(TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 60, velocity: 700))
    }

    func testReleaseFlickRejectedWhenVelocityOpposesCumulativeTravel() {
        XCTAssertNil(TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 60, velocity: -900))
    }

    func testReleaseFlickAllowedWithZeroCumulativeTravel() {
        XCTAssertEqual(
            TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 0, velocity: -900),
            CGFloat(-900)
        )
    }

    func testWindowGestureModeClaimsFingerCountAndMoveWinsOverResize() {
        var config = makeConfig(columnEnabled: false, workspaceEnabled: false)
        config.windowMoveEnabled = true
        config.windowMoveFingerCount = 4
        config.windowResizeEnabled = true
        config.windowResizeFingerCount = 3
        XCTAssertEqual(TrackpadGestureIntent.windowGestureMode(config, fingerCount: 4), .windowMove)
        XCTAssertEqual(TrackpadGestureIntent.windowGestureMode(config, fingerCount: 3), .windowResize)
        XCTAssertNil(TrackpadGestureIntent.windowGestureMode(config, fingerCount: 2))

        config.windowResizeFingerCount = 4
        XCTAssertEqual(TrackpadGestureIntent.windowGestureMode(config, fingerCount: 4), .windowMove)
        XCTAssertNil(TrackpadGestureIntent.windowGestureMode(config, fingerCount: 3))
    }

    func testDisabledWindowGesturesNeverClaimTheirFingerCount() {
        var config = makeConfig(columnEnabled: false, workspaceEnabled: false)
        config.windowMoveFingerCount = 4
        config.windowResizeFingerCount = 3
        XCTAssertNil(TrackpadGestureIntent.windowGestureMode(config, fingerCount: 4))
        XCTAssertNil(TrackpadGestureIntent.windowGestureMode(config, fingerCount: 3))
        XCTAssertFalse(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 4))
    }

    func testWindowGestureAllowsStartAndRequiresWindowContext() {
        var config = makeConfig(columnEnabled: false, workspaceEnabled: false)
        config.windowMoveEnabled = true
        config.windowMoveFingerCount = 4
        XCTAssertTrue(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 4))
        XCTAssertFalse(
            TrackpadGestureIntent.hasCandidateMode(
                config,
                fingerCount: 4,
                columnContextAvailable: true,
                windowContextAvailable: false
            )
        )
        XCTAssertTrue(
            TrackpadGestureIntent.hasCandidateMode(
                config,
                fingerCount: 4,
                columnContextAvailable: false,
                windowContextAvailable: true
            )
        )
    }

    func testWindowGestureTakesPrecedenceOverColumnScrollAndWorkspaceSwipeForSharedCount() {
        var config = makeConfig(columnFingers: 3, workspaceFingers: 3)
        config.windowResizeEnabled = true
        config.windowResizeFingerCount = 3

        let horizontal = TrackpadGestureIntent.resolveMode(
            config,
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true,
            windowContextAvailable: true
        )
        XCTAssertEqual(horizontal, .windowResize)

        let vertical = TrackpadGestureIntent.resolveMode(
            config,
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 10, dy: 50),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true,
            windowContextAvailable: true
        )
        XCTAssertEqual(vertical, .windowResize)

        XCTAssertFalse(
            TrackpadGestureIntent.hasCandidateMode(config, fingerCount: 3, columnContextAvailable: true),
            "A claimed finger count is not a column scroll candidate without a window under the cursor"
        )
        XCTAssertTrue(
            TrackpadGestureIntent.hasCandidateMode(
                config,
                fingerCount: 3,
                columnContextAvailable: true,
                windowContextAvailable: true
            )
        )
        XCTAssertNil(
            TrackpadGestureIntent.resolveMode(
                config,
                fingerCount: 3,
                cumulativeTranslation: CGVector(dx: 50, dy: 10),
                columnScrollAxis: .horizontal,
                columnContextAvailable: true,
                windowContextAvailable: false
            ),
            "A claimed finger count must not fall back to column scroll when no window is under the cursor"
        )
    }

    func testWindowGestureLeavesOtherFingerCountsToExistingGestures() {
        var config = makeConfig(columnFingers: 3, workspaceFingers: 3)
        config.windowMoveEnabled = true
        config.windowMoveFingerCount = 4
        let mode = TrackpadGestureIntent.resolveMode(
            config,
            fingerCount: 3,
            cumulativeTranslation: CGVector(dx: 50, dy: 10),
            columnScrollAxis: .horizontal,
            columnContextAvailable: true,
            windowContextAvailable: true
        )
        XCTAssertEqual(mode, .columnScroll)
    }

    func testWindowGestureLocationScalesTrackpadTravelToMonitorAndClamps() {
        let monitor = CGRect(x: 100, y: 200, width: 1600, height: 900)
        let start = CGPoint(x: 500, y: 650)

        let moved = TrackpadGestureIntent.windowGestureLocation(
            start: start,
            startTouch: CGPoint(x: 0.2, y: 0.5),
            currentTouch: CGPoint(x: 0.45, y: 0.4),
            monitorFrame: monitor,
            sensitivity: 1
        )
        XCTAssertEqual(moved.x, 900, accuracy: 0.001)
        XCTAssertEqual(moved.y, 560, accuracy: 0.001)

        let scaled = TrackpadGestureIntent.windowGestureLocation(
            start: start,
            startTouch: CGPoint(x: 0.2, y: 0.5),
            currentTouch: CGPoint(x: 0.3, y: 0.5),
            monitorFrame: monitor,
            sensitivity: 2
        )
        XCTAssertEqual(scaled.x, 820, accuracy: 0.001)

        let clamped = TrackpadGestureIntent.windowGestureLocation(
            start: start,
            startTouch: CGPoint(x: 0.9, y: 0.9),
            currentTouch: CGPoint(x: 0.0, y: 0.0),
            monitorFrame: monitor,
            sensitivity: 3
        )
        XCTAssertEqual(clamped, CGPoint(x: monitor.minX, y: monitor.minY))
    }

    func testWindowModesReportAsWindowInteractions() {
        XCTAssertTrue(TrackpadGestureMode.windowMove.isWindowInteraction)
        XCTAssertTrue(TrackpadGestureMode.windowResize.isWindowInteraction)
        XCTAssertFalse(TrackpadGestureMode.columnScroll.isWindowInteraction)
        XCTAssertFalse(TrackpadGestureMode.workspaceSwitch(axis: .vertical).isWindowInteraction)
    }
}
