import CoreGraphics
import Carbon
import Foundation
import Testing

@testable import OmniWM

private func makeTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
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

@Suite struct IncrementalSettingsExportTests {
    @Test func incrementalExportOmitsRemovedAnimationsKeyAndDefaultHotkeys() throws {
        var export = SettingsExport.defaults()
        export.menuAnywherePaletteEnabled = false

        let data = try export.exportData(incrementalOnly: true)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected incremental export to produce a JSON object")
            return
        }

        #expect(json["animationsEnabled"] == nil)
        #expect((json["menuAnywherePaletteEnabled"] as? Bool) == false)
        #expect(json["hotkeyBindings"] == nil)
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

        let rawData = try changed.exportData(incrementalOnly: true, defaults: defaults)
        let mergedData = try SettingsExport.mergedImportData(from: rawData, defaults: defaults)
        let merged = try JSONDecoder().decode(SettingsExport.self, from: mergedData)

        #expect(merged.hotkeyBindings[0].binding == updatedBinding)
        #expect(merged.hotkeyBindings[1].binding == defaults.hotkeyBindings[1].binding)
    }

    @Test func legacyAnimationsEnabledKeyIsIgnoredOnImportAndOmittedOnReexport() throws {
        let rawData = Data(
            """
            {
              "version": 1,
              "animationsEnabled": false,
              "menuAnywherePaletteEnabled": false
            }
            """.utf8
        )

        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: mergedData)
        #expect(decoded.menuAnywherePaletteEnabled == false)

        let reexported = try decoded.exportData(incrementalOnly: false)
        guard let json = try JSONSerialization.jsonObject(with: reexported) as? [String: Any] else {
            Issue.record("Expected re-export to produce a JSON object")
            return
        }

        #expect(json["animationsEnabled"] == nil)
        #expect((json["menuAnywherePaletteEnabled"] as? Bool) == false)
    }

    @Test func sameEpochLegacyWorkspaceKeysAreIgnoredOnImportAndDroppedOnReexport() throws {
        var export = SettingsExport.defaults()
        export.workspaceConfigurations = [
            WorkspaceConfiguration(name: "ws1", monitorAssignment: .main, isPersistent: true)
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

        let reexported = try decoded.exportData(incrementalOnly: false)
        guard let reexportedJSON = try JSONSerialization.jsonObject(with: reexported) as? [String: Any] else {
            Issue.record("Expected re-export to produce a JSON object")
            return
        }

        #expect(reexportedJSON["persistentWorkspacesRaw"] == nil)
        #expect(reexportedJSON["workspaceAssignmentsRaw"] == nil)
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
        #expect(HotkeyCommand.move(.left).layoutCompatibility == .shared)
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
}

@Suite @MainActor struct WorkspaceConfigurationPersistenceTests {
    @Test func settingsStoreIgnoresLegacyWorkspaceKeys() {
        let defaults = makeTestDefaults()
        defaults.set("ws1,ws2", forKey: "settings.persistentWorkspaces")
        defaults.set("ws1=Studio Display", forKey: "settings.workspaceAssignments")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.workspaceConfigurations.isEmpty)
        #expect(settings.persistentWorkspaceNames().isEmpty)
        #expect(settings.workspaceToMonitorAssignments().isEmpty)
    }

    @Test func savingWorkspaceConfigurationsDoesNotRewriteLegacyWorkspaceKeys() {
        let defaults = makeTestDefaults()
        defaults.set("ws1,ws2", forKey: "settings.persistentWorkspaces")
        defaults.set("ws1=Studio Display", forKey: "settings.workspaceAssignments")

        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "ws1", monitorAssignment: .main, isPersistent: true)
        ]

        #expect(defaults.string(forKey: "settings.persistentWorkspaces") == "ws1,ws2")
        #expect(defaults.string(forKey: "settings.workspaceAssignments") == "ws1=Studio Display")
        #expect(settings.persistentWorkspaceNames() == ["ws1"])
        #expect(defaults.data(forKey: "settings.workspaceConfigurations") != nil)
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
        defaults.set(1, forKey: "settings.settingsEpoch")

        #expect(SettingsMigration.startupDecision(defaults: defaults) == .requireReset(storedEpoch: 1))
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
        defaults.set(7, forKey: "appliedSettingsPatches")

        SettingsMigration.resetOwnedSettings(defaults: defaults)

        #expect(defaults.object(forKey: "settings.hotkeysEnabled") == nil)
        #expect(defaults.object(forKey: "settings.persistentWorkspaces") == nil)
        #expect(defaults.object(forKey: "settings.workspaceAssignments") == nil)
        #expect(defaults.object(forKey: "settings.workspaceConfigurations") == nil)
        #expect(defaults.object(forKey: "appliedSettingsPatches") == nil)
        #expect(defaults.integer(forKey: "settings.settingsEpoch") == SettingsMigration.currentSettingsEpoch)
    }

    @Test func validateImportEpochRejectsWrongEpochBeforeFullDecode() {
        let rawData = Data("{\"version\":1,\"hotkeyBindings\":[{\"id\":\"move.left\",\"binding\":\"Option+Shift+Left\"}]}".utf8)

        do {
            try SettingsMigration.validateImportEpoch(from: rawData)
            Issue.record("Expected import epoch validation to reject an older schema")
        } catch let error as SettingsMigration.MigrationError {
            guard case let .unsupportedEpoch(expected, found) = error else {
                Issue.record("Unexpected migration error: \(error)")
                return
            }
            #expect(expected == SettingsMigration.currentSettingsEpoch)
            #expect(found == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func validateImportEpochAcceptsCurrentEpoch() throws {
        let rawData = Data("{\"version\":\(SettingsMigration.currentSettingsEpoch)}".utf8)
        try SettingsMigration.validateImportEpoch(from: rawData)
    }
}
