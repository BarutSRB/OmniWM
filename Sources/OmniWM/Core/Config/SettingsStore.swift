// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import OmniWMIPC

@MainActor @Observable
final class SettingsStore {
    private nonisolated static let defaultExport = SettingsExport.defaults()

    private let persistence: SettingsFilePersistence
    private let runtimeState: RuntimeStateStore
    private let autosaveEnabled: Bool
    private var isApplyingExport = false

    var onIPCEnabledChanged: (@MainActor (Bool) -> Void)?
    var onExternalSettingsReloaded: (@MainActor () -> Void)?

    var hotkeysEnabled = SettingsStore.defaultExport.hotkeysEnabled {
        didSet { scheduleSave() }
    }

    var focusFollowsMouse = SettingsStore.defaultExport.focusFollowsMouse {
        didSet { scheduleSave() }
    }

    var moveMouseToFocusedWindow = SettingsStore.defaultExport.moveMouseToFocusedWindow {
        didSet { scheduleSave() }
    }

    var focusFollowsWindowToMonitor = SettingsStore.defaultExport.focusFollowsWindowToMonitor {
        didSet { scheduleSave() }
    }

    var mouseWarpMonitorOrder = SettingsStore.defaultExport.mouseWarpMonitorOrder {
        didSet { scheduleSave() }
    }

    var mouseWarpAxis = MouseWarpAxis(rawValue: SettingsStore.defaultExport.mouseWarpAxis ?? "") ?? .horizontal {
        didSet { scheduleSave() }
    }

    var niriColumnWidthPresets = SettingsStore.validatedPresets(
        SettingsStore.defaultExport.niriColumnWidthPresets ?? BuiltInSettingsDefaults.niriColumnWidthPresets
    ) {
        didSet { scheduleSave() }
    }

    var niriDefaultColumnWidth = SettingsStore.validatedDefaultColumnWidth(
        SettingsStore.defaultExport.niriDefaultColumnWidth
    ) {
        didSet {
            let validated = SettingsStore.validatedDefaultColumnWidth(niriDefaultColumnWidth)
            if validated != niriDefaultColumnWidth {
                niriDefaultColumnWidth = validated
                return
            }
            scheduleSave()
        }
    }

    var mouseWarpMargin = SettingsStore.defaultExport.mouseWarpMargin {
        didSet { scheduleSave() }
    }

    var gapSize = SettingsStore.defaultExport.gapSize {
        didSet { scheduleSave() }
    }

    var outerGapLeft = SettingsStore.defaultExport.outerGapLeft {
        didSet { scheduleSave() }
    }

    var outerGapRight = SettingsStore.defaultExport.outerGapRight {
        didSet { scheduleSave() }
    }

    var outerGapTop = SettingsStore.defaultExport.outerGapTop {
        didSet { scheduleSave() }
    }

    var outerGapBottom = SettingsStore.defaultExport.outerGapBottom {
        didSet { scheduleSave() }
    }

    var niriMaxWindowsPerColumn = SettingsStore.defaultExport.niriMaxWindowsPerColumn {
        didSet { scheduleSave() }
    }

    var niriMaxVisibleColumns = SettingsStore.defaultExport.niriMaxVisibleColumns {
        didSet { scheduleSave() }
    }

    var niriInfiniteLoop = SettingsStore.defaultExport.niriInfiniteLoop {
        didSet { scheduleSave() }
    }

    var niriCenterFocusedColumn = CenterFocusedColumn(
        rawValue: SettingsStore.defaultExport.niriCenterFocusedColumn
    ) ?? .never {
        didSet { scheduleSave() }
    }

    var niriAlwaysCenterSingleColumn = SettingsStore.defaultExport.niriAlwaysCenterSingleColumn {
        didSet { scheduleSave() }
    }

    var niriSingleWindowAspectRatio = SingleWindowAspectRatio(
        rawValue: SettingsStore.defaultExport.niriSingleWindowAspectRatio
    ) ?? .none {
        didSet { scheduleSave() }
    }

    var workspaceConfigurations = SettingsStore.defaultExport.workspaceConfigurations {
        didSet { scheduleSave() }
    }

    var defaultLayoutType = LayoutType(
        rawValue: SettingsStore.defaultExport.defaultLayoutType
    ) ?? .niri {
        didSet { scheduleSave() }
    }

    var bordersEnabled = SettingsStore.defaultExport.bordersEnabled {
        didSet { scheduleSave() }
    }

