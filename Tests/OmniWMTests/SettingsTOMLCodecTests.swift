// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OmniWMIPC
import Testing

@testable import OmniWM

@Suite struct SettingsTOMLCodecTests {
    @Test func roundTripsDefaults() throws {
        let original = SettingsExport.defaults()
        let data = try SettingsTOMLCodec.encode(original)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded == original)
    }

    @Test func encodeProducesSectionedToml() throws {
        let data = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        let output = try #require(String(data: data, encoding: .utf8))

        #expect(output.contains("[general]"))
        #expect(output.contains("[focus]"))
        #expect(output.contains("[mouseWarp]"))
        #expect(output.contains("[gaps]"))
        #expect(output.contains("[gaps.outer]"))
        #expect(output.contains("[niri]"))
        #expect(output.contains("[dwindle]"))
        #expect(output.contains("[borders]"))
        #expect(output.contains("[borders.color]"))
        #expect(output.contains("[workspaceBar]"))
        #expect(output.contains("[workspaceBar.accentColor]"))
        #expect(output.contains("[workspaceBar.textColor]"))
        #expect(output.contains("[gestures]"))
        #expect(output.contains("[statusBar]"))
        #expect(output.contains("[quakeTerminal]"))
        #expect(output.contains("[appearance]"))
        #expect(output.contains("[state]"))
        #expect(output.contains("[[hotkeys]]"))
        #expect(output.contains("[[workspaces]]"))
        #expect(output.contains("[[appRules]]"))

        #expect(output.contains("niriMaxVisibleColumns") == false)
        #expect(output.contains("borderColorRed") == false)
        #expect(output.contains("workspaceBarAccentColorRed") == false)
        #expect(output.contains("outerGapLeft") == false)
    }

    @Test func roundTripsWithQuakeCustomFrameSet() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminalUseCustomFrame = true
        export.quakeTerminalCustomFrame = QuakeTerminalFrameExport(
            x: 120, y: 80, width: 1680, height: 900
        )

        let data = try SettingsTOMLCodec.encode(export)
        let output = try #require(String(data: data, encoding: .utf8))
        #expect(output.contains("[quakeTerminal.customFrame]"))

        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded == export)
    }

    @Test func quakeCustomFrameIsOmittedWhenNil() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminalUseCustomFrame = false
        export.quakeTerminalCustomFrame = nil

        let data = try SettingsTOMLCodec.encode(export)
        let output = try #require(String(data: data, encoding: .utf8))
        #expect(output.contains("customFrame") == false)

        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.quakeTerminalCustomFrame == nil)
    }

    @Test func roundTripsWorkspaceWithMainMonitorAssignment() throws {
        var export = SettingsExport.defaults()
        export.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri)
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.workspaceConfigurations == export.workspaceConfigurations)
    }

    @Test func roundTripsWorkspaceWithSecondaryMonitorAssignment() throws {
        var export = SettingsExport.defaults()
        export.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .secondary, layoutType: .dwindle)
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.workspaceConfigurations == export.workspaceConfigurations)
    }

    @Test func roundTripsWorkspaceWithSpecificDisplayAssignment() throws {
        var export = SettingsExport.defaults()
        let output = OutputId(displayId: 42, name: "Studio Display")
        export.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "2",
                displayName: "Code",
                monitorAssignment: .specificDisplay(output),
                layoutType: .niri
            )
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.workspaceConfigurations == export.workspaceConfigurations)
    }

    @Test func roundTripsNonEmptyMouseWarpMonitorOrder() throws {
        var export = SettingsExport.defaults()
        export.mouseWarpMonitorOrder = [
            OutputId(displayId: 11, name: "Studio Display"),
            OutputId(displayId: 22, name: "LG UltraFine")
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)

        #expect(decoded.mouseWarpMonitorOrder == export.mouseWarpMonitorOrder)
    }

    @Test func roundTripsAppRulesWithMixedOptionalFields() throws {
        var export = SettingsExport.defaults()
        export.appRules = [
            AppRule(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                bundleId: "com.example.full",
                appNameSubstring: "Example",
                titleSubstring: "Main",
                titleRegex: "^Main.*$",
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                manage: .auto,
                layout: .tile,
                assignToWorkspace: "1",
                minWidth: 400,
                minHeight: 300
            ),
            AppRule(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                bundleId: "com.example.minimal"
            )
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.appRules == export.appRules)
    }

    @Test func roundTripsAllMonitorOverrideArrays() throws {
        var export = SettingsExport.defaults()
        export.monitorBarSettings = [
            MonitorBarSettings(
                monitorName: "Display A",
                monitorDisplayId: 1,
                enabled: false,
                height: 30
            )
        ]
        export.monitorOrientationSettings = [
            MonitorOrientationSettings(
                monitorName: "Display B",
                monitorDisplayId: 2,
                orientation: .vertical
            )
        ]
        export.monitorNiriSettings = [
            MonitorNiriSettings(
                monitorName: "Display C",
                monitorDisplayId: 3,
                maxVisibleColumns: 4
            )
        ]
        export.monitorDwindleSettings = [
            MonitorDwindleSettings(
                monitorName: "Display D",
                monitorDisplayId: 4,
                smartSplit: true,
                defaultSplitRatio: 0.75
            )
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.monitorBarSettings == export.monitorBarSettings)
        #expect(decoded.monitorOrientationSettings == export.monitorOrientationSettings)
        #expect(decoded.monitorNiriSettings == export.monitorNiriSettings)
        #expect(decoded.monitorDwindleSettings == export.monitorDwindleSettings)
    }

    @Test func roundTripsNestedColorQuartets() throws {
        var export = SettingsExport.defaults()
        export.borderColorRed = 0.1
        export.borderColorGreen = 0.2
        export.borderColorBlue = 0.3
        export.borderColorAlpha = 0.4
        export.workspaceBarAccentColorRed = 0.5
        export.workspaceBarAccentColorGreen = 0.6
        export.workspaceBarAccentColorBlue = 0.7
        export.workspaceBarAccentColorAlpha = 0.8
        export.workspaceBarTextColorRed = 0.9
        export.workspaceBarTextColorGreen = 1.0
        export.workspaceBarTextColorBlue = 0.0
        export.workspaceBarTextColorAlpha = 0.25

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.borderColorRed == export.borderColorRed)
        #expect(decoded.borderColorGreen == export.borderColorGreen)
        #expect(decoded.borderColorBlue == export.borderColorBlue)
        #expect(decoded.borderColorAlpha == export.borderColorAlpha)
        #expect(decoded.workspaceBarAccentColorRed == export.workspaceBarAccentColorRed)
        #expect(decoded.workspaceBarTextColorBlue == export.workspaceBarTextColorBlue)
    }

    @Test func roundTripsOuterGaps() throws {
        var export = SettingsExport.defaults()
        export.outerGapLeft = 12
        export.outerGapRight = 14
        export.outerGapTop = 16
        export.outerGapBottom = 18

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.outerGapLeft == 12)
        #expect(decoded.outerGapRight == 14)
        #expect(decoded.outerGapTop == 16)
        #expect(decoded.outerGapBottom == 18)
    }

    @Test func roundTripsHumanReadableHotkeyBindings() throws {
        let export = SettingsExport.defaults()
        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.hotkeyBindings == export.hotkeyBindings)
    }

    @Test func preservesNilColumnWidthPresetsDistinctFromEmptyArray() throws {
        var exportWithNil = SettingsExport.defaults()
        exportWithNil.niriColumnWidthPresets = nil
        let dataNil = try SettingsTOMLCodec.encode(exportWithNil)
        let decodedNil = try SettingsTOMLCodec.decode(dataNil)
        #expect(decodedNil.niriColumnWidthPresets == nil)

        var exportEmpty = SettingsExport.defaults()
        exportEmpty.niriColumnWidthPresets = []
        let dataEmpty = try SettingsTOMLCodec.encode(exportEmpty)
        let decodedEmpty = try SettingsTOMLCodec.decode(dataEmpty)
        #expect(decodedEmpty.niriColumnWidthPresets == [])
    }

    @Test func preservesNilOptionalScalarsInQuakeTerminalAndMouseWarp() throws {
        var export = SettingsExport.defaults()
        export.mouseWarpAxis = nil
        export.quakeTerminalOpacity = nil
        export.quakeTerminalMonitorMode = nil
        export.niriDefaultColumnWidth = nil

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.mouseWarpAxis == nil)
        #expect(decoded.quakeTerminalOpacity == nil)
        #expect(decoded.quakeTerminalMonitorMode == nil)
        #expect(decoded.niriDefaultColumnWidth == nil)
    }

    @Test func topLevelVersionPrecedesAllTables() throws {
        let data = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        let output = try #require(String(data: data, encoding: .utf8))



        let versionRange = try #require(output.range(of: "version"))
        let firstTableRange = try #require(output.range(of: "[general]"))
        #expect(versionRange.lowerBound < firstTableRange.lowerBound)
    }

    @Test func canonicalDefaultsMatchGoldenFixture() throws {
        let bundle = Bundle.module
        guard let fixtureURL = bundle.url(forResource: "canonical-settings", withExtension: "toml") else {
            Issue.record("Golden fixture canonical-settings.toml is missing from test resources")
            return
        }

        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        let data = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        let actual = try #require(String(data: data, encoding: .utf8))

        if expected != actual {
            let diffURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("canonical-settings.actual.toml")
            try? actual.write(to: diffURL, atomically: true, encoding: .utf8)
            let message = "Canonical TOML output drifted from fixture. Expected length \(expected.count), got \(actual.count). Actual written to \(diffURL.path) for inspection."
            Issue.record(Comment(rawValue: message))
        }
    }
}
