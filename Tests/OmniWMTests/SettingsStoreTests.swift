import Foundation
import Testing

@testable import OmniWM

private func makeTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
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
}

@Suite struct SettingsExportTests {

    @Test func settingsExportDecodesUnknownEnumStrings() throws {
        let json = """
        {
            "version": 1,
            "hotkeysEnabled": true,
            "focusFollowsMouse": false,
            "moveMouseToFocusedWindow": false,
            "mouseWarpEnabled": false,
            "mouseWarpMonitorOrder": [],
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
            "persistentWorkspacesRaw": "",
            "workspaceAssignmentsRaw": "",
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
            "scrollGestureEnabled": true,
            "scrollSensitivity": 1,
            "scrollModifierKey": "futureModifier",
            "gestureFingerCount": 99,
            "gestureInvertDirection": true,
            "animationsEnabled": true,
            "menuAnywhereNativeEnabled": true,
            "menuAnywherePaletteEnabled": true,
            "menuAnywherePosition": "futurePos",
            "menuAnywhereShowShortcuts": true,
            "hiddenBarEnabled": false,
            "hiddenBarIsCollapsed": false,
            "appearanceMode": "futureMode"
        }
        """
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: Data(json.utf8))
        #expect(decoded.niriCenterFocusedColumn == "futureUnknownValue")
        #expect(decoded.workspaceBarPosition == "futurePosition")
        #expect(decoded.scrollModifierKey == "futureModifier")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let export = SettingsExport(
            hotkeysEnabled: true,
            focusFollowsMouse: true,
            moveMouseToFocusedWindow: true,
            mouseWarpEnabled: true,
            mouseWarpMonitorOrder: ["Monitor1", "Monitor2"],
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
            niriColumnWidthPresets: [0.33, 0.5, 0.67],
            persistentWorkspacesRaw: "ws1,ws2",
            workspaceAssignmentsRaw: "app1=ws1",
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
            workspaceBarHeight: 30.0,
            workspaceBarBackgroundOpacity: 0.5,
            workspaceBarXOffset: 10.0,
            workspaceBarYOffset: 20.0,
            monitorBarSettings: [MonitorBarSettings(monitorName: "TestBar", enabled: true)],
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
            scrollGestureEnabled: false,
            scrollSensitivity: 2.0,
            scrollModifierKey: "option",
            gestureFingerCount: 4,
            gestureInvertDirection: true,
            animationsEnabled: false,
            menuAnywhereNativeEnabled: false,
            menuAnywherePaletteEnabled: true,
            menuAnywherePosition: "center",
            menuAnywhereShowShortcuts: false,
            hiddenBarEnabled: true,
            hiddenBarIsCollapsed: true,
            quakeTerminalOpacity: 0.85,
            quakeTerminalMonitorMode: "focused",
            appearanceMode: "dark"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data1 = try encoder.encode(export)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: data1)
        let data2 = try encoder.encode(decoded)
        #expect(data1 == data2)
    }
}
