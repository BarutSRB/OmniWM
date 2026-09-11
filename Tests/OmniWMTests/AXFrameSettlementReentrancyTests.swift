// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AXFrameSettlementReentrancyTests: XCTestCase {
    func testAcceptedCallbackRekeyPrecedesTerminalObserverSettlement() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_506)
        let target = AXFrameApplicationTarget(
            pid: getpid(),
            window: window,
            frame: CGRect(x: 20, y: 30, width: 640, height: 480)
        )
        let newWindowId = window.windowId + 1
        var terminalResults: [AXFrameApplyResult] = []
        let request = try XCTUnwrap(prepare(ledger, target: target) { terminalResults.append($0) }.request)
        var acceptedWindowIds: [Int] = []

        let outcome = ledger
            .handleFrameApplyResults([WindowAdmissionTestSupport.successfulFrameResult(request: request)]) {
                acceptedWindowIds.append($0.windowId)
                XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), target.frame)
                XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
                ledger.rekeyWindowState(oldWindowId: window.windowId, newWindowId: newWindowId)
            }

        XCTAssertEqual(acceptedWindowIds, [window.windowId])
        XCTAssertNil(ledger.lastAppliedFrame(for: window.windowId))
        XCTAssertEqual(ledger.lastAppliedFrame(for: newWindowId), target.frame)
        XCTAssertEqual(outcome.deliveries.map(\.result.windowId), [newWindowId])
        XCTAssertTrue(terminalResults.isEmpty)
        for delivery in outcome.deliveries { delivery.deliver() }
        XCTAssertEqual(terminalResults.map(\.requestId), [request.requestId])
        XCTAssertEqual(terminalResults.map(\.windowId), [newWindowId])
        XCTAssertTrue(sameAXWindowIdentity(
            try XCTUnwrap(terminalResults.first).expectedWindow,
            AXWindowRef(element: window.element, windowId: newWindowId)
        ))
    }

    func testAcceptedCallbackReplacementKeepsItsPendingWriteAndRetryBudget() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_508)
        let target = AXFrameApplicationTarget(
            pid: getpid(),
            window: window,
            frame: CGRect(x: 20, y: 30, width: 640, height: 480)
        )
        let nextTarget = AXFrameApplicationTarget(
            pid: getpid(),
            window: window,
            frame: target.frame.offsetBy(dx: 80, dy: 0)
        )
        var terminalResults: [AXFrameApplyResult] = []
        let first = try XCTUnwrap(prepare(ledger, target: target) { terminalResults.append($0) }.request)
        var replacement: AXFrameEnqueueDecision?

        let outcome = ledger
            .handleFrameApplyResults([WindowAdmissionTestSupport.successfulFrameResult(request: first)]) { _ in
                replacement = prepare(ledger, target: nextTarget) { terminalResults.append($0) }
            }

        let replacementDecision = try XCTUnwrap(replacement)
        let replacementRequest = try XCTUnwrap(replacementDecision.request)
        XCTAssertTrue(outcome.deliveries.isEmpty)
        XCTAssertEqual(ledger.pendingFrameWrite(for: window.windowId), nextTarget.frame)
        XCTAssertEqual(replacementDecision.deliveries.count, 1)
        for delivery in replacementDecision.deliveries { delivery.deliver() }
        XCTAssertEqual(terminalResults.map(\.requestId), [first.requestId])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
        let failedReplacement = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: replacementRequest,
                observed: target.frame,
                failure: .readbackFailed
            )
        ])
        XCTAssertEqual(failedReplacement.retries.map(\.requestId), [replacementRequest.requestId])
        XCTAssertTrue(failedReplacement.deliveries.isEmpty)
        XCTAssertTrue(failedReplacement.terminalFailures.isEmpty)
    }

    private func prepare(
        _ ledger: AXFrameApplicationLedger,
        target: AXFrameApplicationTarget,
        observer: @escaping AXFrameApplicationTerminalObserver
    ) -> AXFrameEnqueueDecision {
        ledger.prepareFrameApplication(
            target,
            isRetry: false,
            terminalObserver: observer
        )
    }
}
