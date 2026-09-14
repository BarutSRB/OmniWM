// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarExcludedAppsSettingsTests: XCTestCase {
    func testDefaultsEncodeAsEmptyList() throws {
        XCTAssertEqual(SettingsExport.defaults().workspaceBar.excludedBundleIDs, [])

        let canonical = try XCTUnwrap(
            String(
                bytes: SettingsTOMLCodec.encode(.defaults()),
                encoding: .utf8
            )
        )
        XCTAssertTrue(canonical.contains("excludedBundleIDs = []"))
    }

    func testCanonicalAndPreservingRoundTripsKeepBundleIDs() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.excludedBundleIDs = [
            "tracesOf.Uebersicht",
            "com.example.Offline"
        ]

        let canonical = try SettingsTOMLCodec.encode(export)
        let canonicalText = try XCTUnwrap(String(bytes: canonical, encoding: .utf8))
        XCTAssertTrue(canonicalText.contains("excludedBundleIDs = [\"tracesOf.Uebersicht\", \"com.example.Offline\"]"))
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(canonical).workspaceBar.excludedBundleIDs,
            export.workspaceBar.excludedBundleIDs
        )

        let preserving = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: canonical)
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(preserving).workspaceBar.excludedBundleIDs,
            export.workspaceBar.excludedBundleIDs
        )
    }

    func testApplyExportNormalizesAndExportSortsDeterministically() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.workspaceBar.excludedBundleIDs = [
            "  com.Zeta  ",
            "com.beta",
            "",
            "\n",
            "COM.BETA",
            "com.Alpha"
        ]

        settings.applyExport(export)

        XCTAssertEqual(
            settings.workspaceBar.excludedBundleIDs,
            Set(["com.Zeta", "com.beta", "com.Alpha"])
        )
        XCTAssertEqual(
            settings.toExport().workspaceBar.excludedBundleIDs,
            ["com.Alpha", "com.beta", "com.Zeta"]
        )
    }

    func testAddAndRemoveAreTrimmedCaseInsensitiveAndReportNoOps() {
        let settings = makeSettingsStore()

        XCTAssertFalse(settings.workspaceBar.addExcludedBundleID("  \n"))
        XCTAssertTrue(settings.workspaceBar.addExcludedBundleID("  com.Example.One  "))
        XCTAssertEqual(settings.workspaceBar.excludedBundleIDs, ["com.Example.One"])
        XCTAssertFalse(settings.workspaceBar.addExcludedBundleID("COM.EXAMPLE.ONE"))
        XCTAssertTrue(settings.workspaceBar.removeExcludedBundleID("  COM.EXAMPLE.ONE  "))
        XCTAssertTrue(settings.workspaceBar.excludedBundleIDs.isEmpty)
        XCTAssertFalse(settings.workspaceBar.removeExcludedBundleID("com.example.one"))
    }

    func testUIEditsRefreshOnceOnlyWhenTheExclusionChanges() {
        let settings = makeSettingsStore()
        var refreshCount = 0
        let refresh = { refreshCount += 1 }

        XCTAssertTrue(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                true,
                bundleID: "com.Example.One",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                true,
                bundleID: "COM.EXAMPLE.ONE",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                false,
                bundleID: "COM.EXAMPLE.ONE",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 2)
        XCTAssertFalse(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                false,
                bundleID: "com.example.one",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 2)
    }

    func testResolvedSettingsUseTheSameGlobalExclusionsOnEveryMonitor() {
        let settings = makeSettingsStore()
        XCTAssertTrue(settings.workspaceBar.addExcludedBundleID("com.example.global"))
        let first = monitor(displayId: 41_001, name: "First", x: 0)
        let second = monitor(displayId: 41_002, name: "Second", x: 1440)

        settings.workspaceBar.update(
            MonitorBarSettings(
                monitorName: second.name,
                monitorDisplayId: second.displayId,
                hideEmptyWorkspaces: true
            ),
            for: second
        )

        XCTAssertEqual(
            settings.workspaceBar.resolved(for: first).excludedBundleIDs,
            ["com.example.global"]
        )
        XCTAssertEqual(
            settings.workspaceBar.resolved(for: second).excludedBundleIDs,
            ["com.example.global"]
        )
    }

    func testExternalSettingsReloadReplacesLiveExclusions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarExclusionReloadTests-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertTrue(settings.workspaceBar.addExcludedBundleID("com.example.before"))
        var externalReloadCount = 0
        settings.onExternalSettingsReloaded = {
            externalReloadCount += 1
        }
        var external = SettingsExport.defaults()
        external.workspaceBar.excludedBundleIDs = ["  com.example.After  "]

        try SettingsTOMLCodec.encode(external).write(to: persistence.fileURL, options: .atomic)
        for _ in 0 ..< 200 {
            if externalReloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(externalReloadCount, 1)
        XCTAssertEqual(settings.workspaceBar.excludedBundleIDs, ["com.example.After"])
    }

    private func monitor(displayId: CGDirectDisplayID, name: String, x: CGFloat) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: x, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: x, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: name
        )
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarExclusionSettingsTests-\(UUID().uuidString)", isDirectory: true)
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