    var borderWidth = SettingsStore.defaultExport.borderWidth {
        didSet { scheduleSave() }
    }

    var borderColorRed = SettingsStore.defaultExport.borderColorRed {
        didSet { scheduleSave() }
    }

    var borderColorGreen = SettingsStore.defaultExport.borderColorGreen {
        didSet { scheduleSave() }
    }

    var borderColorBlue = SettingsStore.defaultExport.borderColorBlue {
        didSet { scheduleSave() }
    }

    var borderColorAlpha = SettingsStore.defaultExport.borderColorAlpha {
        didSet { scheduleSave() }
    }

    var hotkeyBindings = SettingsStore.defaultExport.hotkeyBindings {
        didSet { scheduleSave() }
    }

    var workspaceBarEnabled = SettingsStore.defaultExport.workspaceBarEnabled {
        didSet { scheduleSave() }
    }

    var workspaceBarShowLabels = SettingsStore.defaultExport.workspaceBarShowLabels {
        didSet { scheduleSave() }
    }

    var workspaceBarShowFloatingWindows = SettingsStore.defaultExport.workspaceBarShowFloatingWindows {
        didSet { scheduleSave() }
    }

    var workspaceBarWindowLevel = WorkspaceBarWindowLevel(
        rawValue: SettingsStore.defaultExport.workspaceBarWindowLevel
    ) ?? .popup {
        didSet { scheduleSave() }
    }

    var workspaceBarPosition = WorkspaceBarPosition(
        rawValue: SettingsStore.defaultExport.workspaceBarPosition
    ) ?? .overlappingMenuBar {
        didSet { scheduleSave() }
    }

    var workspaceBarNotchAware = SettingsStore.defaultExport.workspaceBarNotchAware {
        didSet { scheduleSave() }
    }

    var workspaceBarDeduplicateAppIcons = SettingsStore.defaultExport.workspaceBarDeduplicateAppIcons {
        didSet { scheduleSave() }
    }

    var workspaceBarHideEmptyWorkspaces = SettingsStore.defaultExport.workspaceBarHideEmptyWorkspaces {
        didSet { scheduleSave() }
    }

    var workspaceBarReserveLayoutSpace = SettingsStore.defaultExport.workspaceBarReserveLayoutSpace {
        didSet { scheduleSave() }
    }

    var workspaceBarHeight = SettingsStore.defaultExport.workspaceBarHeight {
        didSet { scheduleSave() }
    }

    var workspaceBarBackgroundOpacity = SettingsStore.defaultExport.workspaceBarBackgroundOpacity {
        didSet { scheduleSave() }
    }

    var workspaceBarXOffset = SettingsStore.defaultExport.workspaceBarXOffset {
        didSet { scheduleSave() }
    }

    var workspaceBarYOffset = SettingsStore.defaultExport.workspaceBarYOffset {
        didSet { scheduleSave() }
    }

    var monitorBarSettings = SettingsStore.defaultExport.monitorBarSettings {
        didSet { scheduleSave() }
    }

    var appRules = SettingsStore.defaultExport.appRules {
        didSet { scheduleSave() }
    }

    var monitorOrientationSettings = SettingsStore.defaultExport.monitorOrientationSettings {
        didSet { scheduleSave() }
    }

    var monitorNiriSettings = SettingsStore.defaultExport.monitorNiriSettings {
        didSet { scheduleSave() }
    }

    var dwindleSmartSplit = SettingsStore.defaultExport.dwindleSmartSplit {
        didSet { scheduleSave() }
    }

    var dwindleDefaultSplitRatio = SettingsStore.defaultExport.dwindleDefaultSplitRatio {
        didSet { scheduleSave() }
    }

    var dwindleSplitWidthMultiplier = SettingsStore.defaultExport.dwindleSplitWidthMultiplier {
        didSet { scheduleSave() }
    }

    var dwindleSingleWindowAspectRatio = DwindleSingleWindowAspectRatio(
        rawValue: SettingsStore.defaultExport.dwindleSingleWindowAspectRatio
    ) ?? .ratio4x3 {
        didSet { scheduleSave() }
    }

    var dwindleUseGlobalGaps = SettingsStore.defaultExport.dwindleUseGlobalGaps {
        didSet { scheduleSave() }
    }

    var dwindleMoveToRootStable = SettingsStore.defaultExport.dwindleMoveToRootStable {
        didSet { scheduleSave() }
    }

