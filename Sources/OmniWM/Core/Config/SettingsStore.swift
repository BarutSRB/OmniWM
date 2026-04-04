import AppKit
import Foundation
import OmniWMIPC

@MainActor @Observable
final class SettingsStore {
    private let defaults: UserDefaults

    var onIPCEnabledChanged: (@MainActor (Bool) -> Void)?

    var hotkeysEnabled: Bool {
        didSet { defaults.set(hotkeysEnabled, forKey: Keys.hotkeysEnabled) }
    }

    var focusFollowsMouse: Bool {
        didSet { defaults.set(focusFollowsMouse, forKey: Keys.focusFollowsMouse) }
    }

    var moveMouseToFocusedWindow: Bool {
        didSet { defaults.set(moveMouseToFocusedWindow, forKey: Keys.moveMouseToFocusedWindow) }
    }

    var focusFollowsWindowToMonitor: Bool {
        didSet { defaults.set(focusFollowsWindowToMonitor, forKey: Keys.focusFollowsWindowToMonitor) }
    }

    var mouseWarpMonitorOrder: [String] {
        didSet { saveMouseWarpMonitorOrder() }
    }

    var mouseWarpAxis: MouseWarpAxis {
        didSet { defaults.set(mouseWarpAxis.rawValue, forKey: Keys.mouseWarpAxis) }
    }

    var niriColumnWidthPresets: [Double] {
        didSet { saveNiriColumnWidthPresets() }
    }

    var niriDefaultColumnWidth: Double? {
        didSet {
            let validated = Self.validatedDefaultColumnWidth(niriDefaultColumnWidth)
            if validated != niriDefaultColumnWidth {
                niriDefaultColumnWidth = validated
                return
            }
            saveNiriDefaultColumnWidth()
        }
    }

    var mouseWarpMargin: Int {
        didSet { defaults.set(mouseWarpMargin, forKey: Keys.mouseWarpMargin) }
    }

    var gapSize: Double {
        didSet { defaults.set(gapSize, forKey: Keys.gapSize) }
    }

    var outerGapLeft: Double {
        didSet { defaults.set(outerGapLeft, forKey: Keys.outerGapLeft) }
    }

    var outerGapRight: Double {
        didSet { defaults.set(outerGapRight, forKey: Keys.outerGapRight) }
    }

    var outerGapTop: Double {
        didSet { defaults.set(outerGapTop, forKey: Keys.outerGapTop) }
    }

    var outerGapBottom: Double {
        didSet { defaults.set(outerGapBottom, forKey: Keys.outerGapBottom) }
    }

    var niriMaxWindowsPerColumn: Int {
        didSet { defaults.set(niriMaxWindowsPerColumn, forKey: Keys.niriMaxWindowsPerColumn) }
    }

    var niriMaxVisibleColumns: Int {
        didSet { defaults.set(niriMaxVisibleColumns, forKey: Keys.niriMaxVisibleColumns) }
    }

    var niriInfiniteLoop: Bool {
        didSet { defaults.set(niriInfiniteLoop, forKey: Keys.niriInfiniteLoop) }
    }

    var niriCenterFocusedColumn: CenterFocusedColumn {
        didSet { defaults.set(niriCenterFocusedColumn.rawValue, forKey: Keys.niriCenterFocusedColumn) }
    }

    var niriAlwaysCenterSingleColumn: Bool {
        didSet { defaults.set(niriAlwaysCenterSingleColumn, forKey: Keys.niriAlwaysCenterSingleColumn) }
    }

    var niriSingleWindowAspectRatio: SingleWindowAspectRatio {
        didSet { defaults.set(niriSingleWindowAspectRatio.rawValue, forKey: Keys.niriSingleWindowAspectRatio) }
    }

    var workspaceConfigurations: [WorkspaceConfiguration] {
        didSet { saveWorkspaceConfigurations() }
    }

    var defaultLayoutType: LayoutType {
        didSet { defaults.set(defaultLayoutType.rawValue, forKey: Keys.defaultLayoutType) }
    }

    var bordersEnabled: Bool {
        didSet { defaults.set(bordersEnabled, forKey: Keys.bordersEnabled) }
    }

    var borderWidth: Double {
        didSet { defaults.set(borderWidth, forKey: Keys.borderWidth) }
    }

    var borderColorRed: Double {
        didSet { defaults.set(borderColorRed, forKey: Keys.borderColorRed) }
    }

    var borderColorGreen: Double {
        didSet { defaults.set(borderColorGreen, forKey: Keys.borderColorGreen) }
    }

    var borderColorBlue: Double {
        didSet { defaults.set(borderColorBlue, forKey: Keys.borderColorBlue) }
    }

    var borderColorAlpha: Double {
        didSet { defaults.set(borderColorAlpha, forKey: Keys.borderColorAlpha) }
    }

    var hotkeyBindings: [HotkeyBinding] {
        didSet { saveBindings() }
    }

