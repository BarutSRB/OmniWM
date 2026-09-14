// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AXFramePublicationTests: XCTestCase {
    func testForcedAttemptClearsConvergedTargetWhilePreservingVerifiedObservedFrame() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 467_509)
        let target = AXFrameApplicationTarget(
            pid: getpid(),
            window: window,
            frame: CGRect(x: 20, y: 30, width: 640, height: 480)
        )
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        for isRetry in [false, true] {
            let request = try XCTUnwrap(ledger.prepareFrameApplication(
                target,
                isRetry: isRetry,
                terminalObserver: nil
            ).request)
            _ = ledger.handleFrameApplyResults([
                WindowAdmissionTestSupport.verificationMismatchFrameResult(request: request, observed: observed)
            ])
        }
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
        XCTAssertNil(ledger.prepareFrameApplication(target, isRetry: false, terminalObserver: nil).request)

        ledger.forceApplyNextFrame(for: window.windowId)
        let forced = try XCTUnwrap(ledger.prepareFrameApplication(
            target,
            isRetry: false,
            terminalObserver: nil
        ).request)

        XCTAssertEqual(forced.currentFrameHint, observed)
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
        XCTAssertEqual(ledger.trustedVerifiedSize(for: window.windowId), observed.size)
        XCTAssertEqual(ledger.pendingFrameWrite(for: window.windowId), target.frame)
        XCTAssertTrue(ledger.cancelFrameJob(windowId: window.windowId).isEmpty)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
        let next = try XCTUnwrap(ledger.prepareFrameApplication(
            target,
            isRetry: false,
            terminalObserver: nil
        ).request)
        XCTAssertGreaterThan(next.requestId, forced.requestId)
        XCTAssertEqual(next.currentFrameHint, observed)
        XCTAssertEqual(ledger.trustedVerifiedSize(for: window.windowId), observed.size)
    }
}
