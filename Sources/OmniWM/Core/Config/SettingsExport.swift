import Foundation

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

    var animationsEnabled: Bool

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

extension SettingsStore {
    static var exportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omniwm/settings.json")
    }

    var settingsFileExists: Bool {
        FileManager.default.fileExists(atPath: Self.exportURL.path)
    }

    func exportSettings() throws {
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
            animationsEnabled: animationsEnabled,
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

        let directory = Self.exportURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: Self.exportURL)
    }

    func importSettings() throws {
        let data = try Data(contentsOf: Self.exportURL)
        let export = try JSONDecoder().decode(SettingsExport.self, from: data)

        hotkeysEnabled = export.hotkeysEnabled
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

        animationsEnabled = export.animationsEnabled

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