    var workspaceBarEnabled: Bool {
        didSet { defaults.set(workspaceBarEnabled, forKey: Keys.workspaceBarEnabled) }
    }

    var workspaceBarShowLabels: Bool {
        didSet { defaults.set(workspaceBarShowLabels, forKey: Keys.workspaceBarShowLabels) }
    }

    var workspaceBarWindowLevel: WorkspaceBarWindowLevel {
        didSet { defaults.set(workspaceBarWindowLevel.rawValue, forKey: Keys.workspaceBarWindowLevel) }
    }

    var workspaceBarPosition: WorkspaceBarPosition {
        didSet { defaults.set(workspaceBarPosition.rawValue, forKey: Keys.workspaceBarPosition) }
    }

    var workspaceBarNotchAware: Bool {
        didSet { defaults.set(workspaceBarNotchAware, forKey: Keys.workspaceBarNotchAware) }
    }

    var workspaceBarDeduplicateAppIcons: Bool {
        didSet { defaults.set(workspaceBarDeduplicateAppIcons, forKey: Keys.workspaceBarDeduplicateAppIcons) }
    }

    var workspaceBarHideEmptyWorkspaces: Bool {
        didSet { defaults.set(workspaceBarHideEmptyWorkspaces, forKey: Keys.workspaceBarHideEmptyWorkspaces) }
    }

    var workspaceBarReserveLayoutSpace: Bool {
        didSet { defaults.set(workspaceBarReserveLayoutSpace, forKey: Keys.workspaceBarReserveLayoutSpace) }
    }

    var workspaceBarHeight: Double {
        didSet { defaults.set(workspaceBarHeight, forKey: Keys.workspaceBarHeight) }
    }

    var workspaceBarBackgroundOpacity: Double {
        didSet { defaults.set(workspaceBarBackgroundOpacity, forKey: Keys.workspaceBarBackgroundOpacity) }
    }

    var workspaceBarXOffset: Double {
        didSet { defaults.set(workspaceBarXOffset, forKey: Keys.workspaceBarXOffset) }
    }

    var workspaceBarYOffset: Double {
        didSet { defaults.set(workspaceBarYOffset, forKey: Keys.workspaceBarYOffset) }
    }

    var monitorBarSettings: [MonitorBarSettings] {
        didSet { MonitorSettingsStore.save(monitorBarSettings, to: defaults, key: Keys.monitorBarSettings) }
    }

    var appRules: [AppRule] {
        didSet { saveAppRules() }
    }

    var monitorOrientationSettings: [MonitorOrientationSettings] {
        didSet { MonitorSettingsStore.save(monitorOrientationSettings, to: defaults, key: Keys.monitorOrientationSettings) }
    }

    var monitorNiriSettings: [MonitorNiriSettings] {
        didSet { MonitorSettingsStore.save(monitorNiriSettings, to: defaults, key: Keys.monitorNiriSettings) }
    }

    var dwindleSmartSplit: Bool {
        didSet { defaults.set(dwindleSmartSplit, forKey: Keys.dwindleSmartSplit) }
    }

    var dwindleDefaultSplitRatio: Double {
        didSet { defaults.set(dwindleDefaultSplitRatio, forKey: Keys.dwindleDefaultSplitRatio) }
    }

    var dwindleSplitWidthMultiplier: Double {
        didSet { defaults.set(dwindleSplitWidthMultiplier, forKey: Keys.dwindleSplitWidthMultiplier) }
    }

    var dwindleSingleWindowAspectRatio: DwindleSingleWindowAspectRatio {
        didSet { defaults.set(dwindleSingleWindowAspectRatio.rawValue, forKey: Keys.dwindleSingleWindowAspectRatio) }
    }

    var dwindleUseGlobalGaps: Bool {
        didSet { defaults.set(dwindleUseGlobalGaps, forKey: Keys.dwindleUseGlobalGaps) }
    }

    var dwindleMoveToRootStable: Bool {
        didSet { defaults.set(dwindleMoveToRootStable, forKey: Keys.dwindleMoveToRootStable) }
    }

    var monitorDwindleSettings: [MonitorDwindleSettings] {
        didSet { MonitorSettingsStore.save(monitorDwindleSettings, to: defaults, key: Keys.monitorDwindleSettings) }
    }

    var preventSleepEnabled: Bool {
        didSet { defaults.set(preventSleepEnabled, forKey: Keys.preventSleepEnabled) }
    }

    var updateChecksEnabled: Bool {
        didSet { defaults.set(updateChecksEnabled, forKey: Keys.updateChecksEnabled) }
    }

    var ipcEnabled: Bool {
        didSet {
            defaults.set(ipcEnabled, forKey: Keys.ipcEnabled)
            guard oldValue != ipcEnabled else { return }
            onIPCEnabledChanged?(ipcEnabled)
        }
    }

    var scrollGestureEnabled: Bool {
        didSet { defaults.set(scrollGestureEnabled, forKey: Keys.scrollGestureEnabled) }
    }

