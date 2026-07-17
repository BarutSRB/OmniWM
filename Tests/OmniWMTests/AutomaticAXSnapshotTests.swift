// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

final class AutomaticAXSnapshotTests: XCTestCase {
    private enum TimeoutProbeError: Error {
        case expected
    }

    func testExactWindowSelectionPrecedesFocusedFallback() {
        let focused = AXUIElementCreateApplication(91_010)
        let other = AXUIElementCreateApplication(91_011)
        let target = AXUIElementCreateApplication(91_012)

        let selected = AutomaticAXSnapshotCollector.selectWindowElement(
            windowId: 22,
            focusedWindow: focused,
            windows: [other, target]
        ) { element in
            CFEqual(element, target) ? 22 : 11
        }

        XCTAssertNotNil(selected)
        XCTAssertTrue(selected.map { CFEqual($0, target) } == true)
    }

    func testFocusedWindowIsUsedWithoutExactWindowIdentity() {
        let focused = AXUIElementCreateApplication(91_020)
        var resolvedWindowId = false

        let selected = AutomaticAXSnapshotCollector.selectWindowElement(
            windowId: nil,
            focusedWindow: focused,
            windows: [AXUIElementCreateApplication(91_021)]
        ) { _ in
            resolvedWindowId = true
            return nil
        }

        XCTAssertNotNil(selected)
        XCTAssertTrue(selected.map { CFEqual($0, focused) } == true)
        XCTAssertFalse(resolvedWindowId)
    }

    func testFocusedWindowIsUsedWhenExactWindowIdentityIsUnavailable() {
        let focused = AXUIElementCreateApplication(91_022)
        let other = AXUIElementCreateApplication(91_023)

        let selected = AutomaticAXSnapshotCollector.selectWindowElement(
            windowId: 22,
            focusedWindow: focused,
            windows: [other]
        ) { _ in 11 }

        XCTAssertNotNil(selected)
        XCTAssertTrue(selected.map { CFEqual($0, focused) } == true)
    }

    func testMessagingTimeoutIsRestoredWhenSnapshotReadThrows() {
        let element = AXUIElementCreateApplication(91_030)
        var timeouts: [Float] = []

        XCTAssertThrowsError(
            try AutomaticAXSnapshotCollector.withMessagingTimeout(
                element,
                setter: { _, timeout in timeouts.append(timeout) }
            ) {
                throw TimeoutProbeError.expected
            }
        )
        XCTAssertEqual(timeouts, [0.5, 0])
    }

    func testRequestReasonIsUTF8ByteBounded() {
        let request = AutomaticAXSnapshotRequest(
            reason: String(repeating: "🪟", count: 4_096),
            pid: 91_031,
            windowId: nil
        )

        XCTAssertLessThanOrEqual(request.reason.utf8.count, RuntimeTraceLimits.diagnosticStringBytes)
        XCTAssertNotNil(String(data: Data(request.reason.utf8), encoding: .utf8))
    }

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
            windowId: 91_002
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
            windowId: Int.max
        )

        let snapshot = await collector.capture(request)
        let encoded = collector.encoded(snapshot)
        let decoded = try JSONDecoder().decode(AutomaticAXSnapshot.self, from: Data(encoded.utf8))

        XCTAssertNotEqual(decoded.status, "captured")
        XCTAssertEqual(decoded.pid, Int32.max)
        XCTAssertEqual(decoded.windowId, Int.max)
    }
}
