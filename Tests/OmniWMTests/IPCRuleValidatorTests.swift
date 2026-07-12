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
            IPCRuleDefinition(bundleId: "", appNameSubstring: "VMD", layout: .float)
        )
        XCTAssertNil(report.identifierError)
        XCTAssertNil(report.bundleIdError)
        XCTAssertTrue(report.isValid)
    }

    func testEmptyBundleWithTitleIsValid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "", titleSubstring: "Main", layout: .float)
        )
        XCTAssertNil(report.identifierError)
        XCTAssertTrue(report.isValid)
    }

    func testEmptyBundleWithAxOnlyIsInvalid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "", axSubrole: "AXStandardWindow", layout: .float)
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

    func testIdentifyingMatcherWithoutEffectIsInvalid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app")
        )
        XCTAssertNotNil(report.effectError)
        XCTAssertFalse(report.isValid)
    }

    func testWorkspaceAssignmentCountsAsEffect() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", assignToWorkspace: "2")
        )
        XCTAssertNil(report.effectError)
        XCTAssertTrue(report.isValid)
    }

    func testBothTitleMatchersRejected() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", titleSubstring: "Main", titleRegex: "^Main$", layout: .float)
        )
        XCTAssertNotNil(report.titleMatcherError)
        XCTAssertFalse(report.isValid)
    }

    func testNonPositiveMinSizeRejected() {
        for value in [0.0, -10.0, Double.nan] {
            let report = IPCRuleValidator.validate(
                IPCRuleDefinition(bundleId: "com.test.app", minWidth: value)
            )
            XCTAssertNotNil(report.minSizeError, "min width \(value) should be rejected")
            XCTAssertFalse(report.isValid)
        }

        let height = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", minHeight: -1)
        )
        XCTAssertNotNil(height.minSizeError)
    }

    func testPositiveMinSizeAccepted() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", minWidth: 400, minHeight: 300)
        )
        XCTAssertNil(report.minSizeError)
        XCTAssertTrue(report.isValid)
    }

    func testInitialColumnWidthInclusiveBoundsAccepted() {
        for value in [0.05, 0.5, 1.0] {
            let report = IPCRuleValidator.validate(
                IPCRuleDefinition(bundleId: "com.test.app", initialColumnWidth: value)
            )
            XCTAssertNil(report.initialColumnWidthError)
            XCTAssertNil(report.effectError)
            XCTAssertTrue(report.isValid)
        }
    }

    func testInvalidInitialColumnWidthRejectedWithoutCountingAsEffect() {
        for value in [0.049, 1.001, .nan, .infinity, -.infinity] {
            let report = IPCRuleValidator.validate(
                IPCRuleDefinition(bundleId: "com.test.app", initialColumnWidth: value)
            )
            XCTAssertNotNil(report.initialColumnWidthError)
            XCTAssertNotNil(report.effectError)
            XCTAssertFalse(report.isValid)
        }
    }

    func testInvalidInitialColumnWidthDoesNotHideAnotherEffect() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", layout: .float, initialColumnWidth: 1.001)
        )
        XCTAssertNotNil(report.initialColumnWidthError)
        XCTAssertNil(report.effectError)
        XCTAssertFalse(report.isValid)
    }

    func testInitialColumnWidthIPCModelsRoundTrip() throws {
        let definition = IPCRuleDefinition(bundleId: "com.test.app", initialColumnWidth: 0.5)
        let definitionData = try JSONEncoder().encode(definition)
        XCTAssertEqual(try JSONDecoder().decode(IPCRuleDefinition.self, from: definitionData), definition)

        let snapshot = IPCRuleSnapshot(
            id: "x",
            position: 1,
            bundleId: "com.test.app",
            layout: .auto,
            initialColumnWidth: 0.5,
            specificity: 2,
            isValid: true
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(IPCRuleSnapshot.self, from: snapshotData), snapshot)
    }

    func testInitialColumnWidthManifestOption() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.ruleDefinitionOptionDescriptors.first {
                $0.flag == "--initial-column-width"
            }
        )
        XCTAssertEqual(descriptor.valuePlaceholder, "<proportion>")
    }

    func testMessagesAggregateAllErrors() {
        let report = IPCRuleValidator.validate(IPCRuleDefinition(bundleId: ""))
        XCTAssertEqual(report.messages, report.messages.filter { !$0.isEmpty })
        XCTAssertFalse(report.messages.isEmpty)
        XCTAssertTrue(report.messages.contains { $0 == report.identifierError })
    }

    func testSnapshotCodecToleratesMissingValidationMessages() throws {
        let json = """
        {"id":"x","position":1,"bundleId":"com.test.app","layout":"float","specificity":2,"isValid":true}
        """
        let snapshot = try JSONDecoder().decode(IPCRuleSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.validationMessages, [])

        let roundTripped = try JSONDecoder().decode(
            IPCRuleSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(roundTripped, snapshot)
    }
}
