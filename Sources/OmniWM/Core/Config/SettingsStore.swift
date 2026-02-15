import AppKit
import Foundation

@MainActor @Observable
final class SettingsStore {
    private let defaults: UserDefaults

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

    var mouseWarpEnabled: Bool {
        didSet { defaults.set(mouseWarpEnabled, forKey: Keys.mouseWarpEnabled) }
    }

    var mouseWarpMonitorOrder: [String] {
        didSet { saveMouseWarpMonitorOrder() }
    }

    var niriColumnWidthPresets: [Double] {
        didSet { saveNiriColumnWidthPresets() }
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

    var persistentWorkspacesRaw: String {
        didSet { defaults.set(persistentWorkspacesRaw, forKey: Keys.persistentWorkspaces) }
    }

    var workspaceAssignmentsRaw: String {
        didSet { defaults.set(workspaceAssignmentsRaw, forKey: Keys.workspaceAssignments) }
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

    var animationsEnabled: Bool {
        didSet { defaults.set(animationsEnabled, forKey: Keys.animationsEnabled) }
    }

    var menuAnywhereNativeEnabled: Bool {
        didSet { defaults.set(menuAnywhereNativeEnabled, forKey: Keys.menuAnywhereNativeEnabled) }
    }

    var menuAnywherePaletteEnabled: Bool {
        didSet { defaults.set(menuAnywherePaletteEnabled, forKey: Keys.menuAnywherePaletteEnabled) }
    }

    var menuAnywherePosition: MenuAnywherePosition {
        didSet { defaults.set(menuAnywherePosition.rawValue, forKey: Keys.menuAnywherePosition) }
    }

    var menuAnywhereShowShortcuts: Bool {
        didSet { defaults.set(menuAnywhereShowShortcuts, forKey: Keys.menuAnywhereShowShortcuts) }
    }

    var hiddenBarEnabled: Bool {
        didSet { defaults.set(hiddenBarEnabled, forKey: Keys.hiddenBarEnabled) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkeysEnabled = defaults.object(forKey: Keys.hotkeysEnabled) as? Bool ?? true
        focusFollowsMouse = defaults.object(forKey: Keys.focusFollowsMouse) as? Bool ?? false
        moveMouseToFocusedWindow = defaults.object(forKey: Keys.moveMouseToFocusedWindow) as? Bool ?? false
        focusFollowsWindowToMonitor = defaults.object(forKey: Keys.focusFollowsWindowToMonitor) as? Bool ?? false
        mouseWarpEnabled = defaults.object(forKey: Keys.mouseWarpEnabled) as? Bool ?? false
        mouseWarpMonitorOrder = Self.loadMouseWarpMonitorOrder(from: defaults)
        niriColumnWidthPresets = Self.loadNiriColumnWidthPresets(from: defaults)
        mouseWarpMargin = defaults.object(forKey: Keys.mouseWarpMargin) as? Int ?? 2
        gapSize = defaults.object(forKey: Keys.gapSize) as? Double ?? 8

        outerGapLeft = defaults.object(forKey: Keys.outerGapLeft) as? Double ?? 0
        outerGapRight = defaults.object(forKey: Keys.outerGapRight) as? Double ?? 0
        outerGapTop = defaults.object(forKey: Keys.outerGapTop) as? Double ?? 0
        outerGapBottom = defaults.object(forKey: Keys.outerGapBottom) as? Double ?? 0

        niriMaxWindowsPerColumn = defaults.object(forKey: Keys.niriMaxWindowsPerColumn) as? Int ?? 3
        niriMaxVisibleColumns = defaults.object(forKey: Keys.niriMaxVisibleColumns) as? Int ?? 2
        niriInfiniteLoop = defaults.object(forKey: Keys.niriInfiniteLoop) as? Bool ?? false
        niriCenterFocusedColumn = CenterFocusedColumn(rawValue: defaults
            .string(forKey: Keys.niriCenterFocusedColumn) ?? "") ?? .never
        niriAlwaysCenterSingleColumn = defaults.object(forKey: Keys.niriAlwaysCenterSingleColumn) as? Bool ?? true
        niriSingleWindowAspectRatio = SingleWindowAspectRatio(rawValue: defaults
            .string(forKey: Keys.niriSingleWindowAspectRatio) ?? "") ?? .ratio4x3

        persistentWorkspacesRaw = defaults.string(forKey: Keys.persistentWorkspaces) ?? ""
        workspaceAssignmentsRaw = defaults.string(forKey: Keys.workspaceAssignments) ?? ""

        workspaceConfigurations = Self.loadWorkspaceConfigurations(from: defaults)
        defaultLayoutType = LayoutType(rawValue: defaults.string(forKey: Keys.defaultLayoutType) ?? "") ?? .niri

        bordersEnabled = defaults.object(forKey: Keys.bordersEnabled) as? Bool ?? false
        borderWidth = defaults.object(forKey: Keys.borderWidth) as? Double ?? 4.0
        borderColorRed = defaults.object(forKey: Keys.borderColorRed) as? Double ?? 0.0
        borderColorGreen = defaults.object(forKey: Keys.borderColorGreen) as? Double ?? 0.5
        borderColorBlue = defaults.object(forKey: Keys.borderColorBlue) as? Double ?? 1.0
        borderColorAlpha = defaults.object(forKey: Keys.borderColorAlpha) as? Double ?? 1.0

        hotkeyBindings = Self.loadBindings(from: defaults)

        workspaceBarEnabled = defaults.object(forKey: Keys.workspaceBarEnabled) as? Bool ?? false
        workspaceBarShowLabels = defaults.object(forKey: Keys.workspaceBarShowLabels) as? Bool ?? true
        workspaceBarWindowLevel = WorkspaceBarWindowLevel(
            rawValue: defaults.string(forKey: Keys.workspaceBarWindowLevel) ?? ""
        ) ?? .popup
        workspaceBarPosition = WorkspaceBarPosition(
            rawValue: defaults.string(forKey: Keys.workspaceBarPosition) ?? ""
        ) ?? .overlappingMenuBar
        workspaceBarNotchAware = defaults.object(forKey: Keys.workspaceBarNotchAware) as? Bool ?? false
        workspaceBarDeduplicateAppIcons = defaults
            .object(forKey: Keys.workspaceBarDeduplicateAppIcons) as? Bool ?? false
        workspaceBarHideEmptyWorkspaces = defaults
            .object(forKey: Keys.workspaceBarHideEmptyWorkspaces) as? Bool ?? false
        workspaceBarHeight = defaults.object(forKey: Keys.workspaceBarHeight) as? Double ?? 24.0
        workspaceBarBackgroundOpacity = defaults.object(forKey: Keys.workspaceBarBackgroundOpacity) as? Double ?? 0.1
        workspaceBarXOffset = defaults.object(forKey: Keys.workspaceBarXOffset) as? Double ?? 0.0
        workspaceBarYOffset = defaults.object(forKey: Keys.workspaceBarYOffset) as? Double ?? 0.0
        monitorBarSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorBarSettings)
        appRules = Self.loadAppRules(from: defaults)
        monitorOrientationSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorOrientationSettings)
        monitorNiriSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorNiriSettings)

        dwindleSmartSplit = defaults.object(forKey: Keys.dwindleSmartSplit) as? Bool ?? false
        dwindleDefaultSplitRatio = defaults.object(forKey: Keys.dwindleDefaultSplitRatio) as? Double ?? 1.0
        dwindleSplitWidthMultiplier = defaults.object(forKey: Keys.dwindleSplitWidthMultiplier) as? Double ?? 1.0
        dwindleSingleWindowAspectRatio = DwindleSingleWindowAspectRatio(
            rawValue: defaults.string(forKey: Keys.dwindleSingleWindowAspectRatio) ?? ""
        ) ?? .ratio4x3
        dwindleUseGlobalGaps = defaults.object(forKey: Keys.dwindleUseGlobalGaps) as? Bool ?? true
        dwindleMoveToRootStable = defaults.object(forKey: Keys.dwindleMoveToRootStable) as? Bool ?? true
        monitorDwindleSettings = MonitorSettingsStore.load(from: defaults, key: Keys.monitorDwindleSettings)

        preventSleepEnabled = defaults.object(forKey: Keys.preventSleepEnabled) as? Bool ?? false
        scrollGestureEnabled = defaults.object(forKey: Keys.scrollGestureEnabled) as? Bool ?? true
        scrollSensitivity = defaults.object(forKey: Keys.scrollSensitivity) as? Double ?? 1.0
        scrollModifierKey = ScrollModifierKey(rawValue: defaults.string(forKey: Keys.scrollModifierKey) ?? "") ??
            .optionShift
        gestureFingerCount = GestureFingerCount(rawValue: defaults.integer(forKey: Keys.gestureFingerCount)) ?? .three
        gestureInvertDirection = defaults.object(forKey: Keys.gestureInvertDirection) as? Bool ?? true

        animationsEnabled = defaults.object(forKey: Keys.animationsEnabled) as? Bool ?? true

        menuAnywhereNativeEnabled = defaults.object(forKey: Keys.menuAnywhereNativeEnabled) as? Bool ?? true
        menuAnywherePaletteEnabled = defaults.object(forKey: Keys.menuAnywherePaletteEnabled) as? Bool ?? true
        menuAnywherePosition = MenuAnywherePosition(
            rawValue: defaults.string(forKey: Keys.menuAnywherePosition) ?? ""
        ) ??
            .cursor
        menuAnywhereShowShortcuts = defaults.object(forKey: Keys.menuAnywhereShowShortcuts) as? Bool ?? true

        hiddenBarEnabled = defaults.object(forKey: Keys.hiddenBarEnabled) as? Bool ?? false
        hiddenBarIsCollapsed = defaults.object(forKey: Keys.hiddenBarIsCollapsed) as? Bool ?? false

        quakeTerminalEnabled = defaults.object(forKey: Keys.quakeTerminalEnabled) as? Bool ?? false
        quakeTerminalPosition = QuakeTerminalPosition(
            rawValue: defaults.string(forKey: Keys.quakeTerminalPosition) ?? ""
        ) ?? .top
        quakeTerminalWidthPercent = defaults.object(forKey: Keys.quakeTerminalWidthPercent) as? Double ?? 100.0
        quakeTerminalHeightPercent = defaults.object(forKey: Keys.quakeTerminalHeightPercent) as? Double ?? 40.0
        quakeTerminalAnimationDuration = defaults.object(forKey: Keys.quakeTerminalAnimationDuration) as? Double ?? 0.2
        quakeTerminalAutoHide = defaults.object(forKey: Keys.quakeTerminalAutoHide) as? Bool ?? true
        quakeTerminalOpacity = defaults.object(forKey: Keys.quakeTerminalOpacity) as? Double ?? 1.0
        quakeTerminalMonitorMode = QuakeTerminalMonitorMode(
            rawValue: defaults.string(forKey: Keys.quakeTerminalMonitorMode) ?? ""
        ) ?? .mouseCursor
        quakeTerminalUseCustomFrame = defaults.object(forKey: Keys.quakeTerminalUseCustomFrame) as? Bool ?? false
        quakeTerminalCustomFrameX = defaults.object(forKey: Keys.quakeTerminalCustomFrameX) as? Double
        quakeTerminalCustomFrameY = defaults.object(forKey: Keys.quakeTerminalCustomFrameY) as? Double
        quakeTerminalCustomFrameWidth = defaults.object(forKey: Keys.quakeTerminalCustomFrameWidth) as? Double
        quakeTerminalCustomFrameHeight = defaults.object(forKey: Keys.quakeTerminalCustomFrameHeight) as? Double
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .automatic
    }

