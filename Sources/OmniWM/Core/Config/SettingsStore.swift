// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import OmniWMIPC

@MainActor @Observable
final class SettingsStore {
    nonisolated private static let defaultExport = SettingsExport.defaults()

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
        didSet {
            bumpMouseWarpSettingsGeneration()
            scheduleSave()
        }
    }

    var mouseWarpAxis = MouseWarpAxis(rawValue: SettingsStore.defaultExport.mouseWarpAxis ?? "") ?? .horizontal {
        didSet {
            bumpMouseWarpSettingsGeneration()
            scheduleSave()
        }
    }

    var niriColumnWidthPresets = SettingsStore.validatedPresets(
        SettingsStore.defaultExport.niriColumnWidthPresets ?? BuiltInSettingsDefaults.niriColumnWidthPresets
    ) {
        didSet { scheduleSave() }
    }

    var niriDefaultColumnWidth = SettingsStore.validatedDefaultColumnWidth(SettingsStore.defaultExport.niriDefaultColumnWidth) {
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

    var niriCenterFocusedColumn = CenterFocusedColumn(rawValue: SettingsStore.defaultExport.niriCenterFocusedColumn) ?? .never {
        didSet { scheduleSave() }
    }

    var niriAlwaysCenterSingleColumn = SettingsStore.defaultExport.niriAlwaysCenterSingleColumn {
        didSet { scheduleSave() }
    }

    var niriSingleWindowAspectRatio = SingleWindowAspectRatio(
        rawValue: SettingsStore.defaultExport.niriSingleWindowAspectRatio
    ) ?? .ratio4x3 {
        didSet { scheduleSave() }
    }

    var workspaceConfigurations = SettingsStore.normalizedWorkspaceConfigurations(SettingsStore.defaultExport.workspaceConfigurations) {
        didSet { scheduleSave() }
    }

    var defaultLayoutType = LayoutType(rawValue: SettingsStore.defaultExport.defaultLayoutType) ?? .niri {
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

    var workspaceBarWindowLevel = WorkspaceBarWindowLevel(rawValue: SettingsStore.defaultExport.workspaceBarWindowLevel) ?? .popup {
        didSet { scheduleSave() }
    }

    var workspaceBarPosition = WorkspaceBarPosition(rawValue: SettingsStore.defaultExport.workspaceBarPosition)
        ?? .overlappingMenuBar {
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

    var workspaceBarAccentColorRed = SettingsStore.defaultExport.workspaceBarAccentColorRed {
        didSet { scheduleSave() }
    }

    var workspaceBarAccentColorGreen = SettingsStore.defaultExport.workspaceBarAccentColorGreen {
        didSet { scheduleSave() }
    }

    var workspaceBarAccentColorBlue = SettingsStore.defaultExport.workspaceBarAccentColorBlue {
        didSet { scheduleSave() }
    }

    var workspaceBarAccentColorAlpha = SettingsStore.defaultExport.workspaceBarAccentColorAlpha {
        didSet { scheduleSave() }
    }

    var workspaceBarTextColorRed = SettingsStore.defaultExport.workspaceBarTextColorRed {
        didSet { scheduleSave() }
    }

    var workspaceBarTextColorGreen = SettingsStore.defaultExport.workspaceBarTextColorGreen {
        didSet { scheduleSave() }
    }

    var workspaceBarTextColorBlue = SettingsStore.defaultExport.workspaceBarTextColorBlue {
        didSet { scheduleSave() }
    }

    var workspaceBarTextColorAlpha = SettingsStore.defaultExport.workspaceBarTextColorAlpha {
        didSet { scheduleSave() }
    }

    var workspaceBarLabelFontSize = SettingsStore.normalizedWorkspaceBarLabelFontSize(SettingsStore.defaultExport.workspaceBarLabelFontSize) {
        didSet {
            let normalized = SettingsStore.normalizedWorkspaceBarLabelFontSize(workspaceBarLabelFontSize)
            if normalized != workspaceBarLabelFontSize {
                workspaceBarLabelFontSize = normalized
                return
            }
            scheduleSave()
        }
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
            scheduleSave()
            guard oldValue != ipcEnabled else { return }
            onIPCEnabledChanged?(ipcEnabled)
        }
    }

    var scrollGestureEnabled = SettingsStore.defaultExport.scrollGestureEnabled {
        didSet { scheduleSave() }
    }

    var scrollSensitivity = SettingsStore.defaultExport.scrollSensitivity {
        didSet { scheduleSave() }
    }

    var scrollModifierKey = ScrollModifierKey(rawValue: SettingsStore.defaultExport.scrollModifierKey) ?? .optionShift {
        didSet { scheduleSave() }
    }

    var gestureFingerCount = GestureFingerCount(rawValue: SettingsStore.defaultExport.gestureFingerCount) ?? .three {
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

    var commandPaletteLastMode = CommandPaletteMode(rawValue: SettingsStore.defaultExport.commandPaletteLastMode) ?? .windows {
        didSet { scheduleSave() }
    }

    var animationsEnabled = SettingsStore.defaultExport.animationsEnabled {
        didSet { scheduleSave() }
    }

    var hiddenBarIsCollapsed = SettingsStore.defaultExport.hiddenBarIsCollapsed {
        didSet { scheduleSave() }
    }

    var quakeTerminalEnabled = SettingsStore.defaultExport.quakeTerminalEnabled {
        didSet { scheduleSave() }
    }

    var quakeTerminalPosition = QuakeTerminalPosition(rawValue: SettingsStore.defaultExport.quakeTerminalPosition) ?? .center {
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

    private var quakeTerminalCustomFrameX: Double? {
        didSet { scheduleSave() }
    }

    private var quakeTerminalCustomFrameY: Double? {
        didSet { scheduleSave() }
    }

    private var quakeTerminalCustomFrameWidth: Double? {
        didSet { scheduleSave() }
    }

    private var quakeTerminalCustomFrameHeight: Double? {
        didSet { scheduleSave() }
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

    var appearanceMode = AppearanceMode(rawValue: SettingsStore.defaultExport.appearanceMode) ?? .dark {
        didSet { scheduleSave() }
    }

    var settingsFileURL: URL {
        persistence.fileURL
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

    func flushNow() {
        if autosaveEnabled {
            persistence.flushNow()
        } else {
            persistence.save(toExport())
        }
    }

    func loadPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        runtimeState.windowRestoreCatalog ?? .empty
    }

    func savePersistedWindowRestoreCatalog(_ catalog: PersistedWindowRestoreCatalog) {
        runtimeState.windowRestoreCatalog = catalog.entries.isEmpty ? nil : catalog
    }

    func resetQuakeTerminalCustomFrame() {
        quakeTerminalUseCustomFrame = false
        quakeTerminalCustomFrame = nil
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

    func rebindMonitorReferences(to monitors: [Monitor]) {
        let reboundWorkspaceConfigurations = workspaceConfigurations.map { config in
            guard case let .specificDisplay(output) = config.monitorAssignment,
                  let rebound = output.rebound(in: monitors)
            else {
                return config
            }

            var updated = config
            updated.monitorAssignment = .specificDisplay(rebound)
            return updated
        }
        if reboundWorkspaceConfigurations != workspaceConfigurations {
            workspaceConfigurations = reboundWorkspaceConfigurations
        }

        let updatedMouseWarpMonitorOrder = reboundMouseWarpMonitorOrder(
            mouseWarpMonitorOrder,
            to: monitors
        )
        if updatedMouseWarpMonitorOrder != mouseWarpMonitorOrder {
            mouseWarpMonitorOrder = updatedMouseWarpMonitorOrder
        }

        rebindMonitorSettings(\.monitorBarSettings, to: monitors)
        rebindMonitorSettings(\.monitorOrientationSettings, to: monitors)
        rebindMonitorSettings(\.monitorNiriSettings, to: monitors)
        rebindMonitorSettings(\.monitorDwindleSettings, to: monitors)
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

    private struct MouseWarpOrderingCacheEntry {
        let sortedMonitors: [Monitor]
        let orderedMonitorIds: [Monitor.ID]
    }

    private struct MouseWarpOrderingCacheKey: Hashable {
        let settingsGeneration: UInt64
        let monitorsGeneration: UInt64
        let axis: MouseWarpAxis
    }

    private var mouseWarpOrderingCache: [MouseWarpOrderingCacheKey: MouseWarpOrderingCacheEntry] = [:]
    private var mouseWarpSettingsGeneration: UInt64 = 0
    private var mouseWarpMonitorsGeneration: UInt64 = 0

    private func bumpMouseWarpSettingsGeneration() {
        mouseWarpSettingsGeneration &+= 1
        mouseWarpOrderingCache.removeAll(keepingCapacity: true)
    }

    func bumpMouseWarpMonitorsGeneration() {
        mouseWarpMonitorsGeneration &+= 1
        mouseWarpOrderingCache.removeAll(keepingCapacity: true)
    }

    func effectiveMouseWarpMonitorOrder(for monitors: [Monitor], axis: MouseWarpAxis? = nil) -> [Monitor.ID] {
        cachedMouseWarpOrdering(for: monitors, axis: axis).orderedMonitorIds
    }

    func sortedMouseWarpMonitors(for monitors: [Monitor], axis: MouseWarpAxis? = nil) -> [Monitor] {
        cachedMouseWarpOrdering(for: monitors, axis: axis).sortedMonitors
    }

    private func cachedMouseWarpOrdering(
        for monitors: [Monitor],
        axis: MouseWarpAxis?
    ) -> MouseWarpOrderingCacheEntry {
        let resolvedAxis = axis ?? mouseWarpAxis
        let key = MouseWarpOrderingCacheKey(
            settingsGeneration: mouseWarpSettingsGeneration,
            monitorsGeneration: mouseWarpMonitorsGeneration,
            axis: resolvedAxis
        )
        if let cached = mouseWarpOrderingCache[key] {
            return cached
        }
        let entry = computeMouseWarpOrdering(
            for: monitors,
            storedOrder: mouseWarpMonitorOrder,
            axis: resolvedAxis
        )
        mouseWarpOrderingCache[key] = entry
        return entry
    }

    private func effectiveMouseWarpMonitorOrder(
        for monitors: [Monitor],
        storedOrder: [OutputId],
        axis: MouseWarpAxis? = nil
    ) -> [Monitor.ID] {
        computeMouseWarpOrdering(
            for: monitors,
            storedOrder: storedOrder,
            axis: axis ?? mouseWarpAxis
        ).orderedMonitorIds
    }

    private func computeMouseWarpOrdering(
        for monitors: [Monitor],
        storedOrder: [OutputId],
        axis: MouseWarpAxis
    ) -> MouseWarpOrderingCacheEntry {
        let sortedMonitors = axis.sortedMonitors(monitors)
        guard !sortedMonitors.isEmpty else {
            return MouseWarpOrderingCacheEntry(sortedMonitors: [], orderedMonitorIds: [])
        }

        let resolution = OutputId.resolveOrderedPreservingUnresolved(
            storedOrder,
            in: sortedMonitors
        )
        var orderedMonitorIds = resolution.resolvedMonitorIds

        for monitor in sortedMonitors where !resolution.claimedMonitorIds.contains(monitor.id) {
            orderedMonitorIds.append(monitor.id)
        }

        return MouseWarpOrderingCacheEntry(
            sortedMonitors: sortedMonitors,
            orderedMonitorIds: orderedMonitorIds
        )
    }

    @discardableResult
    func persistEffectiveMouseWarpMonitorOrder(for monitors: [Monitor], axis: MouseWarpAxis? = nil) -> [Monitor.ID] {
        let warpAxis = axis ?? mouseWarpAxis
        let persisted = reboundMouseWarpMonitorOrder(mouseWarpMonitorOrder, to: monitors, axis: warpAxis)
        return effectiveMouseWarpMonitorOrder(for: monitors, storedOrder: persisted, axis: warpAxis)
    }

    func commitMouseWarpMonitorOrder(
        orderedMonitorIds: [Monitor.ID],
        connectedMonitors: [Monitor],
        axis: MouseWarpAxis? = nil
    ) {
        let warpAxis = axis ?? mouseWarpAxis
        let sortedMonitors = warpAxis.sortedMonitors(connectedMonitors)
        let outputsById = Dictionary(uniqueKeysWithValues: sortedMonitors.map { ($0.id, OutputId(from: $0)) })

        var seenMonitorIds: Set<Monitor.ID> = []
        var reorderedLiveOutputs: [OutputId] = []
        for monitorId in orderedMonitorIds {
            guard seenMonitorIds.insert(monitorId).inserted,
                  let output = outputsById[monitorId]
            else {
                continue
            }
            reorderedLiveOutputs.append(output)
        }
        for monitor in sortedMonitors where seenMonitorIds.insert(monitor.id).inserted {
            reorderedLiveOutputs.append(OutputId(from: monitor))
        }

        let resolution = OutputId.resolveOrderedPreservingUnresolved(
            mouseWarpMonitorOrder,
            in: sortedMonitors
        )
        var reorderedIterator = reorderedLiveOutputs.makeIterator()
        var persisted: [OutputId] = []
        persisted.reserveCapacity(max(mouseWarpMonitorOrder.count, reorderedLiveOutputs.count))

        for (index, output) in mouseWarpMonitorOrder.enumerated() {
            if resolution.resolvedSlotIndices.contains(index) {
                if let reorderedOutput = reorderedIterator.next() {
                    persisted.append(reorderedOutput)
                }
            } else {
                persisted.append(output)
            }
        }

        while let reorderedOutput = reorderedIterator.next() {
            persisted.append(reorderedOutput)
        }

        if mouseWarpMonitorOrder != persisted {
            mouseWarpMonitorOrder = persisted
        }
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
           let orientation = override.orientation {
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

    nonisolated static let defaultColumnWidthPresets: [Double] = BuiltInSettingsDefaults.niriColumnWidthPresets
    nonisolated static let workspaceBarLabelFontSizeRange: ClosedRange<Double> = 10 ... 16

    nonisolated static func validatedPresets(_ presets: [Double]) -> [Double] {
        let result = presets.map { min(1.0, max(0.05, $0)) }
        if result.count < 2 {
            return defaultColumnWidthPresets
        }
        return result
    }

    nonisolated static func validatedDefaultColumnWidth(_ width: Double?) -> Double? {
        guard let width else { return nil }
        return min(1.0, max(0.05, width))
    }

    nonisolated static func normalizedWorkspaceBarLabelFontSize(_ size: Double) -> Double {
        min(workspaceBarLabelFontSizeRange.upperBound, max(workspaceBarLabelFontSizeRange.lowerBound, size))
    }

    func toExport() -> SettingsExport {
        SettingsExport(
            version: SettingsFilePersistence.configVersion,
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
            workspaceBarAccentColorRed: workspaceBarAccentColorRed,
            workspaceBarAccentColorGreen: workspaceBarAccentColorGreen,
            workspaceBarAccentColorBlue: workspaceBarAccentColorBlue,
            workspaceBarAccentColorAlpha: workspaceBarAccentColorAlpha,
            workspaceBarTextColorRed: workspaceBarTextColorRed,
            workspaceBarTextColorGreen: workspaceBarTextColorGreen,
            workspaceBarTextColorBlue: workspaceBarTextColorBlue,
            workspaceBarTextColorAlpha: workspaceBarTextColorAlpha,
            workspaceBarLabelFontSize: workspaceBarLabelFontSize,
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
    }

    func applyExport(_ export: SettingsExport, monitors: [Monitor]) {
        let baseline = SettingsStore.defaultExport
        let importedMouseWarpAxis = MouseWarpAxis(rawValue: export.mouseWarpAxis ?? baseline.mouseWarpAxis ?? "") ?? .horizontal

        isApplyingExport = true
        defer { isApplyingExport = false }

        hotkeysEnabled = export.hotkeysEnabled
        focusFollowsMouse = export.focusFollowsMouse
        moveMouseToFocusedWindow = export.moveMouseToFocusedWindow
        focusFollowsWindowToMonitor = export.focusFollowsWindowToMonitor
        mouseWarpMonitorOrder = reboundMouseWarpMonitorOrder(
            export.mouseWarpMonitorOrder,
            to: monitors,
            axis: importedMouseWarpAxis
        )
        mouseWarpAxis = importedMouseWarpAxis
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
        niriColumnWidthPresets = SettingsStore.validatedPresets(
            export.niriColumnWidthPresets ?? baseline.niriColumnWidthPresets ?? SettingsStore.defaultColumnWidthPresets
        )
        niriDefaultColumnWidth = SettingsStore.validatedDefaultColumnWidth(export.niriDefaultColumnWidth)

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
        workspaceBarAccentColorRed = export.workspaceBarAccentColorRed
        workspaceBarAccentColorGreen = export.workspaceBarAccentColorGreen
        workspaceBarAccentColorBlue = export.workspaceBarAccentColorBlue
        workspaceBarAccentColorAlpha = export.workspaceBarAccentColorAlpha
        workspaceBarTextColorRed = export.workspaceBarTextColorRed
        workspaceBarTextColorGreen = export.workspaceBarTextColorGreen
        workspaceBarTextColorBlue = export.workspaceBarTextColorBlue
        workspaceBarTextColorAlpha = export.workspaceBarTextColorAlpha
        workspaceBarLabelFontSize = SettingsStore.normalizedWorkspaceBarLabelFontSize(export.workspaceBarLabelFontSize)
        monitorBarSettings = Self.reboundMonitorBarSettings(export.monitorBarSettings, monitors: monitors)

        appRules = export.appRules
        monitorOrientationSettings = Self.reboundMonitorOrientationSettings(
            export.monitorOrientationSettings,
            monitors: monitors
        )
        monitorNiriSettings = Self.reboundMonitorNiriSettings(export.monitorNiriSettings, monitors: monitors)

        dwindleSmartSplit = export.dwindleSmartSplit
        dwindleDefaultSplitRatio = export.dwindleDefaultSplitRatio
        dwindleSplitWidthMultiplier = export.dwindleSplitWidthMultiplier
        dwindleSingleWindowAspectRatio = DwindleSingleWindowAspectRatio(
            rawValue: export.dwindleSingleWindowAspectRatio
        ) ?? .ratio4x3
        dwindleUseGlobalGaps = export.dwindleUseGlobalGaps
        dwindleMoveToRootStable = export.dwindleMoveToRootStable
        monitorDwindleSettings = Self.reboundMonitorDwindleSettings(export.monitorDwindleSettings, monitors: monitors)

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
        quakeTerminalUseCustomFrame = export.quakeTerminalUseCustomFrame
        quakeTerminalCustomFrame = export.quakeTerminalCustomFrame?.frame

        appearanceMode = AppearanceMode(rawValue: export.appearanceMode) ?? .automatic
    }

    private func handleExternalReload(_ export: SettingsExport) {
        applyExport(export, monitors: Monitor.current())
        onExternalSettingsReloaded?()
    }

    private func scheduleSave() {
        guard autosaveEnabled, !isApplyingExport else { return }
        persistence.scheduleSave(toExport())
    }

    private func rebindMonitorSettings<T: MonitorSettingsType>(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, [T]>,
        to monitors: [Monitor]
    ) {
        let currentSettings = self[keyPath: keyPath]
        let reboundSettings = MonitorSettingsStore.rebound(currentSettings, to: monitors)
        if reboundSettings != currentSettings {
            self[keyPath: keyPath] = reboundSettings
        }
    }

    nonisolated private static func normalizedWorkspaceConfigurations(_ configs: [WorkspaceConfiguration]) -> [WorkspaceConfiguration] {
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

    private func resolvedBarSettings(override: MonitorBarSettings?) -> ResolvedBarSettings {
        ResolvedBarSettings(
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
            yOffset: override?.yOffset ?? workspaceBarYOffset,
            accentColorRed: workspaceBarAccentColorRed,
            accentColorGreen: workspaceBarAccentColorGreen,
            accentColorBlue: workspaceBarAccentColorBlue,
            accentColorAlpha: workspaceBarAccentColorAlpha,
            textColorRed: workspaceBarTextColorRed,
            textColorGreen: workspaceBarTextColorGreen,
            textColorBlue: workspaceBarTextColorBlue,
            textColorAlpha: workspaceBarTextColorAlpha,
            labelFontSize: workspaceBarLabelFontSize
        )
    }

    private func resolvedNiriSettings(override: MonitorNiriSettings?) -> ResolvedNiriSettings {
        ResolvedNiriSettings(
            maxVisibleColumns: override?.maxVisibleColumns ?? niriMaxVisibleColumns,
            maxWindowsPerColumn: override?.maxWindowsPerColumn ?? niriMaxWindowsPerColumn,
            centerFocusedColumn: override?.centerFocusedColumn ?? niriCenterFocusedColumn,
            alwaysCenterSingleColumn: override?.alwaysCenterSingleColumn ?? niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: override?.singleWindowAspectRatio ?? niriSingleWindowAspectRatio,
            infiniteLoop: override?.infiniteLoop ?? niriInfiniteLoop
        )
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

    private static func normalizedImportedWorkspaceConfigurations(
        _ configs: [WorkspaceConfiguration],
        monitors: [Monitor]
    ) -> [WorkspaceConfiguration] {
        var seen: Set<String> = []
        let rebound = configs.map { config in
            guard case let .specificDisplay(output) = config.monitorAssignment,
                  let reboundOutput = output.rebound(in: monitors)
            else {
                return config
            }

            var updated = config
            updated.monitorAssignment = .specificDisplay(reboundOutput)
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

    private func reboundMouseWarpMonitorOrder(
        _ storedOrder: [OutputId],
        to monitors: [Monitor],
        axis: MouseWarpAxis? = nil
    ) -> [OutputId] {
        let sortedMonitors = (axis ?? mouseWarpAxis).sortedMonitors(monitors)
        guard !sortedMonitors.isEmpty else { return storedOrder }

        let resolution = OutputId.resolveOrderedPreservingUnresolved(
            storedOrder,
            in: sortedMonitors
        )
        var reboundOrder = resolution.reboundOutputs

        for monitor in sortedMonitors where !resolution.claimedMonitorIds.contains(monitor.id) {
            reboundOrder.append(OutputId(from: monitor))
        }

        return reboundOrder
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
           monitors.contains(where: { $0.displayId == displayId }) {
            return displayId
        }

        let matches = monitors.filter { $0.name.caseInsensitiveCompare(monitorName) == .orderedSame }
        guard matches.count == 1 else { return nil }
        return matches[0].displayId
    }
}