    var scrollSensitivity: Double {
        didSet { defaults.set(scrollSensitivity, forKey: Keys.scrollSensitivity) }
    }

    var scrollModifierKey: ScrollModifierKey {
        didSet { defaults.set(scrollModifierKey.rawValue, forKey: Keys.scrollModifierKey) }
    }

    var gestureFingerCount: GestureFingerCount {
        didSet { defaults.set(gestureFingerCount.rawValue, forKey: Keys.gestureFingerCount) }
    }

    var gestureInvertDirection: Bool {
        didSet { defaults.set(gestureInvertDirection, forKey: Keys.gestureInvertDirection) }
    }

    var statusBarShowWorkspaceName: Bool {
        didSet { defaults.set(statusBarShowWorkspaceName, forKey: Keys.statusBarShowWorkspaceName) }
    }

    var statusBarShowAppNames: Bool {
        didSet { defaults.set(statusBarShowAppNames, forKey: Keys.statusBarShowAppNames) }
    }

    var statusBarUseWorkspaceId: Bool {
        didSet { defaults.set(statusBarUseWorkspaceId, forKey: Keys.statusBarUseWorkspaceId) }
    }

    var commandPaletteLastMode: CommandPaletteMode {
        didSet { defaults.set(commandPaletteLastMode.rawValue, forKey: Keys.commandPaletteLastMode) }
    }

    var animationsEnabled: Bool {
        didSet { defaults.set(animationsEnabled, forKey: Keys.animationsEnabled) }
    }

    var hiddenBarIsCollapsed: Bool {
        didSet { defaults.set(hiddenBarIsCollapsed, forKey: Keys.hiddenBarIsCollapsed) }
    }

    var quakeTerminalEnabled: Bool {
        didSet { defaults.set(quakeTerminalEnabled, forKey: Keys.quakeTerminalEnabled) }
    }

    var quakeTerminalPosition: QuakeTerminalPosition {
        didSet { defaults.set(quakeTerminalPosition.rawValue, forKey: Keys.quakeTerminalPosition) }
    }

    var quakeTerminalWidthPercent: Double {
        didSet { defaults.set(quakeTerminalWidthPercent, forKey: Keys.quakeTerminalWidthPercent) }
    }

    var quakeTerminalHeightPercent: Double {
        didSet { defaults.set(quakeTerminalHeightPercent, forKey: Keys.quakeTerminalHeightPercent) }
    }

    var quakeTerminalAnimationDuration: Double {
        didSet { defaults.set(quakeTerminalAnimationDuration, forKey: Keys.quakeTerminalAnimationDuration) }
    }

    var quakeTerminalAutoHide: Bool {
        didSet { defaults.set(quakeTerminalAutoHide, forKey: Keys.quakeTerminalAutoHide) }
    }

    var quakeTerminalOpacity: Double {
        didSet { defaults.set(quakeTerminalOpacity, forKey: Keys.quakeTerminalOpacity) }
    }

    var quakeTerminalMonitorMode: QuakeTerminalMonitorMode {
        didSet { defaults.set(quakeTerminalMonitorMode.rawValue, forKey: Keys.quakeTerminalMonitorMode) }
    }

    var quakeTerminalUseCustomFrame: Bool {
        didSet { defaults.set(quakeTerminalUseCustomFrame, forKey: Keys.quakeTerminalUseCustomFrame) }
    }

    private var quakeTerminalCustomFrameX: Double? {
        didSet { defaults.set(quakeTerminalCustomFrameX, forKey: Keys.quakeTerminalCustomFrameX) }
    }

    private var quakeTerminalCustomFrameY: Double? {
        didSet { defaults.set(quakeTerminalCustomFrameY, forKey: Keys.quakeTerminalCustomFrameY) }
    }

    private var quakeTerminalCustomFrameWidth: Double? {
        didSet { defaults.set(quakeTerminalCustomFrameWidth, forKey: Keys.quakeTerminalCustomFrameWidth) }
    }

    private var quakeTerminalCustomFrameHeight: Double? {
        didSet { defaults.set(quakeTerminalCustomFrameHeight, forKey: Keys.quakeTerminalCustomFrameHeight) }
    }

