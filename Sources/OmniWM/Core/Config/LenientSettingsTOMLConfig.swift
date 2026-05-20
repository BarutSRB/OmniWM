import Foundation

private struct TOMLCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == TOMLCodingKey {
    func decodeIfPresent<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        try decodeIfPresent(type, forKey: TOMLCodingKey(key))
    }

    func decode<T: Decodable>(_ type: T.Type, for key: String, default defaultValue: T) throws -> T {
        try decodeIfPresent(type, for: key) ?? defaultValue
    }

    func nestedContainerIfPresent(for key: String) throws -> KeyedDecodingContainer<TOMLCodingKey>? {
        let codingKey = TOMLCodingKey(key)
        guard contains(codingKey) else { return nil }
        return try nestedContainer(keyedBy: TOMLCodingKey.self, forKey: codingKey)
    }
}

/// Migration decoder for older config files.
///
/// The canonical TOML schema intentionally writes every supported setting, but
/// decode must be more forgiving: a config from a previous OmniWM release should
/// keep the user's existing values and fill newly introduced keys from current
/// defaults instead of being treated as corrupt.
struct LenientSettingsTOMLConfig: Decodable {
    let export: SettingsExport

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: TOMLCodingKey.self)
        var export = SettingsExport.defaults()

        if let general = try root.nestedContainerIfPresent(for: "general") {
            export.hotkeysEnabled = try general.decode(Bool.self, for: "hotkeysEnabled", default: export.hotkeysEnabled)
            export.defaultLayoutType = try general.decode(String.self, for: "defaultLayoutType", default: export.defaultLayoutType)
            export.preventSleepEnabled = try general.decode(Bool.self, for: "preventSleepEnabled", default: export.preventSleepEnabled)
            export.updateChecksEnabled = try general.decode(Bool.self, for: "updateChecksEnabled", default: export.updateChecksEnabled)
            export.ipcEnabled = try general.decode(Bool.self, for: "ipcEnabled", default: export.ipcEnabled)
            export.animationsEnabled = try general.decode(Bool.self, for: "animationsEnabled", default: export.animationsEnabled)
        }

        if let focus = try root.nestedContainerIfPresent(for: "focus") {
            export.focusFollowsMouse = try focus.decode(Bool.self, for: "followsMouse", default: export.focusFollowsMouse)
            export.moveMouseToFocusedWindow = try focus.decode(Bool.self, for: "moveMouseToFocusedWindow", default: export.moveMouseToFocusedWindow)
            export.focusFollowsWindowToMonitor = try focus.decode(Bool.self, for: "followsWindowToMonitor", default: export.focusFollowsWindowToMonitor)
        }

        if let mouseWarp = try root.nestedContainerIfPresent(for: "mouseWarp") {
            export.mouseWarpMonitorOrder = try mouseWarp.decode([String].self, for: "monitorOrder", default: export.mouseWarpMonitorOrder)
            export.mouseWarpAxis = try mouseWarp.decodeIfPresent(String.self, for: "axis") ?? export.mouseWarpAxis
            export.mouseWarpMargin = try mouseWarp.decode(Int.self, for: "margin", default: export.mouseWarpMargin)
        }

        if let gaps = try root.nestedContainerIfPresent(for: "gaps") {
            export.gapSize = try gaps.decode(Double.self, for: "size", default: export.gapSize)
            if let outer = try gaps.nestedContainerIfPresent(for: "outer") {
                export.outerGapLeft = try outer.decode(Double.self, for: "left", default: export.outerGapLeft)
                export.outerGapRight = try outer.decode(Double.self, for: "right", default: export.outerGapRight)
                export.outerGapTop = try outer.decode(Double.self, for: "top", default: export.outerGapTop)
                export.outerGapBottom = try outer.decode(Double.self, for: "bottom", default: export.outerGapBottom)
            }
        }

        if let niri = try root.nestedContainerIfPresent(for: "niri") {
            export.niriMaxWindowsPerColumn = try niri.decode(Int.self, for: "maxWindowsPerColumn", default: export.niriMaxWindowsPerColumn)
            export.niriMaxVisibleColumns = try niri.decode(Int.self, for: "maxVisibleColumns", default: export.niriMaxVisibleColumns)
            export.niriInfiniteLoop = try niri.decode(Bool.self, for: "infiniteLoop", default: export.niriInfiniteLoop)
            export.niriCenterFocusedColumn = try niri.decode(String.self, for: "centerFocusedColumn", default: export.niriCenterFocusedColumn)
            export.niriAlwaysCenterSingleColumn = try niri.decode(Bool.self, for: "alwaysCenterSingleColumn", default: export.niriAlwaysCenterSingleColumn)
            export.niriSingleWindowAspectRatio = try niri.decode(String.self, for: "singleWindowAspectRatio", default: export.niriSingleWindowAspectRatio)
            export.niriColumnWidthPresets = try niri.decodeIfPresent([Double].self, for: "columnWidthPresets") ?? export.niriColumnWidthPresets
            export.niriDefaultColumnWidth = try niri.decodeIfPresent(Double.self, for: "defaultColumnWidth") ?? export.niriDefaultColumnWidth
        }

        if let dwindle = try root.nestedContainerIfPresent(for: "dwindle") {
            export.dwindleSmartSplit = try dwindle.decode(Bool.self, for: "smartSplit", default: export.dwindleSmartSplit)
            export.dwindleDefaultSplitRatio = try dwindle.decode(Double.self, for: "defaultSplitRatio", default: export.dwindleDefaultSplitRatio)
            export.dwindleSplitWidthMultiplier = try dwindle.decode(Double.self, for: "splitWidthMultiplier", default: export.dwindleSplitWidthMultiplier)
            export.dwindleSingleWindowAspectRatio = try dwindle.decode(String.self, for: "singleWindowAspectRatio", default: export.dwindleSingleWindowAspectRatio)
            export.dwindleUseGlobalGaps = try dwindle.decode(Bool.self, for: "useGlobalGaps", default: export.dwindleUseGlobalGaps)
            export.dwindleMoveToRootStable = try dwindle.decode(Bool.self, for: "moveToRootStable", default: export.dwindleMoveToRootStable)
        }

        if let borders = try root.nestedContainerIfPresent(for: "borders") {
            export.bordersEnabled = try borders.decode(Bool.self, for: "enabled", default: export.bordersEnabled)
            export.borderWidth = try borders.decode(Double.self, for: "width", default: export.borderWidth)
            if let color = try borders.nestedContainerIfPresent(for: "color") {
                export.borderColorRed = try color.decode(Double.self, for: "red", default: export.borderColorRed)
                export.borderColorGreen = try color.decode(Double.self, for: "green", default: export.borderColorGreen)
                export.borderColorBlue = try color.decode(Double.self, for: "blue", default: export.borderColorBlue)
                export.borderColorAlpha = try color.decode(Double.self, for: "alpha", default: export.borderColorAlpha)
            }
        }

        if let workspaceBar = try root.nestedContainerIfPresent(for: "workspaceBar") {
            export.workspaceBarEnabled = try workspaceBar.decode(Bool.self, for: "enabled", default: export.workspaceBarEnabled)
            export.workspaceBarShowLabels = try workspaceBar.decode(Bool.self, for: "showLabels", default: export.workspaceBarShowLabels)
            export.workspaceBarShowFloatingWindows = try workspaceBar.decode(Bool.self, for: "showFloatingWindows", default: export.workspaceBarShowFloatingWindows)
            export.workspaceBarWindowLevel = try workspaceBar.decode(String.self, for: "windowLevel", default: export.workspaceBarWindowLevel)
            export.workspaceBarPosition = try workspaceBar.decode(String.self, for: "position", default: export.workspaceBarPosition)
            export.workspaceBarNotchAware = try workspaceBar.decode(Bool.self, for: "notchAware", default: export.workspaceBarNotchAware)
            export.workspaceBarDeduplicateAppIcons = try workspaceBar.decode(Bool.self, for: "deduplicateAppIcons", default: export.workspaceBarDeduplicateAppIcons)
            export.workspaceBarHideEmptyWorkspaces = try workspaceBar.decode(Bool.self, for: "hideEmptyWorkspaces", default: export.workspaceBarHideEmptyWorkspaces)
            export.workspaceBarReserveLayoutSpace = try workspaceBar.decode(Bool.self, for: "reserveLayoutSpace", default: export.workspaceBarReserveLayoutSpace)
            export.workspaceBarHeight = try workspaceBar.decode(Double.self, for: "height", default: export.workspaceBarHeight)
            export.workspaceBarBackgroundOpacity = try workspaceBar.decode(Double.self, for: "backgroundOpacity", default: export.workspaceBarBackgroundOpacity)
            export.workspaceBarXOffset = try workspaceBar.decode(Double.self, for: "xOffset", default: export.workspaceBarXOffset)
            export.workspaceBarYOffset = try workspaceBar.decode(Double.self, for: "yOffset", default: export.workspaceBarYOffset)
            export.workspaceBarLabelFontSize = try workspaceBar.decode(Double.self, for: "labelFontSize", default: export.workspaceBarLabelFontSize)
            if let accent = try workspaceBar.nestedContainerIfPresent(for: "accentColor") {
                export.workspaceBarAccentColorRed = try accent.decode(Double.self, for: "red", default: export.workspaceBarAccentColorRed)
                export.workspaceBarAccentColorGreen = try accent.decode(Double.self, for: "green", default: export.workspaceBarAccentColorGreen)
                export.workspaceBarAccentColorBlue = try accent.decode(Double.self, for: "blue", default: export.workspaceBarAccentColorBlue)
                export.workspaceBarAccentColorAlpha = try accent.decode(Double.self, for: "alpha", default: export.workspaceBarAccentColorAlpha)
            }
            if let text = try workspaceBar.nestedContainerIfPresent(for: "textColor") {
                export.workspaceBarTextColorRed = try text.decode(Double.self, for: "red", default: export.workspaceBarTextColorRed)
                export.workspaceBarTextColorGreen = try text.decode(Double.self, for: "green", default: export.workspaceBarTextColorGreen)
                export.workspaceBarTextColorBlue = try text.decode(Double.self, for: "blue", default: export.workspaceBarTextColorBlue)
                export.workspaceBarTextColorAlpha = try text.decode(Double.self, for: "alpha", default: export.workspaceBarTextColorAlpha)
            }
        }

        if let gestures = try root.nestedContainerIfPresent(for: "gestures") {
            export.scrollGestureEnabled = try gestures.decode(Bool.self, for: "scrollEnabled", default: export.scrollGestureEnabled)
            export.scrollSensitivity = try gestures.decode(Double.self, for: "scrollSensitivity", default: export.scrollSensitivity)
            export.scrollModifierKey = try gestures.decode(String.self, for: "scrollModifierKey", default: export.scrollModifierKey)
            export.gestureFingerCount = try gestures.decode(Int.self, for: "fingerCount", default: export.gestureFingerCount)
            export.gestureInvertDirection = try gestures.decode(Bool.self, for: "invertDirection", default: export.gestureInvertDirection)
        }

        if let statusBar = try root.nestedContainerIfPresent(for: "statusBar") {
            export.statusBarShowWorkspaceName = try statusBar.decode(Bool.self, for: "showWorkspaceName", default: export.statusBarShowWorkspaceName)
            export.statusBarShowAppNames = try statusBar.decode(Bool.self, for: "showAppNames", default: export.statusBarShowAppNames)
            export.statusBarUseWorkspaceId = try statusBar.decode(Bool.self, for: "useWorkspaceId", default: export.statusBarUseWorkspaceId)
        }

        if let clipboard = try root.nestedContainerIfPresent(for: "clipboard") {
            export.clipboardHistoryEnabled = try clipboard.decode(Bool.self, for: "historyEnabled", default: export.clipboardHistoryEnabled)
            export.clipboardMaxItems = try clipboard.decode(Int.self, for: "maxItems", default: export.clipboardMaxItems)
            export.clipboardMaxItemBytes = try clipboard.decode(Int.self, for: "maxItemBytes", default: export.clipboardMaxItemBytes)
            export.clipboardMaxTotalBytes = try clipboard.decode(Int.self, for: "maxTotalBytes", default: export.clipboardMaxTotalBytes)
        }

        if let quake = try root.nestedContainerIfPresent(for: "quakeTerminal") {
            export.quakeTerminalEnabled = try quake.decode(Bool.self, for: "enabled", default: export.quakeTerminalEnabled)
            export.quakeTerminalPosition = try quake.decode(String.self, for: "position", default: export.quakeTerminalPosition)
            export.quakeTerminalWidthPercent = try quake.decode(Double.self, for: "widthPercent", default: export.quakeTerminalWidthPercent)
            export.quakeTerminalHeightPercent = try quake.decode(Double.self, for: "heightPercent", default: export.quakeTerminalHeightPercent)
            export.quakeTerminalAnimationDuration = try quake.decode(Double.self, for: "animationDuration", default: export.quakeTerminalAnimationDuration)
            export.quakeTerminalAutoHide = try quake.decode(Bool.self, for: "autoHide", default: export.quakeTerminalAutoHide)
            export.quakeTerminalOpacity = try quake.decodeIfPresent(Double.self, for: "opacity") ?? export.quakeTerminalOpacity
            export.quakeTerminalMonitorMode = try quake.decodeIfPresent(String.self, for: "monitorMode") ?? export.quakeTerminalMonitorMode
            export.quakeTerminalUseCustomFrame = try quake.decode(Bool.self, for: "useCustomFrame", default: export.quakeTerminalUseCustomFrame)
            if let frame = try quake.nestedContainerIfPresent(for: "customFrame") {
                let seededFrame = export.quakeTerminalCustomFrame
                let x = try frame.decodeIfPresent(Double.self, for: "x") ?? seededFrame?.x
                let y = try frame.decodeIfPresent(Double.self, for: "y") ?? seededFrame?.y
                let width = try frame.decodeIfPresent(Double.self, for: "width") ?? seededFrame?.width
                let height = try frame.decodeIfPresent(Double.self, for: "height") ?? seededFrame?.height

                if let x, let y, let width, let height {
                    export.quakeTerminalCustomFrame = QuakeTerminalFrameExport(
                        x: x,
                        y: y,
                        width: width,
                        height: height
                    )
                }
            }
        }

        if let appearance = try root.nestedContainerIfPresent(for: "appearance") {
            export.appearanceMode = try appearance.decode(String.self, for: "mode", default: export.appearanceMode)
        }

        if let state = try root.nestedContainerIfPresent(for: "state") {
            export.commandPaletteLastMode = try state.decode(String.self, for: "commandPaletteLastMode", default: export.commandPaletteLastMode)
            export.hiddenBarIsCollapsed = try state.decode(Bool.self, for: "hiddenBarIsCollapsed", default: export.hiddenBarIsCollapsed)
        }

        export.hotkeyBindings = try root.decode([HotkeyBinding].self, for: "hotkeys", default: export.hotkeyBindings)
        export.workspaceConfigurations = try root.decode([WorkspaceConfiguration].self, for: "workspaces", default: export.workspaceConfigurations)
        export.appRules = try root.decode([AppRule].self, for: "appRules", default: export.appRules)
        export.monitorBarSettings = try root.decode([MonitorBarSettings].self, for: "monitorBarOverrides", default: export.monitorBarSettings)
        export.monitorOrientationSettings = try root.decode([MonitorOrientationSettings].self, for: "monitorOrientationOverrides", default: export.monitorOrientationSettings)
        export.monitorNiriSettings = try root.decode([MonitorNiriSettings].self, for: "monitorNiriOverrides", default: export.monitorNiriSettings)
        export.monitorDwindleSettings = try root.decode([MonitorDwindleSettings].self, for: "monitorDwindleOverrides", default: export.monitorDwindleSettings)

        self.export = export
    }
}
