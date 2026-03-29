import AppKit
import CoreGraphics
import ApplicationServices
import Carbon
import Foundation
import Testing

@testable import OmniWM

private func makeTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeTestSettingsURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-settings-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("settings-\(UUID().uuidString).json")
}

private func makeSettingsTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

@Suite struct MonitorSettingsStoreTests {

    @Test func loadReturnsEmptyForMissingData() {
        let defaults = makeTestDefaults()
        let result: [MonitorBarSettings] = MonitorSettingsStore.load(from: defaults, key: "nonexistent")
        #expect(result.isEmpty)
    }

    @Test func loadReturnsEmptyForCorruptData() {
        let defaults = makeTestDefaults()
        defaults.set(Data("not json".utf8), forKey: "corrupt")
        let result: [MonitorBarSettings] = MonitorSettingsStore.load(from: defaults, key: "corrupt")
        #expect(result.isEmpty)
    }

    @Test func getReturnsNilForUnknownMonitor() {
        let settings = [MonitorNiriSettings(monitorName: "Monitor A")]
        let result = MonitorSettingsStore.get(for: "Monitor B", in: settings)
        #expect(result == nil)
    }

    @Test func updateReplacesExistingAtSameIndex() {
        var settings = [
            MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 2),
            MonitorNiriSettings(monitorName: "B", maxVisibleColumns: 3),
        ]
        let updated = MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 5)
        MonitorSettingsStore.update(updated, in: &settings)
        #expect(settings.count == 2)
        #expect(settings[0].monitorName == "A")
        #expect(settings[0].maxVisibleColumns == 5)
        #expect(settings[1].monitorName == "B")
    }

    @Test func updateAppendsWhenNotFound() {
        var settings = [MonitorNiriSettings(monitorName: "A")]
        let newItem = MonitorNiriSettings(monitorName: "B", maxVisibleColumns: 4)
        MonitorSettingsStore.update(newItem, in: &settings)
        #expect(settings.count == 2)
        #expect(settings[1].monitorName == "B")
        #expect(settings[1].maxVisibleColumns == 4)
    }

    @Test func removeDeletesAllMatches() {
        var settings = [
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "B"),
        ]
        MonitorSettingsStore.remove(for: "A", from: &settings)
        #expect(settings.count == 1)
        #expect(settings[0].monitorName == "B")
    }

    @Test func roundTripSaveLoad() {
        let defaults = makeTestDefaults()
        let key = "test.settings"
        let original = [
            MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 3, centerFocusedColumn: .always),
            MonitorNiriSettings(monitorName: "B", infiniteLoop: true),
        ]
        MonitorSettingsStore.save(original, to: defaults, key: key)
        let loaded: [MonitorNiriSettings] = MonitorSettingsStore.load(from: defaults, key: key)
        #expect(loaded == original)
    }

    @Test func duplicateMonitorNameOnLoad() {
        let defaults = makeTestDefaults()
        let key = "test.dupes"
        let dupes = [
            MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 1),
            MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 2),
        ]
        let data = try! JSONEncoder().encode(dupes)
        defaults.set(data, forKey: key)
        let loaded: [MonitorNiriSettings] = MonitorSettingsStore.load(from: defaults, key: key)
        #expect(loaded.count == 2)
        #expect(loaded[0].maxVisibleColumns == 1)
        #expect(loaded[1].maxVisibleColumns == 2)
    }

    @Test func monitorLookupPrefersDisplayIdOverNameFallback() {
        let monitor = makeSettingsTestMonitor(displayId: 42, name: "Studio Display")
        let settings = [
            MonitorNiriSettings(monitorName: "Studio Display", maxVisibleColumns: 1),
            MonitorNiriSettings(monitorName: "Studio Display", monitorDisplayId: 42, maxVisibleColumns: 3),
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.maxVisibleColumns == 3)
    }

    @Test func monitorLookupFallsBackToLegacyNameWhenDisplayIdMissing() {
        let monitor = makeSettingsTestMonitor(displayId: 99, name: "Legacy")
        let settings = [
            MonitorNiriSettings(monitorName: "Legacy", maxVisibleColumns: 2),
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.maxVisibleColumns == 2)
    }

    @Test func updateMigratesLegacyNameEntryToDisplayIdEntry() {
        var settings = [
            MonitorNiriSettings(monitorName: "Studio Display", maxVisibleColumns: 1)
        ]

        let updated = MonitorNiriSettings(
            monitorName: "Studio Display",
            monitorDisplayId: 77,
            maxVisibleColumns: 4
        )
        MonitorSettingsStore.update(updated, in: &settings)

        #expect(settings.count == 1)
        #expect(settings[0].monitorDisplayId == 77)
        #expect(settings[0].maxVisibleColumns == 4)
    }
}

@Suite struct CodableBackwardCompatTests {

