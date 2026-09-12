// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AXSizeConvergenceReentrancyTests: XCTestCase {
    func testConvergenceCallbackRekeysOnlyTheLaterTerminalDelivery() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_509)
        let target = AXFrameApplicationTarget(
            pid: getpid(),
            window: window,
            frame: CGRect(x: 20, y: 30, width: 640, height: 480)
        )
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        let newWindowId = window.windowId + 1
        var terminalResults: [AXFrameApplyResult] = []
        let retry = try primeRetry(ledger, target: target, observedFrame: observed) { terminalResults.append($0) }
        var acceptedWindowIds: [Int] = []

        let outcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: retry, observed: observed)
        ]) { result in
            acceptedWindowIds.append(result.windowId)
            XCTAssertNil(result.writeResult.failureReason)
            XCTAssertEqual(result.confirmedFrame, observed)
            XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
            XCTAssertEqual(ledger.trustedVerifiedSize(for: window.windowId), observed.size)
            XCTAssertNil(ledger.recentFrameWriteFailure(for: window.windowId))
            XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
            ledger.rekeyWindowState(oldWindowId: window.windowId, newWindowId: newWindowId)
        }

        XCTAssertEqual(acceptedWindowIds, [window.windowId])
        XCTAssertEqual(outcome.stableSizeClamps.map(\.windowId), [window.windowId])
        XCTAssertEqual(outcome.stableSizeClamps.map(\.writeResult.failureReason), [.verificationMismatch])
        XCTAssertEqual(outcome.deliveries.map(\.result.windowId), [newWindowId])
        XCTAssertNil(ledger.lastAppliedFrame(for: window.windowId))
        XCTAssertEqual(ledger.lastAppliedFrame(for: newWindowId), observed)
        XCTAssertTrue(outcome.terminalRefusals.isEmpty)
        XCTAssertTrue(outcome.terminalFailures.isEmpty)
        XCTAssertTrue(terminalResults.isEmpty)
        for delivery in outcome.deliveries { delivery.deliver() }
        XCTAssertEqual(terminalResults.map(\.requestId), [retry.requestId])
        XCTAssertEqual(terminalResults.map(\.windowId), [newWindowId])
        XCTAssertEqual(terminalResults.map(\.confirmedFrame), [observed])
    }

    func testConvergenceCallbackReplacementKeepsItsPendingWriteAndRetryBudget() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_511)
        let target = AXFrameApplicationTarget(
            pid: getpid(),
            window: window,
            frame: CGRect(x: 20, y: 30, width: 640, height: 480)
        )
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        let nextTarget = AXFrameApplicationTarget(
            pid: getpid(),
            window: window,
            frame: target.frame.offsetBy(dx: 80, dy: 0)
        )
        var terminalResults: [AXFrameApplyResult] = []
        let retry = try primeRetry(ledger, target: target, observedFrame: observed) { terminalResults.append($0) }
        var replacement: AXFrameEnqueueDecision?

        let outcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: retry, observed: observed)
        ]) { result in
            XCTAssertNil(result.writeResult.failureReason)
            replacement = prepare(ledger, target: nextTarget) { terminalResults.append($0) }
        }

        let replacementDecision = try XCTUnwrap(replacement)
        let replacementRequest = try XCTUnwrap(replacementDecision.request)
        XCTAssertTrue(outcome.deliveries.isEmpty)
        XCTAssertEqual(outcome.stableSizeClamps.map(\.requestId), [retry.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
        XCTAssertEqual(ledger.pendingFrameWrite(for: window.windowId), nextTarget.frame)
        XCTAssertEqual(replacementDecision.deliveries.count, 1)
        for delivery in replacementDecision.deliveries { delivery.deliver() }
        XCTAssertEqual(terminalResults.map(\.requestId), [retry.requestId])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
        let failedReplacement = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: replacementRequest,
                observed: observed,
                failure: .readbackFailed
            )
        ])
        XCTAssertEqual(failedReplacement.retries.map(\.requestId), [replacementRequest.requestId])
        XCTAssertTrue(failedReplacement.deliveries.isEmpty)
        XCTAssertTrue(failedReplacement.terminalFailures.isEmpty)
    }

    private func primeRetry(
        _ ledger: AXFrameApplicationLedger,
        target: AXFrameApplicationTarget,
        observedFrame: CGRect,
        observer: @escaping AXFrameApplicationTerminalObserver
    ) throws -> AXFrameApplicationRequest {
        let first = try XCTUnwrap(prepare(ledger, target: target, observer: observer).request)
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: first, observed: observedFrame)
        ])
        XCTAssertEqual(firstOutcome.retries.map(\.requestId), [first.requestId])
        XCTAssertTrue(firstOutcome.deliveries.isEmpty)
        return try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
            ledger, pid: target.pid, window: target.expectedWindow, frame: target.frame, isRetry: true
        ))
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
