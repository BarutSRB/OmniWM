// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class AXFrameObserverRegistrationTests: XCTestCase {
    func testReplacementRetainsObserverHintAndDeliveryOrderAfterCacheChanges() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 764_902
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 764_903)
        let originalHint = CGRect(x: 10, y: 20, width: 300, height: 200)
        let updatedHint = originalHint.offsetBy(dx: 30, dy: 10)
        let target = AXFrameApplicationTarget(
            pid: pid,
            window: window,
            frame: originalHint.offsetBy(dx: 300, dy: 0)
        )
        var deliveries: [(String, AXFrameApplyResult)] = []
        ledger.confirmFrameWrite(for: window.windowId, frame: originalHint)
        let first = ledger.prepareFrameApplication(target, isRetry: false) {
            deliveries.append(("first", $0))
        }
        let firstRequest = try XCTUnwrap(first.request)
        XCTAssertEqual(firstRequest.currentFrameHint, originalHint)
        ledger.confirmFrameWrite(for: window.windowId, frame: updatedHint)
        ledger.forceApplyNextFrame(for: window.windowId)
        let replacement = ledger.prepareFrameApplication(target, isRetry: false) {
            deliveries.append(("replacement", $0))
        }
        let replacementRequest = try XCTUnwrap(replacement.request)
        XCTAssertNotEqual(replacementRequest.requestId, firstRequest.requestId)
        XCTAssertEqual(replacementRequest.currentFrameHint, updatedHint)
        XCTAssertTrue(replacement.deliveries.isEmpty)
        XCTAssertTrue(deliveries.isEmpty)
        let cancelled = ledger.cancelFrameJob(windowId: window.windowId)
        XCTAssertEqual(cancelled.count, 1)
        for delivery in cancelled {
            delivery.deliver()
        }
        XCTAssertEqual(deliveries.map(\.0), ["first", "replacement"])
        XCTAssertEqual(deliveries.map(\.1.requestId), [replacementRequest.requestId, replacementRequest.requestId])
        XCTAssertEqual(deliveries.map(\.1.currentFrameHint), [originalHint, originalHint])
        XCTAssertEqual(deliveries.map(\.1.writeResult.failureReason), [.cancelled, .cancelled])
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
    }
}