    @Test func monitorNiriDecodesLegacyStringFields() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "centerFocusedColumn": "always",
            "singleWindowAspectRatio": "4:3"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorNiriSettings.self, from: Data(json.utf8))
        #expect(decoded.centerFocusedColumn == .always)
        #expect(decoded.singleWindowAspectRatio == .ratio4x3)
    }

    @Test func monitorNiriDecodesUnknownEnumAsNil() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "centerFocusedColumn": "futureValue",
            "singleWindowAspectRatio": "99:1"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorNiriSettings.self, from: Data(json.utf8))
        #expect(decoded.centerFocusedColumn == nil)
        #expect(decoded.singleWindowAspectRatio == nil)
    }

    @Test func monitorBarDecodesUnknownPositionAsNil() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "position": "unknownPosition",
            "windowLevel": "unknownLevel"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorBarSettings.self, from: Data(json.utf8))
        #expect(decoded.position == nil)
        #expect(decoded.windowLevel == nil)
    }

    @Test func monitorDwindleDecodesUnknownRatioAsNil() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "singleWindowAspectRatio": "unknownRatio"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorDwindleSettings.self, from: Data(json.utf8))
        #expect(decoded.singleWindowAspectRatio == nil)
    }

    @Test func monitorNiriEncodeDecodeRoundTrip() throws {
        let original = MonitorNiriSettings(
            monitorName: "Roundtrip",
            maxVisibleColumns: 4,
            maxWindowsPerColumn: 2,
            centerFocusedColumn: .onOverflow,
            alwaysCenterSingleColumn: false,
            singleWindowAspectRatio: .ratio16x9,
            infiniteLoop: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitorNiriSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func monitorBarEncodeDecodeRoundTrip() throws {
        let original = MonitorBarSettings(
            monitorName: "Roundtrip",
            enabled: true,
            showLabels: false,
            reserveLayoutSpace: true,
            position: .belowMenuBar,
            windowLevel: .status,
            height: 30
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitorBarSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func monitorDwindleEncodeDecodeRoundTrip() throws {
        let original = MonitorDwindleSettings(
            monitorName: "Roundtrip",
            smartSplit: true,
            singleWindowAspectRatio: .ratio21x9,
            useGlobalGaps: false,
            innerGap: 10
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitorDwindleSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func appRuleDecodesLegacyAlwaysFloatWithoutNewFields() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000031",
            "bundleId": "com.example.legacy",
            "alwaysFloat": true
        }
        """

        let decoded = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))

        #expect(decoded.bundleId == "com.example.legacy")
        #expect(decoded.alwaysFloat == true)
        #expect(decoded.manage == nil)
        #expect(decoded.layout == nil)
        #expect(decoded.effectiveLayoutAction == .float)
    }

    @Test func appRuleDecodesLegacyIgnoreRuleAsFloating() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000032",
            "bundleId": "com.example.advanced",
            "appNameSubstring": "Example",
            "titleSubstring": "Chooser",
            "titleRegex": "^Chooser$",
            "axRole": "AXWindow",
            "axSubrole": "AXStandardWindow",
            "manage": "off",
            "assignToWorkspace": "2",
            "minWidth": 800,
            "minHeight": 600
        }
        """

        let decoded = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))

        #expect(decoded.bundleId == "com.example.advanced")
        #expect(decoded.appNameSubstring == "Example")
        #expect(decoded.titleSubstring == "Chooser")
        #expect(decoded.titleRegex == "^Chooser$")
        #expect(decoded.axRole == kAXWindowRole as String)
        #expect(decoded.axSubrole == kAXStandardWindowSubrole as String)
        #expect(decoded.manage == nil)
        #expect(decoded.layout == .float)
        #expect(decoded.assignToWorkspace == "2")
        #expect(decoded.minWidth == 800)
        #expect(decoded.minHeight == 600)
    }

    @Test @MainActor func settingsStoreRewritesLegacyIgnoredAppRulesOnLoad() throws {
        let defaults = makeTestDefaults()
        let json = """
        [
            {
                "id": "00000000-0000-0000-0000-000000000033",
                "bundleId": "com.example.legacy-ignore",
                "manage": "off"
            }
        ]
        """
        defaults.set(Data(json.utf8), forKey: "settings.appRules")

        let settings = SettingsStore(defaults: defaults)
        let persisted = try #require(defaults.data(forKey: "settings.appRules"))
        let rewrittenRules = try JSONDecoder().decode([AppRule].self, from: persisted)

        #expect(settings.appRules.count == 1)
        #expect(settings.appRules[0].bundleId == "com.example.legacy-ignore")
        #expect(settings.appRules[0].manage == nil)
        #expect(settings.appRules[0].layout == .float)
        #expect(rewrittenRules.count == 1)
        #expect(rewrittenRules[0].manage == nil)
        #expect(rewrittenRules[0].layout == .float)
    }
}

@Suite struct SettingsExportTests {

    @Test func defaultsReflectPromotedBuiltInValues() {
        let defaults = SettingsExport.defaults()

        #expect(defaults.mouseWarpAxis == MouseWarpAxis.horizontal.rawValue)
        #expect(defaults.mouseWarpMargin == 1)
        #expect(defaults.niriColumnWidthPresets == BuiltInSettingsDefaults.niriColumnWidthPresets)
        #expect(defaults.outerGapLeft == 8)
        #expect(defaults.outerGapRight == 8)
        #expect(defaults.outerGapTop == 8)
        #expect(defaults.outerGapBottom == 8)
        #expect(defaults.workspaceConfigurations == BuiltInSettingsDefaults.workspaceConfigurations)
        #expect(defaults.bordersEnabled == true)
        #expect(defaults.borderWidth == 5.0)
        #expect(defaults.borderColorRed == 0.084585202284378935)
        #expect(defaults.borderColorGreen == 1.0)
        #expect(defaults.borderColorBlue == 0.97930003794467602)
        #expect(defaults.hotkeyBindings == HotkeyBindingRegistry.defaults())
        #expect(defaults.workspaceBarEnabled == true)
        #expect(defaults.workspaceBarNotchAware == true)
        #expect(defaults.workspaceBarReserveLayoutSpace == false)
        #expect(defaults.appRules == BuiltInSettingsDefaults.appRules)
        #expect(defaults.preventSleepEnabled == false)
        #expect(defaults.ipcEnabled == false)
        #expect(defaults.scrollSensitivity == 5.0)
        #expect(defaults.statusBarShowWorkspaceName == false)
        #expect(defaults.statusBarShowAppNames == false)
        #expect(defaults.statusBarUseWorkspaceId == false)
        #expect(defaults.hiddenBarIsCollapsed == true)
        #expect(defaults.quakeTerminalEnabled == true)
        #expect(defaults.quakeTerminalPosition == QuakeTerminalPosition.center.rawValue)
        #expect(defaults.quakeTerminalWidthPercent == 50.0)
        #expect(defaults.quakeTerminalHeightPercent == 50.0)
        #expect(defaults.quakeTerminalAutoHide == false)
        #expect(defaults.quakeTerminalMonitorMode == QuakeTerminalMonitorMode.focusedWindow.rawValue)
        #expect(defaults.quakeTerminalUseCustomFrame == false)
        #expect(defaults.quakeTerminalCustomFrame == nil)
        #expect(defaults.appearanceMode == AppearanceMode.dark.rawValue)
    }

    @Test func settingsExportDecodesUnknownEnumStrings() throws {
        let json = """
        {
            "version": \(SettingsMigration.currentSettingsEpoch),
            "hotkeysEnabled": true,
            "focusFollowsMouse": false,
            "moveMouseToFocusedWindow": false,
            "focusFollowsWindowToMonitor": false,
            "mouseWarpMonitorOrder": [],
            "mouseWarpAxis": "futureAxis",
            "mouseWarpMargin": 2,
            "gapSize": 8,
            "outerGapLeft": 0,
            "outerGapRight": 0,
            "outerGapTop": 0,
            "outerGapBottom": 0,
            "niriMaxWindowsPerColumn": 3,
            "niriMaxVisibleColumns": 2,
            "niriInfiniteLoop": false,
            "niriCenterFocusedColumn": "futureUnknownValue",
            "niriAlwaysCenterSingleColumn": true,
            "niriSingleWindowAspectRatio": "futureRatio",
            "workspaceConfigurations": [],
            "defaultLayoutType": "futureLayout",
            "bordersEnabled": false,
            "borderWidth": 4,
            "borderColorRed": 0,
            "borderColorGreen": 0.5,
            "borderColorBlue": 1,
            "borderColorAlpha": 1,
            "hotkeyBindings": [],
            "workspaceBarEnabled": false,
            "workspaceBarShowLabels": true,
            "workspaceBarWindowLevel": "futureLevel",
            "workspaceBarPosition": "futurePosition",
            "workspaceBarNotchAware": false,
            "workspaceBarDeduplicateAppIcons": false,
            "workspaceBarHideEmptyWorkspaces": false,
            "workspaceBarReserveLayoutSpace": false,
            "workspaceBarHeight": 24,
            "workspaceBarBackgroundOpacity": 0.1,
            "workspaceBarXOffset": 0,
            "workspaceBarYOffset": 0,
            "monitorBarSettings": [],
            "appRules": [],
            "monitorOrientationSettings": [],
            "monitorNiriSettings": [],
            "dwindleSmartSplit": false,
            "dwindleDefaultSplitRatio": 1,
            "dwindleSplitWidthMultiplier": 1,
            "dwindleSingleWindowAspectRatio": "futureRatio",
            "dwindleUseGlobalGaps": true,
            "dwindleMoveToRootStable": true,
            "monitorDwindleSettings": [],
            "preventSleepEnabled": false,
            "ipcEnabled": true,
            "scrollGestureEnabled": true,
            "scrollSensitivity": 1,
            "scrollModifierKey": "futureModifier",
            "gestureFingerCount": 99,
            "gestureInvertDirection": true,
            "statusBarShowWorkspaceName": true,
            "statusBarShowAppNames": true,
            "statusBarUseWorkspaceId": true,
            "commandPaletteLastMode": "futurePaletteMode",
            "animationsEnabled": true,
            "hiddenBarIsCollapsed": false,
            "quakeTerminalEnabled": false,
            "quakeTerminalPosition": "futurePosition",
            "quakeTerminalWidthPercent": 75,
            "quakeTerminalHeightPercent": 50,
            "quakeTerminalAnimationDuration": 0.4,
            "quakeTerminalAutoHide": true,
            "quakeTerminalOpacity": 0.8,
            "quakeTerminalMonitorMode": "futureMonitorMode",
            "quakeTerminalUseCustomFrame": false,
            "appearanceMode": "futureMode"
        }
        """
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: Data(json.utf8))
        #expect(decoded.mouseWarpAxis == "futureAxis")
        #expect(decoded.niriCenterFocusedColumn == "futureUnknownValue")
        #expect(decoded.workspaceBarPosition == "futurePosition")
        #expect(decoded.scrollModifierKey == "futureModifier")
        #expect(decoded.commandPaletteLastMode == "futurePaletteMode")
        #expect(decoded.quakeTerminalPosition == "futurePosition")
        #expect(decoded.quakeTerminalMonitorMode == "futureMonitorMode")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let export = SettingsExport(
            hotkeysEnabled: true,
            focusFollowsMouse: true,
            moveMouseToFocusedWindow: true,
            focusFollowsWindowToMonitor: true,
            mouseWarpMonitorOrder: ["Monitor1", "Monitor2"],
            mouseWarpAxis: MouseWarpAxis.vertical.rawValue,
            mouseWarpMargin: 5,
            gapSize: 12.0,
            outerGapLeft: 2.0,
            outerGapRight: 3.0,
            outerGapTop: 4.0,
            outerGapBottom: 5.0,
            niriMaxWindowsPerColumn: 4,
            niriMaxVisibleColumns: 3,
            niriInfiniteLoop: true,
            niriCenterFocusedColumn: "always",
            niriAlwaysCenterSingleColumn: true,
            niriSingleWindowAspectRatio: "16:9",
            niriColumnWidthPresets: [0.85, 0.5, 0.85, 1.0],
            niriDefaultColumnWidth: 0.6,
            workspaceConfigurations: [],
            defaultLayoutType: "niri",
            bordersEnabled: true,
            borderWidth: 3.0,
            borderColorRed: 0.2,
            borderColorGreen: 0.4,
            borderColorBlue: 0.8,
            borderColorAlpha: 0.9,
            hotkeyBindings: [],
            workspaceBarEnabled: true,
            workspaceBarShowLabels: false,
            workspaceBarWindowLevel: "status",
            workspaceBarPosition: "belowMenuBar",
            workspaceBarNotchAware: true,
            workspaceBarDeduplicateAppIcons: true,
            workspaceBarHideEmptyWorkspaces: true,
            workspaceBarReserveLayoutSpace: true,
            workspaceBarHeight: 30.0,
            workspaceBarBackgroundOpacity: 0.5,
            workspaceBarXOffset: 10.0,
            workspaceBarYOffset: 20.0,
            monitorBarSettings: [MonitorBarSettings(monitorName: "TestBar", enabled: true, reserveLayoutSpace: true)],
            appRules: [],
            monitorOrientationSettings: [],
            monitorNiriSettings: [MonitorNiriSettings(monitorName: "TestNiri", maxVisibleColumns: 3)],
            dwindleSmartSplit: true,
            dwindleDefaultSplitRatio: 0.6,
            dwindleSplitWidthMultiplier: 1.5,
            dwindleSingleWindowAspectRatio: "21:9",
            dwindleUseGlobalGaps: false,
            dwindleMoveToRootStable: false,
            monitorDwindleSettings: [MonitorDwindleSettings(monitorName: "TestDwindle", smartSplit: true)],
            preventSleepEnabled: true,
            ipcEnabled: true,
            scrollGestureEnabled: false,
            scrollSensitivity: 2.0,
            scrollModifierKey: "option",
            gestureFingerCount: 4,
            gestureInvertDirection: true,
            statusBarShowWorkspaceName: true,
            statusBarShowAppNames: true,
            statusBarUseWorkspaceId: true,
            commandPaletteLastMode: "menu",
            hiddenBarIsCollapsed: true,
            quakeTerminalEnabled: true,
            quakeTerminalPosition: "bottom",
            quakeTerminalWidthPercent: 80,
            quakeTerminalHeightPercent: 55,
            quakeTerminalAnimationDuration: 0.4,
            quakeTerminalAutoHide: false,
            quakeTerminalOpacity: 0.85,
            quakeTerminalMonitorMode: "focusedWindow",
            quakeTerminalUseCustomFrame: true,
            quakeTerminalCustomFrame: QuakeTerminalFrameExport(x: 10, y: 20, width: 1200, height: 700),
            appearanceMode: "dark"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data1 = try encoder.encode(export)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: data1)
        let data2 = try encoder.encode(decoded)
        #expect(data1 == data2)
    }

    @Test func fullExportByDefaultIncludesCanonicalHotkeyBindings() throws {
        let data = try SettingsExport.defaults().exportData()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected full export to produce a JSON object")
            return
        }

        guard let hotkeyBindings = json["hotkeyBindings"] as? [[String: Any]] else {
            Issue.record("Expected default export to include full hotkey bindings")
            return
        }

        #expect(hotkeyBindings.count == HotkeyBindingRegistry.defaults().count)
    }
}

