// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class AXPendingFrameCoalescenceTests: XCTestCase {
    func testLateObserverCreatesRequestThenMatchingObserverSharesItsSettlement() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 764_904
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 764_905)
        let target = AXFrameApplicationTarget(
            pid: pid,
            window: window,
            frame: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
        let first = ledger.prepareFrameApplication(target, isRetry: false, terminalObserver: nil)
        let firstRequest = try XCTUnwrap(first.request)
        var delivered: [(String, AXFrameApplyResult)] = []
        let observed = ledger.prepareFrameApplication(target, isRetry: false) {
            delivered.append(("first", $0))
        }
        let observedRequest = try XCTUnwrap(observed.request)
        XCTAssertNotEqual(observedRequest.requestId, firstRequest.requestId)
        XCTAssertTrue(observed.deliveries.isEmpty)
        let coalesced = ledger.prepareFrameApplication(target, isRetry: false) {
            delivered.append(("second", $0))
        }
        XCTAssertNil(coalesced.request)
        XCTAssertFalse(coalesced.shouldCancelPendingRetry)
        XCTAssertTrue(coalesced.deliveries.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
        let cancelled = ledger.cancelFrameJob(windowId: window.windowId)
        XCTAssertEqual(cancelled.count, 1)
        for delivery in cancelled {
            delivery.deliver()
        }
        XCTAssertEqual(delivered.map(\.0), ["first", "second"])
        XCTAssertEqual(delivered.map(\.1.requestId), [observedRequest.requestId, observedRequest.requestId])
        XCTAssertEqual(delivered.map(\.1.targetFrame), [target.frame, target.frame])
        XCTAssertEqual(delivered.map(\.1.writeResult.failureReason), [.cancelled, .cancelled])
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
    }
}
