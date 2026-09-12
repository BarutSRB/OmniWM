// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarIconOverridesSettingsTests: XCTestCase {
    func testDottedBundleIDRoundTripsAndUnknownKeysArePreserved() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.iconOverrides = [
            "com.example.App": "bundle-resource:AppIconDark",
            "org.example.Other": "/tmp/other.png"
        ]

        let canonical = try SettingsTOMLCodec.encode(export)
        let canonicalText = try XCTUnwrap(String(bytes: canonical, encoding: .utf8))
        XCTAssertTrue(canonicalText.contains("[workspaceBar.iconOverrides]"))
        XCTAssertTrue(
            canonicalText.contains(
                "\"com.example.App\" = \"bundle-resource:AppIconDark\""
            )
        )
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(canonical).workspaceBar.iconOverrides,
            export.workspaceBar.iconOverrides
        )
        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: canonical).isEmpty)

        let previous = Data(
            """
            \(canonicalText)

            [workspaceBar.futureAppearance]
            glow = true
            """.utf8
        )
        let preserving = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous)
        let preservingText = try XCTUnwrap(String(bytes: preserving, encoding: .utf8))

        XCTAssertTrue(preservingText.contains("[workspaceBar.futureAppearance]"))
        XCTAssertTrue(preservingText.contains("glow = true"))
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(preserving).workspaceBar.iconOverrides,
            export.workspaceBar.iconOverrides
        )
        XCTAssertTrue(
            SettingsTOMLCodec.unknownKeyPaths(in: preserving).contains(
                "workspaceBar.futureAppearance"
            )
        )
    }

    func testApplyExportNormalizesCaseCollisionsDeterministically() {
        let entries = [
            (" com.Example.App ", " zeta.icns "),
            ("COM.EXAMPLE.APP", " alpha.icns "),
            ("org.example.Other", " other.png "),
            ("", "ignored.png"),
            ("net.example.Blank", "\n")
        ]
        let forward = Dictionary(uniqueKeysWithValues: entries)
        let reversed = Dictionary(uniqueKeysWithValues: entries.reversed())
        let first = makeSettingsStore()
        let second = makeSettingsStore()
        var firstExport = SettingsExport.defaults()
        firstExport.workspaceBar.iconOverrides = forward
        var secondExport = SettingsExport.defaults()
        secondExport.workspaceBar.iconOverrides = reversed

        first.applyExport(firstExport)
        second.applyExport(secondExport)

        let expected = [
            "COM.EXAMPLE.APP": "alpha.icns",
            "org.example.Other": "other.png"
        ]
        XCTAssertEqual(first.workspaceBar.iconOverrides, expected)
        XCTAssertEqual(second.workspaceBar.iconOverrides, expected)
        XCTAssertEqual(first.toExport().workspaceBar.iconOverrides, expected)
    }

    func testMutatorsTrimMatchCaseInsensitivelyAndReportNoOps() {
        let settings = makeSettingsStore()

        XCTAssertFalse(settings.workspaceBar.setIconOverride("icon.png", for: " \n"))
        XCTAssertFalse(settings.workspaceBar.setIconOverride("\n", for: "com.example.App"))
        XCTAssertTrue(settings.workspaceBar.setIconOverride(" icons/first.icns ", for: " com.Example.App "))
        XCTAssertEqual(
            settings.workspaceBar.iconOverrideValue(for: "COM.EXAMPLE.APP"),
            "icons/first.icns"
        )
        XCTAssertFalse(
            settings.workspaceBar.setIconOverride("icons/first.icns", for: "COM.EXAMPLE.APP")
        )
        XCTAssertTrue(
            settings.workspaceBar.setIconOverride("/tmp/replacement.png", for: "COM.EXAMPLE.APP")
        )
        XCTAssertEqual(
            settings.workspaceBar.iconOverrides,
            ["com.Example.App": "/tmp/replacement.png"]
        )
        XCTAssertNil(settings.workspaceBar.iconOverrideValue(for: " \n"))
        XCTAssertTrue(settings.workspaceBar.removeIconOverride(for: " COM.EXAMPLE.APP "))
        XCTAssertTrue(settings.workspaceBar.iconOverrides.isEmpty)
        XCTAssertFalse(settings.workspaceBar.removeIconOverride(for: "com.example.App"))
    }

    func testExternalSettingsReloadReplacesAndNormalizesLiveOverrides() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarIconOverrideReloadTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: true,
            deferSaves: false
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        XCTAssertTrue(
            settings.workspaceBar.setIconOverride("before.png", for: "com.example.Before")
        )
        var externalReloadCount = 0
        settings.onExternalSettingsReloaded = {
            externalReloadCount += 1
        }
        var external = SettingsExport.defaults()
        external.workspaceBar.iconOverrides = [
            "  com.example.After  ": " icons/after.icns ",
            "org.example.Blank": "\n"
        ]

        try SettingsTOMLCodec.encode(external).write(to: persistence.fileURL, options: .atomic)
        for _ in 0 ..< 200 {
            if externalReloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(externalReloadCount, 1)
        XCTAssertEqual(
            settings.workspaceBar.iconOverrides,
            ["com.example.After": "icons/after.icns"]
        )
        XCTAssertNil(settings.workspaceBar.iconOverrideValue(for: "com.example.Before"))
    }

    private func removingTOMLTable(named tableName: String, from text: String) -> String {
        var skipping = false
        var retained: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "[\(tableName)]" {
                skipping = true
                continue
            }
            if skipping, line.hasPrefix("[") {
                skipping = false
            }
            if !skipping {
                retained.append(line)
            }
        }
        return retained.joined(separator: "\n")
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OmniWMWorkspaceBarIconOverrideSettingsTests-\(UUID().uuidString)",
                isDirectory: true
            )
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
