// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class DiagnosticsAlwaysOnRecorderTests: XCTestCase {
    func testInteractionMonitorWriteRecorderFormatsAndResets() {
        let recorder = InteractionMonitorWriteRecorder.shared
        recorder.reset()
        XCTAssertEqual(recorder.dump(), "none")

        recorder.record(
            field: .interaction,
            oldValue: nil,
            newValue: Monitor.ID(displayId: 2),
            reason: "focusChanged"
        )
        recorder.record(
            field: .previous,
            oldValue: Monitor.ID(displayId: 2),
            newValue: Monitor.ID(displayId: 3),
            reason: "topologyChanged"
        )

        let dump = recorder.dump()
        XCTAssertTrue(dump.contains("interaction nil->2 reason=focusChanged"))
        XCTAssertTrue(dump.contains("previous 2->3 reason=topologyChanged"))

        recorder.reset()
        XCTAssertEqual(recorder.dump(), "none")
    }

    func testRawAXAlwaysOnRetainsRecentWhileCaptureWindowIsScoped() {
        let recorder = RawAXNotificationTrace.shared

        recorder.record(name: "ax.recent", pid: 1, windowId: nil)
        XCTAssertTrue(recorder.recentDump().contains("ax.recent"))

        recorder.beginCapture()
        recorder.record(name: "ax.during", pid: 7, windowId: 42)
        recorder.endCapture()
        recorder.record(name: "ax.after", pid: 1, windowId: nil)

        let captured = recorder.dump()
        XCTAssertTrue(captured.contains("ax.during"))
        XCTAssertFalse(captured.contains("ax.after"))
        XCTAssertFalse(captured.contains("ax.recent"))
        XCTAssertTrue(recorder.recentDump().contains("ax.after"))
    }
}