@Suite @MainActor struct NiriColumnWidthPresetPersistenceTests {
    @Test func validatedPresetsPreserveOrderAndDuplicatesWhileClamping() {
        let presets = SettingsStore.validatedPresets([0.85, 0.02, 0.85, 1.2])

        #expect(presets == [0.85, 0.05, 0.85, 1.0])
    }

    @Test func validatedPresetsFallbackToDefaultsWhenTooShort() {
        let presets = SettingsStore.validatedPresets([0.85])

        #expect(presets == SettingsStore.defaultColumnWidthPresets)
    }

    @Test func settingsStoreLoadsOrderedDuplicatePresetsWithoutReordering() throws {
        let defaults = makeTestDefaults()
        let presets = [0.85, 0.02, 0.85, 1.2]
        defaults.set(try JSONEncoder().encode(presets), forKey: "settings.niriColumnWidthPresets")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.niriColumnWidthPresets == [0.85, 0.05, 0.85, 1.0])
    }

    @Test func settingsStoreRoundTripsOrderedDuplicatePresets() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.niriColumnWidthPresets = [0.85, 0.5, 0.85, 1.0]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.niriColumnWidthPresets == [0.85, 0.5, 0.85, 1.0])
    }

    @Test func validatedDefaultColumnWidthClampsAndSupportsAuto() {
        #expect(SettingsStore.validatedDefaultColumnWidth(nil) == nil)
        #expect(SettingsStore.validatedDefaultColumnWidth(0.02) == 0.05)
        #expect(SettingsStore.validatedDefaultColumnWidth(1.2) == 1.0)
    }

    @Test func settingsStoreLoadsClampedDefaultColumnWidth() {
        let defaults = makeTestDefaults()
        defaults.set(0.02, forKey: "settings.niriDefaultColumnWidth")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.niriDefaultColumnWidth == 0.05)
    }

    @Test func settingsStoreRoundTripsOptionalDefaultColumnWidth() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.niriDefaultColumnWidth = 0.85
        let reloadedCustom = SettingsStore(defaults: defaults)
        #expect(reloadedCustom.niriDefaultColumnWidth == 0.85)

        settings.niriDefaultColumnWidth = nil
        let reloadedAuto = SettingsStore(defaults: defaults)
        #expect(reloadedAuto.niriDefaultColumnWidth == nil)
    }
}

@Suite struct CompactSettingsExportTests {
    @Test func compactExportOmitsRemovedAnimationsKeyAndDefaultHotkeys() throws {
        var export = SettingsExport.defaults()
        export.hiddenBarIsCollapsed = false

        let data = try export.exportData(mode: .compact)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected compact export to produce a JSON object")
            return
        }

        #expect(json["animationsEnabled"] == nil)
        #expect((json["hiddenBarIsCollapsed"] as? Bool) == false)
        #expect(json["hotkeyBindings"] == nil)
    }

    @Test func compactExportIncludesReadableAdditionalPersistedSettings() throws {
        var export = SettingsExport.defaults()
        export.focusFollowsWindowToMonitor = true
        export.commandPaletteLastMode = CommandPaletteMode.menu.rawValue
        export.quakeTerminalPosition = QuakeTerminalPosition.bottom.rawValue
        export.quakeTerminalWidthPercent = 80
        export.quakeTerminalHeightPercent = 55
        export.quakeTerminalAnimationDuration = 0.4
        export.quakeTerminalAutoHide = true
        export.quakeTerminalUseCustomFrame = true
        export.quakeTerminalCustomFrame = QuakeTerminalFrameExport(x: 10, y: 20, width: 1200, height: 700)

        let data = try export.exportData(mode: .compact)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected compact export to produce a JSON object")
            return
        }

        #expect((json["focusFollowsWindowToMonitor"] as? Bool) == true)
        #expect(json["commandPaletteLastMode"] as? String == "menu")
        #expect(json["quakeTerminalEnabled"] == nil)
        #expect(json["quakeTerminalPosition"] as? String == "bottom")
        #expect((json["quakeTerminalWidthPercent"] as? NSNumber)?.doubleValue == 80)
        #expect((json["quakeTerminalHeightPercent"] as? NSNumber)?.doubleValue == 55)
        #expect((json["quakeTerminalAnimationDuration"] as? NSNumber)?.doubleValue == 0.4)
        #expect((json["quakeTerminalAutoHide"] as? Bool) == true)
        #expect((json["quakeTerminalUseCustomFrame"] as? Bool) == true)
        #expect(json["quakeTerminalCustomFrameX"] == nil)
        #expect(json["quakeTerminalCustomFrameY"] == nil)
        #expect(json["quakeTerminalCustomFrameWidth"] == nil)
        #expect(json["quakeTerminalCustomFrameHeight"] == nil)

        guard let frame = json["quakeTerminalCustomFrame"] as? [String: Any] else {
            Issue.record("Expected compact export to include a readable quakeTerminalCustomFrame object")
            return
        }
        #expect((frame["x"] as? NSNumber)?.doubleValue == 10)
        #expect((frame["y"] as? NSNumber)?.doubleValue == 20)
        #expect((frame["width"] as? NSNumber)?.doubleValue == 1200)
        #expect((frame["height"] as? NSNumber)?.doubleValue == 700)
    }

    @Test func compactExportOmitsPromotedWorkspaceAndRuleDefaults() throws {
        let data = try SettingsExport.defaults().exportData(mode: .compact)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected compact export to produce a JSON object")
            return
        }

        #expect(json["workspaceConfigurations"] == nil)
        #expect(json["appRules"] == nil)
        #expect(json["mouseWarpMonitorOrder"] == nil)
        #expect(json["quakeTerminalUseCustomFrame"] == nil)
        #expect(json["preventSleepEnabled"] == nil)
        #expect(json["ipcEnabled"] == nil)
    }

    @Test func fullExportOmitsRemovedMenuAnywhereKeys() throws {
        let export = SettingsExport.defaults()
        let data = try export.exportData(mode: .full)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected full export to produce a JSON object")
            return
        }

        #expect(json["menuAnywhereNativeEnabled"] == nil)
        #expect(json["menuAnywherePaletteEnabled"] == nil)
        #expect(json["menuAnywherePosition"] == nil)
        #expect(json["menuAnywhereShowShortcuts"] == nil)
    }

    @Test func mergedImportDataPreservesUnchangedHotkeysById() throws {
        let defaults = SettingsExport.defaults()
        guard defaults.hotkeyBindings.count >= 2 else {
            Issue.record("Expected at least two default hotkey bindings")
            return
        }

        var changed = defaults
        let updatedBinding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey) | UInt32(optionKey)
        )
        changed.hotkeyBindings[0].binding = updatedBinding

        let rawData = try changed.exportData(mode: .compact, defaults: defaults)
        let mergedData = try SettingsExport.mergedImportData(from: rawData, defaults: defaults)
        let merged = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(merged.hotkeyBindings[0].binding == updatedBinding)
        #expect(merged.hotkeyBindings[1].binding == defaults.hotkeyBindings[1].binding)
    }

    @Test func legacyAnimationsEnabledKeyIsIgnoredOnImportAndOmittedOnReexport() throws {
        let rawData = Data(
            """
            {
              "version": \(SettingsMigration.currentSettingsEpoch),
              "animationsEnabled": false,
              "hiddenBarIsCollapsed": true
            }
            """.utf8
        )

        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)
        #expect(decoded.hiddenBarIsCollapsed == true)

        let reexported = try decoded.exportData(mode: .full)
        guard let json = try JSONSerialization.jsonObject(with: reexported) as? [String: Any] else {
            Issue.record("Expected re-export to produce a JSON object")
            return
        }

        #expect(json["animationsEnabled"] == nil)
        #expect((json["hiddenBarIsCollapsed"] as? Bool) == true)
    }

    @Test func sameEpochLegacyWorkspaceKeysAreIgnoredOnImportAndDroppedOnReexport() throws {
        var export = SettingsExport.defaults()
        export.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let encoded = try SettingsExport.makeEncoder().encode(export)
        guard var json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("Expected encoded settings export to produce a JSON object")
            return
        }

        json["persistentWorkspacesRaw"] = "ws1,ws2"
        json["workspaceAssignmentsRaw"] = "ws1=Studio Display"

        let rawData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(decoded.workspaceConfigurations == export.workspaceConfigurations)

        let reexported = try decoded.exportData(mode: .full)
        guard let reexportedJSON = try JSONSerialization.jsonObject(with: reexported) as? [String: Any] else {
            Issue.record("Expected re-export to produce a JSON object")
            return
        }

        #expect(reexportedJSON["persistentWorkspacesRaw"] == nil)
        #expect(reexportedJSON["workspaceAssignmentsRaw"] == nil)
    }

    @Test func mergedImportDataBackfillsNewPersistedSettingsWithDefaults() throws {
        let rawData = Data(
            """
            {
              "version": \(SettingsMigration.currentSettingsEpoch),
              "hiddenBarIsCollapsed": true
            }
            """.utf8
        )

        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(decoded.hiddenBarIsCollapsed == true)
        #expect(decoded.mouseWarpAxis == MouseWarpAxis.horizontal.rawValue)
        #expect(decoded.focusFollowsWindowToMonitor == false)
        #expect(decoded.commandPaletteLastMode == CommandPaletteMode.windows.rawValue)
        #expect(decoded.workspaceBarEnabled == true)
        #expect(decoded.workspaceBarNotchAware == true)
        #expect(decoded.workspaceBarReserveLayoutSpace == false)
        #expect(decoded.workspaceConfigurations == BuiltInSettingsDefaults.workspaceConfigurations)
        #expect(decoded.appRules == BuiltInSettingsDefaults.appRules)
        #expect(decoded.preventSleepEnabled == false)
        #expect(decoded.ipcEnabled == false)
        #expect(decoded.hotkeyBindings == HotkeyBindingRegistry.defaults())
        #expect(decoded.quakeTerminalEnabled == true)
        #expect(decoded.quakeTerminalPosition == QuakeTerminalPosition.center.rawValue)
        #expect(decoded.quakeTerminalWidthPercent == 50.0)
        #expect(decoded.quakeTerminalHeightPercent == 50.0)
        #expect(decoded.quakeTerminalAnimationDuration == 0.2)
        #expect(decoded.quakeTerminalAutoHide == false)
        #expect(decoded.quakeTerminalUseCustomFrame == false)
        #expect(decoded.quakeTerminalCustomFrame == nil)
    }
}

