// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarAppearanceSettingsTests: XCTestCase {
    func testAppearanceDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertNil(export.workspaceBarInactiveIconOpacity)
        XCTAssertFalse(export.workspaceBarTransparentBackground)
        XCTAssertFalse(export.workspaceBarSolidBlackBackground)
        XCTAssertTrue(export.workspaceBarShowItemBackgrounds)
        XCTAssertTrue(export.workspaceBarShowAccentHighlights)

        export.workspaceBarTransparentBackground = true
        export.workspaceBarSolidBlackBackground = true
        export.workspaceBarShowItemBackgrounds = false
        export.workspaceBarShowAccentHighlights = false
        export.workspaceBarInactiveIconOpacity = 0.25
        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(toml.contains("transparentBackground = true"))
        XCTAssertTrue(toml.contains("solidBlackBackground = true"))
        XCTAssertTrue(toml.contains("showItemBackgrounds = false"))
        XCTAssertTrue(toml.contains("showAccentHighlights = false"))
        XCTAssertTrue(toml.contains("inactiveIconOpacity = 0.25"))
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertTrue(decoded.workspaceBarTransparentBackground)
        XCTAssertTrue(decoded.workspaceBarSolidBlackBackground)
        XCTAssertFalse(decoded.workspaceBarShowItemBackgrounds)
        XCTAssertFalse(decoded.workspaceBarShowAccentHighlights)
        XCTAssertEqual(decoded.workspaceBarInactiveIconOpacity, 0.25)
    }

    func testVersionThreeMigratesMissingAppearanceSettingsToDefaults() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "schemaVersion = 4", with: "schemaVersion = 3")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                !$0.contains("inactiveIconOpacity") &&
                    !$0.contains("transparentBackground") &&
                    !$0.contains("solidBlackBackground") &&
                    !$0.contains("showItemBackgrounds") &&
                    !$0.contains("showAccentHighlights")
            }
            .joined(separator: "\n")

        let result = try SettingsTOMLCodec.decodeForLoad(Data(toml.utf8))
        XCTAssertEqual(result.migration?.fromVersion, 3)
        XCTAssertFalse(result.export.workspaceBarTransparentBackground)
        XCTAssertFalse(result.export.workspaceBarSolidBlackBackground)
        XCTAssertTrue(result.export.workspaceBarShowItemBackgrounds)
        XCTAssertTrue(result.export.workspaceBarShowAccentHighlights)
        XCTAssertNil(result.export.workspaceBarInactiveIconOpacity)
    }

    func testCurrentSchemaRejectsInvalidAppearanceType() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let invalid = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "transparentBackground = false", with: "transparentBackground = \"no\"")
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(invalid.utf8)))
    }

    func testMonitorAppearanceOverrideRoundTrips() throws {
        var export = SettingsExport.defaults()
        export.monitorBarSettings = [
            MonitorBarSettings(
                monitorName: "Built-in",
                inactiveIconOpacity: 0.2,
                transparentBackground: true,
                solidBlackBackground: true,
                showItemBackgrounds: false,
                showAccentHighlights: false
            ),
            MonitorBarSettings(monitorName: "External")
        ]

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))

        XCTAssertEqual(decoded.monitorBarSettings[0].inactiveIconOpacity, 0.2)
        XCTAssertEqual(decoded.monitorBarSettings[0].transparentBackground, true)
        XCTAssertEqual(decoded.monitorBarSettings[0].solidBlackBackground, true)
        XCTAssertEqual(decoded.monitorBarSettings[0].showItemBackgrounds, false)
        XCTAssertEqual(decoded.monitorBarSettings[0].showAccentHighlights, false)
        XCTAssertNil(decoded.monitorBarSettings[1].inactiveIconOpacity)
        XCTAssertNil(decoded.monitorBarSettings[1].transparentBackground)
        XCTAssertNil(decoded.monitorBarSettings[1].solidBlackBackground)
        XCTAssertNil(decoded.monitorBarSettings[1].showItemBackgrounds)
        XCTAssertNil(decoded.monitorBarSettings[1].showAccentHighlights)
    }

    @MainActor
    func testResolvedBarSettingsMergesAppearanceOverride() {
        let settings = makeSettingsStore()
        settings.workspaceBarInactiveIconOpacity = 0.5
        settings.workspaceBarTransparentBackground = false
        settings.workspaceBarSolidBlackBackground = false
        settings.workspaceBarShowItemBackgrounds = true
        settings.workspaceBarShowAccentHighlights = true
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            name: "Built-in"
        )

        let resolved = settings.resolvedBarSettings(for: monitor)
        XCTAssertEqual(resolved.inactiveIconOpacity, 0.5)
        XCTAssertFalse(resolved.transparentBackground)
        XCTAssertFalse(resolved.solidBlackBackground)
        XCTAssertTrue(resolved.showItemBackgrounds)
        XCTAssertTrue(resolved.showAccentHighlights)

        settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: "Built-in",
                inactiveIconOpacity: 0.2,
                transparentBackground: true,
                solidBlackBackground: true,
                showItemBackgrounds: false,
                showAccentHighlights: false
            ),
            for: monitor
        )

        let resolvedOverride = settings.resolvedBarSettings(for: monitor)
        XCTAssertEqual(resolvedOverride.inactiveIconOpacity, 0.2)
        XCTAssertTrue(resolvedOverride.transparentBackground)
        XCTAssertTrue(resolvedOverride.solidBlackBackground)
        XCTAssertFalse(resolvedOverride.showItemBackgrounds)
        XCTAssertFalse(resolvedOverride.showAccentHighlights)
    }

    @MainActor
    func testResolvedBarSettingsUsesDefaultsWhenOverrideNil() {
        let settings = makeSettingsStore()
        settings.workspaceBarInactiveIconOpacity = 0.5
        settings.workspaceBarTransparentBackground = false
        settings.workspaceBarSolidBlackBackground = false
        settings.workspaceBarShowItemBackgrounds = true
        settings.workspaceBarShowAccentHighlights = true
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            name: "Built-in"
        )

        settings.updateBarSettings(
            MonitorBarSettings(monitorName: "Built-in"),
            for: monitor
        )

        let resolved = settings.resolvedBarSettings(for: monitor)
        XCTAssertEqual(resolved.inactiveIconOpacity, 0.5)
        XCTAssertFalse(resolved.transparentBackground)
        XCTAssertFalse(resolved.solidBlackBackground)
        XCTAssertTrue(resolved.showItemBackgrounds)
        XCTAssertTrue(resolved.showAccentHighlights)
    }
}

private extension WorkspaceBarAppearanceSettingsTests {
    @MainActor
    func makeSettingsStore() -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: FileManager.default.temporaryDirectory),
            runtimeState: RuntimeStateStore(),
            autosaveEnabled: false
        )
    }
}