    var quakeTerminalCustomFrame: NSRect? {
        get {
            guard let x = quakeTerminalCustomFrameX,
                  let y = quakeTerminalCustomFrameY,
                  let width = quakeTerminalCustomFrameWidth,
                  let height = quakeTerminalCustomFrameHeight else {
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

    var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    func loadPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        guard let data = defaults.data(forKey: Keys.persistedWindowRestoreCatalog),
              let catalog = try? JSONDecoder().decode(PersistedWindowRestoreCatalog.self, from: data)
        else {
            return .empty
        }

        return catalog
    }

    func savePersistedWindowRestoreCatalog(_ catalog: PersistedWindowRestoreCatalog) {
        if catalog.entries.isEmpty {
            defaults.removeObject(forKey: Keys.persistedWindowRestoreCatalog)
            return
        }

        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: Keys.persistedWindowRestoreCatalog)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let baseline = SettingsExport.defaults()

        hotkeysEnabled = defaults.object(forKey: Keys.hotkeysEnabled) as? Bool ?? baseline.hotkeysEnabled
        focusFollowsMouse = defaults.object(forKey: Keys.focusFollowsMouse) as? Bool ?? baseline.focusFollowsMouse
        moveMouseToFocusedWindow = defaults.object(forKey: Keys.moveMouseToFocusedWindow) as? Bool ??
            baseline.moveMouseToFocusedWindow
        focusFollowsWindowToMonitor = defaults.object(forKey: Keys.focusFollowsWindowToMonitor) as? Bool ??
            baseline.focusFollowsWindowToMonitor
        mouseWarpMonitorOrder = Self.loadMouseWarpMonitorOrder(from: defaults)
        mouseWarpAxis = MouseWarpAxis(rawValue: defaults.string(forKey: Keys.mouseWarpAxis) ?? "") ??
            MouseWarpAxis(rawValue: baseline.mouseWarpAxis ?? "") ?? .horizontal
        niriColumnWidthPresets = Self.loadNiriColumnWidthPresets(from: defaults)
        niriDefaultColumnWidth = Self.loadNiriDefaultColumnWidth(from: defaults)
        mouseWarpMargin = defaults.object(forKey: Keys.mouseWarpMargin) as? Int ?? baseline.mouseWarpMargin
        gapSize = defaults.object(forKey: Keys.gapSize) as? Double ?? baseline.gapSize

        outerGapLeft = defaults.object(forKey: Keys.outerGapLeft) as? Double ?? baseline.outerGapLeft
        outerGapRight = defaults.object(forKey: Keys.outerGapRight) as? Double ?? baseline.outerGapRight
        outerGapTop = defaults.object(forKey: Keys.outerGapTop) as? Double ?? baseline.outerGapTop
        outerGapBottom = defaults.object(forKey: Keys.outerGapBottom) as? Double ?? baseline.outerGapBottom

        niriMaxWindowsPerColumn = defaults.object(forKey: Keys.niriMaxWindowsPerColumn) as? Int ??
            baseline.niriMaxWindowsPerColumn
        niriMaxVisibleColumns = defaults.object(forKey: Keys.niriMaxVisibleColumns) as? Int ??
            baseline.niriMaxVisibleColumns
        niriInfiniteLoop = defaults.object(forKey: Keys.niriInfiniteLoop) as? Bool ?? baseline.niriInfiniteLoop
        niriCenterFocusedColumn = CenterFocusedColumn(rawValue: defaults
            .string(forKey: Keys.niriCenterFocusedColumn) ?? "") ??
            CenterFocusedColumn(rawValue: baseline.niriCenterFocusedColumn) ?? .never
        niriAlwaysCenterSingleColumn = defaults.object(forKey: Keys.niriAlwaysCenterSingleColumn) as? Bool ??
            baseline.niriAlwaysCenterSingleColumn
        niriSingleWindowAspectRatio = SingleWindowAspectRatio(rawValue: defaults
            .string(forKey: Keys.niriSingleWindowAspectRatio) ?? "") ??
            SingleWindowAspectRatio(rawValue: baseline.niriSingleWindowAspectRatio) ?? .ratio4x3

        workspaceConfigurations = Self.loadWorkspaceConfigurations(from: defaults)
        defaultLayoutType = LayoutType(rawValue: defaults.string(forKey: Keys.defaultLayoutType) ?? "") ??
            LayoutType(rawValue: baseline.defaultLayoutType) ?? .niri

        bordersEnabled = defaults.object(forKey: Keys.bordersEnabled) as? Bool ?? baseline.bordersEnabled
        borderWidth = defaults.object(forKey: Keys.borderWidth) as? Double ?? baseline.borderWidth
        borderColorRed = defaults.object(forKey: Keys.borderColorRed) as? Double ?? baseline.borderColorRed
        borderColorGreen = defaults.object(forKey: Keys.borderColorGreen) as? Double ?? baseline.borderColorGreen
        borderColorBlue = defaults.object(forKey: Keys.borderColorBlue) as? Double ?? baseline.borderColorBlue
        borderColorAlpha = defaults.object(forKey: Keys.borderColorAlpha) as? Double ?? baseline.borderColorAlpha

        hotkeyBindings = Self.loadBindings(from: defaults)

        workspaceBarEnabled = defaults.object(forKey: Keys.workspaceBarEnabled) as? Bool ?? baseline.workspaceBarEnabled
        workspaceBarShowLabels = defaults.object(forKey: Keys.workspaceBarShowLabels) as? Bool ??
            baseline.workspaceBarShowLabels
        workspaceBarWindowLevel = WorkspaceBarWindowLevel(
            rawValue: defaults.string(forKey: Keys.workspaceBarWindowLevel) ?? ""
        ) ?? WorkspaceBarWindowLevel(rawValue: baseline.workspaceBarWindowLevel) ?? .popup
        workspaceBarPosition = WorkspaceBarPosition(
            rawValue: defaults.string(forKey: Keys.workspaceBarPosition) ?? ""
        ) ?? WorkspaceBarPosition(rawValue: baseline.workspaceBarPosition) ?? .overlappingMenuBar
        workspaceBarNotchAware = defaults.object(forKey: Keys.workspaceBarNotchAware) as? Bool ??
            baseline.workspaceBarNotchAware
        workspaceBarDeduplicateAppIcons = defaults
            .object(forKey: Keys.workspaceBarDeduplicateAppIcons) as? Bool ?? baseline.workspaceBarDeduplicateAppIcons
        workspaceBarHideEmptyWorkspaces = defaults
            .object(forKey: Keys.workspaceBarHideEmptyWorkspaces) as? Bool ?? baseline.workspaceBarHideEmptyWorkspaces
        workspaceBarReserveLayoutSpace = defaults
            .object(forKey: Keys.workspaceBarReserveLayoutSpace) as? Bool ?? baseline.workspaceBarReserveLayoutSpace
        workspaceBarHeight = defaults.object(forKey: Keys.workspaceBarHeight) as? Double ?? baseline.workspaceBarHeight
        workspaceBarBackgroundOpacity = defaults.object(forKey: Keys.workspaceBarBackgroundOpacity) as? Double ??
            baseline.workspaceBarBackgroundOpacity
        workspaceBarXOffset = defaults.object(forKey: Keys.workspaceBarXOffset) as? Double ?? baseline.workspaceBarXOffset
        workspaceBarYOffset = defaults.object(forKey: Keys.workspaceBarYOffset) as? Double ?? baseline.workspaceBarYOffset
        monitorBarSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorBarSettings)
        let loadedAppRules = Self.loadAppRules(from: defaults)
        appRules = loadedAppRules
        if defaults.data(forKey: Keys.appRules) != nil,
           let normalizedRulesData = try? JSONEncoder().encode(loadedAppRules),
           normalizedRulesData != defaults.data(forKey: Keys.appRules)
        {
            defaults.set(normalizedRulesData, forKey: Keys.appRules)
        }
        monitorOrientationSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorOrientationSettings)
        monitorNiriSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorNiriSettings)

        dwindleSmartSplit = defaults.object(forKey: Keys.dwindleSmartSplit) as? Bool ?? baseline.dwindleSmartSplit
        dwindleDefaultSplitRatio = defaults.object(forKey: Keys.dwindleDefaultSplitRatio) as? Double ??
            baseline.dwindleDefaultSplitRatio
        dwindleSplitWidthMultiplier = defaults.object(forKey: Keys.dwindleSplitWidthMultiplier) as? Double ??
            baseline.dwindleSplitWidthMultiplier
        dwindleSingleWindowAspectRatio = DwindleSingleWindowAspectRatio(
            rawValue: defaults.string(forKey: Keys.dwindleSingleWindowAspectRatio) ?? ""
        ) ?? DwindleSingleWindowAspectRatio(rawValue: baseline.dwindleSingleWindowAspectRatio) ?? .ratio4x3
        dwindleUseGlobalGaps = defaults.object(forKey: Keys.dwindleUseGlobalGaps) as? Bool ??
            baseline.dwindleUseGlobalGaps
        dwindleMoveToRootStable = defaults.object(forKey: Keys.dwindleMoveToRootStable) as? Bool ??
            baseline.dwindleMoveToRootStable
        monitorDwindleSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorDwindleSettings)

        preventSleepEnabled = defaults.object(forKey: Keys.preventSleepEnabled) as? Bool ?? baseline.preventSleepEnabled
        updateChecksEnabled = defaults.object(forKey: Keys.updateChecksEnabled) as? Bool ?? baseline.updateChecksEnabled
        ipcEnabled = defaults.object(forKey: Keys.ipcEnabled) as? Bool ?? baseline.ipcEnabled
        scrollGestureEnabled = defaults.object(forKey: Keys.scrollGestureEnabled) as? Bool ??
            baseline.scrollGestureEnabled
        scrollSensitivity = defaults.object(forKey: Keys.scrollSensitivity) as? Double ?? baseline.scrollSensitivity
        scrollModifierKey = ScrollModifierKey(rawValue: defaults.string(forKey: Keys.scrollModifierKey) ?? "") ??
            ScrollModifierKey(rawValue: baseline.scrollModifierKey) ?? .optionShift
        gestureFingerCount = GestureFingerCount(
            rawValue: defaults.object(forKey: Keys.gestureFingerCount) as? Int ?? baseline.gestureFingerCount
        ) ?? .three
        gestureInvertDirection = defaults.object(forKey: Keys.gestureInvertDirection) as? Bool ??
            baseline.gestureInvertDirection
        statusBarShowWorkspaceName = defaults.object(forKey: Keys.statusBarShowWorkspaceName) as? Bool ?? false
        statusBarShowAppNames = defaults.object(forKey: Keys.statusBarShowAppNames) as? Bool ?? false
        statusBarUseWorkspaceId = defaults.object(forKey: Keys.statusBarUseWorkspaceId) as? Bool ?? false

        commandPaletteLastMode = CommandPaletteMode(
            rawValue: defaults.string(forKey: Keys.commandPaletteLastMode) ?? ""
        ) ?? CommandPaletteMode(rawValue: baseline.commandPaletteLastMode) ?? .windows

        animationsEnabled = defaults.object(forKey: Keys.animationsEnabled) as? Bool ?? baseline.animationsEnabled

        hiddenBarIsCollapsed = defaults.object(forKey: Keys.hiddenBarIsCollapsed) as? Bool ??
            baseline.hiddenBarIsCollapsed

        quakeTerminalEnabled = defaults.object(forKey: Keys.quakeTerminalEnabled) as? Bool ?? baseline.quakeTerminalEnabled
        quakeTerminalPosition = QuakeTerminalPosition(
            rawValue: defaults.string(forKey: Keys.quakeTerminalPosition) ?? ""
        ) ?? QuakeTerminalPosition(rawValue: baseline.quakeTerminalPosition) ?? .center
        quakeTerminalWidthPercent = defaults.object(forKey: Keys.quakeTerminalWidthPercent) as? Double ??
            baseline.quakeTerminalWidthPercent
        quakeTerminalHeightPercent = defaults.object(forKey: Keys.quakeTerminalHeightPercent) as? Double ??
            baseline.quakeTerminalHeightPercent
        quakeTerminalAnimationDuration = defaults.object(forKey: Keys.quakeTerminalAnimationDuration) as? Double ??
            baseline.quakeTerminalAnimationDuration
        quakeTerminalAutoHide = defaults.object(forKey: Keys.quakeTerminalAutoHide) as? Bool ??
            baseline.quakeTerminalAutoHide
        quakeTerminalOpacity = defaults.object(forKey: Keys.quakeTerminalOpacity) as? Double ??
            (baseline.quakeTerminalOpacity ?? 1.0)
        quakeTerminalMonitorMode = QuakeTerminalMonitorMode(
            rawValue: defaults.string(forKey: Keys.quakeTerminalMonitorMode) ?? ""
        ) ?? QuakeTerminalMonitorMode(rawValue: baseline.quakeTerminalMonitorMode ?? "") ?? .focusedWindow
        quakeTerminalUseCustomFrame = defaults.object(forKey: Keys.quakeTerminalUseCustomFrame) as? Bool ??
            baseline.quakeTerminalUseCustomFrame
        quakeTerminalCustomFrameX = defaults.object(forKey: Keys.quakeTerminalCustomFrameX) as? Double
        quakeTerminalCustomFrameY = defaults.object(forKey: Keys.quakeTerminalCustomFrameY) as? Double
        quakeTerminalCustomFrameWidth = defaults.object(forKey: Keys.quakeTerminalCustomFrameWidth) as? Double
        quakeTerminalCustomFrameHeight = defaults.object(forKey: Keys.quakeTerminalCustomFrameHeight) as? Double
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ??
            AppearanceMode(rawValue: baseline.appearanceMode) ?? .dark
    }

    private static func loadBindings(from defaults: UserDefaults) -> [HotkeyBinding] {
        guard let data = defaults.data(forKey: Keys.hotkeyBindings),
              let bindings = HotkeyBindingRegistry.decodePersistedBindings(from: data)
        else {
            return HotkeyBindingRegistry.defaults()
        }

        if let cleanedData = try? JSONEncoder().encode(bindings) {
            defaults.set(cleanedData, forKey: Keys.hotkeyBindings)
        }

        return bindings
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(hotkeyBindings) else { return }
        defaults.set(data, forKey: Keys.hotkeyBindings)
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

    private static func loadWorkspaceConfigurations(from defaults: UserDefaults) -> [WorkspaceConfiguration] {
        if let data = defaults.data(forKey: Keys.workspaceConfigurations),
           let configs = try? JSONDecoder().decode([WorkspaceConfiguration].self, from: data)
        {
            return normalizedWorkspaceConfigurations(configs)
        }
        return normalizedWorkspaceConfigurations([])
    }

    private func saveWorkspaceConfigurations() {
        guard let data = try? JSONEncoder().encode(workspaceConfigurations) else { return }
        defaults.set(data, forKey: Keys.workspaceConfigurations)
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
            for _ in 0..<(currentCount - persistedCount) {
                persisted.append(name)
            }
            persistedCounts[name] = currentCount
        }

        if mouseWarpMonitorOrder != persisted {
            mouseWarpMonitorOrder = persisted
        }

        return effectiveMouseWarpMonitorOrder(for: monitors, axis: warpAxis)
    }

    private static func normalizedWorkspaceConfigurations(_ configs: [WorkspaceConfiguration]) -> [WorkspaceConfiguration] {
        var seen: Set<String> = []
        let normalized = configs
            .filter { WorkspaceIDPolicy.normalizeRawID($0.name) != nil }
            .filter { seen.insert($0.name).inserted }
            .sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }

        if normalized.isEmpty {
            return BuiltInSettingsDefaults.workspaceConfigurations
        }

        return normalized
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

    private static func loadAppRules(from defaults: UserDefaults) -> [AppRule] {
        guard let data = defaults.data(forKey: Keys.appRules),
              let rules = try? JSONDecoder().decode([AppRule].self, from: data)
        else {
            return BuiltInSettingsDefaults.appRules
        }
        return rules
    }

    private func saveAppRules() {
        guard let data = try? JSONEncoder().encode(appRules) else { return }
        defaults.set(data, forKey: Keys.appRules)
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
            outerGapBottom: useGlobalGaps ? CGFloat(outerGapBottom) : CGFloat(override?.outerGapBottom ?? outerGapBottom),
            outerGapLeft: useGlobalGaps ? CGFloat(outerGapLeft) : CGFloat(override?.outerGapLeft ?? outerGapLeft),
            outerGapRight: useGlobalGaps ? CGFloat(outerGapRight) : CGFloat(override?.outerGapRight ?? outerGapRight)
        )
    }

    private static func loadMouseWarpMonitorOrder(from defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: Keys.mouseWarpMonitorOrder),
              let order = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return order
    }

    private func saveMouseWarpMonitorOrder() {
        guard let data = try? JSONEncoder().encode(mouseWarpMonitorOrder) else { return }
        defaults.set(data, forKey: Keys.mouseWarpMonitorOrder)
    }

    nonisolated static let defaultColumnWidthPresets: [Double] = BuiltInSettingsDefaults.niriColumnWidthPresets

    static func validatedPresets(_ presets: [Double]) -> [Double] {
        let result = presets.map { min(1.0, max(0.05, $0)) }
        if result.count < 2 {
            return defaultColumnWidthPresets
        }
        return result
    }

    private static func loadNiriColumnWidthPresets(from defaults: UserDefaults) -> [Double] {
        guard let data = defaults.data(forKey: Keys.niriColumnWidthPresets),
              let presets = try? JSONDecoder().decode([Double].self, from: data)
        else {
            return defaultColumnWidthPresets
        }
        return validatedPresets(presets)
    }

    static func validatedDefaultColumnWidth(_ width: Double?) -> Double? {
        guard let width else { return nil }
        return min(1.0, max(0.05, width))
    }

    private static func loadNiriDefaultColumnWidth(from defaults: UserDefaults) -> Double? {
        guard let width = defaults.object(forKey: Keys.niriDefaultColumnWidth) as? NSNumber else {
            return nil
        }
        return validatedDefaultColumnWidth(width.doubleValue)
    }

    private func saveNiriColumnWidthPresets() {
        guard let data = try? JSONEncoder().encode(niriColumnWidthPresets) else { return }
        defaults.set(data, forKey: Keys.niriColumnWidthPresets)
    }

    private func saveNiriDefaultColumnWidth() {
        guard let width = niriDefaultColumnWidth else {
            defaults.removeObject(forKey: Keys.niriDefaultColumnWidth)
            return
        }
        defaults.set(width, forKey: Keys.niriDefaultColumnWidth)
    }
}

