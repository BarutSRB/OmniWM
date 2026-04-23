// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct CanonicalTOMLConfig: Codable, Equatable {
    var version: Int
    var general: General
    var focus: Focus
    var mouseWarp: MouseWarp
    var gaps: Gaps
    var niri: Niri
    var dwindle: Dwindle
    var borders: Borders
    var workspaceBar: WorkspaceBar
    var gestures: Gestures
    var statusBar: StatusBar
    var quakeTerminal: QuakeTerminal
    var appearance: Appearance
    var state: State
    var hotkeys: [HotkeyBinding]
    var workspaces: [WorkspaceConfiguration]
    var appRules: [AppRule]
    var monitorBarOverrides: [MonitorBarSettings]
    var monitorOrientationOverrides: [MonitorOrientationSettings]
    var monitorNiriOverrides: [MonitorNiriSettings]
    var monitorDwindleOverrides: [MonitorDwindleSettings]

    struct General: Codable, Equatable {
        var hotkeysEnabled: Bool
        var defaultLayoutType: String
        var preventSleepEnabled: Bool
        var updateChecksEnabled: Bool
        var ipcEnabled: Bool
        var animationsEnabled: Bool
    }

    struct Focus: Codable, Equatable {
        var followsMouse: Bool
        var moveMouseToFocusedWindow: Bool
        var followsWindowToMonitor: Bool
    }

    struct MouseWarp: Codable, Equatable {
        var monitorOrder: [OutputId]
        var axis: String?
        var margin: Int
    }

    struct Gaps: Codable, Equatable {
        var size: Double
        var outer: Outer

        struct Outer: Codable, Equatable {
            var left: Double
            var right: Double
            var top: Double
            var bottom: Double
        }
    }

    struct Niri: Codable, Equatable {
        var maxWindowsPerColumn: Int
        var maxVisibleColumns: Int
        var infiniteLoop: Bool
        var centerFocusedColumn: String
        var alwaysCenterSingleColumn: Bool
        var singleWindowAspectRatio: String
        var columnWidthPresets: [Double]?
        var defaultColumnWidth: Double?
    }

    struct Dwindle: Codable, Equatable {
        var smartSplit: Bool
        var defaultSplitRatio: Double
        var splitWidthMultiplier: Double
        var singleWindowAspectRatio: String
        var useGlobalGaps: Bool
        var moveToRootStable: Bool
    }

    struct Borders: Codable, Equatable {
        var enabled: Bool
        var width: Double
        var color: Color

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double
        }
    }

    struct WorkspaceBar: Codable, Equatable {
        var enabled: Bool
        var showLabels: Bool
        var showFloatingWindows: Bool
        var windowLevel: String
        var position: String
        var notchAware: Bool
        var deduplicateAppIcons: Bool
        var hideEmptyWorkspaces: Bool
        var reserveLayoutSpace: Bool
        var height: Double
        var backgroundOpacity: Double
        var xOffset: Double
        var yOffset: Double
        var labelFontSize: Double
        var accentColor: Color
        var textColor: Color

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double
        }
    }

    struct Gestures: Codable, Equatable {
        var scrollEnabled: Bool
        var scrollSensitivity: Double
        var scrollModifierKey: String
        var fingerCount: Int
        var invertDirection: Bool
    }

    struct StatusBar: Codable, Equatable {
        var showWorkspaceName: Bool
        var showAppNames: Bool
        var useWorkspaceId: Bool
    }

    struct QuakeTerminal: Codable, Equatable {
        var enabled: Bool
        var position: String
        var widthPercent: Double
        var heightPercent: Double
        var animationDuration: Double
        var autoHide: Bool
        var opacity: Double?
        var monitorMode: String?
        var useCustomFrame: Bool
        var customFrame: Frame?

        struct Frame: Codable, Equatable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double
        }
    }

    struct Appearance: Codable, Equatable {
        var mode: String
    }

    struct State: Codable, Equatable {
        var commandPaletteLastMode: String
        var hiddenBarIsCollapsed: Bool
    }
}