    var monitorDwindleSettings = SettingsStore.defaultExport.monitorDwindleSettings {
        didSet { scheduleSave() }
    }

    var preventSleepEnabled = SettingsStore.defaultExport.preventSleepEnabled {
        didSet { scheduleSave() }
    }

    var updateChecksEnabled = SettingsStore.defaultExport.updateChecksEnabled {
        didSet { scheduleSave() }
    }

    var ipcEnabled = SettingsStore.defaultExport.ipcEnabled {
        didSet {
            guard oldValue != ipcEnabled else { return }
            onIPCEnabledChanged?(ipcEnabled)
            scheduleSave()
        }
    }

    var scrollGestureEnabled = SettingsStore.defaultExport.scrollGestureEnabled {
        didSet { scheduleSave() }
    }

    var scrollSensitivity = SettingsStore.defaultExport.scrollSensitivity {
        didSet { scheduleSave() }
    }

    var scrollModifierKey = ScrollModifierKey(
        rawValue: SettingsStore.defaultExport.scrollModifierKey
    ) ?? .optionShift {
        didSet { scheduleSave() }
    }

    var gestureFingerCount = GestureFingerCount(
        rawValue: SettingsStore.defaultExport.gestureFingerCount
    ) ?? .three {
        didSet { scheduleSave() }
    }

    var gestureInvertDirection = SettingsStore.defaultExport.gestureInvertDirection {
        didSet { scheduleSave() }
    }

    var statusBarShowWorkspaceName = SettingsStore.defaultExport.statusBarShowWorkspaceName {
        didSet { scheduleSave() }
    }

    var statusBarShowAppNames = SettingsStore.defaultExport.statusBarShowAppNames {
        didSet { scheduleSave() }
    }

    var statusBarUseWorkspaceId = SettingsStore.defaultExport.statusBarUseWorkspaceId {
        didSet { scheduleSave() }
    }

    var commandPaletteLastMode = CommandPaletteMode(
        rawValue: SettingsStore.defaultExport.commandPaletteLastMode
    ) ?? .windows {
        didSet { scheduleSave() }
    }

    var animationsEnabled = SettingsStore.defaultExport.animationsEnabled {
        didSet { scheduleSave() }
    }

    var clipboardHistoryEnabled = SettingsStore.defaultExport.clipboardHistoryEnabled {
        didSet { scheduleSave() }
    }

    var clipboardMaxItems = SettingsStore.defaultExport.clipboardMaxItems {
        didSet { scheduleSave() }
    }

    var clipboardMaxItemBytes = SettingsStore.defaultExport.clipboardMaxItemBytes {
        didSet { scheduleSave() }
    }

    var clipboardMaxTotalBytes = SettingsStore.defaultExport.clipboardMaxTotalBytes {
        didSet { scheduleSave() }
    }

    var hiddenBarIsCollapsed = SettingsStore.defaultExport.hiddenBarIsCollapsed {
        didSet { scheduleSave() }
    }

    var quakeTerminalEnabled = SettingsStore.defaultExport.quakeTerminalEnabled {
        didSet { scheduleSave() }
    }

    var quakeTerminalPosition = QuakeTerminalPosition(
        rawValue: SettingsStore.defaultExport.quakeTerminalPosition
    ) ?? .center {
        didSet { scheduleSave() }
    }

    var quakeTerminalWidthPercent = SettingsStore.defaultExport.quakeTerminalWidthPercent {
        didSet { scheduleSave() }
    }

    var quakeTerminalHeightPercent = SettingsStore.defaultExport.quakeTerminalHeightPercent {
        didSet { scheduleSave() }
    }

    var quakeTerminalAnimationDuration = SettingsStore.defaultExport.quakeTerminalAnimationDuration {
        didSet { scheduleSave() }
    }

    var quakeTerminalAutoHide = SettingsStore.defaultExport.quakeTerminalAutoHide {
        didSet { scheduleSave() }
    }

    var quakeTerminalOpacity = SettingsStore.defaultExport.quakeTerminalOpacity ?? 1.0 {
        didSet { scheduleSave() }
    }

    var quakeTerminalMonitorMode = QuakeTerminalMonitorMode(
        rawValue: SettingsStore.defaultExport.quakeTerminalMonitorMode ?? ""
    ) ?? .focusedWindow {
        didSet { scheduleSave() }
    }