    private static func loadBindings(from defaults: UserDefaults) -> [HotkeyBinding] {
        guard let data = defaults.data(forKey: Keys.hotkeyBindings),
              let bindings = try? JSONDecoder().decode([HotkeyBinding].self, from: data)
        else {
            return DefaultHotkeyBindings.all()
        }

        let merged = mergeWithDefaults(stored: bindings)

        let storedIds = Set(bindings.map(\.id))
        let mergedIds = Set(merged.map(\.id))
        if storedIds != mergedIds {
            if let cleanedData = try? JSONEncoder().encode(merged) {
                defaults.set(cleanedData, forKey: Keys.hotkeyBindings)
            }
        }

        return merged
    }

    private static func mergeWithDefaults(stored: [HotkeyBinding]) -> [HotkeyBinding] {
        let defaults = DefaultHotkeyBindings.all()
        let defaultIds = Set(defaults.map(\.id))

        var result = stored.filter { defaultIds.contains($0.id) }

        let storedIds = Set(result.map(\.id))
        for defaultBinding in defaults where !storedIds.contains(defaultBinding.id) {
            result.append(defaultBinding)
        }
        return result
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(hotkeyBindings) else { return }
        defaults.set(data, forKey: Keys.hotkeyBindings)
    }

    func resetHotkeysToDefaults() {
        hotkeyBindings = DefaultHotkeyBindings.all()
    }

