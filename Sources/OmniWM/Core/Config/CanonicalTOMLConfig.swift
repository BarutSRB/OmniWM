import Foundation

extension CodingUserInfoKey {
    static let settingsTOMLRecoverMissingKeys = CodingUserInfoKey(rawValue: "settingsTOMLRecoverMissingKeys")!
}

struct CanonicalTOMLConfig: Codable, Equatable {
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
    var clipboard: Clipboard
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
        // monitorOrder is a flat string array for now; future revision may use a typed OutputId.
        var monitorOrder: [String]
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
        var scrollSnapEnabled: Bool
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
        var mouseResizeModifierKey: String
        var fingerCount: Int
        var invertDirection: Bool
    }

    struct StatusBar: Codable, Equatable {
        var showWorkspaceName: Bool
        var showAppNames: Bool
        var useWorkspaceId: Bool
    }

    struct Clipboard: Codable, Equatable {
        var historyEnabled: Bool
        var maxItems: Int
        var maxItemBytes: Int
        var maxTotalBytes: Int
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
    }
}

private extension Decoder {
    var recoversMissingSettingsTOMLKeys: Bool {
        userInfo[.settingsTOMLRecoverMissingKeys] as? Bool == true
    }
}

private extension KeyedDecodingContainer {
    func decode<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T,
        recovering: Bool
    ) throws -> T {
        if recovering {
            return try decodeIfPresent(type, forKey: key) ?? defaultValue
        }
        return try decode(type, forKey: key)
    }

    func decode<T>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T,
        recovering: Bool,
        using decode: (Decoder, T, Bool) throws -> T
    ) throws -> T {
        if recovering, !contains(key) {
            return defaultValue
        }
        return try decode(superDecoder(forKey: key), defaultValue, recovering)
    }
}

private extension CanonicalTOMLConfig {
    static func recoveryDefaults() -> CanonicalTOMLConfig {
        CanonicalTOMLConfig(export: SettingsExport.defaults())
    }
}

