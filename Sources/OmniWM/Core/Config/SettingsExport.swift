import Foundation

// MARK: - SettingsExport

struct SettingsExport: Codable {
    var version: Int = 1

    var hotkeysEnabled: Bool
    var focusFollowsMouse: Bool
    var moveMouseToFocusedWindow: Bool
    var mouseWarpEnabled: Bool
    var mouseWarpMonitorOrder: [String]
    var mouseWarpMargin: Int
    var gapSize: Double
    var outerGapLeft: Double
    var outerGapRight: Double
    var outerGapTop: Double
    var outerGapBottom: Double

    var niriMaxWindowsPerColumn: Int
    var niriMaxVisibleColumns: Int
    var niriInfiniteLoop: Bool
    var niriCenterFocusedColumn: String
    var niriAlwaysCenterSingleColumn: Bool
    var niriSingleWindowAspectRatio: String
    var niriColumnWidthPresets: [Double]?

    var persistentWorkspacesRaw: String
    var workspaceAssignmentsRaw: String
    var workspaceConfigurations: [WorkspaceConfiguration]
    var defaultLayoutType: String

    var bordersEnabled: Bool
    var borderWidth: Double
    var borderColorRed: Double
    var borderColorGreen: Double
    var borderColorBlue: Double
    var borderColorAlpha: Double

    var hotkeyBindings: [HotkeyBinding]

    var workspaceBarEnabled: Bool
    var workspaceBarShowLabels: Bool
    var workspaceBarWindowLevel: String
    var workspaceBarPosition: String
    var workspaceBarNotchAware: Bool
    var workspaceBarDeduplicateAppIcons: Bool
    var workspaceBarHideEmptyWorkspaces: Bool
    var workspaceBarHeight: Double
    var workspaceBarBackgroundOpacity: Double
    var workspaceBarXOffset: Double
    var workspaceBarYOffset: Double
    var monitorBarSettings: [MonitorBarSettings]

    var appRules: [AppRule]
    var monitorOrientationSettings: [MonitorOrientationSettings]
    var monitorNiriSettings: [MonitorNiriSettings]

    var dwindleSmartSplit: Bool
    var dwindleDefaultSplitRatio: Double
    var dwindleSplitWidthMultiplier: Double
    var dwindleSingleWindowAspectRatio: String
    var dwindleUseGlobalGaps: Bool
    var dwindleMoveToRootStable: Bool
    var monitorDwindleSettings: [MonitorDwindleSettings]

    var preventSleepEnabled: Bool
    var scrollGestureEnabled: Bool
    var scrollSensitivity: Double
    var scrollModifierKey: String
    var gestureFingerCount: Int
    var gestureInvertDirection: Bool

    var menuAnywhereNativeEnabled: Bool
    var menuAnywherePaletteEnabled: Bool
    var menuAnywherePosition: String
    var menuAnywhereShowShortcuts: Bool

    var hiddenBarEnabled: Bool
    var hiddenBarIsCollapsed: Bool

    var quakeTerminalOpacity: Double?
    var quakeTerminalMonitorMode: String?

    var appearanceMode: String
}

// MARK: - Defaults & Diffing

extension SettingsExport {
    static func defaults() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: true,
            focusFollowsMouse: false,
            moveMouseToFocusedWindow: false,
            mouseWarpEnabled: false,
            mouseWarpMonitorOrder: [],
            mouseWarpMargin: 2,
            gapSize: 8,
            outerGapLeft: 0,
            outerGapRight: 0,
            outerGapTop: 0,
            outerGapBottom: 0,
            niriMaxWindowsPerColumn: 3,
            niriMaxVisibleColumns: 2,
            niriInfiniteLoop: false,
            niriCenterFocusedColumn: CenterFocusedColumn.never.rawValue,
            niriAlwaysCenterSingleColumn: true,
            niriSingleWindowAspectRatio: SingleWindowAspectRatio.ratio4x3.rawValue,
            niriColumnWidthPresets: [1.0 / 3.0, 0.5, 2.0 / 3.0],
            persistentWorkspacesRaw: "",
            workspaceAssignmentsRaw: "",
            workspaceConfigurations: [],
            defaultLayoutType: LayoutType.niri.rawValue,
            bordersEnabled: false,
            borderWidth: 4.0,
            borderColorRed: 0.0,
            borderColorGreen: 0.5,
            borderColorBlue: 1.0,
            borderColorAlpha: 1.0,
            hotkeyBindings: DefaultHotkeyBindings.all(),
            workspaceBarEnabled: false,
            workspaceBarShowLabels: true,
            workspaceBarWindowLevel: WorkspaceBarWindowLevel.popup.rawValue,
            workspaceBarPosition: WorkspaceBarPosition.overlappingMenuBar.rawValue,
            workspaceBarNotchAware: false,
            workspaceBarDeduplicateAppIcons: false,
            workspaceBarHideEmptyWorkspaces: false,
            workspaceBarHeight: 24.0,
            workspaceBarBackgroundOpacity: 0.1,
            workspaceBarXOffset: 0.0,
            workspaceBarYOffset: 0.0,
            monitorBarSettings: [],
            appRules: [],
            monitorOrientationSettings: [],
            monitorNiriSettings: [],
            dwindleSmartSplit: false,
            dwindleDefaultSplitRatio: 1.0,
            dwindleSplitWidthMultiplier: 1.0,
            dwindleSingleWindowAspectRatio: DwindleSingleWindowAspectRatio.ratio4x3.rawValue,
            dwindleUseGlobalGaps: true,
            dwindleMoveToRootStable: true,
            monitorDwindleSettings: [],
            preventSleepEnabled: false,
            scrollGestureEnabled: true,
            scrollSensitivity: 1.0,
            scrollModifierKey: ScrollModifierKey.optionShift.rawValue,
            gestureFingerCount: GestureFingerCount.three.rawValue,
            gestureInvertDirection: true,
            menuAnywhereNativeEnabled: true,
            menuAnywherePaletteEnabled: true,
            menuAnywherePosition: MenuAnywherePosition.cursor.rawValue,
            menuAnywhereShowShortcuts: true,
            hiddenBarEnabled: false,
            hiddenBarIsCollapsed: false,
            quakeTerminalOpacity: 1.0,
            quakeTerminalMonitorMode: QuakeTerminalMonitorMode.mouseCursor.rawValue,
            appearanceMode: AppearanceMode.automatic.rawValue
        )
    }
}