@Suite @MainActor struct WorkspaceBarSettingsResolutionTests {
    @Test func monitorOverrideCanEnableReservedLayoutSpaceIndependently() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Reservation Test")

        settings.workspaceBarReserveLayoutSpace = false
        settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                reserveLayoutSpace: true
            )
        )

        #expect(settings.resolvedBarSettings(for: monitor).reserveLayoutSpace == true)
    }
}

@Suite struct KeyBindingCodecTests {
    @Test func humanReadableBindingsRoundTripAsStrings() throws {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey) | UInt32(optionKey)
        )

        let data = try JSONEncoder().encode(binding)
        let decodedJSON = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        #expect(decodedJSON as? String == "Control+Option+K")
        #expect(try JSONDecoder().decode(KeyBinding.self, from: data) == binding)
    }

    @Test func keypadBindingsUseReadableStringsAndDistinctCompactBadges() throws {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_Keypad1),
            modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        )

        let data = try JSONEncoder().encode(binding)
        let decodedJSON = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        #expect(binding.displayString == "⌃⌥⌘KP1")
        #expect(binding.humanReadableString == "Control+Option+Command+Keypad 1")
        #expect(decodedJSON as? String == "Control+Option+Command+Keypad 1")
        #expect(try JSONDecoder().decode(KeyBinding.self, from: data) == binding)
    }

    @Test func keypadActionKeysUseCanonicalReadableNames() {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_KeypadEnter),
            modifiers: UInt32(cmdKey)
        )

        #expect(binding.displayString == "⌘KPEnter")
        #expect(binding.humanReadableString == "Command+Keypad Enter")
        #expect(KeySymbolMapper.fromHumanReadable("Command+Keypad Enter") == binding)
    }

    @Test func unknownKeyCodesFallBackToLegacyNumericEncoding() throws {
        let binding = KeyBinding(keyCode: 200, modifiers: UInt32(controlKey))

        let data = try JSONEncoder().encode(binding)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected unknown key binding to encode as an object")
            return
        }

        #expect((json["keyCode"] as? NSNumber)?.uint32Value == 200)
        #expect((json["modifiers"] as? NSNumber)?.uint32Value == UInt32(controlKey))
        #expect(try JSONDecoder().decode(KeyBinding.self, from: data) == binding)
    }

    @Test func keypadDigitsRemainDistinctFromTopRowDigits() {
        let modifiers = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        let topRow = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers)
        let keypad = KeyBinding(keyCode: UInt32(kVK_ANSI_Keypad1), modifiers: modifiers)

        #expect(topRow != keypad)
        #expect(topRow.displayString == "⌃⌥⌘1")
        #expect(keypad.displayString == "⌃⌥⌘KP1")
        #expect(topRow.humanReadableString == "Control+Option+Command+1")
        #expect(keypad.humanReadableString == "Control+Option+Command+Keypad 1")
    }
}

@Suite struct HotkeySurfaceTests {
    @Test func moveIsTheOnlyDirectionalWindowCommandFamily() {
        let ids = Set(HotkeyBindingRegistry.defaults().map(\.id))

        #expect(ids.contains("move.left"))
        #expect(ids.contains("move.right"))
        #expect(ids.contains("move.up"))
        #expect(ids.contains("move.down"))
        #expect(!ids.contains("swap.left"))
        #expect(!ids.contains("consumeWindow.left"))
        #expect(!ids.contains("expelWindow.left"))
        #expect(ids.contains("openCommandPalette"))
        #expect(!ids.contains("openWindowFinder"))
        #expect(!ids.contains("openMenuPalette"))
        #expect(HotkeyCommand.move(.left).layoutCompatibility == .shared)
    }

    @Test func removedDirectionalMonitorBindingsAreAbsent() {
        let ids = Set(HotkeyBindingRegistry.defaults().map(\.id))

        #expect(!ids.contains("moveToMonitor.left"))
        #expect(!ids.contains("moveToMonitor.right"))
        #expect(!ids.contains("moveToMonitor.up"))
        #expect(!ids.contains("moveToMonitor.down"))
        #expect(!ids.contains("focusMonitor.left"))
        #expect(!ids.contains("focusMonitor.right"))
        #expect(!ids.contains("focusMonitor.up"))
        #expect(!ids.contains("focusMonitor.down"))
        #expect(!ids.contains("moveColumnToMonitor.left"))
        #expect(!ids.contains("moveColumnToMonitor.right"))
        #expect(!ids.contains("moveColumnToMonitor.up"))
        #expect(!ids.contains("moveColumnToMonitor.down"))
        #expect(!ids.contains("moveWorkspaceToMonitor.left"))
        #expect(!ids.contains("moveWorkspaceToMonitor.right"))
        #expect(!ids.contains("moveWorkspaceToMonitor.up"))
        #expect(!ids.contains("moveWorkspaceToMonitor.down"))
        #expect(!ids.contains("moveWorkspaceToMonitor.next"))
        #expect(!ids.contains("moveWorkspaceToMonitor.previous"))
        #expect(!ids.contains("focusWindowTop"))
        #expect(!ids.contains("focusWindowBottom"))
        #expect(!ids.contains("summonWorkspace.0"))
        #expect(!ids.contains("summonWorkspace.1"))
        #expect(!ids.contains("summonWorkspace.2"))
        #expect(!ids.contains("summonWorkspace.3"))
        #expect(!ids.contains("summonWorkspace.4"))
        #expect(!ids.contains("summonWorkspace.5"))
        #expect(!ids.contains("summonWorkspace.6"))
        #expect(!ids.contains("summonWorkspace.7"))
        #expect(!ids.contains("summonWorkspace.8"))
        #expect(ids.contains("focusMonitorNext"))
        #expect(ids.contains("focusMonitorLast"))
    }

    @Test func hotkeyBindingEncodesWithoutSerializedCommand() throws {
        let binding = HotkeyBinding(id: "move.left", command: .move(.left), binding: .unassigned)
        let data = try JSONEncoder().encode(binding)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected hotkey binding to encode as an object")
            return
        }

        #expect(json["id"] as? String == "move.left")
        #expect(json["command"] == nil)
        #expect(json["binding"] != nil)
    }
}