    func updateBinding(for commandId: String, newBinding: KeyBinding) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == commandId }) else { return }
        hotkeyBindings[index] = HotkeyBinding(
            id: hotkeyBindings[index].id,
            command: hotkeyBindings[index].command,
            binding: newBinding
        )
    }

    func findConflicts(for binding: KeyBinding, excluding commandId: String) -> [HotkeyBinding] {
        hotkeyBindings.filter { $0.id != commandId && $0.binding.conflicts(with: binding) }
    }

    func persistentWorkspaceNames() -> [String] {
        if !workspaceConfigurations.isEmpty {
            return workspaceConfigurations
                .filter(\.isPersistent)
                .map(\.name)
        }

        let parts = persistentWorkspacesRaw.split { $0 == "," || $0 == "\n" || $0 == "\r" }
        var result: [String] = []
        var seen: Set<String> = []
        for part in parts {
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard case let .success(name) = WorkspaceName.parse(trimmed) else { continue }
            guard !seen.contains(name.raw) else { continue }
            seen.insert(name.raw)
            result.append(name.raw)
        }
        return result
    }

    func workspaceToMonitorAssignments() -> [String: [MonitorDescription]] {
        if !workspaceConfigurations.isEmpty {
            var result: [String: [MonitorDescription]] = [:]
            for config in workspaceConfigurations {
                if let desc = config.monitorAssignment.toMonitorDescription() {
                    result[config.name] = [desc]
                }
            }
            return result
        }

        var result: [String: [MonitorDescription]] = [:]
        let lines = workspaceAssignmentsRaw.split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmedLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            let parts: [Substring] = if trimmedLine.contains(":") {
                trimmedLine.split(separator: ":", maxSplits: 1)
            } else {
                trimmedLine.split(separator: "=", maxSplits: 1)
            }
            guard parts.count == 2 else { continue }
            let namePart = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let monitorsPart = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard case let .success(name) = WorkspaceName.parse(namePart) else { continue }

            let monitorTokens = monitorsPart.split(separator: ",")
            let monitors: [MonitorDescription] = monitorTokens.compactMap { token in
                let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard case let .success(desc) = parseMonitorDescription(raw) else { return nil }
                return desc
            }
            guard !monitors.isEmpty else { continue }
            result[name.raw, default: []].append(contentsOf: monitors)
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
            return configs
        }

        let migrated = defaults.bool(forKey: Keys.workspaceSettingsMigrated)
        if !migrated {
            let configs = migrateFromLegacySettings(defaults: defaults)
            if !configs.isEmpty {
                if let data = try? JSONEncoder().encode(configs) {
                    defaults.set(data, forKey: Keys.workspaceConfigurations)
                }
                defaults.set(true, forKey: Keys.workspaceSettingsMigrated)
                return configs
            }
        }

        return []
    }

    private static func migrateFromLegacySettings(defaults: UserDefaults) -> [WorkspaceConfiguration] {
        var result: [WorkspaceConfiguration] = []
        var seen: Set<String> = []

        let persistentRaw = defaults.string(forKey: Keys.persistentWorkspaces) ?? ""
        let persistentNames = persistentRaw
            .split { $0 == "," || $0 == "\n" || $0 == "\r" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let assignmentsRaw = defaults.string(forKey: Keys.workspaceAssignments) ?? ""
        var assignments: [String: MonitorAssignment] = [:]
        for line in assignmentsRaw.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.contains(":")
                ? trimmed.split(separator: ":", maxSplits: 1)
                : trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let monitorStr = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            let firstMonitor = monitorStr.split(separator: ",").first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? monitorStr
            assignments[name] = MonitorAssignment.fromString(firstMonitor)
        }

        for name in persistentNames {
            guard !seen.contains(name) else { continue }
            guard case .success = WorkspaceName.parse(name) else { continue }
            seen.insert(name)
            result.append(WorkspaceConfiguration(
                name: name,
                monitorAssignment: assignments[name] ?? .any,
                layoutType: .defaultLayout,
                isPersistent: true
            ))
        }

        for (name, assignment) in assignments where !seen.contains(name) {
            guard case .success = WorkspaceName.parse(name) else { continue }
            seen.insert(name)
            result.append(WorkspaceConfiguration(
                name: name,
                monitorAssignment: assignment,
                layoutType: .defaultLayout,
                isPersistent: false
            ))
        }

        return result
    }

    private func saveWorkspaceConfigurations() {
        guard let data = try? JSONEncoder().encode(workspaceConfigurations) else { return }
        defaults.set(data, forKey: Keys.workspaceConfigurations)
        defaults.set(true, forKey: Keys.workspaceSettingsMigrated)
    }

    func barSettings(for monitorName: String) -> MonitorBarSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorBarSettings)
    }

    func updateBarSettings(_ settings: MonitorBarSettings) {
        MonitorSettingsStore.update(settings, in: &monitorBarSettings)
    }

    func removeBarSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorBarSettings)
    }

    func resolvedBarSettings(for monitorName: String) -> ResolvedBarSettings {
        let override = barSettings(for: monitorName)

        return ResolvedBarSettings(
            enabled: override?.enabled ?? workspaceBarEnabled,
            showLabels: override?.showLabels ?? workspaceBarShowLabels,
            deduplicateAppIcons: override?.deduplicateAppIcons ?? workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: override?.hideEmptyWorkspaces ?? workspaceBarHideEmptyWorkspaces,
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
            return []
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

    func orientationSettings(for monitorName: String) -> MonitorOrientationSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorOrientationSettings)
    }

    func effectiveOrientation(for monitor: Monitor) -> Monitor.Orientation {
        if let override = orientationSettings(for: monitor.name),
           let orientation = override.orientation
        {
            return orientation
        }
        return monitor.autoOrientation
    }

    func updateOrientationSettings(_ settings: MonitorOrientationSettings) {
        MonitorSettingsStore.update(settings, in: &monitorOrientationSettings)
    }

    func removeOrientationSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorOrientationSettings)
    }

    func niriSettings(for monitorName: String) -> MonitorNiriSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorNiriSettings)
    }

    func updateNiriSettings(_ settings: MonitorNiriSettings) {
        MonitorSettingsStore.update(settings, in: &monitorNiriSettings)
    }

    func removeNiriSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorNiriSettings)
    }

    func resolvedNiriSettings(for monitorName: String) -> ResolvedNiriSettings {
        let override = niriSettings(for: monitorName)

        return ResolvedNiriSettings(
            maxVisibleColumns: override?.maxVisibleColumns ?? niriMaxVisibleColumns,
            maxWindowsPerColumn: override?.maxWindowsPerColumn ?? niriMaxWindowsPerColumn,
            centerFocusedColumn: override?.centerFocusedColumn ?? niriCenterFocusedColumn,
            alwaysCenterSingleColumn: override?.alwaysCenterSingleColumn ?? niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: override?.singleWindowAspectRatio ?? niriSingleWindowAspectRatio,
            infiniteLoop: override?.infiniteLoop ?? niriInfiniteLoop
        )
    }

    func dwindleSettings(for monitorName: String) -> MonitorDwindleSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorDwindleSettings)
    }

    func updateDwindleSettings(_ settings: MonitorDwindleSettings) {
        MonitorSettingsStore.update(settings, in: &monitorDwindleSettings)
    }

    func removeDwindleSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorDwindleSettings)
    }

    func resolvedDwindleSettings(for monitorName: String) -> ResolvedDwindleSettings {
        let override = dwindleSettings(for: monitorName)
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

    static let defaultColumnWidthPresets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]

    static func validatedPresets(_ presets: [Double]) -> [Double] {
        var result: [Double] = []
        for value in presets.map({ min(1.0, max(0.05, $0)) }).sorted() {
            if let last = result.last, abs(last - value) < 0.01 {
                continue
            }
            result.append(value)
        }
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

    private func saveNiriColumnWidthPresets() {
        guard let data = try? JSONEncoder().encode(niriColumnWidthPresets) else { return }
        defaults.set(data, forKey: Keys.niriColumnWidthPresets)
    }
}