    var quakeTerminalUseCustomFrame = SettingsStore.defaultExport.quakeTerminalUseCustomFrame {
        didSet { scheduleSave() }
    }

    private var quakeTerminalCustomFrameX: Double? = SettingsStore.defaultExport.quakeTerminalCustomFrame?.x {
        didSet { scheduleSave() }
    }

    private var quakeTerminalCustomFrameY: Double? = SettingsStore.defaultExport.quakeTerminalCustomFrame?.y {
        didSet { scheduleSave() }
    }

    private var quakeTerminalCustomFrameWidth: Double? = SettingsStore.defaultExport.quakeTerminalCustomFrame?.width {
        didSet { scheduleSave() }
    }

    private var quakeTerminalCustomFrameHeight: Double? = SettingsStore.defaultExport.quakeTerminalCustomFrame?.height {
        didSet { scheduleSave() }
    }

    var quakeTerminalCustomFrame: NSRect? {
        get {
            guard let x = quakeTerminalCustomFrameX,
                  let y = quakeTerminalCustomFrameY,
                  let width = quakeTerminalCustomFrameWidth,
                  let height = quakeTerminalCustomFrameHeight
            else {
                return nil
            }
            return NSRect(x: x, y: y, width: width, height: height)
        }
        set {
            if let frame = newValue {
                quakeTerminalCustomFrameX = frame.origin.x
                quakeTerminalCustomFrameY = frame.origin.y
                quakeTerminalCustomFrameWidth = frame.size.width
                quakeTerminalCustomFrameHeight = frame.size.height
            } else {
                quakeTerminalCustomFrameX = nil
                quakeTerminalCustomFrameY = nil
                quakeTerminalCustomFrameWidth = nil
                quakeTerminalCustomFrameHeight = nil
            }
        }
    }

    func resetQuakeTerminalCustomFrame() {
        quakeTerminalUseCustomFrame = false
        quakeTerminalCustomFrame = nil
    }

    var appearanceMode = AppearanceMode(
        rawValue: SettingsStore.defaultExport.appearanceMode
    ) ?? .dark {
        didSet { scheduleSave() }
    }

