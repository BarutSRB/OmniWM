// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class MenuBarItemSampleTrackerTests: XCTestCase {
    private let bundleID = "com.example.status"
    private let frames = [CGRect(x: 100, y: 0, width: 24, height: 24)]

    func testStableFramesRequireTheSameProcessAndRepeatedSample() {
        let clock = ContinuousClock()
        var tracker = MenuBarItemSampleTracker(clock: clock, startedAt: clock.now)
        let first = tracker.beginAttempt(for: bundleID)
        XCTAssertTrue(first.isFirst)
        XCTAssertFalse(tracker.recordSample(pid: 41, frames: frames, for: bundleID, attempt: first))

        let second = tracker.beginAttempt(for: bundleID)
        XCTAssertFalse(second.isFirst)
        XCTAssertTrue(tracker.recordSample(pid: 41, frames: frames, for: bundleID, attempt: second))
        XCTAssertFalse(tracker.recordSample(pid: 42, frames: frames, for: bundleID, attempt: second))
        XCTAssertTrue(tracker.recordSample(pid: 42, frames: frames, for: bundleID, attempt: second))
        XCTAssertFalse(tracker.recordSample(
            pid: 42,
            frames: [frames[0].offsetBy(dx: 24, dy: 0)],
            for: bundleID,
            attempt: second
        ))
    }

    func testMissingSampleResetsStabilityWithoutRestartingFirstAttempt() {
        let clock = ContinuousClock()
        var tracker = MenuBarItemSampleTracker(clock: clock, startedAt: clock.now)
        let first = tracker.beginAttempt(for: bundleID)
        XCTAssertFalse(tracker.recordSample(pid: 41, frames: frames, for: bundleID, attempt: first))
        tracker.discardSample(for: bundleID)

        let next = tracker.beginAttempt(for: bundleID)
        XCTAssertFalse(next.isFirst)
        XCTAssertFalse(tracker.recordSample(pid: 41, frames: frames, for: bundleID, attempt: next))
        XCTAssertTrue(tracker.recordSample(pid: 41, frames: frames, for: bundleID, attempt: next))
    }

    func testPendingEmptyGraceExtendsOnlyThroughHardDeadline() {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var tracker = MenuBarItemSampleTracker(clock: clock, startedAt: startedAt)
        let attempt = MenuBarItemSampleTracker.Attempt(
            isFirst: true,
            startedAt: startedAt.advanced(by: .seconds(1))
        )
        XCTAssertFalse(tracker.recordSample(pid: 41, frames: [], for: bundleID, attempt: attempt))

        XCTAssertTrue(tracker.shouldContinue(at: startedAt.advanced(by: .milliseconds(1999))))
        XCTAssertTrue(tracker.shouldContinue(at: startedAt.advanced(by: .seconds(2))))
        XCTAssertTrue(tracker.shouldContinue(at: startedAt.advanced(by: .milliseconds(3999))))
        XCTAssertFalse(tracker.shouldContinue(at: startedAt.advanced(by: .seconds(4))))
    }

    func testExpiredEmptyGraceDoesNotExtendInitialDeadline() {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var tracker = MenuBarItemSampleTracker(clock: clock, startedAt: startedAt)
        let attempt = MenuBarItemSampleTracker.Attempt(isFirst: true, startedAt: startedAt)
        XCTAssertFalse(tracker.recordSample(pid: 41, frames: [], for: bundleID, attempt: attempt))

        XCTAssertFalse(tracker.shouldContinue(at: startedAt.advanced(by: .seconds(2))))
    }

    func testContentAppearingAfterEmptyKeepsExtendedResolution() {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var tracker = MenuBarItemSampleTracker(clock: clock, startedAt: startedAt)
        let attempt = MenuBarItemSampleTracker.Attempt(isFirst: true, startedAt: startedAt)
        XCTAssertFalse(tracker.recordSample(pid: 41, frames: [], for: bundleID, attempt: attempt))
        XCTAssertFalse(tracker.recordSample(pid: 42, frames: frames, for: bundleID, attempt: attempt))

        XCTAssertTrue(tracker.shouldContinue(at: startedAt.advanced(by: .seconds(3))))
        XCTAssertFalse(tracker.shouldContinue(at: startedAt.advanced(by: .seconds(4))))
    }
}
