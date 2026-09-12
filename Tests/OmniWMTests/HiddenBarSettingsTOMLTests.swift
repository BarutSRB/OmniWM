// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class HiddenBarSettingsTOMLTests: XCTestCase {
    func testRoundTripsAllHiddenBarFields() throws {
        var export = SettingsExport.defaults()
        export.hiddenBar.enabled = false
        export.hiddenBar.hiddenBundleIDs = ["com.example.a", "com.example.b"]
        export.hiddenBar.rehideIntervalSeconds = 12

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))

        XCTAssertEqual(decoded.hiddenBar.enabled, false)
        XCTAssertEqual(decoded.hiddenBar.hiddenBundleIDs, ["com.example.a", "com.example.b"])
        XCTAssertEqual(decoded.hiddenBar.rehideIntervalSeconds, 12)
    }

    func testEmptyBundleListRoundTrips() throws {
        var export = SettingsExport.defaults()
        export.hiddenBar.hiddenBundleIDs = []

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        XCTAssertEqual(decoded.hiddenBar.hiddenBundleIDs, [])
    }

    func testPopulatedBundleListSurvivesPreservingEncode() throws {
        var export = SettingsExport.defaults()
        export.hiddenBar.hiddenBundleIDs = ["com.keep.me"]
        let previous = try SettingsTOMLCodec.encode(export)

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )
        XCTAssertTrue(rewritten.contains("com.keep.me"))
    }

    @MainActor
    func testApplyExportNormalizesRehideIntervalFromTOML() throws {
        let settings = makeSettingsStore()
        let cases = [
            (literal: "nan", expected: 5.0),
            (literal: "inf", expected: 5.0),
            (literal: "-inf", expected: 5.0),
            (literal: "1", expected: 2.0),
            (literal: "12", expected: 12.0),
            (literal: "31", expected: 30.0)
        ]

        for testCase in cases {
            let export = try SettingsTOMLCodec.decode(tomlWithRehideInterval(testCase.literal))
            settings.applyExport(export)

            XCTAssertEqual(
                settings.hiddenBar.rehideIntervalSeconds,
                testCase.expected,
                "TOML value: \(testCase.literal)"
            )
        }
    }

    @MainActor
    func testApplyExportNormalizesHiddenBundleIDsFromTOML() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.hiddenBar.hiddenBundleIDs = [
            "  com.example.first  ",
            "",
            "com.apple.systemuiserver",
            "com.example.first",
            "com.example.second"
        ]

        settings.applyExport(export)

        XCTAssertEqual(
            settings.hiddenBar.hiddenBundleIDs,
            ["com.example.first", "com.example.second"]
        )
    }

    @MainActor
    func testSettingsEditsReconcileOnceExceptForDelayOnlyEdit() {
        let settings = makeSettingsStore()
        var reconciliations = 0

        HiddenBarSettingsEdits.setEnabled(true) { enabled in
            settings.hiddenBar.enabled = enabled
            reconciliations += 1
        }
        XCTAssertTrue(settings.hiddenBar.enabled)
        XCTAssertEqual(reconciliations, 1)

        reconciliations = 0
        HiddenBarSettingsEdits.setHidden(
            true,
            bundleID: "com.example.item",
            settings: settings
        ) {
            reconciliations += 1
        }
        XCTAssertEqual(settings.hiddenBar.hiddenBundleIDs, ["com.example.item"])
        XCTAssertEqual(reconciliations, 1)

        HiddenBarSettingsEdits.setHidden(
            true,
            bundleID: "com.apple.systemuiserver",
            settings: settings
        ) {
            reconciliations += 1
        }
        XCTAssertEqual(settings.hiddenBar.hiddenBundleIDs, ["com.example.item"])
        XCTAssertEqual(reconciliations, 1)

        reconciliations = 0
        HiddenBarSettingsEdits.setRehideInterval(12, settings: settings)
        XCTAssertEqual(settings.hiddenBar.rehideIntervalSeconds, 12)
        XCTAssertEqual(reconciliations, 0)
    }

    private func tomlWithRehideInterval(_ literal: String) throws -> Data {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.hasPrefix("rehideIntervalSeconds = ") else { return String(line) }
            return "rehideIntervalSeconds = \(literal)"
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMHiddenBarSettingsTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
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
    }
}