private enum Keys {
    static let hotkeysEnabled = "settings.hotkeysEnabled"
    static let focusFollowsMouse = "settings.focusFollowsMouse"
    static let moveMouseToFocusedWindow = "settings.moveMouseToFocusedWindow"
    static let focusFollowsWindowToMonitor = "settings.focusFollowsWindowToMonitor"
    static let mouseWarpMonitorOrder = "settings.mouseWarp.monitorOrder"
    static let mouseWarpAxis = "settings.mouseWarp.axis"
    static let niriColumnWidthPresets = "settings.niriColumnWidthPresets"
    static let niriDefaultColumnWidth = "settings.niriDefaultColumnWidth"
    static let mouseWarpMargin = "settings.mouseWarp.margin"
    static let gapSize = "settings.gapSize"

    static let outerGapLeft = "settings.outerGapLeft"
    static let outerGapRight = "settings.outerGapRight"
    static let outerGapTop = "settings.outerGapTop"
    static let outerGapBottom = "settings.outerGapBottom"

    static let niriMaxWindowsPerColumn = "settings.niriMaxWindowsPerColumn"
    static let niriMaxVisibleColumns = "settings.niriMaxVisibleColumns"
    static let niriInfiniteLoop = "settings.niriInfiniteLoop"
    static let niriCenterFocusedColumn = "settings.niriCenterFocusedColumn"
    static let niriAlwaysCenterSingleColumn = "settings.niriAlwaysCenterSingleColumn"
    static let niriSingleWindowAspectRatio = "settings.niriSingleWindowAspectRatio"
    static let monitorNiriSettings = "settings.monitorNiriSettings"