@Suite @MainActor struct HotkeyBindingPersistenceTests {
    @Test func settingsStoreSalvagesValidBindingsAndDropsUnknownRows() throws {
        let defaults = makeTestDefaults()
        let rawData = Data(
            """
            [
              { "id": "move.left", "binding": "Control+Option+K", "command": { "focusPrevious": {} } },
              { "id": "unknown.binding", "binding": "Option+L" },
              { "id": 42, "binding": "Option+J" }
            ]
            """.utf8
        )
        defaults.set(rawData, forKey: "settings.hotkeyBindings")

        let settings = SettingsStore(defaults: defaults)
        let moveLeft = settings.hotkeyBindings.first { $0.id == "move.left" }
        let moveRight = settings.hotkeyBindings.first { $0.id == "move.right" }

        #expect(moveLeft?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey)
        ))
        #expect(moveRight?.binding == KeyBinding(
            keyCode: UInt32(kVK_RightArrow),
            modifiers: UInt32(optionKey | shiftKey)
        ))
        #expect(settings.hotkeyBindings.map(\.id) == HotkeyBindingRegistry.defaults().map(\.id))
    }

    @Test func mergedImportDataCanonicalizesBindingsById() throws {
        let rawData = Data(
            """
            {
              "version": \(SettingsMigration.currentSettingsEpoch),
              "hotkeyBindings": [
                { "id": "move.left", "binding": "Control+Option+J", "command": { "focusPrevious": {} } },
                { "id": "unknown.binding", "binding": "Option+L" },
                { "id": "move.left", "binding": "Control+Option+K" }
              ]
            }
            """.utf8
        )

        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(decoded.hotkeyBindings.map(\.id) == HotkeyBindingRegistry.defaults().map(\.id))
        #expect(decoded.hotkeyBindings.first { $0.id == "move.left" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey)
        ))
        #expect(decoded.hotkeyBindings.first { $0.id == "move.right" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_RightArrow),
            modifiers: UInt32(optionKey | shiftKey)
        ))
    }

    @Test func settingsStoreDropsRemovedDirectionalBindingsWithoutTouchingValidOnes() throws {
        let defaults = makeTestDefaults()
        let rawData = Data(
            """
            [
              { "id": "moveToMonitor.left", "binding": "Control+Option+Left" },
              { "id": "focusWindowTop", "binding": "Option+Shift+Home" },
              { "id": "move.left", "binding": "Control+Option+K" }
            ]
            """.utf8
        )
        defaults.set(rawData, forKey: "settings.hotkeyBindings")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey)
        ))
        #expect(settings.hotkeyBindings.contains { $0.id == "moveToMonitor.left" } == false)
        #expect(settings.hotkeyBindings.contains { $0.id == "focusWindowTop" } == false)
    }

    @Test func mergedImportDataDropsRemovedDirectionalBindingsWithoutTouchingValidOnes() throws {
        let rawData = Data(
            """
            {
              "version": \(SettingsMigration.currentSettingsEpoch),
              "hotkeyBindings": [
                { "id": "moveWorkspaceToMonitor.left", "binding": "Option+Shift+M" },
                { "id": "focusMonitor.left", "binding": "Control+Command+Left" },
                { "id": "move.left", "binding": "Control+Option+K" }
              ]
            }
            """.utf8
        )

        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(decoded.hotkeyBindings.first { $0.id == "move.left" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey)
        ))
        #expect(decoded.hotkeyBindings.contains { $0.id == "moveWorkspaceToMonitor.left" } == false)
        #expect(decoded.hotkeyBindings.contains { $0.id == "focusMonitor.left" } == false)
    }

    @Test func settingsStoreDropsRemovedRelativeMonitorMoveAndSummonBindings() throws {
        let defaults = makeTestDefaults()
        let rawData = Data(
            """
            [
              { "id": "moveWorkspaceToMonitor.next", "binding": "Control+Option+N" },
              { "id": "moveWorkspaceToMonitor.previous", "binding": "Control+Option+P" },
              { "id": "summonWorkspace.0", "binding": "Control+Shift+1" },
              { "id": "move.left", "binding": "Control+Option+K" }
            ]
            """.utf8
        )
        defaults.set(rawData, forKey: "settings.hotkeyBindings")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey)
        ))
        #expect(settings.hotkeyBindings.contains { $0.id == "moveWorkspaceToMonitor.next" } == false)
        #expect(settings.hotkeyBindings.contains { $0.id == "moveWorkspaceToMonitor.previous" } == false)
        #expect(settings.hotkeyBindings.contains { $0.id == "summonWorkspace.0" } == false)
    }

    @Test func mergedImportDataDropsRemovedRelativeMonitorMoveAndSummonBindings() throws {
        let rawData = Data(
            """
            {
              "version": \(SettingsMigration.currentSettingsEpoch),
              "hotkeyBindings": [
                { "id": "moveWorkspaceToMonitor.next", "binding": "Control+Option+N" },
                { "id": "moveWorkspaceToMonitor.previous", "binding": "Control+Option+P" },
                { "id": "summonWorkspace.8", "binding": "Control+Shift+9" },
                { "id": "move.left", "binding": "Control+Option+K" }
              ]
            }
            """.utf8
        )

        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(decoded.hotkeyBindings.first { $0.id == "move.left" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey)
        ))
        #expect(decoded.hotkeyBindings.contains { $0.id == "moveWorkspaceToMonitor.next" } == false)
        #expect(decoded.hotkeyBindings.contains { $0.id == "moveWorkspaceToMonitor.previous" } == false)
        #expect(decoded.hotkeyBindings.contains { $0.id == "summonWorkspace.8" } == false)
    }

    @Test func settingsStoreMigratesLegacyWindowFinderBindingToCommandPalette() {
        let defaults = makeTestDefaults()
        let rawData = Data(
            """
            [
              { "id": "openWindowFinder", "binding": "Control+Option+Space" }
            ]
            """.utf8
        )
        defaults.set(rawData, forKey: "settings.hotkeyBindings")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.hotkeyBindings.first { $0.id == "openCommandPalette" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey)
        ))
    }

    @Test func settingsStoreUsesLegacyMenuPaletteBindingWhenWindowFinderBindingIsMissing() {
        let defaults = makeTestDefaults()
        let rawData = Data(
            """
            [
              { "id": "openMenuPalette", "binding": "Control+Option+Shift+M" }
            ]
            """.utf8
        )
        defaults.set(rawData, forKey: "settings.hotkeyBindings")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.hotkeyBindings.first { $0.id == "openCommandPalette" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(controlKey | optionKey | shiftKey)
        ))
    }

    @Test func explicitCommandPaletteBindingWinsOverLegacyBindings() {
        let defaults = makeTestDefaults()
        let rawData = Data(
            """
            [
              { "id": "openCommandPalette", "binding": "Control+Option+P" },
              { "id": "openWindowFinder", "binding": "Control+Option+Space" },
              { "id": "openMenuPalette", "binding": "Control+Option+Shift+M" }
            ]
            """.utf8
        )
        defaults.set(rawData, forKey: "settings.hotkeyBindings")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.hotkeyBindings.first { $0.id == "openCommandPalette" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey)
        ))
    }

    @Test func mergedImportDataCanonicalizesLegacyCommandPaletteBindings() throws {
        let rawData = Data(
            """
            {
              "version": \(SettingsMigration.currentSettingsEpoch),
              "hotkeyBindings": [
                { "id": "openMenuPalette", "binding": "Control+Option+Shift+M" },
                { "id": "openWindowFinder", "binding": "Control+Option+Space" }
              ]
            }
            """.utf8
        )

        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(decoded.hotkeyBindings.first { $0.id == "openCommandPalette" }?.binding == KeyBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey)
        ))
    }
}

@Suite @MainActor struct CommandPaletteSettingsTests {
    @Test func commandPaletteLastModeDefaultsToWindowsAndPersists() {
        let defaults = makeTestDefaults()

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.commandPaletteLastMode == .windows)

        settings.commandPaletteLastMode = .menu

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.commandPaletteLastMode == .menu)
    }

    @Test func menuStatusHelpersDoNotMentionSettings() {
        #expect(CommandPaletteController.menuModeAvailable(hasMenuFocusTarget: true) == true)
        #expect(CommandPaletteController.menuModeAvailable(hasMenuFocusTarget: false) == false)
        #expect(CommandPaletteController.availableMenuStatusText(for: "Safari") == "Searching menus in Safari")
        #expect(CommandPaletteController.availableMenuStatusText(for: nil) == "Searching menus in Current App")
        #expect(CommandPaletteController.unavailableMenuStatusText == "Open the palette while another app is frontmost to search its menus.")
    }
}

@Suite @MainActor struct SettingsStoreFileRoundTripTests {
    @Test func exportAndImportRoundTripNewlyCoveredPersistedState() throws {
        let exportURL = makeTestSettingsURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.focusFollowsWindowToMonitor = true
        settings.mouseWarpAxis = .vertical
        settings.statusBarShowWorkspaceName = true
        settings.statusBarShowAppNames = true
        settings.statusBarUseWorkspaceId = true
        settings.commandPaletteLastMode = .menu
        settings.quakeTerminalEnabled = true
        settings.quakeTerminalPosition = .bottom
        settings.quakeTerminalWidthPercent = 80
        settings.quakeTerminalHeightPercent = 55
        settings.quakeTerminalAnimationDuration = 0.4
        settings.quakeTerminalAutoHide = false
        settings.quakeTerminalOpacity = 0.75
        settings.quakeTerminalMonitorMode = .focusedWindow
        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = CGRect(x: 10, y: 20, width: 1200, height: 700)

        try settings.exportSettings(to: exportURL, mode: .full)

        let imported = SettingsStore(defaults: makeTestDefaults())
        try imported.importSettings(from: exportURL)

        #expect(imported.focusFollowsWindowToMonitor == true)
        #expect(imported.mouseWarpAxis == .vertical)
        #expect(imported.statusBarShowWorkspaceName == true)
        #expect(imported.statusBarShowAppNames == true)
        #expect(imported.statusBarUseWorkspaceId == true)
        #expect(imported.commandPaletteLastMode == .menu)
        #expect(imported.quakeTerminalEnabled == true)
        #expect(imported.quakeTerminalPosition == .bottom)
        #expect(imported.quakeTerminalWidthPercent == 80)
        #expect(imported.quakeTerminalHeightPercent == 55)
        #expect(imported.quakeTerminalAnimationDuration == 0.4)
        #expect(imported.quakeTerminalAutoHide == false)
        #expect(imported.quakeTerminalOpacity == 0.75)
        #expect(imported.quakeTerminalMonitorMode == .focusedWindow)
        #expect(imported.quakeTerminalUseCustomFrame == true)
        #expect(imported.quakeTerminalCustomFrame == CGRect(x: 10, y: 20, width: 1200, height: 700))
    }

