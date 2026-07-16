// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AutomaticAXSnapshotTests: XCTestCase {
    func testOverallTimeoutProducesEncodableSnapshot() async throws {
        let collector = AutomaticAXSnapshotCollector(overallTimeoutSeconds: 0.01) { request in
            Thread.sleep(forTimeInterval: 0.1)
            return AutomaticAXSnapshot(
                generatedAt: Date().ISO8601Format(),
                reason: request.reason,
                pid: request.pid,
                windowId: request.windowId,
                status: "late",
                app: nil,
                window: nil
            )
        }
        let request = AutomaticAXSnapshotRequest(
            reason: "timeout_test",
            pid: 91_001,
            windowId: 91_002,
            axRef: nil
        )

        let snapshot = await collector.capture(request)
        let encoded = collector.encoded(snapshot)
        let decoded = try JSONDecoder().decode(AutomaticAXSnapshot.self, from: Data(encoded.utf8))

        XCTAssertEqual(decoded.status, "timed_out")
        XCTAssertEqual(decoded.reason, "timeout_test")
        XCTAssertEqual(decoded.windowId, 91_002)
    }

    func testUnavailableTargetStillProducesStructuredEvidence() async throws {
        let collector = AutomaticAXSnapshotCollector(overallTimeoutSeconds: 1)
        let request = AutomaticAXSnapshotRequest(
            reason: "missing_target",
            pid: Int32.max,
            windowId: Int.max,
            axRef: nil
        )

        let snapshot = await collector.capture(request)
        let encoded = collector.encoded(snapshot)
        let decoded = try JSONDecoder().decode(AutomaticAXSnapshot.self, from: Data(encoded.utf8))

        XCTAssertNotEqual(decoded.status, "captured")
        XCTAssertEqual(decoded.pid, Int32.max)
        XCTAssertEqual(decoded.windowId, Int.max)
    }
}