    static let dwindleSmartSplit = "settings.dwindleSmartSplit"
    static let dwindleDefaultSplitRatio = "settings.dwindleDefaultSplitRatio"
    static let dwindleSplitWidthMultiplier = "settings.dwindleSplitWidthMultiplier"
    static let dwindleSingleWindowAspectRatio = "settings.dwindleSingleWindowAspectRatio"
    static let dwindleUseGlobalGaps = "settings.dwindleUseGlobalGaps"
    static let dwindleMoveToRootStable = "settings.dwindleMoveToRootStable"
    static let monitorDwindleSettings = "settings.monitorDwindleSettings"

    static let workspaceConfigurations = "settings.workspaceConfigurations"
    static let defaultLayoutType = "settings.defaultLayoutType"

    static let bordersEnabled = "settings.bordersEnabled"
    static let borderWidth = "settings.borderWidth"
    static let borderColorRed = "settings.borderColorRed"
    static let borderColorGreen = "settings.borderColorGreen"
    static let borderColorBlue = "settings.borderColorBlue"
    static let borderColorAlpha = "settings.borderColorAlpha"

    static let hotkeyBindings = "settings.hotkeyBindings"

    static let workspaceBarEnabled = "settings.workspaceBar.enabled"
    static let workspaceBarShowLabels = "settings.workspaceBar.showLabels"
    static let workspaceBarWindowLevel = "settings.workspaceBar.windowLevel"
    static let workspaceBarPosition = "settings.workspaceBar.position"
    static let workspaceBarNotchAware = "settings.workspaceBar.notchAware"
    static let workspaceBarDeduplicateAppIcons = "settings.workspaceBar.deduplicateAppIcons"
    static let workspaceBarHideEmptyWorkspaces = "settings.workspaceBar.hideEmptyWorkspaces"
    static let workspaceBarReserveLayoutSpace = "settings.workspaceBar.reserveLayoutSpace"
    static let workspaceBarHeight = "settings.workspaceBar.height"
    static let workspaceBarBackgroundOpacity = "settings.workspaceBar.backgroundOpacity"
    static let workspaceBarXOffset = "settings.workspaceBar.xOffset"
    static let workspaceBarYOffset = "settings.workspaceBar.yOffset"
    static let monitorBarSettings = "settings.workspaceBar.monitorSettings"