extension CanonicalTOMLConfig {
    init(export: SettingsExport) {
        version = export.version
        general = General(
            hotkeysEnabled: export.hotkeysEnabled,
            defaultLayoutType: export.defaultLayoutType,
            preventSleepEnabled: export.preventSleepEnabled,
            updateChecksEnabled: export.updateChecksEnabled,
            ipcEnabled: export.ipcEnabled,
            animationsEnabled: export.animationsEnabled
        )
        focus = Focus(
            followsMouse: export.focusFollowsMouse,
            moveMouseToFocusedWindow: export.moveMouseToFocusedWindow,
            followsWindowToMonitor: export.focusFollowsWindowToMonitor
        )
        mouseWarp = MouseWarp(
            monitorOrder: export.mouseWarpMonitorOrder,
            axis: export.mouseWarpAxis,
            margin: export.mouseWarpMargin
        )
        gaps = Gaps(
            size: export.gapSize,
            outer: Gaps.Outer(
                left: export.outerGapLeft,
                right: export.outerGapRight,
                top: export.outerGapTop,
                bottom: export.outerGapBottom
            )
        )
        niri = Niri(
            maxWindowsPerColumn: export.niriMaxWindowsPerColumn,
            maxVisibleColumns: export.niriMaxVisibleColumns,
            infiniteLoop: export.niriInfiniteLoop,
            centerFocusedColumn: export.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: export.niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: export.niriSingleWindowAspectRatio,
            columnWidthPresets: export.niriColumnWidthPresets,
            defaultColumnWidth: export.niriDefaultColumnWidth
        )
        dwindle = Dwindle(
            smartSplit: export.dwindleSmartSplit,
            defaultSplitRatio: export.dwindleDefaultSplitRatio,
            splitWidthMultiplier: export.dwindleSplitWidthMultiplier,
            singleWindowAspectRatio: export.dwindleSingleWindowAspectRatio,
            useGlobalGaps: export.dwindleUseGlobalGaps,
            moveToRootStable: export.dwindleMoveToRootStable
        )
        borders = Borders(
            enabled: export.bordersEnabled,
            width: export.borderWidth,
            color: Borders.Color(
                red: export.borderColorRed,
                green: export.borderColorGreen,
                blue: export.borderColorBlue,
                alpha: export.borderColorAlpha
            )
        )
        workspaceBar = WorkspaceBar(
            enabled: export.workspaceBarEnabled,
            showLabels: export.workspaceBarShowLabels,
            showFloatingWindows: export.workspaceBarShowFloatingWindows,
            windowLevel: export.workspaceBarWindowLevel,
            position: export.workspaceBarPosition,
            notchAware: export.workspaceBarNotchAware,
            deduplicateAppIcons: export.workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: export.workspaceBarHideEmptyWorkspaces,
            reserveLayoutSpace: export.workspaceBarReserveLayoutSpace,
            height: export.workspaceBarHeight,
            backgroundOpacity: export.workspaceBarBackgroundOpacity,
            xOffset: export.workspaceBarXOffset,
            yOffset: export.workspaceBarYOffset,
            labelFontSize: export.workspaceBarLabelFontSize,
            accentColor: WorkspaceBar.Color(
                red: export.workspaceBarAccentColorRed,
                green: export.workspaceBarAccentColorGreen,
                blue: export.workspaceBarAccentColorBlue,
                alpha: export.workspaceBarAccentColorAlpha
            ),
            textColor: WorkspaceBar.Color(
                red: export.workspaceBarTextColorRed,
                green: export.workspaceBarTextColorGreen,
                blue: export.workspaceBarTextColorBlue,
                alpha: export.workspaceBarTextColorAlpha
            )
        )
        gestures = Gestures(
            scrollEnabled: export.scrollGestureEnabled,
            scrollSensitivity: export.scrollSensitivity,
            scrollModifierKey: export.scrollModifierKey,
            fingerCount: export.gestureFingerCount,
            invertDirection: export.gestureInvertDirection
        )
        statusBar = StatusBar(
            showWorkspaceName: export.statusBarShowWorkspaceName,
            showAppNames: export.statusBarShowAppNames,
            useWorkspaceId: export.statusBarUseWorkspaceId
        )
        let customFrame: QuakeTerminal.Frame? = export.quakeTerminalCustomFrame.map { frame in
            QuakeTerminal.Frame(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
        quakeTerminal = QuakeTerminal(
            enabled: export.quakeTerminalEnabled,
            position: export.quakeTerminalPosition,
            widthPercent: export.quakeTerminalWidthPercent,
            heightPercent: export.quakeTerminalHeightPercent,
            animationDuration: export.quakeTerminalAnimationDuration,
            autoHide: export.quakeTerminalAutoHide,
            opacity: export.quakeTerminalOpacity,
            monitorMode: export.quakeTerminalMonitorMode,
            useCustomFrame: export.quakeTerminalUseCustomFrame,
            customFrame: customFrame
        )
        appearance = Appearance(mode: export.appearanceMode)
        state = State(
            commandPaletteLastMode: export.commandPaletteLastMode,
            hiddenBarIsCollapsed: export.hiddenBarIsCollapsed
        )
        hotkeys = export.hotkeyBindings
        workspaces = export.workspaceConfigurations
        appRules = export.appRules
        monitorBarOverrides = export.monitorBarSettings
        monitorOrientationOverrides = export.monitorOrientationSettings
        monitorNiriOverrides = export.monitorNiriSettings
        monitorDwindleOverrides = export.monitorDwindleSettings
    }

    func toSettingsExport() -> SettingsExport {
        let customFrame: QuakeTerminalFrameExport? = quakeTerminal.customFrame.map { frame in
            QuakeTerminalFrameExport(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
        return SettingsExport(
            version: version,
            hotkeysEnabled: general.hotkeysEnabled,
            focusFollowsMouse: focus.followsMouse,
            moveMouseToFocusedWindow: focus.moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: focus.followsWindowToMonitor,
            mouseWarpMonitorOrder: mouseWarp.monitorOrder,
            mouseWarpAxis: mouseWarp.axis,
            mouseWarpMargin: mouseWarp.margin,
            gapSize: gaps.size,
            outerGapLeft: gaps.outer.left,
            outerGapRight: gaps.outer.right,
            outerGapTop: gaps.outer.top,
            outerGapBottom: gaps.outer.bottom,
            niriMaxWindowsPerColumn: niri.maxWindowsPerColumn,
            niriMaxVisibleColumns: niri.maxVisibleColumns,
            niriInfiniteLoop: niri.infiniteLoop,
            niriCenterFocusedColumn: niri.centerFocusedColumn,
            niriAlwaysCenterSingleColumn: niri.alwaysCenterSingleColumn,
            niriSingleWindowAspectRatio: niri.singleWindowAspectRatio,
            niriColumnWidthPresets: niri.columnWidthPresets,
            niriDefaultColumnWidth: niri.defaultColumnWidth,
            workspaceConfigurations: workspaces,
            defaultLayoutType: general.defaultLayoutType,
            bordersEnabled: borders.enabled,
            borderWidth: borders.width,
            borderColorRed: borders.color.red,
            borderColorGreen: borders.color.green,
            borderColorBlue: borders.color.blue,
            borderColorAlpha: borders.color.alpha,
            hotkeyBindings: hotkeys,
            workspaceBarEnabled: workspaceBar.enabled,
            workspaceBarShowLabels: workspaceBar.showLabels,
            workspaceBarShowFloatingWindows: workspaceBar.showFloatingWindows,
            workspaceBarWindowLevel: workspaceBar.windowLevel,
            workspaceBarPosition: workspaceBar.position,
            workspaceBarNotchAware: workspaceBar.notchAware,
            workspaceBarDeduplicateAppIcons: workspaceBar.deduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: workspaceBar.hideEmptyWorkspaces,
            workspaceBarReserveLayoutSpace: workspaceBar.reserveLayoutSpace,
            workspaceBarHeight: workspaceBar.height,
            workspaceBarBackgroundOpacity: workspaceBar.backgroundOpacity,
            workspaceBarXOffset: workspaceBar.xOffset,
            workspaceBarYOffset: workspaceBar.yOffset,
            workspaceBarAccentColorRed: workspaceBar.accentColor.red,
            workspaceBarAccentColorGreen: workspaceBar.accentColor.green,
            workspaceBarAccentColorBlue: workspaceBar.accentColor.blue,
            workspaceBarAccentColorAlpha: workspaceBar.accentColor.alpha,
            workspaceBarTextColorRed: workspaceBar.textColor.red,
            workspaceBarTextColorGreen: workspaceBar.textColor.green,
            workspaceBarTextColorBlue: workspaceBar.textColor.blue,
            workspaceBarTextColorAlpha: workspaceBar.textColor.alpha,
            workspaceBarLabelFontSize: workspaceBar.labelFontSize,
            monitorBarSettings: monitorBarOverrides,
            appRules: appRules,
            monitorOrientationSettings: monitorOrientationOverrides,
            monitorNiriSettings: monitorNiriOverrides,
            dwindleSmartSplit: dwindle.smartSplit,
            dwindleDefaultSplitRatio: dwindle.defaultSplitRatio,
            dwindleSplitWidthMultiplier: dwindle.splitWidthMultiplier,
            dwindleSingleWindowAspectRatio: dwindle.singleWindowAspectRatio,
            dwindleUseGlobalGaps: dwindle.useGlobalGaps,
            dwindleMoveToRootStable: dwindle.moveToRootStable,
            monitorDwindleSettings: monitorDwindleOverrides,
            preventSleepEnabled: general.preventSleepEnabled,
            updateChecksEnabled: general.updateChecksEnabled,
            ipcEnabled: general.ipcEnabled,
            scrollGestureEnabled: gestures.scrollEnabled,
            scrollSensitivity: gestures.scrollSensitivity,
            scrollModifierKey: gestures.scrollModifierKey,
            gestureFingerCount: gestures.fingerCount,
            gestureInvertDirection: gestures.invertDirection,
            statusBarShowWorkspaceName: statusBar.showWorkspaceName,
            statusBarShowAppNames: statusBar.showAppNames,
            statusBarUseWorkspaceId: statusBar.useWorkspaceId,
            commandPaletteLastMode: state.commandPaletteLastMode,
            animationsEnabled: general.animationsEnabled,
            hiddenBarIsCollapsed: state.hiddenBarIsCollapsed,
            quakeTerminalEnabled: quakeTerminal.enabled,
            quakeTerminalPosition: quakeTerminal.position,
            quakeTerminalWidthPercent: quakeTerminal.widthPercent,
            quakeTerminalHeightPercent: quakeTerminal.heightPercent,
            quakeTerminalAnimationDuration: quakeTerminal.animationDuration,
            quakeTerminalAutoHide: quakeTerminal.autoHide,
            quakeTerminalOpacity: quakeTerminal.opacity,
            quakeTerminalMonitorMode: quakeTerminal.monitorMode,
            quakeTerminalUseCustomFrame: quakeTerminal.useCustomFrame,
            quakeTerminalCustomFrame: customFrame,
            appearanceMode: appearance.mode
        )
    }
}
