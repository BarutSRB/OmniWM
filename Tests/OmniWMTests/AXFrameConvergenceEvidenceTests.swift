// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AXFrameConvergenceEvidenceTests: XCTestCase {
    func testBothObservationsMustRespectTheSixteenPointConvergenceBound() throws {
        try assertConvergence(firstWidth: 656, retryWidth: 656, accepted: true)
        try assertConvergence(firstWidth: 656.5, retryWidth: 656, accepted: false)
        try assertConvergence(firstWidth: 656, retryWidth: 656.5, accepted: false)
    }

    private func assertConvergence(firstWidth: CGFloat, retryWidth: CGFloat, accepted: Bool) throws {
        let ledger = AXFrameApplicationLedger()
        let pid = getpid()
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_505)
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let first = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
            ledger, pid: pid, window: window, frame: target
        ))
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: first,
                observed: CGRect(x: 20, y: 30, width: firstWidth, height: 480)
            )
        ])
        XCTAssertEqual(firstOutcome.retries.count, 1)
        let retry = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
            ledger, pid: pid, window: window, frame: target, isRetry: true
        ))
        let observed = CGRect(x: 20, y: 30, width: retryWidth, height: 480)
        var successes: [AXFrameApplyResult] = []

        let outcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: retry, observed: observed)
        ]) { successes.append($0) }

        XCTAssertEqual(outcome.stableSizeClamps.count, 1)
        XCTAssertTrue(outcome.retries.isEmpty)
        XCTAssertEqual(successes.count, accepted ? 1 : 0)
        XCTAssertEqual(outcome.terminalRefusals.count, accepted ? 0 : 1)
        XCTAssertEqual(outcome.terminalFailures.count, accepted ? 0 : 1)
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), accepted ? observed : nil)
        XCTAssertEqual(ledger.hasTerminalRefusal(for: window.windowId), !accepted)
    }
}