private func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    guard let lData = try? JSONSerialization.data(withJSONObject: ["_": lhs], options: .sortedKeys),
          let rData = try? JSONSerialization.data(withJSONObject: ["_": rhs], options: .sortedKeys)
    else { return false }
    return lData == rData
}

// MARK: - Export & Import

extension SettingsStore {
    static var exportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omniwm/settings.json")
    }

    var settingsFileExists: Bool {
        FileManager.default.fileExists(atPath: Self.exportURL.path)
    }

    func exportSettings(incrementalOnly: Bool = true) throws {
        let export = SettingsExport(
            hotkeysEnabled: hotkeysEnabled,
            focusFollowsMouse: focusFollowsMouse,
            moveMouseToFocusedWindow: moveMouseToFocusedWindow,
            mouseWarpEnabled: mouseWarpEnabled,
            mouseWarpMonitorOrder: mouseWarpMonitorOrder,
            mouseWarpMargin: mouseWarpMargin,
            gapSize: gapSize,
            outerGapLeft: outerGapLeft,
            outerGapRight: outerGapRight,
            outerGapTop: outerGapTop,
            outerGapBottom: outerGapBottom,
            niriMaxWindowsPerColumn: niriMaxWindowsPerColumn,
            niriMaxVisibleColumns: niriMaxVisibleColumns,
            niriInfiniteLoop: niriInfiniteLoop,
            niriCenterFocusedColumn: niriCenterFocusedColumn.rawValue,
            niriAlwaysCenterSingleColumn: niriAlwaysCenterSingleColumn,
            niriSingleWindowAspectRatio: niriSingleWindowAspectRatio.rawValue,
            niriColumnWidthPresets: niriColumnWidthPresets,
            persistentWorkspacesRaw: persistentWorkspacesRaw,
            workspaceAssignmentsRaw: workspaceAssignmentsRaw,
            workspaceConfigurations: workspaceConfigurations,
            defaultLayoutType: defaultLayoutType.rawValue,
            bordersEnabled: bordersEnabled,
            borderWidth: borderWidth,
            borderColorRed: borderColorRed,
            borderColorGreen: borderColorGreen,
            borderColorBlue: borderColorBlue,
            borderColorAlpha: borderColorAlpha,
            hotkeyBindings: hotkeyBindings,
            workspaceBarEnabled: workspaceBarEnabled,
            workspaceBarShowLabels: workspaceBarShowLabels,
            workspaceBarWindowLevel: workspaceBarWindowLevel.rawValue,
            workspaceBarPosition: workspaceBarPosition.rawValue,
            workspaceBarNotchAware: workspaceBarNotchAware,
            workspaceBarDeduplicateAppIcons: workspaceBarDeduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: workspaceBarHideEmptyWorkspaces,
            workspaceBarHeight: workspaceBarHeight,
            workspaceBarBackgroundOpacity: workspaceBarBackgroundOpacity,
            workspaceBarXOffset: workspaceBarXOffset,
            workspaceBarYOffset: workspaceBarYOffset,
            monitorBarSettings: monitorBarSettings,
            appRules: appRules,
            monitorOrientationSettings: monitorOrientationSettings,
            monitorNiriSettings: monitorNiriSettings,
            dwindleSmartSplit: dwindleSmartSplit,
            dwindleDefaultSplitRatio: dwindleDefaultSplitRatio,
            dwindleSplitWidthMultiplier: dwindleSplitWidthMultiplier,
            dwindleSingleWindowAspectRatio: dwindleSingleWindowAspectRatio.rawValue,
            dwindleUseGlobalGaps: dwindleUseGlobalGaps,
            dwindleMoveToRootStable: dwindleMoveToRootStable,
            monitorDwindleSettings: monitorDwindleSettings,
            preventSleepEnabled: preventSleepEnabled,
            scrollGestureEnabled: scrollGestureEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey.rawValue,
            gestureFingerCount: gestureFingerCount.rawValue,
            gestureInvertDirection: gestureInvertDirection,
            menuAnywhereNativeEnabled: menuAnywhereNativeEnabled,
            menuAnywherePaletteEnabled: menuAnywherePaletteEnabled,
            menuAnywherePosition: menuAnywherePosition.rawValue,
            menuAnywhereShowShortcuts: menuAnywhereShowShortcuts,
            hiddenBarEnabled: hiddenBarEnabled,
            hiddenBarIsCollapsed: hiddenBarIsCollapsed,
            quakeTerminalOpacity: quakeTerminalOpacity,
            quakeTerminalMonitorMode: quakeTerminalMonitorMode.rawValue,
            appearanceMode: appearanceMode.rawValue
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)

        let outputData: Data
        if incrementalOnly {
            let defaultsData = try encoder.encode(SettingsExport.defaults())
            guard let currentDict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let defaultsDict = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
            else {
                outputData = data
                let directory = Self.exportURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try outputData.write(to: Self.exportURL)
                return
            }
            var filtered: [String: Any] = ["version": export.version]
            for (key, value) in currentDict where key != "version" && key != "hotkeyBindings" {
                if let defaultValue = defaultsDict[key], jsonValuesEqual(value, defaultValue) {
                    continue
                }
                filtered[key] = value
            }

            // Element-wise diff for hotkeyBindings by id
            if let currentBindings = currentDict["hotkeyBindings"] as? [[String: Any]],
               let defaultBindings = defaultsDict["hotkeyBindings"] as? [[String: Any]] {
                let defaultsByID = Dictionary(
                    defaultBindings.compactMap { b in (b["id"] as? String).map { ($0, b) } },
                    uniquingKeysWith: { _, last in last }
                )
                let changedBindings = currentBindings.filter { binding in
                    guard let id = binding["id"] as? String,
                          let defaultBinding = defaultsByID[id] else { return true }
                    return !jsonValuesEqual(binding, defaultBinding)
                }
                if !changedBindings.isEmpty {
                    filtered["hotkeyBindings"] = changedBindings
                }
            }
            outputData = try JSONSerialization.data(
                withJSONObject: filtered,
                options: [.prettyPrinted, .sortedKeys]
            )
        } else {
            outputData = data
        }

        let directory = Self.exportURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try outputData.write(to: Self.exportURL)
    }

    func importSettings() throws {
        let rawData = try Data(contentsOf: Self.exportURL)

        let encoder = JSONEncoder()
        let defaultsData = try encoder.encode(SettingsExport.defaults())

        guard var defaultsDict = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              let importedDict = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        else {
            let export = try JSONDecoder().decode(SettingsExport.self, from: rawData)
            applyImport(export)
            return
        }

        for (key, value) in importedDict where key != "hotkeyBindings" {
            defaultsDict[key] = value
        }

        // Element-wise merge for hotkeyBindings by id
        if let importedBindings = importedDict["hotkeyBindings"] as? [[String: Any]],
           let defaultBindings = defaultsDict["hotkeyBindings"] as? [[String: Any]] {
            let importedByID = Dictionary(
                importedBindings.compactMap { b in (b["id"] as? String).map { ($0, b) } },
                uniquingKeysWith: { _, last in last }
            )
            let merged = defaultBindings.map { defaultBinding -> [String: Any] in
                guard let id = defaultBinding["id"] as? String,
                      let imported = importedByID[id] else { return defaultBinding }
                return imported
            }
            defaultsDict["hotkeyBindings"] = merged
        }

        let mergedData = try JSONSerialization.data(withJSONObject: defaultsDict)
        let export = try JSONDecoder().decode(SettingsExport.self, from: mergedData)
        applyImport(export)
    }

    private func applyImport(_ export: SettingsExport) {        hotkeysEnabled = export.hotkeysEnabled
        focusFollowsMouse = export.focusFollowsMouse
        moveMouseToFocusedWindow = export.moveMouseToFocusedWindow
        mouseWarpEnabled = export.mouseWarpEnabled
        mouseWarpMonitorOrder = export.mouseWarpMonitorOrder
        mouseWarpMargin = export.mouseWarpMargin
        gapSize = export.gapSize
        outerGapLeft = export.outerGapLeft
        outerGapRight = export.outerGapRight
        outerGapTop = export.outerGapTop
        outerGapBottom = export.outerGapBottom

        niriMaxWindowsPerColumn = export.niriMaxWindowsPerColumn
        niriMaxVisibleColumns = export.niriMaxVisibleColumns
        niriInfiniteLoop = export.niriInfiniteLoop
        niriCenterFocusedColumn = CenterFocusedColumn(rawValue: export.niriCenterFocusedColumn) ?? .never
        niriAlwaysCenterSingleColumn = export.niriAlwaysCenterSingleColumn
        niriSingleWindowAspectRatio = SingleWindowAspectRatio(rawValue: export.niriSingleWindowAspectRatio) ?? .ratio4x3
        if let presets = export.niriColumnWidthPresets {
            niriColumnWidthPresets = Self.validatedPresets(presets)
        }

        persistentWorkspacesRaw = export.persistentWorkspacesRaw
        workspaceAssignmentsRaw = export.workspaceAssignmentsRaw
        workspaceConfigurations = export.workspaceConfigurations
        defaultLayoutType = LayoutType(rawValue: export.defaultLayoutType) ?? .niri

        bordersEnabled = export.bordersEnabled
        borderWidth = export.borderWidth
        borderColorRed = export.borderColorRed
        borderColorGreen = export.borderColorGreen
        borderColorBlue = export.borderColorBlue
        borderColorAlpha = export.borderColorAlpha

        hotkeyBindings = export.hotkeyBindings

        workspaceBarEnabled = export.workspaceBarEnabled
        workspaceBarShowLabels = export.workspaceBarShowLabels
        workspaceBarWindowLevel = WorkspaceBarWindowLevel(rawValue: export.workspaceBarWindowLevel) ?? .popup
        workspaceBarPosition = WorkspaceBarPosition(rawValue: export.workspaceBarPosition) ?? .overlappingMenuBar
        workspaceBarNotchAware = export.workspaceBarNotchAware
        workspaceBarDeduplicateAppIcons = export.workspaceBarDeduplicateAppIcons
        workspaceBarHideEmptyWorkspaces = export.workspaceBarHideEmptyWorkspaces
        workspaceBarHeight = export.workspaceBarHeight
        workspaceBarBackgroundOpacity = export.workspaceBarBackgroundOpacity
        workspaceBarXOffset = export.workspaceBarXOffset
        workspaceBarYOffset = export.workspaceBarYOffset
        monitorBarSettings = export.monitorBarSettings

        appRules = export.appRules
        monitorOrientationSettings = export.monitorOrientationSettings
        monitorNiriSettings = export.monitorNiriSettings

        dwindleSmartSplit = export.dwindleSmartSplit
        dwindleDefaultSplitRatio = export.dwindleDefaultSplitRatio
        dwindleSplitWidthMultiplier = export.dwindleSplitWidthMultiplier
        dwindleSingleWindowAspectRatio = DwindleSingleWindowAspectRatio(rawValue: export.dwindleSingleWindowAspectRatio) ?? .ratio4x3
        dwindleUseGlobalGaps = export.dwindleUseGlobalGaps
        dwindleMoveToRootStable = export.dwindleMoveToRootStable
        monitorDwindleSettings = export.monitorDwindleSettings

        preventSleepEnabled = export.preventSleepEnabled
        scrollGestureEnabled = export.scrollGestureEnabled
        scrollSensitivity = export.scrollSensitivity
        scrollModifierKey = ScrollModifierKey(rawValue: export.scrollModifierKey) ?? .optionShift
        gestureFingerCount = GestureFingerCount(rawValue: export.gestureFingerCount) ?? .three
        gestureInvertDirection = export.gestureInvertDirection

        menuAnywhereNativeEnabled = export.menuAnywhereNativeEnabled
        menuAnywherePaletteEnabled = export.menuAnywherePaletteEnabled
        menuAnywherePosition = MenuAnywherePosition(rawValue: export.menuAnywherePosition) ?? .cursor
        menuAnywhereShowShortcuts = export.menuAnywhereShowShortcuts

        hiddenBarEnabled = export.hiddenBarEnabled
        hiddenBarIsCollapsed = export.hiddenBarIsCollapsed

        if let opacity = export.quakeTerminalOpacity {
            quakeTerminalOpacity = opacity
        }
        if let modeRaw = export.quakeTerminalMonitorMode,
           let mode = QuakeTerminalMonitorMode(rawValue: modeRaw) {
            quakeTerminalMonitorMode = mode
        }

        appearanceMode = AppearanceMode(rawValue: export.appearanceMode) ?? .automatic
    }
}
