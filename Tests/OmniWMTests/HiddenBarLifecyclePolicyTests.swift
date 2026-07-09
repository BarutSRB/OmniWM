// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarLifecyclePolicyTests: XCTestCase {
    func testRefreshRequiresEnabledAvailableAndConfiguredHiddenApp() {
        XCTAssertFalse(HiddenBarController.wantsRefresh(
            enabled: false,
            available: true,
            hiddenBundleIDs: ["a"]
        ))
        XCTAssertFalse(HiddenBarController.wantsRefresh(
            enabled: true,
            available: false,
            hiddenBundleIDs: ["a"]
        ))
        XCTAssertFalse(HiddenBarController.wantsRefresh(
            enabled: true,
            available: true,
            hiddenBundleIDs: []
        ))
        XCTAssertTrue(HiddenBarController.wantsRefresh(
            enabled: true,
            available: true,
            hiddenBundleIDs: ["a"]
        ))
    }

    func testTemporaryRevealAndPendingCaptureStayAllowed() {
        XCTAssertEqual(
            HiddenBarController.effectiveHiddenBundleIDs(
                configured: ["revealed", "capturing", "concealed"],
                temporarilyRevealed: ["revealed"],
                pendingCapture: ["capturing"]
            ),
            ["concealed"]
        )
    }

    func testLaunchCaptureStaysAllowedDuringAnotherAppsReveal() {
        let effectiveHidden = HiddenBarController.effectiveHiddenBundleIDs(
            configured: ["revealed", "newly-launched", "concealed"],
            temporarilyRevealed: ["revealed"],
            pendingCapture: ["newly-launched"]
        )
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: effectiveHidden,
            runningBundleIDs: ["revealed", "concealed", "newly-launched"],
            protectedBundleIDs: []
        )
        XCTAssertTrue(result.allowed.contains("revealed"))
        XCTAssertTrue(result.allowed.contains("newly-launched"))
        XCTAssertEqual(result.concealed, ["concealed"])
    }

    func testOpenMenuDoesNotConsumeRehideTime() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: false,
                menuOpen: true
            ),
            .seconds(5)
        )
    }

    func testUnknownMenuStateDoesNotConsumeRehideTime() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: false,
                menuOpen: nil
            ),
            .seconds(5)
        )
    }

    func testClosedIntervalsAccumulateUntilRehideExpires() {
        var remaining = Duration.seconds(5)
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(2),
            previousMenuOpen: false,
            menuOpen: false
        )
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(4),
            previousMenuOpen: false,
            menuOpen: true
        )
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(3),
            previousMenuOpen: true,
            menuOpen: false
        )
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(3),
            previousMenuOpen: false,
            menuOpen: false
        )
        XCTAssertEqual(remaining, .zero)
    }

    func testNegativeElapsedTimeDoesNotIncreaseCountdown() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(-2),
                previousMenuOpen: false,
                menuOpen: false
            ),
            .seconds(5)
        )
    }

    func testFirstClosedSampleStartsCountdownWithFullInterval() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: nil,
                menuOpen: false
            ),
            .seconds(5)
        )
    }

    func testFailedRevealDoesNotStartCountdownDuringPriorActivation() {
        XCTAssertFalse(HiddenBarController.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: true,
            activationInFlight: true
        ))
        XCTAssertTrue(HiddenBarController.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: true,
            activationInFlight: false
        ))
        XCTAssertFalse(HiddenBarController.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: false,
            activationInFlight: false
        ))
    }

    func testActivationContextRequiresConfigurationRevealAndExactPID() {
        let candidates = [
            MenuBarAppCandidate(bundleID: "target", pid: 42, name: "Target"),
            MenuBarAppCandidate(bundleID: "target", pid: 43, name: "Replacement")
        ]
        XCTAssertTrue(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: [],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: [],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 44,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
    }

    func testAppliedConfigReportsWhetherTargetRemainsConcealed() {
        let config = HiddenBarAppliedConfig(
            allowed: ["visible"],
            concealed: ["hidden"],
            at: .now
        )
        XCTAssertTrue(AssessmentModeHider.appliedConfig(config, conceals: "hidden"))
        XCTAssertFalse(AssessmentModeHider.appliedConfig(config, conceals: "visible"))
        XCTAssertFalse(AssessmentModeHider.appliedConfig(nil, conceals: "hidden"))
    }

    @MainActor
    func testDroppingAssertionInvalidatesActivationGeneration() {
        let hider = AssessmentModeHider()
        let generation = hider.activationGeneration

        hider.drop()

        XCTAssertEqual(hider.activationGeneration, generation + 1)
    }
}
