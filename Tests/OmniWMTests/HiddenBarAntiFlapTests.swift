// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarAntiFlapTests: XCTestCase {
    private func decide(
        desiredAllowed: Set<String> = ["a"],
        desiredConcealed: Set<String> = ["b"],
        current: HiddenBarAppliedConfig?,
        previousConfig: HiddenBarAppliedConfig? = nil,
        now: ContinuousClock.Instant
    ) -> Bool {
        HiddenBarAntiFlap.shouldReactivate(
            desired: HiddenBarDesiredConfig(allowed: desiredAllowed, concealed: desiredConcealed),
            current: current,
            previousConfig: previousConfig,
            now: now
        )
    }

    func testHandleNilAlwaysReactivates() {
        let now = ContinuousClock.now
        XCTAssertTrue(decide(current: nil, now: now))
    }

    func testNoChangeDoesNotReactivate() {
        let now = ContinuousClock.now
        let current = HiddenBarAppliedConfig(allowed: ["a"], concealed: ["b"], at: now)
        XCTAssertFalse(decide(desiredAllowed: ["a"], desiredConcealed: ["b"], current: current, now: now))
    }

    func testConcealedChangedReactivates() {
        let now = ContinuousClock.now
        let current = HiddenBarAppliedConfig(allowed: ["a"], concealed: ["z"], at: now)
        XCTAssertTrue(decide(desiredAllowed: ["a"], desiredConcealed: ["b"], current: current, now: now))
    }

    func testNewlyAppearedReactivates() {
        let now = ContinuousClock.now
        let current = HiddenBarAppliedConfig(allowed: ["a"], concealed: ["b"], at: now)
        XCTAssertTrue(decide(desiredAllowed: ["a", "c"], desiredConcealed: ["b"], current: current, now: now))
    }

    func testFlapBackWithinWindowSuppressed() {
        let now = ContinuousClock.now
        let current = HiddenBarAppliedConfig(allowed: ["a"], concealed: ["z"], at: now)
        let previous = HiddenBarAppliedConfig(allowed: ["a"], concealed: ["b"], at: now)
        XCTAssertFalse(decide(
            desiredAllowed: ["a"],
            desiredConcealed: ["b"],
            current: current,
            previousConfig: previous,
            now: now.advanced(by: .seconds(1))
        ))
    }

    func testFlapBackOutsideWindowReactivates() {
        let now = ContinuousClock.now
        let current = HiddenBarAppliedConfig(allowed: ["a"], concealed: ["z"], at: now)
        let previous = HiddenBarAppliedConfig(allowed: ["a"], concealed: ["b"], at: now)
        XCTAssertTrue(decide(
            desiredAllowed: ["a"],
            desiredConcealed: ["b"],
            current: current,
            previousConfig: previous,
            now: now.advanced(by: .seconds(4))
        ))
    }
}
