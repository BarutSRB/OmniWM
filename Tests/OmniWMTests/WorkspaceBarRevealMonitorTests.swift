// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarRevealMonitorTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate.rawValue

    func testZeroDelayPressAndRelease() {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 0)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        monitor.handleFlagsChanged(rawFlags: 0)

        XCTAssertEqual(callbacks, [true, false])
    }

    func testRepeatedHeldEventsEmitNothingExtra() {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 0)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        monitor.handleFlagsChanged(rawFlags: option)
        monitor.handleFlagsChanged(rawFlags: option)

        XCTAssertEqual(callbacks, [true])
    }

    func testDelayedPressQuickReleaseNeverReveals() async {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 50)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        monitor.handleFlagsChanged(rawFlags: 0)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(callbacks, [])
    }

    func testDelayedPressAndHoldRevealsAfterDelay() async {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 50)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        XCTAssertEqual(callbacks, [])
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(callbacks, [true])
    }

    func testStopWhileRevealedEmitsFalse() {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 0)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        monitor.stop()

        XCTAssertEqual(callbacks, [true, false])
    }
}