    @Test func fullExportAndImportRoundTripMonitorOverridesAndAppRules() throws {
        let exportURL = makeTestSettingsURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let settings = SettingsStore(defaults: makeTestDefaults())
        let barOverride = MonitorBarSettings(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            monitorName: "Studio Display",
            monitorDisplayId: 101,
            enabled: false,
            showLabels: false,
            deduplicateAppIcons: true,
            hideEmptyWorkspaces: true,
            reserveLayoutSpace: true,
            notchAware: false,
            position: .belowMenuBar,
            windowLevel: .status,
            height: 32,
            backgroundOpacity: 0.35,
            xOffset: 12,
            yOffset: 6
        )
        let niriOverride = MonitorNiriSettings(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            monitorName: "Studio Display",
            monitorDisplayId: 101,
            maxVisibleColumns: 4,
            maxWindowsPerColumn: 2,
            centerFocusedColumn: .always,
            alwaysCenterSingleColumn: false,
            singleWindowAspectRatio: .ratio16x9,
            infiniteLoop: true
        )
        let dwindleOverride = MonitorDwindleSettings(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            monitorName: "Studio Display",
            monitorDisplayId: 101,
            smartSplit: true,
            defaultSplitRatio: 0.62,
            splitWidthMultiplier: 1.4,
            singleWindowAspectRatio: .ratio21x9,
            useGlobalGaps: false,
            innerGap: 5,
            outerGapTop: 7,
            outerGapBottom: 8,
            outerGapLeft: 9,
            outerGapRight: 10
        )
        let customRule = AppRule(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            bundleId: "com.example.Editor",
            appNameSubstring: "Editor",
            titleSubstring: "Draft",
            titleRegex: ".*Sprint.*",
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            layout: .float,
            assignToWorkspace: "4",
            minWidth: 900,
            minHeight: 700
        )

        settings.monitorBarSettings = [barOverride]
        settings.monitorNiriSettings = [niriOverride]
        settings.monitorDwindleSettings = [dwindleOverride]
        settings.appRules = BuiltInSettingsDefaults.appRules + [customRule]

        try settings.exportSettings(to: exportURL, mode: .full)

        let imported = SettingsStore(defaults: makeTestDefaults())
        let reboundMonitor = makeSettingsTestMonitor(displayId: 501, name: "Studio Display")
        try imported.importSettings(from: exportURL, monitors: [reboundMonitor])

        var expectedBarOverride = barOverride
        expectedBarOverride.monitorDisplayId = reboundMonitor.displayId
        var expectedNiriOverride = niriOverride
        expectedNiriOverride.monitorDisplayId = reboundMonitor.displayId
        var expectedDwindleOverride = dwindleOverride
        expectedDwindleOverride.monitorDisplayId = reboundMonitor.displayId

        #expect(imported.monitorBarSettings == [expectedBarOverride])
        #expect(imported.monitorNiriSettings == [expectedNiriOverride])
        #expect(imported.monitorDwindleSettings == [expectedDwindleOverride])
        #expect(imported.appRules == BuiltInSettingsDefaults.appRules + [customRule])
    }

    @Test func compactExportImportAndReexportPreservesMonitorOverridesAndCustomAppRules() throws {
        let exportURL = makeTestSettingsURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let settings = SettingsStore(defaults: makeTestDefaults())
        let barOverride = MonitorBarSettings(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            monitorName: "LG UltraFine",
            monitorDisplayId: 202,
            reserveLayoutSpace: true,
            backgroundOpacity: 0.42
        )
        let niriOverride = MonitorNiriSettings(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            monitorName: "LG UltraFine",
            monitorDisplayId: 202,
            maxVisibleColumns: 5,
            infiniteLoop: true
        )
        let dwindleOverride = MonitorDwindleSettings(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            monitorName: "LG UltraFine",
            monitorDisplayId: 202,
            useGlobalGaps: false,
            innerGap: 4,
            outerGapLeft: 11
        )
        let customRule = AppRule(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            bundleId: "com.example.Terminal",
            titleSubstring: "Prod",
            layout: .tile,
            assignToWorkspace: "2",
            minWidth: 700,
            minHeight: 500
        )

        settings.monitorBarSettings = [barOverride]
        settings.monitorNiriSettings = [niriOverride]
        settings.monitorDwindleSettings = [dwindleOverride]
        settings.appRules = BuiltInSettingsDefaults.appRules + [customRule]

        try settings.exportSettings(to: exportURL, mode: .compact)

        let imported = SettingsStore(defaults: makeTestDefaults())
        let reboundMonitor = makeSettingsTestMonitor(displayId: 909, name: "LG UltraFine")
        try imported.importSettings(from: exportURL, monitors: [reboundMonitor])

        var expectedBarOverride = barOverride
        expectedBarOverride.monitorDisplayId = reboundMonitor.displayId
        var expectedNiriOverride = niriOverride
        expectedNiriOverride.monitorDisplayId = reboundMonitor.displayId
        var expectedDwindleOverride = dwindleOverride
        expectedDwindleOverride.monitorDisplayId = reboundMonitor.displayId

        #expect(imported.monitorBarSettings == [expectedBarOverride])
        #expect(imported.monitorNiriSettings == [expectedNiriOverride])
        #expect(imported.monitorDwindleSettings == [expectedDwindleOverride])
        #expect(imported.appRules == BuiltInSettingsDefaults.appRules + [customRule])

        let reexported = try SettingsExport(
            hotkeysEnabled: imported.hotkeysEnabled,
            focusFollowsMouse: imported.focusFollowsMouse,
            moveMouseToFocusedWindow: imported.moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: imported.focusFollowsWindowToMonitor,
            mouseWarpMonitorOrder: imported.mouseWarpMonitorOrder,
            mouseWarpAxis: imported.mouseWarpAxis.rawValue,
            mouseWarpMargin: imported.mouseWarpMargin,
            gapSize: imported.gapSize,
            outerGapLeft: imported.outerGapLeft,
            outerGapRight: imported.outerGapRight,
            outerGapTop: imported.outerGapTop,
            outerGapBottom: imported.outerGapBottom,
            niriMaxWindowsPerColumn: imported.niriMaxWindowsPerColumn,
            niriMaxVisibleColumns: imported.niriMaxVisibleColumns,
            niriInfiniteLoop: imported.niriInfiniteLoop,
            niriCenterFocusedColumn: imported.niriCenterFocusedColumn.rawValue,
            niriAlwaysCenterSingleColumn: imported.niriAlwaysCenterSingleColumn,
            niriSingleWindowAspectRatio: imported.niriSingleWindowAspectRatio.rawValue,
            niriColumnWidthPresets: imported.niriColumnWidthPresets,
            niriDefaultColumnWidth: imported.niriDefaultColumnWidth,
            workspaceConfigurations: imported.workspaceConfigurations,
            defaultLayoutType: imported.defaultLayoutType.rawValue,
            bordersEnabled: imported.bordersEnabled,
            borderWidth: imported.borderWidth,
            borderColorRed: imported.borderColorRed,
            borderColorGreen: imported.borderColorGreen,
            borderColorBlue: imported.borderColorBlue,
            borderColorAlpha: imported.borderColorAlpha,
            hotkeyBindings: imported.hotkeyBindings,
            workspaceBarEnabled: imported.workspaceBarEnabled,
            workspaceBarShowLabels: imported.workspaceBarShowLabels,
            workspaceBarWindowLevel: imported.workspaceBarWindowLevel.rawValue,
            workspaceBarPosition: imported.workspaceBarPosition.rawValue,
            workspaceBarNotchAware: imported.workspaceBarNotchAware,
            workspaceBarDeduplicateAppIcons: imported.workspaceBarDeduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: imported.workspaceBarHideEmptyWorkspaces,
            workspaceBarReserveLayoutSpace: imported.workspaceBarReserveLayoutSpace,
            workspaceBarHeight: imported.workspaceBarHeight,
            workspaceBarBackgroundOpacity: imported.workspaceBarBackgroundOpacity,
            workspaceBarXOffset: imported.workspaceBarXOffset,
            workspaceBarYOffset: imported.workspaceBarYOffset,
            monitorBarSettings: imported.monitorBarSettings,
            appRules: imported.appRules,
            monitorOrientationSettings: imported.monitorOrientationSettings,
            monitorNiriSettings: imported.monitorNiriSettings,
            dwindleSmartSplit: imported.dwindleSmartSplit,
            dwindleDefaultSplitRatio: imported.dwindleDefaultSplitRatio,
            dwindleSplitWidthMultiplier: imported.dwindleSplitWidthMultiplier,
            dwindleSingleWindowAspectRatio: imported.dwindleSingleWindowAspectRatio.rawValue,
            dwindleUseGlobalGaps: imported.dwindleUseGlobalGaps,
            dwindleMoveToRootStable: imported.dwindleMoveToRootStable,
            monitorDwindleSettings: imported.monitorDwindleSettings,
            preventSleepEnabled: imported.preventSleepEnabled,
            ipcEnabled: imported.ipcEnabled,
            scrollGestureEnabled: imported.scrollGestureEnabled,
            scrollSensitivity: imported.scrollSensitivity,
            scrollModifierKey: imported.scrollModifierKey.rawValue,
            gestureFingerCount: imported.gestureFingerCount.rawValue,
            gestureInvertDirection: imported.gestureInvertDirection,
            statusBarShowWorkspaceName: imported.statusBarShowWorkspaceName,
            statusBarShowAppNames: imported.statusBarShowAppNames,
            statusBarUseWorkspaceId: imported.statusBarUseWorkspaceId,
            commandPaletteLastMode: imported.commandPaletteLastMode.rawValue,
            hiddenBarIsCollapsed: imported.hiddenBarIsCollapsed,
            quakeTerminalEnabled: imported.quakeTerminalEnabled,
            quakeTerminalPosition: imported.quakeTerminalPosition.rawValue,
            quakeTerminalWidthPercent: imported.quakeTerminalWidthPercent,
            quakeTerminalHeightPercent: imported.quakeTerminalHeightPercent,
            quakeTerminalAnimationDuration: imported.quakeTerminalAnimationDuration,
            quakeTerminalAutoHide: imported.quakeTerminalAutoHide,
            quakeTerminalOpacity: imported.quakeTerminalOpacity,
            quakeTerminalMonitorMode: imported.quakeTerminalMonitorMode.rawValue,
            quakeTerminalUseCustomFrame: imported.quakeTerminalUseCustomFrame,
            quakeTerminalCustomFrame: imported.quakeTerminalCustomFrame.map(QuakeTerminalFrameExport.init(frame:)),
            appearanceMode: imported.appearanceMode.rawValue
        ).exportData(mode: .compact)

        guard let json = try JSONSerialization.jsonObject(with: reexported) as? [String: Any] else {
            Issue.record("Expected compact re-export to produce a JSON object")
            return
        }

        #expect((json["monitorBarSettings"] as? [[String: Any]])?.count == 1)
        #expect((json["monitorNiriSettings"] as? [[String: Any]])?.count == 1)
        #expect((json["monitorDwindleSettings"] as? [[String: Any]])?.count == 1)
        #expect((json["appRules"] as? [[String: Any]])?.count == BuiltInSettingsDefaults.appRules.count + 1)
    }

