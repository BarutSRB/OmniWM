// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import OmniWMIPC

struct QuakeTerminalFrameExport: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(frame: CGRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
    }

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SettingsExport: Codable, Equatable {
    var version: Int = SettingsFilePersistence.configVersion

    var hotkeysEnabled: Bool
    var focusFollowsMouse: Bool
    var moveMouseToFocusedWindow: Bool
    var focusFollowsWindowToMonitor: Bool
    var mouseWarpMonitorOrder: [OutputId]
    var mouseWarpAxis: String?
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
    var niriDefaultColumnWidth: Double?

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
    var workspaceBarShowFloatingWindows: Bool
    var workspaceBarWindowLevel: String
    var workspaceBarPosition: String
    var workspaceBarNotchAware: Bool
    var workspaceBarDeduplicateAppIcons: Bool
    var workspaceBarHideEmptyWorkspaces: Bool
    var workspaceBarReserveLayoutSpace: Bool
    var workspaceBarHeight: Double
    var workspaceBarBackgroundOpacity: Double
    var workspaceBarXOffset: Double
    var workspaceBarYOffset: Double
    var workspaceBarAccentColorRed: Double
    var workspaceBarAccentColorGreen: Double
    var workspaceBarAccentColorBlue: Double
    var workspaceBarAccentColorAlpha: Double
    var workspaceBarTextColorRed: Double
    var workspaceBarTextColorGreen: Double
    var workspaceBarTextColorBlue: Double
    var workspaceBarTextColorAlpha: Double
    var workspaceBarLabelFontSize: Double
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
    var updateChecksEnabled: Bool
    var ipcEnabled: Bool
    var scrollGestureEnabled: Bool
    var scrollSensitivity: Double
    var scrollModifierKey: String
    var gestureFingerCount: Int
    var gestureInvertDirection: Bool
    var statusBarShowWorkspaceName: Bool
    var statusBarShowAppNames: Bool
    var statusBarUseWorkspaceId: Bool
    var commandPaletteLastMode: String
    var animationsEnabled: Bool

    var hiddenBarIsCollapsed: Bool

    var quakeTerminalEnabled: Bool
    var quakeTerminalPosition: String
    var quakeTerminalWidthPercent: Double
    var quakeTerminalHeightPercent: Double
    var quakeTerminalAnimationDuration: Double
    var quakeTerminalAutoHide: Bool
    var quakeTerminalOpacity: Double?
    var quakeTerminalMonitorMode: String?
    var quakeTerminalUseCustomFrame: Bool
    var quakeTerminalCustomFrame: QuakeTerminalFrameExport?

    var appearanceMode: String
}

extension SettingsExport {
    static func defaults() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: true,
            focusFollowsMouse: false,
            moveMouseToFocusedWindow: false,
            focusFollowsWindowToMonitor: false,
            mouseWarpMonitorOrder: [],
            mouseWarpAxis: MouseWarpAxis.horizontal.rawValue,
            mouseWarpMargin: 1,
            gapSize: 8,
            outerGapLeft: 8,
            outerGapRight: 8,
            outerGapTop: 8,
            outerGapBottom: 8,
            niriMaxWindowsPerColumn: 3,
            niriMaxVisibleColumns: 2,
            niriInfiniteLoop: false,
            niriCenterFocusedColumn: CenterFocusedColumn.never.rawValue,
            niriAlwaysCenterSingleColumn: true,
            niriSingleWindowAspectRatio: SingleWindowAspectRatio.ratio4x3.rawValue,
            niriColumnWidthPresets: BuiltInSettingsDefaults.niriColumnWidthPresets,
            niriDefaultColumnWidth: nil,
            workspaceConfigurations: BuiltInSettingsDefaults.workspaceConfigurations,
            defaultLayoutType: LayoutType.niri.rawValue,
            bordersEnabled: true,
            borderWidth: 5.0,
            borderColorRed: 0.084585202284378935,
            borderColorGreen: 1.0,
            borderColorBlue: 0.97930003794467602,
            borderColorAlpha: 1.0,
            hotkeyBindings: HotkeyBindingRegistry.defaults(),
            workspaceBarEnabled: true,
            workspaceBarShowLabels: true,
            workspaceBarShowFloatingWindows: false,
            workspaceBarWindowLevel: WorkspaceBarWindowLevel.popup.rawValue,
            workspaceBarPosition: WorkspaceBarPosition.overlappingMenuBar.rawValue,
            workspaceBarNotchAware: true,
            workspaceBarDeduplicateAppIcons: false,
            workspaceBarHideEmptyWorkspaces: false,
            workspaceBarReserveLayoutSpace: false,
            workspaceBarHeight: 24.0,
            workspaceBarBackgroundOpacity: 0.1,
            workspaceBarXOffset: 0.0,
            workspaceBarYOffset: 0.0,
            workspaceBarAccentColorRed: -1,
            workspaceBarAccentColorGreen: -1,
            workspaceBarAccentColorBlue: -1,
            workspaceBarAccentColorAlpha: 1,
            workspaceBarTextColorRed: -1,
            workspaceBarTextColorGreen: -1,
            workspaceBarTextColorBlue: -1,
            workspaceBarTextColorAlpha: 1,
            workspaceBarLabelFontSize: 12,
            monitorBarSettings: [],
            appRules: BuiltInSettingsDefaults.appRules,
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
            updateChecksEnabled: true,
            ipcEnabled: false,
            scrollGestureEnabled: true,
            scrollSensitivity: 5.0,
            scrollModifierKey: ScrollModifierKey.optionShift.rawValue,
            gestureFingerCount: GestureFingerCount.three.rawValue,
            gestureInvertDirection: true,
            statusBarShowWorkspaceName: false,
            statusBarShowAppNames: false,
            statusBarUseWorkspaceId: false,
            commandPaletteLastMode: CommandPaletteMode.windows.rawValue,
            animationsEnabled: true,
            hiddenBarIsCollapsed: true,
            quakeTerminalEnabled: true,
            quakeTerminalPosition: QuakeTerminalPosition.center.rawValue,
            quakeTerminalWidthPercent: 50.0,
            quakeTerminalHeightPercent: 50.0,
            quakeTerminalAnimationDuration: 0.2,
            quakeTerminalAutoHide: false,
            quakeTerminalOpacity: 1.0,
            quakeTerminalMonitorMode: QuakeTerminalMonitorMode.focusedWindow.rawValue,
            quakeTerminalUseCustomFrame: false,
            quakeTerminalCustomFrame: nil,
            appearanceMode: AppearanceMode.dark.rawValue
        )
    }

}