private enum Keys {
    static let hotkeysEnabled = "settings.hotkeysEnabled"
    static let focusFollowsMouse = "settings.focusFollowsMouse"
    static let moveMouseToFocusedWindow = "settings.moveMouseToFocusedWindow"
    static let focusFollowsWindowToMonitor = "settings.focusFollowsWindowToMonitor"
    static let mouseWarpEnabled = "settings.mouseWarp.enabled"
    static let mouseWarpMonitorOrder = "settings.mouseWarp.monitorOrder"
    static let niriColumnWidthPresets = "settings.niriColumnWidthPresets"
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

    static let persistentWorkspaces = "settings.persistentWorkspaces"
    static let workspaceAssignments = "settings.workspaceAssignments"
    static let workspaceConfigurations = "settings.workspaceConfigurations"
    static let defaultLayoutType = "settings.defaultLayoutType"
    static let workspaceSettingsMigrated = "settings.workspaceSettingsMigrated"

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
    static let workspaceBarHeight = "settings.workspaceBar.height"
    static let workspaceBarBackgroundOpacity = "settings.workspaceBar.backgroundOpacity"
    static let workspaceBarXOffset = "settings.workspaceBar.xOffset"
    static let workspaceBarYOffset = "settings.workspaceBar.yOffset"
    static let monitorBarSettings = "settings.workspaceBar.monitorSettings"

    static let appRules = "settings.appRules"
    static let monitorOrientationSettings = "settings.monitorOrientationSettings"
    static let preventSleepEnabled = "settings.preventSleepEnabled"
    static let scrollGestureEnabled = "settings.scrollGestureEnabled"
    static let scrollSensitivity = "settings.scrollSensitivity"
    static let scrollModifierKey = "settings.scrollModifierKey"
    static let gestureFingerCount = "settings.gestureFingerCount"
    static let gestureInvertDirection = "settings.gestureInvertDirection"

    static let animationsEnabled = "settings.animationsEnabled"

    static let menuAnywhereNativeEnabled = "settings.menuAnywhere.nativeEnabled"
    static let menuAnywherePaletteEnabled = "settings.menuAnywhere.paletteEnabled"
    static let menuAnywherePosition = "settings.menuAnywhere.position"
    static let menuAnywhereShowShortcuts = "settings.menuAnywhere.showShortcuts"

    static let hiddenBarEnabled = "settings.hiddenBar.enabled"
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
}