    @Test func importNormalizesWorkspaceConfigurationsAndRebindsSpecificDisplayAssignments() throws {
        let exportURL = makeTestSettingsURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "2",
                displayName: "Code",
                monitorAssignment: .specificDisplay(OutputId(displayId: 10, name: "Studio Display")),
                layoutType: .dwindle
            ),
            WorkspaceConfiguration(name: "10", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", displayName: "Duplicate", monitorAssignment: .secondary)
        ]

        try settings.exportSettings(to: exportURL, mode: .full)

        let imported = SettingsStore(defaults: makeTestDefaults())
        let reboundMonitor = makeSettingsTestMonitor(displayId: 77, name: "Studio Display")
        try imported.importSettings(from: exportURL, monitors: [reboundMonitor])

        #expect(imported.workspaceConfigurations.count == 1)
        #expect(imported.workspaceConfigurations.first?.name == "2")
        #expect(imported.workspaceConfigurations.first?.displayName == "Code")
        #expect(
            imported.workspaceConfigurations.first?.monitorAssignment
                == .specificDisplay(OutputId(displayId: reboundMonitor.displayId, name: reboundMonitor.name))
        )
    }

    @Test func importClearsStaleMonitorDisplayIdsWhenNoCurrentMatchExists() throws {
        let exportURL = makeTestSettingsURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.monitorBarSettings = [
            MonitorBarSettings(
                monitorName: "Detached",
                monitorDisplayId: 404,
                reserveLayoutSpace: true
            )
        ]

        try settings.exportSettings(to: exportURL, mode: .full)

        let imported = SettingsStore(defaults: makeTestDefaults())
        let currentMonitor = makeSettingsTestMonitor(displayId: 12, name: "Current")
        try imported.importSettings(from: exportURL, monitors: [currentMonitor])

        #expect(imported.monitorBarSettings.count == 1)
        #expect(imported.monitorBarSettings.first?.monitorDisplayId == nil)
        #expect(imported.monitorBarSettings.first?.monitorName == "Detached")
    }
}

@Suite(.serialized) @MainActor struct SettingsStoreAppearanceImportTests {
    @Test func importSettingsApplyingToControllerUsesSharedAppearancePath() throws {
        let exportURL = makeTestSettingsURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        let exportSource = SettingsStore(defaults: makeTestDefaults())
        exportSource.hotkeysEnabled = false
        exportSource.workspaceBarEnabled = false
        exportSource.appearanceMode = .light
        try exportSource.exportSettings(to: exportURL, mode: .full)

        let controller = makeLayoutPlanTestController()
        defer { controller.setEnabled(false) }

        application.appearance = NSAppearance(named: .darkAqua)
        try controller.settings.importSettings(from: exportURL, applyingTo: controller)

        #expect(controller.settings.appearanceMode == .light)
        #expect(application.appearance?.name == .aqua)
    }
}

@Suite @MainActor struct SettingsStoreBuiltInDefaultsTests {
    @Test func settingsStoreBootsWithPromotedDefaultsAndExcludedLocalStateStaysOut() {
        let settings = SettingsStore(defaults: makeTestDefaults())

        #expect(settings.mouseWarpAxis == .horizontal)
        #expect(settings.mouseWarpMargin == 1)
        #expect(settings.niriColumnWidthPresets == BuiltInSettingsDefaults.niriColumnWidthPresets)
        #expect(settings.outerGapLeft == 8)
        #expect(settings.outerGapRight == 8)
        #expect(settings.outerGapTop == 8)
        #expect(settings.outerGapBottom == 8)
        #expect(settings.workspaceConfigurations == BuiltInSettingsDefaults.workspaceConfigurations)
        #expect(settings.bordersEnabled == true)
        #expect(settings.borderWidth == 5.0)
        #expect(settings.borderColorRed == 0.084585202284378935)
        #expect(settings.borderColorGreen == 1.0)
        #expect(settings.borderColorBlue == 0.97930003794467602)
        #expect(settings.hotkeyBindings == HotkeyBindingRegistry.defaults())
        #expect(settings.workspaceBarEnabled == true)
        #expect(settings.workspaceBarNotchAware == true)
        #expect(settings.workspaceBarReserveLayoutSpace == false)
        #expect(settings.appRules == BuiltInSettingsDefaults.appRules)
        #expect(settings.mouseWarpMonitorOrder.isEmpty)
        #expect(settings.preventSleepEnabled == false)
        #expect(settings.ipcEnabled == false)
        #expect(settings.scrollSensitivity == 5.0)
        #expect(settings.statusBarShowWorkspaceName == false)
        #expect(settings.statusBarShowAppNames == false)
        #expect(settings.statusBarUseWorkspaceId == false)
        #expect(settings.hiddenBarIsCollapsed == true)
        #expect(settings.quakeTerminalEnabled == true)
        #expect(settings.quakeTerminalPosition == .center)
        #expect(settings.quakeTerminalWidthPercent == 50.0)
        #expect(settings.quakeTerminalHeightPercent == 50.0)
        #expect(settings.quakeTerminalAutoHide == false)
        #expect(settings.quakeTerminalMonitorMode == .focusedWindow)
        #expect(settings.quakeTerminalUseCustomFrame == false)
        #expect(settings.quakeTerminalCustomFrame == nil)
        #expect(settings.appearanceMode == .dark)
    }

    @Test func settingsStoreFallbackDefaultsMatchExportDefaults() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let exportDefaults = SettingsExport.defaults()

        #expect(settings.hotkeysEnabled == exportDefaults.hotkeysEnabled)
        #expect(settings.focusFollowsMouse == exportDefaults.focusFollowsMouse)
        #expect(settings.moveMouseToFocusedWindow == exportDefaults.moveMouseToFocusedWindow)
        #expect(settings.focusFollowsWindowToMonitor == exportDefaults.focusFollowsWindowToMonitor)
        #expect(settings.mouseWarpAxis.rawValue == exportDefaults.mouseWarpAxis)
        #expect(settings.mouseWarpMargin == exportDefaults.mouseWarpMargin)
        #expect(settings.gapSize == exportDefaults.gapSize)
        #expect(settings.niriMaxWindowsPerColumn == exportDefaults.niriMaxWindowsPerColumn)
        #expect(settings.niriMaxVisibleColumns == exportDefaults.niriMaxVisibleColumns)
        #expect(settings.defaultLayoutType.rawValue == exportDefaults.defaultLayoutType)
        #expect(settings.borderWidth == exportDefaults.borderWidth)
        #expect(settings.workspaceBarPosition.rawValue == exportDefaults.workspaceBarPosition)
        #expect(settings.dwindleDefaultSplitRatio == exportDefaults.dwindleDefaultSplitRatio)
        #expect(settings.scrollModifierKey.rawValue == exportDefaults.scrollModifierKey)
        #expect(settings.gestureFingerCount.rawValue == exportDefaults.gestureFingerCount)
        #expect(settings.statusBarShowWorkspaceName == exportDefaults.statusBarShowWorkspaceName)
        #expect(settings.statusBarShowAppNames == exportDefaults.statusBarShowAppNames)
        #expect(settings.statusBarUseWorkspaceId == exportDefaults.statusBarUseWorkspaceId)
        #expect(settings.commandPaletteLastMode.rawValue == exportDefaults.commandPaletteLastMode)
        #expect(settings.hiddenBarIsCollapsed == exportDefaults.hiddenBarIsCollapsed)
        #expect(settings.ipcEnabled == exportDefaults.ipcEnabled)
        #expect(settings.quakeTerminalPosition.rawValue == exportDefaults.quakeTerminalPosition)
        #expect(settings.quakeTerminalMonitorMode.rawValue == exportDefaults.quakeTerminalMonitorMode)
        #expect(settings.appearanceMode.rawValue == exportDefaults.appearanceMode)
    }
}

