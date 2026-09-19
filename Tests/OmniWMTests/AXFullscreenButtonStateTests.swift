// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AXFullscreenButtonStateTests: XCTestCase {
    private func decision(
        result: AXError,
        value: CFTypeRef?,
        engine: WindowRuleEngine
    ) -> WindowDecision {
        let button = AXUIElementCreateApplication(72_037)
        let state = AXWindowService.fullscreenButtonEnabledState(result: result, value: value)
        let facts = AXWindowService.makeWindowFacts(
            AXWindowFactAttributeValues(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Fullscreen button evidence",
                closeButton: button,
                fullscreenButton: button,
                fullscreenButtonEnabled: state.enabled,
                zoomButton: button,
                minimizeButton: button
            ),
            appPolicy: .regular,
            bundleId: "org.example.fullscreen-evidence",
            attributeFetchSucceeded: state.succeeded
        )
        return engine.decision(
            for: WindowRuleFacts(appName: "Example", ax: facts, sizeConstraints: nil, windowServer: nil),
            token: nil,
            appFullscreen: false
        )
    }

    func testFailedEnabledReadDefersAdmissionUntilSuccessfulEvidence() {
        let engine = WindowRuleEngine()
        for error in [AXError.cannotComplete, .invalidUIElement, .failure] {
            let failed = decision(result: error, value: nil, engine: engine)

            XCTAssertEqual(failed.disposition, .undecided, "\(error)")
            XCTAssertEqual(failed.deferredReason, .attributeFetchFailed, "\(error)")
            XCTAssertEqual(failed.admissionOutcome, .deferred, "\(error)")
            XCTAssertFalse(failed.tracksWindow, "\(error)")

            let recovered = decision(result: .success, value: kCFBooleanTrue, engine: engine)

            XCTAssertEqual(recovered.disposition, .managed)
            XCTAssertNil(recovered.deferredReason)
        }
    }

    func testFailedEnabledReadCannotBeAdmittedByRulesOrManualOverrides() {
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [AppRule(bundleId: "org.example.fullscreen-evidence", layout: .tile)])
        let failed = decision(result: .cannotComplete, value: kCFBooleanTrue, engine: engine)

        XCTAssertEqual(failed.disposition, .undecided)
        XCTAssertEqual(failed.deferredReason, .attributeFetchFailed)
        for override in [ManualWindowOverride.forceTile, .forceFloat] {
            XCTAssertEqual(WindowRuleEngine.applyingManualOverride(failed, manualOverride: override), failed)
        }
    }

    func testDisabledFullscreenButtonStillFloats() {
        let disabled = decision(result: .success, value: kCFBooleanFalse, engine: WindowRuleEngine())

        XCTAssertEqual(disabled.disposition, .floating)
        XCTAssertEqual(disabled.heuristicReasons, [.disabledFullscreenButton])
        XCTAssertNil(disabled.deferredReason)
    }

    func testUnavailableEnabledAttributePreservesFloatingClassification() {
        let engine = WindowRuleEngine()
        for result in [AXError.success, .noValue, .attributeUnsupported] {
            let unavailable = decision(result: result, value: nil, engine: engine)

            XCTAssertEqual(unavailable.disposition, .floating, "\(result)")
            XCTAssertEqual(unavailable.heuristicReasons, [.disabledFullscreenButton], "\(result)")
            XCTAssertNil(unavailable.deferredReason, "\(result)")
        }
    }

    func testMalformedEnabledAttributeDefersAdmission() {
        let engine = WindowRuleEngine()
        for value: CFTypeRef in [kCFNull, "not a boolean" as CFString] {
            let malformed = decision(result: .success, value: value, engine: engine)

            XCTAssertEqual(malformed.disposition, .undecided)
            XCTAssertEqual(malformed.deferredReason, .attributeFetchFailed)
        }
    }

    func testExplicitTileRuleStillOverridesLegitimateDisabledButton() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "org.example.fullscreen-evidence", layout: .tile)
        engine.rebuild(rules: [rule])
        let disabled = decision(result: .success, value: kCFBooleanFalse, engine: engine)

        XCTAssertEqual(disabled.disposition, .managed)
        XCTAssertEqual(disabled.source, .userRule(rule.id))
        XCTAssertNil(disabled.deferredReason)
    }
}
