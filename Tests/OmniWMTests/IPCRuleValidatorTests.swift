// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC
import XCTest

final class IPCRuleValidatorTests: XCTestCase {
    func testEmptyBundleWithoutMatchersIsInvalid() {
        let report = IPCRuleValidator.validate(IPCRuleDefinition(bundleId: ""))
        XCTAssertNotNil(report.identifierError)
        XCTAssertFalse(report.isValid)
    }

    func testEmptyBundleWithAppNameIsValid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "", appNameSubstring: "VMD")
        )
        XCTAssertNil(report.identifierError)
        XCTAssertNil(report.bundleIdError)
        XCTAssertTrue(report.isValid)
    }

    func testEmptyBundleWithTitleIsValid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "", titleSubstring: "Main")
        )
        XCTAssertNil(report.identifierError)
        XCTAssertTrue(report.isValid)
    }

    func testEmptyBundleWithAxOnlyIsInvalid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "", axSubrole: "AXStandardWindow")
        )
        XCTAssertNotNil(report.identifierError)
        XCTAssertFalse(report.isValid)
    }

    func testMalformedBundleIsRejected() {
        let report = IPCRuleValidator.validate(IPCRuleDefinition(bundleId: "not a bundle id"))
        XCTAssertNotNil(report.bundleIdError)
        XCTAssertFalse(report.isValid)
    }

    func testEmptyBundleStringHasNoFormatError() {
        XCTAssertNil(IPCRuleValidator.bundleIdError(for: ""))
    }
}
