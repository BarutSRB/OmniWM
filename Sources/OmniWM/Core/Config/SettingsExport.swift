import CoreGraphics
import Foundation

// MARK: - SettingsExport

enum SettingsExportMode {
    case full
    case compact
}

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

struct SettingsExport: Codable {
    var version: Int = SettingsMigration.currentSettingsEpoch

    var hotkeysEnabled: Bool
    var focusFollowsMouse: Bool
    var moveMouseToFocusedWindow: Bool
    var focusFollowsWindowToMonitor: Bool
    var mouseWarpMonitorOrder: [String]
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
    var commandPaletteLastMode: String

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

// MARK: - Defaults & Diffing

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
            scrollGestureEnabled: true,
            scrollSensitivity: 5.0,
            scrollModifierKey: ScrollModifierKey.optionShift.rawValue,
            gestureFingerCount: GestureFingerCount.three.rawValue,
            gestureInvertDirection: true,
            commandPaletteLastMode: CommandPaletteMode.windows.rawValue,
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

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    func exportData(
        mode: SettingsExportMode = .full,
        defaults: SettingsExport = .defaults(),
        encoder: JSONEncoder = Self.makeEncoder()
    ) throws -> Data {
        let data = try encoder.encode(self)
        guard mode == .compact else { return data }

        let defaultsData = try encoder.encode(defaults)
        guard let currentDict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsDict = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else {
            return data
        }

        var filtered: [String: Any] = ["version": version]
        for (key, value) in currentDict where key != "version" && key != "hotkeyBindings" {
            if let defaultValue = defaultsDict[key], jsonValuesEqual(value, defaultValue) {
                continue
            }
            filtered[key] = value
        }

        if let currentBindings = currentDict["hotkeyBindings"] as? [[String: Any]],
           let defaultBindings = defaultsDict["hotkeyBindings"] as? [[String: Any]] {
            let defaultsByID = Dictionary(
                defaultBindings.compactMap { binding in
                    (binding["id"] as? String).map { ($0, binding) }
                },
                uniquingKeysWith: { _, last in last }
            )
            let changedBindings = currentBindings.filter { binding in
                guard let id = binding["id"] as? String,
                      let defaultBinding = defaultsByID[id]
                else {
                    return true
                }
                return !jsonValuesEqual(binding, defaultBinding)
            }
            if !changedBindings.isEmpty {
                filtered["hotkeyBindings"] = changedBindings
            }
        }

        return try JSONSerialization.data(
            withJSONObject: filtered,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func mergedImportData(
        from rawData: Data,
        defaults: SettingsExport = .defaults(),
        encoder: JSONEncoder = Self.makeEncoder()
    ) throws -> Data {
        let defaultsData = try encoder.encode(defaults)
        guard var defaultsDict = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              let importedDict = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        else {
            return rawData
        }

        for (key, value) in importedDict where key != "hotkeyBindings" {
            defaultsDict[key] = value
        }

        if let importedBindings = importedDict["hotkeyBindings"] {
            defaultsDict["hotkeyBindings"] = HotkeyBindingRegistry.canonicalizedJSONArray(from: importedBindings)
        }

        return try JSONSerialization.data(withJSONObject: defaultsDict, options: [.sortedKeys])
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
        settingsFileExists(at: Self.exportURL)
    }

    func settingsFileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func exportSettings(mode: SettingsExportMode = .full) throws {
        try exportSettings(to: Self.exportURL, mode: mode)
    }

    func exportSettings(to url: URL, mode: SettingsExportMode = .full) throws {
        let export = SettingsExport(
            hotkeysEnabled: hotkeysEnabled,
            focusFollowsMouse: focusFollowsMouse,
            moveMouseToFocusedWindow: moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: focusFollowsWindowToMonitor,
            mouseWarpMonitorOrder: mouseWarpMonitorOrder,
            mouseWarpAxis: mouseWarpAxis.rawValue,
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
            niriDefaultColumnWidth: niriDefaultColumnWidth,
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
            workspaceBarReserveLayoutSpace: workspaceBarReserveLayoutSpace,
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
            commandPaletteLastMode: commandPaletteLastMode.rawValue,
            hiddenBarIsCollapsed: hiddenBarIsCollapsed,
            quakeTerminalEnabled: quakeTerminalEnabled,
            quakeTerminalPosition: quakeTerminalPosition.rawValue,
            quakeTerminalWidthPercent: quakeTerminalWidthPercent,
            quakeTerminalHeightPercent: quakeTerminalHeightPercent,
            quakeTerminalAnimationDuration: quakeTerminalAnimationDuration,
            quakeTerminalAutoHide: quakeTerminalAutoHide,
            quakeTerminalOpacity: quakeTerminalOpacity,
            quakeTerminalMonitorMode: quakeTerminalMonitorMode.rawValue,
            quakeTerminalUseCustomFrame: quakeTerminalUseCustomFrame,
            quakeTerminalCustomFrame: quakeTerminalCustomFrame.map(QuakeTerminalFrameExport.init(frame:)),
            appearanceMode: appearanceMode.rawValue
        )

        let outputData = try export.exportData(mode: mode)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try outputData.write(to: url)
    }

    func importSettings(applyingTo controller: WMController) throws {
        try importSettings(from: Self.exportURL, applyingTo: controller)
    }

    func importSettings(
        from url: URL,
        applyingTo controller: WMController? = nil,
        monitors: [Monitor]? = nil
    ) throws {
        let rawData = try Data(contentsOf: url)
        try SettingsMigration.validateImportEpoch(from: rawData)
        let mergedData = try SettingsExport.mergedImportData(from: rawData)
        let export = try JSONDecoder().decode(SettingsExport.self, from: mergedData)
        applyImport(
            export,
            monitors: monitors ?? controller?.workspaceManager.monitors ?? Monitor.current()
        )
        controller?.applyPersistedSettings(self)
    }

    private func applyImport(
        _ export: SettingsExport,
        monitors: [Monitor]
    ) {
        hotkeysEnabled = export.hotkeysEnabled
        focusFollowsMouse = export.focusFollowsMouse
        moveMouseToFocusedWindow = export.moveMouseToFocusedWindow
        focusFollowsWindowToMonitor = export.focusFollowsWindowToMonitor
        mouseWarpMonitorOrder = export.mouseWarpMonitorOrder
        mouseWarpAxis = MouseWarpAxis(rawValue: export.mouseWarpAxis ?? "") ?? .horizontal
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
        niriDefaultColumnWidth = Self.validatedDefaultColumnWidth(export.niriDefaultColumnWidth)

        workspaceConfigurations = Self.normalizedImportedWorkspaceConfigurations(
            export.workspaceConfigurations,
            monitors: monitors
        )
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
        workspaceBarReserveLayoutSpace = export.workspaceBarReserveLayoutSpace
        workspaceBarHeight = export.workspaceBarHeight
        workspaceBarBackgroundOpacity = export.workspaceBarBackgroundOpacity
        workspaceBarXOffset = export.workspaceBarXOffset
        workspaceBarYOffset = export.workspaceBarYOffset
        monitorBarSettings = Self.reboundMonitorBarSettings(
            export.monitorBarSettings,
            monitors: monitors
        )

        appRules = export.appRules
        monitorOrientationSettings = Self.reboundMonitorOrientationSettings(
            export.monitorOrientationSettings,
            monitors: monitors
        )
        monitorNiriSettings = Self.reboundMonitorNiriSettings(
            export.monitorNiriSettings,
            monitors: monitors
        )

        dwindleSmartSplit = export.dwindleSmartSplit
        dwindleDefaultSplitRatio = export.dwindleDefaultSplitRatio
        dwindleSplitWidthMultiplier = export.dwindleSplitWidthMultiplier
        dwindleSingleWindowAspectRatio = DwindleSingleWindowAspectRatio(
            rawValue: export.dwindleSingleWindowAspectRatio
        ) ?? .ratio4x3
        dwindleUseGlobalGaps = export.dwindleUseGlobalGaps
        dwindleMoveToRootStable = export.dwindleMoveToRootStable
        monitorDwindleSettings = Self.reboundMonitorDwindleSettings(
            export.monitorDwindleSettings,
            monitors: monitors
        )

        preventSleepEnabled = export.preventSleepEnabled
        scrollGestureEnabled = export.scrollGestureEnabled
        scrollSensitivity = export.scrollSensitivity
        scrollModifierKey = ScrollModifierKey(rawValue: export.scrollModifierKey) ?? .optionShift
        gestureFingerCount = GestureFingerCount(rawValue: export.gestureFingerCount) ?? .three
        gestureInvertDirection = export.gestureInvertDirection
        commandPaletteLastMode = CommandPaletteMode(rawValue: export.commandPaletteLastMode) ?? .windows

        hiddenBarIsCollapsed = export.hiddenBarIsCollapsed

        quakeTerminalEnabled = export.quakeTerminalEnabled
        quakeTerminalPosition = QuakeTerminalPosition(rawValue: export.quakeTerminalPosition) ?? .top
        quakeTerminalWidthPercent = export.quakeTerminalWidthPercent
        quakeTerminalHeightPercent = export.quakeTerminalHeightPercent
        quakeTerminalAnimationDuration = export.quakeTerminalAnimationDuration
        quakeTerminalAutoHide = export.quakeTerminalAutoHide
        if let opacity = export.quakeTerminalOpacity {
            quakeTerminalOpacity = opacity
        }
        if let modeRaw = export.quakeTerminalMonitorMode,
           let mode = QuakeTerminalMonitorMode(rawValue: modeRaw) {
            quakeTerminalMonitorMode = mode
        }
        quakeTerminalUseCustomFrame = export.quakeTerminalUseCustomFrame
        quakeTerminalCustomFrame = export.quakeTerminalCustomFrame?.frame

        appearanceMode = AppearanceMode(rawValue: export.appearanceMode) ?? .automatic
    }

    private static func normalizedImportedWorkspaceConfigurations(
        _ configs: [WorkspaceConfiguration],
        monitors: [Monitor]
    ) -> [WorkspaceConfiguration] {
        var seen: Set<String> = []
        let rebound = configs.map { config in
            guard case let .specificDisplay(output) = config.monitorAssignment,
                  let resolvedMonitor = output.resolveMonitor(in: monitors)
            else {
                return config
            }

            var updated = config
            updated.monitorAssignment = .specificDisplay(OutputId(from: resolvedMonitor))
            return updated
        }

        let normalized = rebound
            .filter { WorkspaceConfiguration.allowedNames.contains($0.name) }
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.sortOrder < $1.sortOrder }

        if normalized.isEmpty {
            return BuiltInSettingsDefaults.workspaceConfigurations
        }

        return normalized
    }

    private static func reboundMonitorBarSettings(
        _ settings: [MonitorBarSettings],
        monitors: [Monitor]
    ) -> [MonitorBarSettings] {
        settings.map { setting in
            var rebound = setting
            rebound.monitorDisplayId = reboundMonitorDisplayId(
                rebound.monitorDisplayId,
                monitorName: rebound.monitorName,
                monitors: monitors
            )
            return rebound
        }
    }

    private static func reboundMonitorOrientationSettings(
        _ settings: [MonitorOrientationSettings],
        monitors: [Monitor]
    ) -> [MonitorOrientationSettings] {
        settings.map { setting in
            var rebound = setting
            rebound.monitorDisplayId = reboundMonitorDisplayId(
                rebound.monitorDisplayId,
                monitorName: rebound.monitorName,
                monitors: monitors
            )
            return rebound
        }
    }

    private static func reboundMonitorNiriSettings(
        _ settings: [MonitorNiriSettings],
        monitors: [Monitor]
    ) -> [MonitorNiriSettings] {
        settings.map { setting in
            var rebound = setting
            rebound.monitorDisplayId = reboundMonitorDisplayId(
                rebound.monitorDisplayId,
                monitorName: rebound.monitorName,
                monitors: monitors
            )
            return rebound
        }
    }

    private static func reboundMonitorDwindleSettings(
        _ settings: [MonitorDwindleSettings],
        monitors: [Monitor]
    ) -> [MonitorDwindleSettings] {
        settings.map { setting in
            var rebound = setting
            rebound.monitorDisplayId = reboundMonitorDisplayId(
                rebound.monitorDisplayId,
                monitorName: rebound.monitorName,
                monitors: monitors
            )
            return rebound
        }
    }

    private static func reboundMonitorDisplayId(
        _ displayId: CGDirectDisplayID?,
        monitorName: String,
        monitors: [Monitor]
    ) -> CGDirectDisplayID? {
        if let displayId,
           monitors.contains(where: { $0.displayId == displayId })
        {
            return displayId
        }

        let matches = monitors.filter { $0.name.caseInsensitiveCompare(monitorName) == .orderedSame }
        guard matches.count == 1 else { return nil }
        return matches[0].displayId
    }
}