@Suite struct SettingsSectionTests {
    @Test func settingsSectionsExcludeMenuSection() {
        #expect(SettingsSection.allCases.map(\.id) == [
            "general",
            "niri",
            "dwindle",
            "monitors",
            "workspaces",
            "borders",
            "bar",
            "hotkeys",
            "quakeTerminal",
        ])
    }
}

@Suite @MainActor struct WorkspaceConfigurationPersistenceTests {
    @Test func settingsStoreIgnoresLegacyWorkspaceKeys() {
        let defaults = makeTestDefaults()
        defaults.set("ws1,ws2", forKey: "settings.persistentWorkspaces")
        defaults.set("ws1=Studio Display", forKey: "settings.workspaceAssignments")

        let settings = SettingsStore(defaults: defaults)

        let defaultNames = BuiltInSettingsDefaults.workspaceConfigurations.map(\.name)
        #expect(settings.workspaceConfigurations.map(\.name) == defaultNames)
        #expect(settings.configuredWorkspaceNames() == defaultNames)
        #expect(settings.workspaceToMonitorAssignments().keys.sorted() == defaultNames)
    }

    @Test func savingWorkspaceConfigurationsDoesNotRewriteLegacyWorkspaceKeys() {
        let defaults = makeTestDefaults()
        defaults.set("ws1,ws2", forKey: "settings.persistentWorkspaces")
        defaults.set("ws1=Studio Display", forKey: "settings.workspaceAssignments")

        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        #expect(defaults.string(forKey: "settings.persistentWorkspaces") == "ws1,ws2")
        #expect(defaults.string(forKey: "settings.workspaceAssignments") == "ws1=Studio Display")
        #expect(settings.configuredWorkspaceNames() == ["1"])
        #expect(defaults.data(forKey: "settings.workspaceConfigurations") != nil)
    }

    @Test func workspaceConfigurationsRoundTripSpecificDisplayAssignments() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let output = OutputId(displayId: 777, name: "Studio Display")

        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "2",
                displayName: "Code",
                monitorAssignment: .specificDisplay(output),
                layoutType: .dwindle
            )
        ]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.workspaceConfigurations == settings.workspaceConfigurations)
        #expect(reloaded.workspaceToMonitorAssignments()["2"] == [.output(output)])
    }

    @Test func settingsStoreNormalizesWorkspaceConfigurationsToConfiguredNumericIds() {
        let defaults = makeTestDefaults()
        let rawConfigurations = [
            WorkspaceConfiguration(name: "2", monitorAssignment: .main),
            WorkspaceConfiguration(name: "10", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", displayName: "Duplicate", monitorAssignment: .secondary),
            WorkspaceConfiguration(name: "abc", monitorAssignment: .main)
        ]
        defaults.set(try? JSONEncoder().encode(rawConfigurations), forKey: "settings.workspaceConfigurations")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.workspaceConfigurations.map(\.name) == ["2"])
        #expect(settings.workspaceConfigurations.first?.monitorAssignment == .main)
    }

    @Test func persistEffectiveMouseWarpMonitorOrderSeedsConnectedDisplaysWithoutDroppingStoredEntries() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let disconnected = makeSettingsTestMonitor(displayId: 99, name: "Disconnected")
        let right = makeSettingsTestMonitor(displayId: 2, name: "Right", x: 1920)
        let left = makeSettingsTestMonitor(displayId: 1, name: "Left", x: 0)

        settings.mouseWarpMonitorOrder = ["Disconnected", "Left"]

        let resolved = settings.persistEffectiveMouseWarpMonitorOrder(for: [right, left])

        #expect(settings.mouseWarpMonitorOrder == ["Disconnected", "Left", "Right"])
        #expect(resolved == ["Left", "Right"])
        #expect(settings.effectiveMouseWarpMonitorOrder(for: [left]) == ["Left"])
        _ = disconnected
    }

    @Test func persistEffectiveMouseWarpMonitorOrderUsesVerticalAxisForTopToBottomSeeding() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let bottom = makeSettingsTestMonitor(displayId: 1, name: "Bottom", x: 0, y: 0)
        let top = makeSettingsTestMonitor(displayId: 2, name: "Top", x: 320, y: 1080)
        settings.mouseWarpAxis = .vertical

        let resolved = settings.persistEffectiveMouseWarpMonitorOrder(for: [bottom, top])

        #expect(settings.mouseWarpMonitorOrder == ["Top", "Bottom"])
        #expect(resolved == ["Top", "Bottom"])
    }

    @Test func switchingMouseWarpAxisDoesNotRewriteStoredMonitorOrder() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.mouseWarpMonitorOrder = ["Left", "Right"]

        settings.mouseWarpAxis = .vertical

        #expect(settings.mouseWarpMonitorOrder == ["Left", "Right"])
    }

    @Test func mouseWarpAxisRoundTripsThroughUserDefaults() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.mouseWarpAxis = .vertical

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.mouseWarpAxis == .vertical)
    }
}

@Suite struct SettingsMigrationTests {
    @Test func startupDecisionBootsFreshInstallWhenNoOwnedKeysExist() {
        let defaults = makeTestDefaults()
        #expect(SettingsMigration.startupDecision(defaults: defaults) == .boot)
    }

    @Test func startupDecisionRequiresResetWhenEpochIsMissingButOwnedKeysExist() {
        let defaults = makeTestDefaults()
        defaults.set(true, forKey: "settings.hotkeysEnabled")

        #expect(SettingsMigration.startupDecision(defaults: defaults) == .requireReset(storedEpoch: nil))
    }

    @Test func startupDecisionRequiresResetWhenStoredEpochIsOlder() {
        let defaults = makeTestDefaults()
        defaults.set(SettingsMigration.currentSettingsEpoch - 1, forKey: "settings.settingsEpoch")

        #expect(
            SettingsMigration.startupDecision(defaults: defaults) ==
                .requireReset(storedEpoch: SettingsMigration.currentSettingsEpoch - 1)
        )
    }

    @Test func startupDecisionRequiresResetWhenStoredEpochIsNewer() {
        let defaults = makeTestDefaults()
        defaults.set(SettingsMigration.currentSettingsEpoch + 1, forKey: "settings.settingsEpoch")

        #expect(
            SettingsMigration.startupDecision(defaults: defaults) ==
                .requireReset(storedEpoch: SettingsMigration.currentSettingsEpoch + 1)
        )
    }

    @Test func resetOwnedSettingsClearsOwnedKeysAndWritesCurrentEpoch() {
        let defaults = makeTestDefaults()
        defaults.set(true, forKey: "settings.hotkeysEnabled")
        defaults.set("ws1,ws2", forKey: "settings.persistentWorkspaces")
        defaults.set("ws1=Studio Display", forKey: "settings.workspaceAssignments")
        defaults.set(Data("payload".utf8), forKey: "settings.workspaceConfigurations")

        SettingsMigration.resetOwnedSettings(defaults: defaults)

        #expect(defaults.object(forKey: "settings.hotkeysEnabled") == nil)
        #expect(defaults.object(forKey: "settings.persistentWorkspaces") == nil)
        #expect(defaults.object(forKey: "settings.workspaceAssignments") == nil)
        #expect(defaults.object(forKey: "settings.workspaceConfigurations") == nil)
        #expect(defaults.integer(forKey: "settings.settingsEpoch") == SettingsMigration.currentSettingsEpoch)
    }

    @Test func validateImportEpochRejectsWrongEpochBeforeFullDecode() {
        let previousEpochJSON =
            """
            {
              "version": \(SettingsMigration.currentSettingsEpoch - 1),
              "hotkeyBindings": [
                { "id": "move.left", "binding": "Option+Shift+Left" }
              ]
            }
            """
        let rawData = Data(
            previousEpochJSON.utf8
        )

        do {
            try SettingsMigration.validateImportEpoch(from: rawData)
            Issue.record("Expected import epoch validation to reject an older schema")
        } catch let error as SettingsMigration.MigrationError {
            guard case let .unsupportedEpoch(expected, found) = error else {
                Issue.record("Unexpected migration error: \(error)")
                return
            }
            #expect(expected == SettingsMigration.currentSettingsEpoch)
            #expect(found == SettingsMigration.currentSettingsEpoch - 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func validateImportEpochAcceptsCurrentEpoch() throws {
        let rawData = Data("{\"version\":\(SettingsMigration.currentSettingsEpoch)}".utf8)
        try SettingsMigration.validateImportEpoch(from: rawData)
    }
}