    static let appRules = "settings.appRules"
    static let monitorOrientationSettings = "settings.monitorOrientationSettings"
    static let preventSleepEnabled = "settings.preventSleepEnabled"
    static let updateChecksEnabled = "settings.updateChecksEnabled"
    static let ipcEnabled = "settings.ipcEnabled"
    static let scrollGestureEnabled = "settings.scrollGestureEnabled"
    static let scrollSensitivity = "settings.scrollSensitivity"
    static let scrollModifierKey = "settings.scrollModifierKey"
    static let gestureFingerCount = "settings.gestureFingerCount"
    static let gestureInvertDirection = "settings.gestureInvertDirection"
    static let statusBarShowWorkspaceName = "settings.statusBarShowWorkspaceName"
    static let statusBarShowAppNames = "settings.statusBarShowAppNames"
    static let statusBarUseWorkspaceId = "settings.statusBarUseWorkspaceId"

    static let commandPaletteLastMode = "settings.commandPalette.lastMode"
    static let animationsEnabled = "settings.animationsEnabled"

    static let hiddenBarIsCollapsed = "settings.hiddenBar.isCollapsed"

    static let quakeTerminalEnabled = "settings.quakeTerminal.enabled"
    static let quakeTerminalPosition = "settings.quakeTerminal.position"
    static let quakeTerminalWidthPercent = "settings.quakeTerminal.widthPercent"
    static let quakeTerminalHeightPercent = "settings.quakeTerminal.heightPercent"
    static let quakeTerminalAnimationDuration = "settings.quakeTerminal.animationDuration"
    static let quakeTerminalAutoHide = "settings.quakeTerminal.autoHide"
    static let quakeTerminalOpacity = "settings.quakeTerminal.opacity"
    static let quakeTerminalMonitorMode = "settings.quakeTerminal.monitorMode"
    static let quakeTerminalUseCustomFrame = "settings.quakeTerminal.useCustomFrame"
    static let quakeTerminalCustomFrameX = "settings.quakeTerminal.customFrameX"
    static let quakeTerminalCustomFrameY = "settings.quakeTerminal.customFrameY"
    static let quakeTerminalCustomFrameWidth = "settings.quakeTerminal.customFrameWidth"
    static let quakeTerminalCustomFrameHeight = "settings.quakeTerminal.customFrameHeight"

    static let appearanceMode = "settings.appearanceMode"
    static let persistedWindowRestoreCatalog = "settings.restoreCatalog"
}
