// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AXFrameVerifiedStateTests: XCTestCase {
    func testAssumedPositionPreservesVerifiedSizeBeforeAcceptedCallback() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_501)
        let priorFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 40, y: 50, width: 500, height: 400)
        let composed = CGRect(x: 40, y: 50, width: 300, height: 200)
        ledger.confirmFrameWrite(for: window.windowId, frame: priorFrame)
        var events: [String] = []
        let request = try XCTUnwrap(ledger.prepareFrameApplication(
            .init(pid: getpid(), window: window, frame: target, components: .position),
            isRetry: false,
            verify: false,
            terminalObserver: { _ in events.append("terminal") }
        ).request)

        let outcome = ledger.handleFrameApplyResults([success(for: request)]) { result in
            XCTAssertEqual(result.targetFrame, target)
            XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), composed)
            XCTAssertEqual(ledger.trustedVerifiedSize(for: window.windowId), priorFrame.size)
            XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
            events.append("accepted")
        }

        XCTAssertEqual(events, ["accepted"])
        XCTAssertEqual(outcome.deliveries.count, 1)
        XCTAssertTrue(outcome.retries.isEmpty)
        XCTAssertTrue(outcome.terminalFailures.isEmpty)
        for delivery in outcome.deliveries { delivery.deliver() }
        XCTAssertEqual(events, ["accepted", "terminal"])
    }

    func testAssumedSizePreservesOriginAndRequiresSizeVerification() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_502)
        let priorFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 40, y: 50, width: 500, height: 400)
        ledger.confirmFrameWrite(for: window.windowId, frame: priorFrame)
        let request = try assumedRequest(ledger, window: window, frame: target, components: .size)

        _ = ledger.handleFrameApplyResults([success(for: request)])

        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), CGRect(x: 10, y: 20, width: 500, height: 400))
        XCTAssertNil(ledger.trustedVerifiedSize(for: window.windowId))
        let verification = ledger.prepareFrameApplication(
            .init(pid: getpid(), window: window, frame: target, components: .size),
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertTrue(try XCTUnwrap(verification.request).verify)
    }

    func testObservedPartialWriteAdoptsTheFullReadbackAsVerified() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_503)
        let priorFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 40, y: 50, width: 500, height: 400)
        let observed = CGRect(x: 40, y: 50, width: 320, height: 240)
        ledger.confirmFrameWrite(for: window.windowId, frame: priorFrame)
        let request = try assumedRequest(ledger, window: window, frame: target, components: .position)
        var accepted: [AXFrameApplyResult] = []

        let outcome = ledger.handleFrameApplyResults([success(for: request, observedFrame: observed)]) {
            accepted.append($0)
        }

        XCTAssertEqual(accepted.map(\.confirmedFrame), [observed])
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
        XCTAssertEqual(ledger.trustedVerifiedSize(for: window.windowId), observed.size)
        XCTAssertTrue(outcome.retries.isEmpty)
        XCTAssertTrue(outcome.terminalFailures.isEmpty)
    }

    func testAssumedWritesWithoutPriorStateDoNotInventVerification() throws {
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_504)
        let target = CGRect(x: 40, y: 50, width: 500, height: 400)
        for components in [AXFrameComponents.position, .size, .all] {
            let ledger = AXFrameApplicationLedger()
            let request = try assumedRequest(ledger, window: window, frame: target, components: components)

            _ = ledger.handleFrameApplyResults([success(for: request)])

            XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), target)
            XCTAssertNil(ledger.trustedVerifiedSize(for: window.windowId))
            XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
        }
    }

    private func assumedRequest(
        _ ledger: AXFrameApplicationLedger,
        window: AXWindowRef,
        frame: CGRect,
        components: AXFrameComponents
    ) throws -> AXFrameApplicationRequest {
        try XCTUnwrap(ledger.prepareFrameApplication(
            .init(pid: getpid(), window: window, frame: frame, components: components),
            isRetry: false,
            verify: false,
            terminalObserver: nil
        ).request)
    }

    private func success(
        for request: AXFrameApplicationRequest,
        observedFrame: CGRect? = nil
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observedFrame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil,
                components: request.components
            ),
            traceRequestId: request.traceRequestId
        )
    }
}