extension CanonicalTOMLConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = Self.recoveryDefaults()

        general = try container.decode(General.self, forKey: .general, default: defaults.general, recovering: recovering)
        focus = try container.decode(Focus.self, forKey: .focus, default: defaults.focus, recovering: recovering)
        mouseWarp = try container.decode(MouseWarp.self, forKey: .mouseWarp, default: defaults.mouseWarp, recovering: recovering)
        gaps = try container.decode(Gaps.self, forKey: .gaps, default: defaults.gaps, recovering: recovering)
        niri = try container.decode(Niri.self, forKey: .niri, default: defaults.niri, recovering: recovering)
        dwindle = try container.decode(Dwindle.self, forKey: .dwindle, default: defaults.dwindle, recovering: recovering)
        borders = try container.decode(Borders.self, forKey: .borders, default: defaults.borders, recovering: recovering)
        workspaceBar = try container.decode(
            WorkspaceBar.self,
            forKey: .workspaceBar,
            default: defaults.workspaceBar,
            recovering: recovering
        )
        gestures = try container.decode(Gestures.self, forKey: .gestures, default: defaults.gestures, recovering: recovering)
        statusBar = try container.decode(StatusBar.self, forKey: .statusBar, default: defaults.statusBar, recovering: recovering)
        clipboard = try container.decode(Clipboard.self, forKey: .clipboard, default: defaults.clipboard, recovering: recovering)
        quakeTerminal = try container.decode(
            QuakeTerminal.self,
            forKey: .quakeTerminal,
            default: defaults.quakeTerminal,
            recovering: recovering
        )
        appearance = try container.decode(Appearance.self, forKey: .appearance, default: defaults.appearance, recovering: recovering)
        state = try container.decode(State.self, forKey: .state, default: defaults.state, recovering: recovering)
        hotkeys = try container.decode([HotkeyBinding].self, forKey: .hotkeys, default: defaults.hotkeys, recovering: recovering)
        workspaces = try container.decode(
            [WorkspaceConfiguration].self,
            forKey: .workspaces,
            default: defaults.workspaces,
            recovering: recovering
        )
        appRules = try container.decode([AppRule].self, forKey: .appRules, default: defaults.appRules, recovering: recovering)
        monitorBarOverrides = try container.decode(
            [MonitorBarSettings].self,
            forKey: .monitorBarOverrides,
            default: defaults.monitorBarOverrides,
            recovering: recovering
        )
        monitorOrientationOverrides = try container.decode(
            [MonitorOrientationSettings].self,
            forKey: .monitorOrientationOverrides,
            default: defaults.monitorOrientationOverrides,
            recovering: recovering
        )
        monitorNiriOverrides = try container.decode(
            [MonitorNiriSettings].self,
            forKey: .monitorNiriOverrides,
            default: defaults.monitorNiriOverrides,
            recovering: recovering
        )
        monitorDwindleOverrides = try container.decode(
            [MonitorDwindleSettings].self,
            forKey: .monitorDwindleOverrides,
            default: defaults.monitorDwindleOverrides,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.General {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().general

        hotkeysEnabled = try container.decode(Bool.self, forKey: .hotkeysEnabled, default: defaults.hotkeysEnabled, recovering: recovering)
        defaultLayoutType = try container.decode(String.self, forKey: .defaultLayoutType, default: defaults.defaultLayoutType, recovering: recovering)
        preventSleepEnabled = try container.decode(Bool.self, forKey: .preventSleepEnabled, default: defaults.preventSleepEnabled, recovering: recovering)
        updateChecksEnabled = try container.decode(Bool.self, forKey: .updateChecksEnabled, default: defaults.updateChecksEnabled, recovering: recovering)
        ipcEnabled = try container.decode(Bool.self, forKey: .ipcEnabled, default: defaults.ipcEnabled, recovering: recovering)
        animationsEnabled = try container.decode(Bool.self, forKey: .animationsEnabled, default: defaults.animationsEnabled, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Focus {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().focus

        followsMouse = try container.decode(Bool.self, forKey: .followsMouse, default: defaults.followsMouse, recovering: recovering)
        moveMouseToFocusedWindow = try container.decode(
            Bool.self,
            forKey: .moveMouseToFocusedWindow,
            default: defaults.moveMouseToFocusedWindow,
            recovering: recovering
        )
        followsWindowToMonitor = try container.decode(
            Bool.self,
            forKey: .followsWindowToMonitor,
            default: defaults.followsWindowToMonitor,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.MouseWarp {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().mouseWarp

        monitorOrder = try container.decode([String].self, forKey: .monitorOrder, default: defaults.monitorOrder, recovering: recovering)
        axis = try container.decodeIfPresent(String.self, forKey: .axis)
        margin = try container.decode(Int.self, forKey: .margin, default: defaults.margin, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Gaps {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().gaps

        size = try container.decode(Double.self, forKey: .size, default: defaults.size, recovering: recovering)
        outer = try container.decode(Outer.self, forKey: .outer, default: defaults.outer, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Gaps.Outer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().gaps.outer

        left = try container.decode(Double.self, forKey: .left, default: defaults.left, recovering: recovering)
        right = try container.decode(Double.self, forKey: .right, default: defaults.right, recovering: recovering)
        top = try container.decode(Double.self, forKey: .top, default: defaults.top, recovering: recovering)
        bottom = try container.decode(Double.self, forKey: .bottom, default: defaults.bottom, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Niri {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().niri

        maxWindowsPerColumn = try container.decode(
            Int.self,
            forKey: .maxWindowsPerColumn,
            default: defaults.maxWindowsPerColumn,
            recovering: recovering
        )
        maxVisibleColumns = try container.decode(Int.self, forKey: .maxVisibleColumns, default: defaults.maxVisibleColumns, recovering: recovering)
        infiniteLoop = try container.decode(Bool.self, forKey: .infiniteLoop, default: defaults.infiniteLoop, recovering: recovering)
        centerFocusedColumn = try container.decode(String.self, forKey: .centerFocusedColumn, default: defaults.centerFocusedColumn, recovering: recovering)
        alwaysCenterSingleColumn = try container.decode(
            Bool.self,
            forKey: .alwaysCenterSingleColumn,
            default: defaults.alwaysCenterSingleColumn,
            recovering: recovering
        )
        scrollSnapEnabled = try container.decode(
            Bool.self,
            forKey: .scrollSnapEnabled,
            default: defaults.scrollSnapEnabled,
            recovering: recovering
        )
        singleWindowAspectRatio = try container.decode(
            String.self,
            forKey: .singleWindowAspectRatio,
            default: defaults.singleWindowAspectRatio,
            recovering: recovering
        )
        columnWidthPresets = try container.decodeIfPresent([Double].self, forKey: .columnWidthPresets)
        defaultColumnWidth = try container.decodeIfPresent(Double.self, forKey: .defaultColumnWidth)
    }
}

extension CanonicalTOMLConfig.Dwindle {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().dwindle

        smartSplit = try container.decode(Bool.self, forKey: .smartSplit, default: defaults.smartSplit, recovering: recovering)
        defaultSplitRatio = try container.decode(Double.self, forKey: .defaultSplitRatio, default: defaults.defaultSplitRatio, recovering: recovering)
        splitWidthMultiplier = try container.decode(
            Double.self,
            forKey: .splitWidthMultiplier,
            default: defaults.splitWidthMultiplier,
            recovering: recovering
        )
        singleWindowAspectRatio = try container.decode(
            String.self,
            forKey: .singleWindowAspectRatio,
            default: defaults.singleWindowAspectRatio,
            recovering: recovering
        )
        useGlobalGaps = try container.decode(Bool.self, forKey: .useGlobalGaps, default: defaults.useGlobalGaps, recovering: recovering)
        moveToRootStable = try container.decode(Bool.self, forKey: .moveToRootStable, default: defaults.moveToRootStable, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Borders {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().borders

        enabled = try container.decode(Bool.self, forKey: .enabled, default: defaults.enabled, recovering: recovering)
        width = try container.decode(Double.self, forKey: .width, default: defaults.width, recovering: recovering)
        color = try container.decode(Color.self, forKey: .color, default: defaults.color, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Borders.Color {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().borders.color

        red = try container.decode(Double.self, forKey: .red, default: defaults.red, recovering: recovering)
        green = try container.decode(Double.self, forKey: .green, default: defaults.green, recovering: recovering)
        blue = try container.decode(Double.self, forKey: .blue, default: defaults.blue, recovering: recovering)
        alpha = try container.decode(Double.self, forKey: .alpha, default: defaults.alpha, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.WorkspaceBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().workspaceBar

        enabled = try container.decode(Bool.self, forKey: .enabled, default: defaults.enabled, recovering: recovering)
        showLabels = try container.decode(Bool.self, forKey: .showLabels, default: defaults.showLabels, recovering: recovering)
        showFloatingWindows = try container.decode(
            Bool.self,
            forKey: .showFloatingWindows,
            default: defaults.showFloatingWindows,
            recovering: recovering
        )
        windowLevel = try container.decode(String.self, forKey: .windowLevel, default: defaults.windowLevel, recovering: recovering)
        position = try container.decode(String.self, forKey: .position, default: defaults.position, recovering: recovering)
        notchAware = try container.decode(Bool.self, forKey: .notchAware, default: defaults.notchAware, recovering: recovering)
        deduplicateAppIcons = try container.decode(
            Bool.self,
            forKey: .deduplicateAppIcons,
            default: defaults.deduplicateAppIcons,
            recovering: recovering
        )
        hideEmptyWorkspaces = try container.decode(
            Bool.self,
            forKey: .hideEmptyWorkspaces,
            default: defaults.hideEmptyWorkspaces,
            recovering: recovering
        )
        reserveLayoutSpace = try container.decode(
            Bool.self,
            forKey: .reserveLayoutSpace,
            default: defaults.reserveLayoutSpace,
            recovering: recovering
        )
        height = try container.decode(Double.self, forKey: .height, default: defaults.height, recovering: recovering)
        backgroundOpacity = try container.decode(
            Double.self,
            forKey: .backgroundOpacity,
            default: defaults.backgroundOpacity,
            recovering: recovering
        )
        xOffset = try container.decode(Double.self, forKey: .xOffset, default: defaults.xOffset, recovering: recovering)
        yOffset = try container.decode(Double.self, forKey: .yOffset, default: defaults.yOffset, recovering: recovering)
        labelFontSize = try container.decode(Double.self, forKey: .labelFontSize, default: defaults.labelFontSize, recovering: recovering)
        accentColor = try container.decode(
            Color.self,
            forKey: .accentColor,
            default: defaults.accentColor,
            recovering: recovering
        ) { decoder, defaultValue, recovering in
            try Color(from: decoder, default: defaultValue, recovering: recovering)
        }
        textColor = try container.decode(
            Color.self,
            forKey: .textColor,
            default: defaults.textColor,
            recovering: recovering
        ) { decoder, defaultValue, recovering in
            try Color(from: decoder, default: defaultValue, recovering: recovering)
        }
    }
}

extension CanonicalTOMLConfig.WorkspaceBar.Color {
    init(from decoder: Decoder, default defaultValue: Self, recovering: Bool) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        red = try container.decode(Double.self, forKey: .red, default: defaultValue.red, recovering: recovering)
        green = try container.decode(Double.self, forKey: .green, default: defaultValue.green, recovering: recovering)
        blue = try container.decode(Double.self, forKey: .blue, default: defaultValue.blue, recovering: recovering)
        alpha = try container.decode(Double.self, forKey: .alpha, default: defaultValue.alpha, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Gestures {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().gestures

        scrollEnabled = try container.decode(Bool.self, forKey: .scrollEnabled, default: defaults.scrollEnabled, recovering: recovering)
        scrollSensitivity = try container.decode(Double.self, forKey: .scrollSensitivity, default: defaults.scrollSensitivity, recovering: recovering)
        scrollModifierKey = try container.decode(String.self, forKey: .scrollModifierKey, default: defaults.scrollModifierKey, recovering: recovering)
        mouseResizeModifierKey = try container.decode(
            String.self,
            forKey: .mouseResizeModifierKey,
            default: defaults.mouseResizeModifierKey,
            recovering: recovering
        )
        fingerCount = try container.decode(Int.self, forKey: .fingerCount, default: defaults.fingerCount, recovering: recovering)
        invertDirection = try container.decode(Bool.self, forKey: .invertDirection, default: defaults.invertDirection, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.StatusBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().statusBar

        showWorkspaceName = try container.decode(Bool.self, forKey: .showWorkspaceName, default: defaults.showWorkspaceName, recovering: recovering)
        showAppNames = try container.decode(Bool.self, forKey: .showAppNames, default: defaults.showAppNames, recovering: recovering)
        useWorkspaceId = try container.decode(Bool.self, forKey: .useWorkspaceId, default: defaults.useWorkspaceId, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Clipboard {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().clipboard

        historyEnabled = try container.decode(Bool.self, forKey: .historyEnabled, default: defaults.historyEnabled, recovering: recovering)
        maxItems = try container.decode(Int.self, forKey: .maxItems, default: defaults.maxItems, recovering: recovering)
        maxItemBytes = try container.decode(Int.self, forKey: .maxItemBytes, default: defaults.maxItemBytes, recovering: recovering)
        maxTotalBytes = try container.decode(Int.self, forKey: .maxTotalBytes, default: defaults.maxTotalBytes, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.QuakeTerminal {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().quakeTerminal

        enabled = try container.decode(Bool.self, forKey: .enabled, default: defaults.enabled, recovering: recovering)
        position = try container.decode(String.self, forKey: .position, default: defaults.position, recovering: recovering)
        widthPercent = try container.decode(Double.self, forKey: .widthPercent, default: defaults.widthPercent, recovering: recovering)
        heightPercent = try container.decode(Double.self, forKey: .heightPercent, default: defaults.heightPercent, recovering: recovering)
        animationDuration = try container.decode(
            Double.self,
            forKey: .animationDuration,
            default: defaults.animationDuration,
            recovering: recovering
        )
        autoHide = try container.decode(Bool.self, forKey: .autoHide, default: defaults.autoHide, recovering: recovering)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        monitorMode = try container.decodeIfPresent(String.self, forKey: .monitorMode)
        useCustomFrame = try container.decode(Bool.self, forKey: .useCustomFrame, default: defaults.useCustomFrame, recovering: recovering)
        customFrame = try container.decodeIfPresent(Frame.self, forKey: .customFrame)
    }
}

extension CanonicalTOMLConfig.Appearance {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().appearance

        mode = try container.decode(String.self, forKey: .mode, default: defaults.mode, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.State {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().state

        commandPaletteLastMode = try container.decode(
            String.self,
            forKey: .commandPaletteLastMode,
            default: defaults.commandPaletteLastMode,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig {
    init(export: SettingsExport) {
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
            scrollSnapEnabled: export.niriScrollSnapEnabled,
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
            mouseResizeModifierKey: export.mouseResizeModifierKey,
            fingerCount: export.gestureFingerCount,
            invertDirection: export.gestureInvertDirection
        )
        statusBar = StatusBar(
            showWorkspaceName: export.statusBarShowWorkspaceName,
            showAppNames: export.statusBarShowAppNames,
            useWorkspaceId: export.statusBarUseWorkspaceId
        )
        clipboard = Clipboard(
            historyEnabled: export.clipboardHistoryEnabled,
            maxItems: export.clipboardMaxItems,
            maxItemBytes: export.clipboardMaxItemBytes,
            maxTotalBytes: export.clipboardMaxTotalBytes
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
        state = State(commandPaletteLastMode: export.commandPaletteLastMode)
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
            niriScrollSnapEnabled: niri.scrollSnapEnabled,
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
            mouseResizeModifierKey: gestures.mouseResizeModifierKey,
            gestureFingerCount: gestures.fingerCount,
            gestureInvertDirection: gestures.invertDirection,
            statusBarShowWorkspaceName: statusBar.showWorkspaceName,
            statusBarShowAppNames: statusBar.showAppNames,
            statusBarUseWorkspaceId: statusBar.useWorkspaceId,
            commandPaletteLastMode: state.commandPaletteLastMode,
            animationsEnabled: general.animationsEnabled,
            clipboardHistoryEnabled: clipboard.historyEnabled,
            clipboardMaxItems: clipboard.maxItems,
            clipboardMaxItemBytes: clipboard.maxItemBytes,
            clipboardMaxTotalBytes: clipboard.maxTotalBytes,
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
