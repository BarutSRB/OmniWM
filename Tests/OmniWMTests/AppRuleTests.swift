// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppRuleTests: XCTestCase {
    func testNormalizeSingleTitleDropsSubstringWhenBothSet() {
        let rule = AppRule(
            bundleId: "com.test.app",
            titleSubstring: "Main",
            titleRegex: "^Main$",
            layout: .float
        )
        XCTAssertNil(rule.titleSubstring)
        XCTAssertEqual(rule.titleRegex, "^Main$")
    }

    func testNormalizeKeepsLoneTitleMatchers() {
        let substring = AppRule(bundleId: "a", titleSubstring: "Main", layout: .float)
        XCTAssertEqual(substring.titleSubstring, "Main")
        XCTAssertNil(substring.titleRegex)

        let regex = AppRule(bundleId: "a", titleRegex: "^Main$", layout: .float)
        XCTAssertNil(regex.titleSubstring)
        XCTAssertEqual(regex.titleRegex, "^Main$")
    }

    func testNormalizeSingleTitleAppliesOnDecode() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","bundleId":"com.test.app",\
        "titleSubstring":"Main","titleRegex":"^Main$","layout":"float"}
        """
        let rule = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))
        XCTAssertNil(rule.titleSubstring)
        XCTAssertEqual(rule.titleRegex, "^Main$")
    }

    func testHasEffect() {
        XCTAssertFalse(AppRule(bundleId: "com.test.app").hasEffect)
        XCTAssertFalse(AppRule(bundleId: "com.test.app", appNameSubstring: "Test").hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", layout: .float).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", assignToWorkspace: "2").hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", initialColumnWidth: 0.05).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", initialColumnWidth: 1.0).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", minWidth: 400).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", minHeight: 300).hasEffect)
    }

    func testInvalidInitialColumnWidthDoesNotCountAsEffect() {
        for value in [0.049, 1.001, .nan, .infinity, -.infinity] {
            let rule = AppRule(bundleId: "com.test.app", initialColumnWidth: value)
            XCTAssertNil(rule.validInitialColumnWidth)
            XCTAssertFalse(rule.hasEffect)
        }
    }

    func testInitialColumnWidthRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.appRules = [AppRule(bundleId: "com.test.app", initialColumnWidth: 0.5)]

        let data = try SettingsTOMLCodec.encode(export)
        let toml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(toml.contains("initialColumnWidth = 0.5"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).appRules.first?.initialColumnWidth, 0.5)
    }

    func testNilInitialColumnWidthIsOmittedFromJSONAndTOML() throws {
        let rule = AppRule(bundleId: "com.test.app", layout: .float)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any]
        )
        XCTAssertNil(json["initialColumnWidth"])

        var export = SettingsExport.defaults()
        export.appRules = [rule]
        let tomlData = try SettingsTOMLCodec.encode(export)
        let toml = try XCTUnwrap(String(data: tomlData, encoding: .utf8))
        XCTAssertFalse(toml.contains("initialColumnWidth"))
        XCTAssertNil(try SettingsTOMLCodec.decode(tomlData).appRules.first?.initialColumnWidth)
    }

    @MainActor
    func testAppRulesRevisionChangesOnlyForDistinctRules() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMRuleRevision-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let baseline = settings.appRulesRevision
        let rules = [AppRule(bundleId: "com.test.app", layout: .float)]

        settings.appRules = rules
        XCTAssertEqual(settings.appRulesRevision, baseline + 1)

        settings.appRules = rules
        XCTAssertEqual(settings.appRulesRevision, baseline + 1)
    }

    @MainActor
    func testIPCProjectionRoundTripsInitialColumnWidth() {
        let rule = AppRule(bundleId: "com.test.app", initialColumnWidth: 0.5)
        let definition = IPCRuleProjection.definition(from: rule)
        let projectedRule = IPCRuleProjection.appRule(from: definition, id: rule.id)
        let snapshot = IPCRuleProjection.snapshot(
            from: projectedRule,
            position: 1,
            invalidRegexMessagesByRuleId: [:]
        )

        XCTAssertEqual(definition.initialColumnWidth, 0.5)
        XCTAssertEqual(projectedRule, rule)
        XCTAssertEqual(snapshot.initialColumnWidth, 0.5)
        XCTAssertTrue(snapshot.isValid)
    }

    @MainActor
    func testIPCProjectionReportsInvalidInitialColumnWidth() {
        let rule = AppRule(bundleId: "com.test.app", initialColumnWidth: 1.001)
        let snapshot = IPCRuleProjection.snapshot(
            from: rule,
            position: 1,
            invalidRegexMessagesByRuleId: [:]
        )

        XCTAssertFalse(snapshot.isValid)
        XCTAssertTrue(snapshot.validationMessages.contains { $0.hasPrefix("Initial column width") })
    }

    func testDraftDefaultsAndRoundTripsInitialColumnWidth() {
        let emptyDraft = AppRuleDraft()
        XCTAssertFalse(emptyDraft.initialColumnWidthEnabled)
        XCTAssertEqual(emptyDraft.initialColumnWidth, 0.5)

        let rule = AppRule(bundleId: "com.test.app", initialColumnWidth: 0.75)
        let draft = AppRuleDraft(rule: rule)
        XCTAssertTrue(draft.initialColumnWidthEnabled)
        XCTAssertEqual(draft.initialColumnWidth, 0.75)
        XCTAssertNil(draft.initialColumnWidthError)
        XCTAssertEqual(draft.makeRule(), rule)
    }

    func testSelectingBundledApplicationReplacesOnlyApplicationIdentityMatchers() {
        var draft = populatedDraft()
        let expectedId = draft.id

        draft.selectApplication(bundleId: "com.example.Bundled", appName: "Bundled")

        XCTAssertEqual(draft.id, expectedId)
        XCTAssertEqual(draft.bundleId, "com.example.Bundled")
        XCTAssertFalse(draft.appNameMatcherEnabled)
        XCTAssertEqual(draft.appNameSubstring, "")
        assertUnrelatedSelectionState(draft)
    }

    func testSelectingBundlelessApplicationReplacesOnlyApplicationIdentityMatchers() {
        var draft = populatedDraft()
        let expectedId = draft.id

        draft.selectApplication(bundleId: nil, appName: "Bundleless")

        XCTAssertEqual(draft.id, expectedId)
        XCTAssertEqual(draft.bundleId, "")
        XCTAssertTrue(draft.appNameMatcherEnabled)
        XCTAssertEqual(draft.appNameSubstring, "Bundleless")
        assertUnrelatedSelectionState(draft)
    }

    func testInitialColumnWidthPercentConversionHandlesFractionsAndExtremeValues() {
        let proportion = 0.5555
        let percent = AppRuleInitialColumnWidthPercent.percent(from: proportion)
        XCTAssertEqual(percent, 55.55, accuracy: 0.000_000_1)
        XCTAssertEqual(
            AppRuleInitialColumnWidthPercent.proportion(from: percent),
            proportion,
            accuracy: 0.000_000_1
        )
        XCTAssertTrue(AppRuleInitialColumnWidthPercent.percent(from: .greatestFiniteMagnitude).isInfinite)
        XCTAssertTrue(AppRuleInitialColumnWidthPercent.percent(from: .nan).isNaN)
        XCTAssertEqual(AppRuleInitialColumnWidthPercent.percent(from: .infinity), .infinity)
        XCTAssertEqual(AppRuleInitialColumnWidthPercent.percent(from: -.infinity), -.infinity)
        XCTAssertEqual(AppRuleInitialColumnWidthPercent.displayText(for: proportion), "55.55")

        var invalidDraft = AppRuleDraft(bundleId: "com.test.app")
        invalidDraft.initialColumnWidthEnabled = true
        invalidDraft.initialColumnWidth = AppRuleInitialColumnWidthPercent.proportion(from: 4.9)
        XCTAssertEqual(invalidDraft.initialColumnWidth, 0.049, accuracy: 0.000_000_1)
        XCTAssertNotNil(invalidDraft.initialColumnWidthError)
    }

    func testDraftEqualityAndRuleRepresentationAreNaNStable() {
        let rule = AppRule(bundleId: "com.test.app", initialColumnWidth: .nan)
        let lhs = AppRuleDraft(rule: rule)
        let rhs = AppRuleDraft(rule: rule)

        XCTAssertEqual(lhs, rhs)
        XCTAssertTrue(lhs.represents(rule))

        var changed = lhs
        changed.initialColumnWidth = .infinity
        XCTAssertNotEqual(changed, rhs)
        XCTAssertFalse(changed.represents(rule))
    }

    private func populatedDraft() -> AppRuleDraft {
        var draft = AppRuleDraft(bundleId: "com.example.Previous")
        draft.layoutAction = .float
        draft.assignToWorkspaceEnabled = true
        draft.assignToWorkspace = "work"
        draft.initialColumnWidthEnabled = true
        draft.initialColumnWidth = 0.7
        draft.minWidthEnabled = true
        draft.minWidth = 640
        draft.minHeightEnabled = true
        draft.minHeight = 480
        draft.appNameMatcherEnabled = true
        draft.appNameSubstring = "Previous"
        draft.titleMatcherMode = .regex
        draft.titleSubstring = "unchanged substring"
        draft.titleRegex = "^Document"
        draft.axRoleEnabled = true
        draft.axRole = "AXWindow"
        draft.axSubroleEnabled = true
        draft.axSubrole = "AXStandardWindow"
        return draft
    }

    private func assertUnrelatedSelectionState(_ draft: AppRuleDraft) {
        XCTAssertEqual(draft.layoutAction, .float)
        XCTAssertTrue(draft.assignToWorkspaceEnabled)
        XCTAssertEqual(draft.assignToWorkspace, "work")
        XCTAssertTrue(draft.initialColumnWidthEnabled)
        XCTAssertEqual(draft.initialColumnWidth, 0.7)
        XCTAssertTrue(draft.minWidthEnabled)
        XCTAssertEqual(draft.minWidth, 640)
        XCTAssertTrue(draft.minHeightEnabled)
        XCTAssertEqual(draft.minHeight, 480)
        XCTAssertEqual(draft.titleMatcherMode, .regex)
        XCTAssertEqual(draft.titleSubstring, "unchanged substring")
        XCTAssertEqual(draft.titleRegex, "^Document")
        XCTAssertTrue(draft.axRoleEnabled)
        XCTAssertEqual(draft.axRole, "AXWindow")
        XCTAssertTrue(draft.axSubroleEnabled)
        XCTAssertEqual(draft.axSubrole, "AXStandardWindow")
    }
}