    func loadPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        runtimeState.windowRestoreCatalog ?? .empty
    }

    func savePersistedWindowRestoreCatalog(_ catalog: PersistedWindowRestoreCatalog) {
        runtimeState.windowRestoreCatalog = catalog.entries.isEmpty ? nil : catalog
    }

    init(
        persistence: SettingsFilePersistence = SettingsFilePersistence(),
        runtimeState: RuntimeStateStore = RuntimeStateStore(),
        autosaveEnabled: Bool = true
    ) {
        self.persistence = persistence
        self.runtimeState = runtimeState
        self.autosaveEnabled = autosaveEnabled

        applyExport(
            persistence.load(),
            monitors: Monitor.current()
        )
        persistence.setExternalChangeHandler { [weak self] export in
            self?.handleExternalReload(export)
        }
    }

    var settingsFileURL: URL {
        persistence.fileURL
    }

    func ensureSettingsFileAvailable() throws {
        guard !FileManager.default.fileExists(atPath: settingsFileURL.path) else { return }
        try persistence.saveImmediately(toExport())
    }

    func flushNow() {
        if autosaveEnabled {
            persistence.flushNow()
        } else {
            persistence.save(toExport())
        }
    }

    func toExport() -> SettingsExport {
        SettingsExport(
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
            workspaceBarShowFloatingWindows: workspaceBarShowFloatingWindows,
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
            workspaceBarAccentColorRed: -1,
            workspaceBarAccentColorGreen: -1,
            workspaceBarAccentColorBlue: -1,
            workspaceBarAccentColorAlpha: 1,
            workspaceBarTextColorRed: -1,
            workspaceBarTextColorGreen: -1,
            workspaceBarTextColorBlue: -1,
            workspaceBarTextColorAlpha: 1,
            workspaceBarLabelFontSize: 12,
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
            updateChecksEnabled: updateChecksEnabled,
            ipcEnabled: ipcEnabled,
            scrollGestureEnabled: scrollGestureEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey.rawValue,
            gestureFingerCount: gestureFingerCount.rawValue,
            gestureInvertDirection: gestureInvertDirection,
            statusBarShowWorkspaceName: statusBarShowWorkspaceName,
            statusBarShowAppNames: statusBarShowAppNames,
            statusBarUseWorkspaceId: statusBarUseWorkspaceId,
            commandPaletteLastMode: commandPaletteLastMode.rawValue,
            animationsEnabled: animationsEnabled,
            clipboardHistoryEnabled: clipboardHistoryEnabled,
            clipboardMaxItems: clipboardMaxItems,
            clipboardMaxItemBytes: clipboardMaxItemBytes,
            clipboardMaxTotalBytes: clipboardMaxTotalBytes,
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
            appearanceMode: appearanceMode.rawValue,
            capabilityOverrides: []
        )
    }

    func applyExport(_ export: SettingsExport, monitors: [Monitor]) {
        let baseline = SettingsStore.defaultExport
        isApplyingExport = true
        defer { isApplyingExport = false }

        hotkeysEnabled = export.hotkeysEnabled
        focusFollowsMouse = export.focusFollowsMouse
        moveMouseToFocusedWindow = export.moveMouseToFocusedWindow
        focusFollowsWindowToMonitor = export.focusFollowsWindowToMonitor
        mouseWarpMonitorOrder = export.mouseWarpMonitorOrder
        mouseWarpAxis = MouseWarpAxis(rawValue: export.mouseWarpAxis ?? baseline.mouseWarpAxis ?? "") ?? .horizontal
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
        niriSingleWindowAspectRatio = SingleWindowAspectRatio(rawValue: export.niriSingleWindowAspectRatio) ?? .none
        niriColumnWidthPresets = SettingsStore.validatedPresets(
            export.niriColumnWidthPresets ?? baseline.niriColumnWidthPresets ?? SettingsStore.defaultColumnWidthPresets
        )
        niriDefaultColumnWidth = SettingsStore.validatedDefaultColumnWidth(export.niriDefaultColumnWidth)

        workspaceConfigurations = SettingsStore.normalizedWorkspaceConfigurations(
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
        workspaceBarShowFloatingWindows = export.workspaceBarShowFloatingWindows
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
        monitorBarSettings = SettingsStore.reboundMonitorSettings(export.monitorBarSettings, monitors: monitors)

        appRules = export.appRules
        monitorOrientationSettings = SettingsStore.reboundMonitorSettings(
            export.monitorOrientationSettings,
            monitors: monitors
        )
        monitorNiriSettings = SettingsStore.reboundMonitorSettings(export.monitorNiriSettings, monitors: monitors)

        dwindleSmartSplit = export.dwindleSmartSplit
        dwindleDefaultSplitRatio = export.dwindleDefaultSplitRatio
        dwindleSplitWidthMultiplier = export.dwindleSplitWidthMultiplier
        dwindleSingleWindowAspectRatio = DwindleSingleWindowAspectRatio(
            rawValue: export.dwindleSingleWindowAspectRatio
        ) ?? .ratio4x3
        dwindleUseGlobalGaps = export.dwindleUseGlobalGaps
        dwindleMoveToRootStable = export.dwindleMoveToRootStable
        monitorDwindleSettings = SettingsStore.reboundMonitorSettings(
            export.monitorDwindleSettings,
            monitors: monitors
        )

        preventSleepEnabled = export.preventSleepEnabled
        updateChecksEnabled = export.updateChecksEnabled
        ipcEnabled = export.ipcEnabled
        scrollGestureEnabled = export.scrollGestureEnabled
        scrollSensitivity = export.scrollSensitivity
        scrollModifierKey = ScrollModifierKey(rawValue: export.scrollModifierKey) ?? .optionShift
        gestureFingerCount = GestureFingerCount(rawValue: export.gestureFingerCount) ?? .three
        gestureInvertDirection = export.gestureInvertDirection
        statusBarShowWorkspaceName = export.statusBarShowWorkspaceName
        statusBarShowAppNames = export.statusBarShowAppNames
        statusBarUseWorkspaceId = export.statusBarUseWorkspaceId
        commandPaletteLastMode = CommandPaletteMode(rawValue: export.commandPaletteLastMode) ?? .windows
        animationsEnabled = export.animationsEnabled
        clipboardHistoryEnabled = export.clipboardHistoryEnabled
        clipboardMaxItems = export.clipboardMaxItems
        clipboardMaxItemBytes = export.clipboardMaxItemBytes
        clipboardMaxTotalBytes = export.clipboardMaxTotalBytes

        hiddenBarIsCollapsed = export.hiddenBarIsCollapsed

        quakeTerminalEnabled = export.quakeTerminalEnabled
        quakeTerminalPosition = QuakeTerminalPosition(rawValue: export.quakeTerminalPosition) ?? .center
        quakeTerminalWidthPercent = export.quakeTerminalWidthPercent
        quakeTerminalHeightPercent = export.quakeTerminalHeightPercent
        quakeTerminalAnimationDuration = export.quakeTerminalAnimationDuration
        quakeTerminalAutoHide = export.quakeTerminalAutoHide
        quakeTerminalOpacity = export.quakeTerminalOpacity ?? baseline.quakeTerminalOpacity ?? 1.0
        quakeTerminalMonitorMode = QuakeTerminalMonitorMode(
            rawValue: export.quakeTerminalMonitorMode ?? baseline.quakeTerminalMonitorMode ?? ""
        ) ?? .focusedWindow
        quakeTerminalCustomFrame = export.quakeTerminalCustomFrame?.frame
        quakeTerminalUseCustomFrame = export.quakeTerminalUseCustomFrame

        appearanceMode = AppearanceMode(rawValue: export.appearanceMode) ?? .dark
    }

    private func handleExternalReload(_ export: SettingsExport) {
        applyExport(export, monitors: Monitor.current())
        onExternalSettingsReloaded?()
    }

    private func scheduleSave() {
        guard autosaveEnabled, !isApplyingExport else { return }
        persistence.scheduleSave(toExport())
    }

    func resetHotkeysToDefaults() {
        hotkeyBindings = HotkeyBindingRegistry.defaults()
    }

    func updateBinding(for commandId: String, newBinding: KeyBinding) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == commandId }) else { return }
        hotkeyBindings[index] = HotkeyBinding(
            id: hotkeyBindings[index].id,
            command: hotkeyBindings[index].command,
            binding: newBinding
        )
    }

    func clearBinding(for commandId: String) {
        updateBinding(for: commandId, newBinding: .unassigned)
    }

    func resetBindings(for commandId: String) {
        guard let defaultBinding = HotkeyBindingRegistry.defaults().first(where: { $0.id == commandId }),
              let index = hotkeyBindings.firstIndex(where: { $0.id == commandId })
        else { return }
        hotkeyBindings[index] = defaultBinding
    }

    func findConflicts(for binding: KeyBinding, excluding commandId: String) -> [HotkeyBinding] {
        hotkeyBindings.filter { hotkeyBinding in
            hotkeyBinding.id != commandId && hotkeyBinding.binding.conflicts(with: binding)
        }
    }

    func configuredWorkspaceNames() -> [String] {
        workspaceConfigurations.map(\.name)
    }

    func workspaceToMonitorAssignments() -> [String: [MonitorDescription]] {
        var result: [String: [MonitorDescription]] = [:]
        for config in workspaceConfigurations {
            result[config.name] = [config.monitorAssignment.toMonitorDescription()]
        }
        return result
    }

    func layoutType(for workspaceName: String) -> LayoutType {
        if let config = workspaceConfigurations.first(where: { $0.name == workspaceName }) {
            if config.layoutType == .defaultLayout {
                return defaultLayoutType
            }
            return config.layoutType
        }
        return defaultLayoutType
    }

    func displayName(for workspaceName: String) -> String {
        workspaceConfigurations.first(where: { $0.name == workspaceName })?.effectiveDisplayName ?? workspaceName
    }

    func effectiveMouseWarpMonitorOrder(for monitors: [Monitor], axis: MouseWarpAxis? = nil) -> [String] {
        let sortedNames = (axis ?? mouseWarpAxis).sortedMonitors(monitors).map(\.name)
        guard !sortedNames.isEmpty else { return [] }

        var remainingCounts = sortedNames.reduce(into: [String: Int]()) { counts, name in
            counts[name, default: 0] += 1
        }
        var resolved: [String] = []

        for name in mouseWarpMonitorOrder {
            guard let remaining = remainingCounts[name], remaining > 0 else { continue }
            resolved.append(name)
            remainingCounts[name] = remaining - 1
        }

        for name in sortedNames {
            guard let remaining = remainingCounts[name], remaining > 0 else { continue }
            resolved.append(name)
            remainingCounts[name] = remaining - 1
        }

        return resolved
    }

    @discardableResult
    func persistEffectiveMouseWarpMonitorOrder(for monitors: [Monitor], axis: MouseWarpAxis? = nil) -> [String] {
        let warpAxis = axis ?? mouseWarpAxis
        let sortedNames = warpAxis.sortedMonitors(monitors).map(\.name)
        guard !sortedNames.isEmpty else { return [] }

        var persisted = mouseWarpMonitorOrder
        var persistedCounts = persisted.reduce(into: [String: Int]()) { counts, name in
            counts[name, default: 0] += 1
        }
        let currentCounts = sortedNames.reduce(into: [String: Int]()) { counts, name in
            counts[name, default: 0] += 1
        }

        for name in sortedNames {
            let currentCount = currentCounts[name, default: 0]
            let persistedCount = persistedCounts[name, default: 0]
            guard persistedCount < currentCount else { continue }
            for _ in 0 ..< (currentCount - persistedCount) {
                persisted.append(name)
            }
            persistedCounts[name] = currentCount
        }

        if mouseWarpMonitorOrder != persisted {
            mouseWarpMonitorOrder = persisted
        }

        return effectiveMouseWarpMonitorOrder(for: monitors, axis: warpAxis)
    }

    static func normalizedWorkspaceConfigurations(
        _ configs: [WorkspaceConfiguration],
        monitors: [Monitor] = []
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
            .filter { WorkspaceIDPolicy.normalizeRawID($0.name) != nil }
            .filter { seen.insert($0.name).inserted }
            .sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }

        if normalized.isEmpty {
            return BuiltInSettingsDefaults.workspaceConfigurations
        }

        return normalized
    }

    private static func reboundMonitorSettings<T: MonitorSettingsType>(
        _ settings: [T],
        monitors: [Monitor]
    ) -> [T] {
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

    func barSettings(for monitor: Monitor) -> MonitorBarSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorBarSettings)
    }

    func barSettings(for monitorName: String) -> MonitorBarSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorBarSettings)
    }

    func updateBarSettings(_ settings: MonitorBarSettings) {
        MonitorSettingsStore.update(settings, in: &monitorBarSettings)
    }

    func removeBarSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorBarSettings)
    }

    func removeBarSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorBarSettings)
    }

    func resolvedBarSettings(for monitor: Monitor) -> ResolvedBarSettings {
        resolvedBarSettings(override: barSettings(for: monitor))
    }

    func resolvedBarSettings(for monitorName: String) -> ResolvedBarSettings {
        resolvedBarSettings(override: barSettings(for: monitorName))
    }

    private func resolvedBarSettings(override: MonitorBarSettings?) -> ResolvedBarSettings {
        return ResolvedBarSettings(
            enabled: override?.enabled ?? workspaceBarEnabled,
            showLabels: override?.showLabels ?? workspaceBarShowLabels,
            showFloatingWindows: override?.showFloatingWindows ?? workspaceBarShowFloatingWindows,
            deduplicateAppIcons: override?.deduplicateAppIcons ?? workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: override?.hideEmptyWorkspaces ?? workspaceBarHideEmptyWorkspaces,
            reserveLayoutSpace: override?.reserveLayoutSpace ?? workspaceBarReserveLayoutSpace,
            notchAware: override?.notchAware ?? workspaceBarNotchAware,
            position: override?.position ?? workspaceBarPosition,
            windowLevel: override?.windowLevel ?? workspaceBarWindowLevel,
            height: override?.height ?? workspaceBarHeight,
            backgroundOpacity: override?.backgroundOpacity ?? workspaceBarBackgroundOpacity,
            xOffset: override?.xOffset ?? workspaceBarXOffset,
            yOffset: override?.yOffset ?? workspaceBarYOffset
        )
    }

    func appRule(for bundleId: String) -> AppRule? {
        appRules.first { $0.bundleId == bundleId }
    }

    func orientationSettings(for monitor: Monitor) -> MonitorOrientationSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorOrientationSettings)
    }

    func orientationSettings(for monitorName: String) -> MonitorOrientationSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorOrientationSettings)
    }

    func effectiveOrientation(for monitor: Monitor) -> Monitor.Orientation {
        if let override = orientationSettings(for: monitor),
           let orientation = override.orientation
        {
            return orientation
        }
        return monitor.autoOrientation
    }

    func updateOrientationSettings(_ settings: MonitorOrientationSettings) {
        MonitorSettingsStore.update(settings, in: &monitorOrientationSettings)
    }

    func removeOrientationSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorOrientationSettings)
    }

    func removeOrientationSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorOrientationSettings)
    }

    func niriSettings(for monitor: Monitor) -> MonitorNiriSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorNiriSettings)
    }

    func niriSettings(for monitorName: String) -> MonitorNiriSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorNiriSettings)
    }

    func updateNiriSettings(_ settings: MonitorNiriSettings) {
        MonitorSettingsStore.update(settings, in: &monitorNiriSettings)
    }

    func removeNiriSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorNiriSettings)
    }

    func removeNiriSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorNiriSettings)
    }

    func resolvedNiriSettings(for monitor: Monitor) -> ResolvedNiriSettings {
        resolvedNiriSettings(override: niriSettings(for: monitor))
    }

    func resolvedNiriSettings(for monitorName: String) -> ResolvedNiriSettings {
        resolvedNiriSettings(override: niriSettings(for: monitorName))
    }

    private func resolvedNiriSettings(override: MonitorNiriSettings?) -> ResolvedNiriSettings {
        return ResolvedNiriSettings(
            maxVisibleColumns: override?.maxVisibleColumns ?? niriMaxVisibleColumns,
            maxWindowsPerColumn: override?.maxWindowsPerColumn ?? niriMaxWindowsPerColumn,
            centerFocusedColumn: override?.centerFocusedColumn ?? niriCenterFocusedColumn,
            alwaysCenterSingleColumn: override?.alwaysCenterSingleColumn ?? niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: override?.singleWindowAspectRatio ?? niriSingleWindowAspectRatio,
            infiniteLoop: override?.infiniteLoop ?? niriInfiniteLoop
        )
    }

    func dwindleSettings(for monitor: Monitor) -> MonitorDwindleSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorDwindleSettings)
    }

    func dwindleSettings(for monitorName: String) -> MonitorDwindleSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorDwindleSettings)
    }

    func updateDwindleSettings(_ settings: MonitorDwindleSettings) {
        MonitorSettingsStore.update(settings, in: &monitorDwindleSettings)
    }

    func removeDwindleSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorDwindleSettings)
    }

    func removeDwindleSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorDwindleSettings)
    }

    func resolvedDwindleSettings(for monitor: Monitor) -> ResolvedDwindleSettings {
        resolvedDwindleSettings(override: dwindleSettings(for: monitor))
    }

    func resolvedDwindleSettings(for monitorName: String) -> ResolvedDwindleSettings {
        resolvedDwindleSettings(override: dwindleSettings(for: monitorName))
    }

    private func resolvedDwindleSettings(override: MonitorDwindleSettings?) -> ResolvedDwindleSettings {
        let useGlobalGaps = override?.useGlobalGaps ?? dwindleUseGlobalGaps
        return ResolvedDwindleSettings(
            smartSplit: override?.smartSplit ?? dwindleSmartSplit,
            defaultSplitRatio: CGFloat(override?.defaultSplitRatio ?? dwindleDefaultSplitRatio),
            splitWidthMultiplier: CGFloat(override?.splitWidthMultiplier ?? dwindleSplitWidthMultiplier),
            singleWindowAspectRatio: override?.singleWindowAspectRatio ?? dwindleSingleWindowAspectRatio,
            useGlobalGaps: useGlobalGaps,
            innerGap: useGlobalGaps ? CGFloat(gapSize) : CGFloat(override?.innerGap ?? gapSize),
            outerGapTop: useGlobalGaps ? CGFloat(outerGapTop) : CGFloat(override?.outerGapTop ?? outerGapTop),
            outerGapBottom: useGlobalGaps ? CGFloat(outerGapBottom) :
                CGFloat(override?.outerGapBottom ?? outerGapBottom),
            outerGapLeft: useGlobalGaps ? CGFloat(outerGapLeft) : CGFloat(override?.outerGapLeft ?? outerGapLeft),
            outerGapRight: useGlobalGaps ? CGFloat(outerGapRight) : CGFloat(override?.outerGapRight ?? outerGapRight)
        )
    }

    nonisolated static let defaultColumnWidthPresets: [Double] = BuiltInSettingsDefaults.niriColumnWidthPresets

    static func validatedPresets(_ presets: [Double]) -> [Double] {
        let result = presets.map { min(1.0, max(0.05, $0)) }
        if result.count < 2 {
            return defaultColumnWidthPresets
        }
        return result
    }

    static func validatedDefaultColumnWidth(_ width: Double?) -> Double? {
        guard let width else { return nil }
        return min(1.0, max(0.05, width))
    }
}
