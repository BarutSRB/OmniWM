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

    var gapSize: Double {
        didSet { defaults.set(gapSize, forKey: Keys.gapSize) }
    }

    var fullscreenIgnoresGaps: Bool {
        didSet { defaults.set(fullscreenIgnoresGaps, forKey: Keys.fullscreenIgnoresGaps) }
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

    var workspaceBarWindowLevel: String {
        didSet { defaults.set(workspaceBarWindowLevel, forKey: Keys.workspaceBarWindowLevel) }
    }

    var workspaceBarPosition: String {
        didSet { defaults.set(workspaceBarPosition, forKey: Keys.workspaceBarPosition) }
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
        didSet { saveMonitorBarSettings() }
    }

    var appRules: [AppRule] {
        didSet { saveAppRules() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkeysEnabled = defaults.object(forKey: Keys.hotkeysEnabled) as? Bool ?? true
        focusFollowsMouse = defaults.object(forKey: Keys.focusFollowsMouse) as? Bool ?? false
        moveMouseToFocusedWindow = defaults.object(forKey: Keys.moveMouseToFocusedWindow) as? Bool ?? false
        gapSize = defaults.object(forKey: Keys.gapSize) as? Double ?? 8
        fullscreenIgnoresGaps = defaults.object(forKey: Keys.fullscreenIgnoresGaps) as? Bool ?? true

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
        workspaceBarWindowLevel = defaults.string(forKey: Keys.workspaceBarWindowLevel) ?? "popup"
        workspaceBarPosition = defaults.string(forKey: Keys.workspaceBarPosition) ?? "overlappingMenuBar"
        workspaceBarNotchAware = defaults.object(forKey: Keys.workspaceBarNotchAware) as? Bool ?? false
        workspaceBarDeduplicateAppIcons = defaults
            .object(forKey: Keys.workspaceBarDeduplicateAppIcons) as? Bool ?? false
        workspaceBarHideEmptyWorkspaces = defaults
            .object(forKey: Keys.workspaceBarHideEmptyWorkspaces) as? Bool ?? false
        workspaceBarHeight = defaults.object(forKey: Keys.workspaceBarHeight) as? Double ?? 24.0
        workspaceBarBackgroundOpacity = defaults.object(forKey: Keys.workspaceBarBackgroundOpacity) as? Double ?? 0.1
        workspaceBarXOffset = defaults.object(forKey: Keys.workspaceBarXOffset) as? Double ?? 0.0
        workspaceBarYOffset = defaults.object(forKey: Keys.workspaceBarYOffset) as? Double ?? 0.0
        monitorBarSettings = Self.loadMonitorBarSettings(from: defaults)
        appRules = Self.loadAppRules(from: defaults)
    }

    private static func loadBindings(from defaults: UserDefaults) -> [HotkeyBinding] {
        guard let data = defaults.data(forKey: Keys.hotkeyBindings),
              let bindings = try? JSONDecoder().decode([HotkeyBinding].self, from: data)
        else {
            return DefaultHotkeyBindings.all()
        }

        return mergeWithDefaults(stored: bindings)
    }

    private static func mergeWithDefaults(stored: [HotkeyBinding]) -> [HotkeyBinding] {
        let storedIds = Set(stored.map(\.id))
        let defaults = DefaultHotkeyBindings.all()
        var result = stored

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

    private static func loadMonitorBarSettings(from defaults: UserDefaults) -> [MonitorBarSettings] {
        guard let data = defaults.data(forKey: Keys.monitorBarSettings),
              let settings = try? JSONDecoder().decode([MonitorBarSettings].self, from: data)
        else {
            return []
        }
        return settings
    }

    private func saveMonitorBarSettings() {
        guard let data = try? JSONEncoder().encode(monitorBarSettings) else { return }
        defaults.set(data, forKey: Keys.monitorBarSettings)
    }

    func barSettings(for monitorName: String) -> MonitorBarSettings? {
        monitorBarSettings.first { $0.monitorName == monitorName }
    }

    func getOrCreateBarSettings(for monitorName: String) -> MonitorBarSettings {
        if let existing = barSettings(for: monitorName) {
            return existing
        }
        let newSettings = MonitorBarSettings(monitorName: monitorName)
        monitorBarSettings.append(newSettings)
        return newSettings
    }

    func updateBarSettings(_ settings: MonitorBarSettings) {
        if let index = monitorBarSettings.firstIndex(where: { $0.monitorName == settings.monitorName }) {
            monitorBarSettings[index] = settings
        } else {
            monitorBarSettings.append(settings)
        }
    }

    func removeBarSettings(for monitorName: String) {
        monitorBarSettings.removeAll { $0.monitorName == monitorName }
    }

    func resolvedBarSettings(for monitorName: String) -> ResolvedBarSettings {
        let override = barSettings(for: monitorName)

        return ResolvedBarSettings(
            enabled: override?.enabled ?? workspaceBarEnabled,
            showLabels: override?.showLabels ?? workspaceBarShowLabels,
            deduplicateAppIcons: override?.deduplicateAppIcons ?? workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: override?.hideEmptyWorkspaces ?? workspaceBarHideEmptyWorkspaces,
            notchAware: override?.notchAware ?? workspaceBarNotchAware,
            position: WorkspaceBarPosition(rawValue: override?.position ?? workspaceBarPosition) ?? .overlappingMenuBar,
            windowLevel: WorkspaceBarWindowLevel(rawValue: override?.windowLevel ?? workspaceBarWindowLevel) ?? .popup,
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
}

private enum Keys {
    static let hotkeysEnabled = "settings.hotkeysEnabled"
    static let focusFollowsMouse = "settings.focusFollowsMouse"
    static let moveMouseToFocusedWindow = "settings.moveMouseToFocusedWindow"
    static let gapSize = "settings.gapSize"
    static let fullscreenIgnoresGaps = "settings.fullscreenIgnoresGaps"

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
}
