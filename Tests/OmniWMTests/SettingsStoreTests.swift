import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation
@testable import OmniWM
import Testing

private func makeTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeSettingsTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func makePersistedRestoreCatalogFixture(
    workspaceName: String = "1",
    monitor: Monitor = makeSettingsTestMonitor(displayId: 77, name: "Studio Display")
) -> PersistedWindowRestoreCatalog {
    let metadata = ManagedReplacementMetadata(
        bundleId: "com.example.editor",
        workspaceId: UUID(),
        mode: .floating,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: "Sprint Notes",
        windowLevel: 0,
        parentWindowId: nil,
        frame: nil
    )
    let key = PersistedWindowRestoreKey(metadata: metadata)!
    return PersistedWindowRestoreCatalog(
        entries: [
            PersistedWindowRestoreEntry(
                key: key,
                restoreIntent: PersistedRestoreIntent(
                    workspaceName: workspaceName,
                    topologyProfile: TopologyProfile(monitors: [monitor]),
                    preferredMonitor: DisplayFingerprint(monitor: monitor),
                    floatingFrame: CGRect(x: 120, y: 140, width: 900, height: 600),
                    normalizedFloatingOrigin: CGPoint(x: 0.25, y: 0.35),
                    restoreToFloating: true,
                    rescueEligible: true
                )
            )
        ]
    )
}

private func writeSettingsExport(
    _ export: SettingsExport,
    to url: URL
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try SettingsTOMLCodec.encode(export).write(to: url, options: .atomic)
}

private func writeSettingsExportInPlace(
    _ export: SettingsExport,
    to url: URL
) throws {
    let data = try SettingsTOMLCodec.encode(export)
    let handle = try FileHandle(forWritingTo: url)
    defer {
        try? handle.close()
    }

    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
}

private func atomicallyReplaceSettingsDataForTests(
    _ data: Data,
    at url: URL,
    preservingModificationDate modificationDate: Date
) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let tempURL = directory.appendingPathComponent(".settings.toml.\(UUID().uuidString).tmp", isDirectory: false)
    try data.write(to: tempURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: tempURL.path)

    let result = tempURL.withUnsafeFileSystemRepresentation { sourcePath -> CInt in
        guard let sourcePath else { return -1 }
        return url.withUnsafeFileSystemRepresentation { destinationPath -> CInt in
            guard let destinationPath else { return -1 }
            return Darwin.rename(sourcePath, destinationPath)
        }
    }

    if result != 0 {
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct MonitorSettingsStoreTests {
    @Test func getReturnsNilForUnknownMonitor() {
        let settings = [MonitorNiriSettings(monitorName: "Monitor A")]
        let result = MonitorSettingsStore.get(for: "Monitor B", in: settings)
        #expect(result == nil)
    }

    @Test func updateReplacesExistingAtSameIndex() {
        var settings = [
            MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 2),
            MonitorNiriSettings(monitorName: "B", maxVisibleColumns: 3)
        ]
        let updated = MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 5)
        MonitorSettingsStore.update(updated, in: &settings)
        #expect(settings.count == 2)
        #expect(settings[0].monitorName == "A")
        #expect(settings[0].maxVisibleColumns == 5)
        #expect(settings[1].monitorName == "B")
    }

    @Test func updateAppendsWhenNotFound() {
        var settings = [MonitorNiriSettings(monitorName: "A")]
        let newItem = MonitorNiriSettings(monitorName: "B", maxVisibleColumns: 4)
        MonitorSettingsStore.update(newItem, in: &settings)
        #expect(settings.count == 2)
        #expect(settings[1].monitorName == "B")
        #expect(settings[1].maxVisibleColumns == 4)
    }

    @Test func removeDeletesAllMatches() {
        var settings = [
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "B")
        ]
        MonitorSettingsStore.remove(for: "A", from: &settings)
        #expect(settings.count == 1)
        #expect(settings[0].monitorName == "B")
    }

    @Test func monitorLookupPrefersDisplayIdOverNameFallback() {
        let monitor = makeSettingsTestMonitor(displayId: 42, name: "Studio Display")
        let settings = [
            MonitorNiriSettings(monitorName: "Studio Display", maxVisibleColumns: 1),
            MonitorNiriSettings(monitorName: "Studio Display", monitorDisplayId: 42, maxVisibleColumns: 3)
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.maxVisibleColumns == 3)
    }

    @Test func monitorLookupFallsBackToLegacyNameWhenDisplayIdMissing() {
        let monitor = makeSettingsTestMonitor(displayId: 99, name: "Legacy")
        let settings = [
            MonitorNiriSettings(monitorName: "Legacy", maxVisibleColumns: 2)
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.maxVisibleColumns == 2)
    }

    @Test func updateMigratesLegacyNameEntryToDisplayIdEntry() {
        var settings = [
            MonitorNiriSettings(monitorName: "Studio Display", maxVisibleColumns: 1)
        ]

        let updated = MonitorNiriSettings(
            monitorName: "Studio Display",
            monitorDisplayId: 77,
            maxVisibleColumns: 4
        )
        MonitorSettingsStore.update(updated, in: &settings)

        #expect(settings.count == 1)
        #expect(settings[0].monitorDisplayId == 77)
        #expect(settings[0].maxVisibleColumns == 4)
    }
}

@MainActor struct PersistedWindowRestoreCatalogSettingsTests {
    @Test func persistedRestoreCatalogRoundTripsThroughRuntimeStateStore() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let catalog = makePersistedRestoreCatalogFixture()

        settings.savePersistedWindowRestoreCatalog(catalog)

        #expect(settings.loadPersistedWindowRestoreCatalog() == catalog)

        // Verify the catalog is persisted in the private runtime-state sidecar by
        // constructing a fresh RuntimeStateStore against the same temp directory.
        // This proves the data path is private runtime state, not UserDefaults.
        settings.flushNow()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let fresh = RuntimeStateStore(directory: directory)
        #expect(fresh.windowRestoreCatalog == catalog)
    }

    @Test func persistedRestoreCatalogIsExcludedFromCanonicalSettingsFile() throws {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.hotkeysEnabled = false
        settings.savePersistedWindowRestoreCatalog(makePersistedRestoreCatalogFixture())
        settings.flushNow()

        let rawData = try Data(contentsOf: settings.settingsFileURL)
        let rawText = try #require(String(data: rawData, encoding: .utf8))
        let decoded = try SettingsTOMLCodec.decode(rawData)
        #expect(decoded.hotkeysEnabled == false)
        #expect(rawText.localizedCaseInsensitiveContains("restoreCatalog") == false)
    }
}

struct SettingsExportTests {
    @Test func defaultsReflectPromotedBuiltInValues() {
        let defaults = SettingsExport.defaults()

        #expect(defaults.mouseWarpAxis == MouseWarpAxis.horizontal.rawValue)
        #expect(defaults.mouseWarpMargin == 1)
        #expect(defaults.niriColumnWidthPresets == BuiltInSettingsDefaults.niriColumnWidthPresets)
        #expect(defaults.gapSize == 16)
        #expect(defaults.outerGapLeft == 0)
        #expect(defaults.outerGapRight == 0)
        #expect(defaults.outerGapTop == 0)
        #expect(defaults.outerGapBottom == 0)
        #expect(defaults.niriMaxWindowsPerColumn == 10)
        #expect(defaults.niriAlwaysCenterSingleColumn == false)
        #expect(defaults.niriSingleWindowAspectRatio == SingleWindowAspectRatio.none.rawValue)
        #expect(defaults.niriDefaultColumnWidth == 0.5)
        #expect(defaults.workspaceConfigurations == BuiltInSettingsDefaults.workspaceConfigurations)
        #expect(defaults.bordersEnabled == true)
        #expect(defaults.borderWidth == 5.0)
        #expect(defaults.borderColorRed == 0.084585202284378935)
        #expect(defaults.borderColorGreen == 1.0)
        #expect(defaults.borderColorBlue == 0.97930003794467602)
        #expect(defaults.hotkeyBindings == HotkeyBindingRegistry.defaults())
        #expect(defaults.workspaceBarEnabled == true)
        #expect(defaults.workspaceBarShowFloatingWindows == false)
        #expect(defaults.workspaceBarNotchAware == true)
        #expect(defaults.workspaceBarReserveLayoutSpace == false)
        #expect(defaults.appRules == BuiltInSettingsDefaults.appRules)
        #expect(defaults.preventSleepEnabled == false)
        #expect(defaults.updateChecksEnabled == true)
        #expect(defaults.ipcEnabled == false)
        #expect(defaults.scrollSensitivity == 5.0)
        #expect(defaults.statusBarShowWorkspaceName == false)
        #expect(defaults.statusBarShowAppNames == false)
        #expect(defaults.statusBarUseWorkspaceId == false)
        #expect(defaults.clipboardHistoryEnabled == false)
        #expect(defaults.clipboardMaxItems == 200)
        #expect(defaults.clipboardMaxItemBytes == 8_388_608)
        #expect(defaults.clipboardMaxTotalBytes == 67_108_864)
        #expect(defaults.hiddenBarIsCollapsed == true)
        #expect(defaults.quakeTerminalEnabled == true)
        #expect(defaults.quakeTerminalPosition == QuakeTerminalPosition.center.rawValue)
        #expect(defaults.quakeTerminalWidthPercent == 50.0)
        #expect(defaults.quakeTerminalHeightPercent == 50.0)
        #expect(defaults.quakeTerminalAutoHide == false)
        #expect(defaults.quakeTerminalMonitorMode == QuakeTerminalMonitorMode.focusedWindow.rawValue)
        #expect(defaults.quakeTerminalUseCustomFrame == false)
        #expect(defaults.quakeTerminalCustomFrame == nil)
        #expect(defaults.appearanceMode == AppearanceMode.dark.rawValue)
    }
}

@MainActor struct NiriColumnWidthPresetPersistenceTests {
    @Test func validatedPresetsPreserveOrderAndDuplicatesWhileClamping() {
        let presets = SettingsStore.validatedPresets([0.85, 0.02, 0.85, 1.2])

        #expect(presets == [0.85, 0.05, 0.85, 1.0])
    }

    @Test func validatedPresetsFallbackToDefaultsWhenTooShort() {
        let presets = SettingsStore.validatedPresets([0.85])

        #expect(presets == SettingsStore.defaultColumnWidthPresets)
    }

    @Test func settingsStoreRoundTripsOrderedDuplicatePresets() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.niriColumnWidthPresets = [0.85, 0.5, 0.85, 1.0]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.niriColumnWidthPresets == [0.85, 0.5, 0.85, 1.0])
    }

    @Test func validatedDefaultColumnWidthClampsAndSupportsAuto() {
        #expect(SettingsStore.validatedDefaultColumnWidth(nil) == nil)
        #expect(SettingsStore.validatedDefaultColumnWidth(0.02) == 0.05)
        #expect(SettingsStore.validatedDefaultColumnWidth(1.2) == 1.0)
    }

    @Test func settingsStoreRoundTripsOptionalDefaultColumnWidth() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.niriDefaultColumnWidth = 0.85
        let reloadedCustom = SettingsStore(defaults: defaults)
        #expect(reloadedCustom.niriDefaultColumnWidth == 0.85)

        settings.niriDefaultColumnWidth = nil
        let reloadedAuto = SettingsStore(defaults: defaults)
        #expect(reloadedAuto.niriDefaultColumnWidth == nil)
    }
}

@MainActor struct WorkspaceBarSettingsResolutionTests {
    @Test func monitorOverrideCanEnableReservedLayoutSpaceIndependently() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Reservation Test")

        settings.workspaceBarReserveLayoutSpace = false
        settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                reserveLayoutSpace: true
            )
        )

        #expect(settings.resolvedBarSettings(for: monitor).reserveLayoutSpace == true)
    }

    @Test func monitorOverrideCanEnableFloatingWindowsIndependently() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Floating Test")

        settings.workspaceBarShowFloatingWindows = false
        settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                showFloatingWindows: true
            )
        )

        #expect(settings.resolvedBarSettings(for: monitor).showFloatingWindows == true)
    }
}

struct KeyBindingCodecTests {
    @Test func humanReadableBindingsRoundTripAsStrings() throws {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey) | UInt32(optionKey)
        )

        let output = try encodeSingleHotkeyBinding(binding)

        #expect(output.contains("binding = \"Control+Option+K\""))
    }

    @Test func keypadBindingsUseReadableStringsAndDistinctCompactBadges() throws {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_Keypad1),
            modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        )

        let output = try encodeSingleHotkeyBinding(binding)

        #expect(binding.displayString == "⌃⌥⌘KP1")
        #expect(binding.humanReadableString == "Control+Option+Command+Keypad 1")
        #expect(output.contains("binding = \"Control+Option+Command+Keypad 1\""))
    }

    @Test func keypadActionKeysUseCanonicalReadableNames() {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_KeypadEnter),
            modifiers: UInt32(cmdKey)
        )

        #expect(binding.displayString == "⌘KPEnter")
        #expect(binding.humanReadableString == "Command+Keypad Enter")
        #expect(KeySymbolMapper.fromHumanReadable("Command+Keypad Enter") == binding)
    }

    @Test func unknownKeyCodesFallBackToLegacyNumericEncoding() throws {
        let binding = KeyBinding(keyCode: 200, modifiers: UInt32(controlKey))

        let output = try encodeSingleHotkeyBinding(binding)

        #expect(output.contains("keyCode = 200"))
        #expect(output.contains("modifiers = \(UInt32(controlKey))"))
    }

    @Test func keypadDigitsRemainDistinctFromTopRowDigits() {
        let modifiers = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        let topRow = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers)
        let keypad = KeyBinding(keyCode: UInt32(kVK_ANSI_Keypad1), modifiers: modifiers)

        #expect(topRow != keypad)
        #expect(topRow.displayString == "⌃⌥⌘1")
        #expect(keypad.displayString == "⌃⌥⌘KP1")
        #expect(topRow.humanReadableString == "Control+Option+Command+1")
        #expect(keypad.humanReadableString == "Control+Option+Command+Keypad 1")
    }

    private func encodeSingleHotkeyBinding(_ binding: KeyBinding) throws -> String {
        var export = SettingsExport.defaults()
        let hotkey = try #require(HotkeyBindingRegistry.makeBinding(id: "openCommandPalette", binding: binding))
        export.hotkeyBindings = [hotkey]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        #expect(decoded.hotkeyBindings == [hotkey])

        return try #require(String(data: data, encoding: .utf8))
    }
}

struct HotkeySurfaceTests {
    @Test func moveIsTheOnlyDirectionalWindowCommandFamily() {
        let ids = Set(HotkeyBindingRegistry.defaults().map(\.id))

        #expect(ids.contains("move.left"))
        #expect(ids.contains("move.right"))
        #expect(ids.contains("move.up"))
        #expect(ids.contains("move.down"))
        #expect(!ids.contains("swap.left"))
        #expect(!ids.contains("consumeWindow.left"))
        #expect(!ids.contains("expelWindow.left"))
        #expect(ids.contains("openCommandPalette"))
        #expect(!ids.contains("openWindowFinder"))
        #expect(!ids.contains("openMenuPalette"))
        #expect(HotkeyCommand.move(.left).layoutCompatibility == .shared)
    }

    @Test func removedDirectionalMonitorBindingsAreAbsent() {
        let ids = Set(HotkeyBindingRegistry.defaults().map(\.id))

        #expect(!ids.contains("moveToMonitor.left"))
        #expect(!ids.contains("moveToMonitor.right"))
        #expect(!ids.contains("moveToMonitor.up"))
        #expect(!ids.contains("moveToMonitor.down"))
        #expect(!ids.contains("focusMonitor.left"))
        #expect(!ids.contains("focusMonitor.right"))
        #expect(!ids.contains("focusMonitor.up"))
        #expect(!ids.contains("focusMonitor.down"))
        #expect(!ids.contains("moveColumnToMonitor.left"))
        #expect(!ids.contains("moveColumnToMonitor.right"))
        #expect(!ids.contains("moveColumnToMonitor.up"))
        #expect(!ids.contains("moveColumnToMonitor.down"))
        #expect(!ids.contains("moveWorkspaceToMonitor.left"))
        #expect(!ids.contains("moveWorkspaceToMonitor.right"))
        #expect(!ids.contains("moveWorkspaceToMonitor.up"))
        #expect(!ids.contains("moveWorkspaceToMonitor.down"))
        #expect(!ids.contains("moveWorkspaceToMonitor.next"))
        #expect(!ids.contains("moveWorkspaceToMonitor.previous"))
        #expect(ids.contains("focusWindowTop"))
        #expect(ids.contains("focusWindowBottom"))
        #expect(!ids.contains("summonWorkspace.0"))
        #expect(!ids.contains("summonWorkspace.1"))
        #expect(!ids.contains("summonWorkspace.2"))
        #expect(!ids.contains("summonWorkspace.3"))
        #expect(!ids.contains("summonWorkspace.4"))
        #expect(!ids.contains("summonWorkspace.5"))
        #expect(!ids.contains("summonWorkspace.6"))
        #expect(!ids.contains("summonWorkspace.7"))
        #expect(!ids.contains("summonWorkspace.8"))
        #expect(ids.contains("focusMonitorNext"))
        #expect(ids.contains("focusMonitorLast"))
    }

    @Test func hotkeyBindingEncodesWithoutSerializedCommand() throws {
        var export = SettingsExport.defaults()
        let binding = HotkeyBinding(id: "move.left", command: .move(.left), binding: .unassigned)
        export.hotkeyBindings = [binding]
        let output = try #require(String(data: SettingsTOMLCodec.encode(export), encoding: .utf8))
        let decoded = try SettingsTOMLCodec.decode(Data(output.utf8))

        #expect(output.contains("id = \"move.left\""))
        #expect(output.contains("binding = \"Unassigned\""))
        #expect(output.contains("command = ") == false)
        #expect(decoded.hotkeyBindings == [binding])
    }
}

@MainActor struct CommandPaletteSettingsTests {
    @Test func commandPaletteLastModeDefaultsToWindowsAndPersistsClipboard() {
        let defaults = makeTestDefaults()

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.commandPaletteLastMode == .windows)

        settings.commandPaletteLastMode = .clipboard

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.commandPaletteLastMode == .clipboard)
    }

    @Test func menuStatusHelpersDoNotMentionSettings() {
        #expect(CommandPaletteController.menuModeAvailable(hasMenuFocusTarget: true) == true)
        #expect(CommandPaletteController.menuModeAvailable(hasMenuFocusTarget: false) == false)
        #expect(CommandPaletteController.availableMenuStatusText(for: "Safari") == "Searching menus in Safari")
        #expect(CommandPaletteController.availableMenuStatusText(for: nil) == "Searching menus in Current App")
        #expect(CommandPaletteController
            .unavailableMenuStatusText == "Open the palette while another app is frontmost to search its menus.")
    }
}

@MainActor struct SettingsStoreFileRoundTripTests {
    @Test func tomlSettingsFileRoundTripsNewlyCoveredPersistedState() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.focusFollowsWindowToMonitor = true
        settings.mouseWarpAxis = .vertical
        settings.updateChecksEnabled = false
        settings.statusBarShowWorkspaceName = true
        settings.statusBarShowAppNames = true
        settings.statusBarUseWorkspaceId = true
        settings.commandPaletteLastMode = .clipboard
        settings.clipboardHistoryEnabled = true
        settings.clipboardMaxItems = 33
        settings.clipboardMaxItemBytes = 4096
        settings.clipboardMaxTotalBytes = 8192
        settings.quakeTerminalEnabled = true
        settings.quakeTerminalPosition = .bottom
        settings.quakeTerminalWidthPercent = 80
        settings.quakeTerminalHeightPercent = 55
        settings.quakeTerminalAnimationDuration = 0.4
        settings.quakeTerminalAutoHide = false
        settings.quakeTerminalOpacity = 0.75
        settings.quakeTerminalMonitorMode = .focusedWindow
        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = CGRect(x: 10, y: 20, width: 1200, height: 700)
        settings.flushNow()

        let reloaded = SettingsStore(defaults: defaults)

        #expect(reloaded.focusFollowsWindowToMonitor == true)
        #expect(reloaded.mouseWarpAxis == .vertical)
        #expect(reloaded.updateChecksEnabled == false)
        #expect(reloaded.statusBarShowWorkspaceName == true)
        #expect(reloaded.statusBarShowAppNames == true)
        #expect(reloaded.statusBarUseWorkspaceId == true)
        #expect(reloaded.commandPaletteLastMode == .clipboard)
        #expect(reloaded.clipboardHistoryEnabled == true)
        #expect(reloaded.clipboardMaxItems == 33)
        #expect(reloaded.clipboardMaxItemBytes == 4096)
        #expect(reloaded.clipboardMaxTotalBytes == 8192)
        #expect(reloaded.quakeTerminalEnabled == true)
        #expect(reloaded.quakeTerminalPosition == .bottom)
        #expect(reloaded.quakeTerminalWidthPercent == 80)
        #expect(reloaded.quakeTerminalHeightPercent == 55)
        #expect(reloaded.quakeTerminalAnimationDuration == 0.4)
        #expect(reloaded.quakeTerminalAutoHide == false)
        #expect(reloaded.quakeTerminalOpacity == 0.75)
        #expect(reloaded.quakeTerminalMonitorMode == .focusedWindow)
        #expect(reloaded.quakeTerminalUseCustomFrame == true)
        #expect(reloaded.quakeTerminalCustomFrame == CGRect(x: 10, y: 20, width: 1200, height: 700))
    }

    @Test func tomlSettingsFileRoundTripsMonitorOverridesAndAppRules() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let barOverride = MonitorBarSettings(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            monitorName: "Studio Display",
            enabled: false,
            showLabels: false,
            showFloatingWindows: true,
            deduplicateAppIcons: true,
            hideEmptyWorkspaces: true,
            reserveLayoutSpace: true,
            notchAware: false,
            position: .belowMenuBar,
            windowLevel: .status,
            height: 32,
            backgroundOpacity: 0.35,
            xOffset: 12,
            yOffset: 6
        )
        let niriOverride = MonitorNiriSettings(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            monitorName: "Studio Display",
            maxVisibleColumns: 4,
            maxWindowsPerColumn: 2,
            centerFocusedColumn: .always,
            alwaysCenterSingleColumn: false,
            singleWindowAspectRatio: .ratio16x9,
            infiniteLoop: true
        )
        let dwindleOverride = MonitorDwindleSettings(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            monitorName: "Studio Display",
            smartSplit: true,
            defaultSplitRatio: 0.62,
            splitWidthMultiplier: 1.4,
            singleWindowAspectRatio: .ratio21x9,
            useGlobalGaps: false,
            innerGap: 5,
            outerGapTop: 7,
            outerGapBottom: 8,
            outerGapLeft: 9,
            outerGapRight: 10
        )
        let customRule = AppRule(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            bundleId: "com.example.Editor",
            appNameSubstring: "Editor",
            titleSubstring: "Draft",
            titleRegex: ".*Sprint.*",
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            layout: .float,
            assignToWorkspace: "4",
            minWidth: 900,
            minHeight: 700
        )

        settings.monitorBarSettings = [barOverride]
        settings.monitorNiriSettings = [niriOverride]
        settings.monitorDwindleSettings = [dwindleOverride]
        settings.appRules = BuiltInSettingsDefaults.appRules + [customRule]
        settings.flushNow()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.monitorBarSettings == [barOverride])
        #expect(reloaded.monitorNiriSettings == [niriOverride])
        #expect(reloaded.monitorDwindleSettings == [dwindleOverride])
        #expect(reloaded.appRules == BuiltInSettingsDefaults.appRules + [customRule])
    }

    @Test func tomlLoadNormalizesWorkspaceConfigurations() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let output = OutputId(displayId: 10, name: "Studio Display")
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "2",
                displayName: "Code",
                monitorAssignment: .specificDisplay(output),
                layoutType: .dwindle
            ),
            WorkspaceConfiguration(name: "10", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", displayName: "Duplicate", monitorAssignment: .secondary)
        ]
        settings.flushNow()

        let reloaded = SettingsStore(defaults: defaults)

        #expect(reloaded.workspaceConfigurations.map(\.name) == ["2", "10"])
        #expect(reloaded.workspaceConfigurations.first?.displayName == "Code")
        #expect(reloaded.workspaceConfigurations.first?.monitorAssignment == .specificDisplay(output))
        #expect(reloaded.workspaceConfigurations.last?.monitorAssignment == .main)
    }

    @Test func tomlApplyRebindsMonitorOverridesByUniqueNameWhenDisplayIdChanges() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let currentMonitor = makeSettingsTestMonitor(displayId: 202, name: "Studio Display")
        var export = SettingsExport.defaults()
        export.monitorBarSettings = [
            MonitorBarSettings(monitorName: currentMonitor.name, monitorDisplayId: 101, enabled: false)
        ]
        export.monitorOrientationSettings = [
            MonitorOrientationSettings(
                monitorName: currentMonitor.name,
                monitorDisplayId: 101,
                orientation: .vertical
            )
        ]
        export.monitorNiriSettings = [
            MonitorNiriSettings(
                monitorName: currentMonitor.name,
                monitorDisplayId: 101,
                maxVisibleColumns: 4
            )
        ]
        export.monitorDwindleSettings = [
            MonitorDwindleSettings(
                monitorName: currentMonitor.name,
                monitorDisplayId: 101,
                smartSplit: true
            )
        ]

        settings.applyExport(export, monitors: [currentMonitor])

        #expect(settings.monitorBarSettings.first?.monitorDisplayId == currentMonitor.displayId)
        #expect(settings.monitorOrientationSettings.first?.monitorDisplayId == currentMonitor.displayId)
        #expect(settings.monitorNiriSettings.first?.monitorDisplayId == currentMonitor.displayId)
        #expect(settings.monitorDwindleSettings.first?.monitorDisplayId == currentMonitor.displayId)
        #expect(settings.barSettings(for: currentMonitor)?.enabled == false)
        #expect(settings.orientationSettings(for: currentMonitor)?.orientation == .vertical)
        #expect(settings.niriSettings(for: currentMonitor)?.maxVisibleColumns == 4)
        #expect(settings.dwindleSettings(for: currentMonitor)?.smartSplit == true)
    }

    @Test func tomlApplyClearsStaleMonitorDisplayIdWhenNameCannotBeResolved() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let currentMonitor = makeSettingsTestMonitor(displayId: 202, name: "Studio Display")
        var export = SettingsExport.defaults()
        export.monitorBarSettings = [
            MonitorBarSettings(monitorName: "Disconnected Display", monitorDisplayId: 101, enabled: false)
        ]

        settings.applyExport(export, monitors: [currentMonitor])

        #expect(settings.monitorBarSettings.first?.monitorDisplayId == nil)
        #expect(settings.barSettings(for: currentMonitor) == nil)
    }

    @Test func tomlApplyRebindsSpecificWorkspaceDisplayByUniqueNameWhenDisplayIdChanges() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let currentMonitor = makeSettingsTestMonitor(displayId: 202, name: "Studio Display")
        var export = SettingsExport.defaults()
        export.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(displayId: 101, name: currentMonitor.name)),
                layoutType: .dwindle
            )
        ]

        settings.applyExport(export, monitors: [currentMonitor])

        #expect(settings.workspaceConfigurations.first?
            .monitorAssignment == .specificDisplay(OutputId(from: currentMonitor)))
    }
}

@Suite(.serialized) @MainActor struct SettingsStoreAppearanceApplyTests {
    @Test func persistedSettingsApplyingToControllerUsesSharedAppearancePath() {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        let controller = makeLayoutPlanTestController()
        defer { controller.setEnabled(false) }
        controller.settings.hotkeysEnabled = false
        controller.settings.workspaceBarEnabled = false
        controller.settings.appearanceMode = .light

        application.appearance = NSAppearance(named: .darkAqua)
        controller.applyPersistedSettings(controller.settings)

        #expect(controller.settings.appearanceMode == .light)
        #expect(application.appearance?.name == .aqua)
    }
}

@MainActor struct SettingsStoreBuiltInDefaultsTests {
    @Test func settingsStoreBootsWithPromotedDefaultsAndExcludedLocalStateStaysOut() {
        let settings = SettingsStore(defaults: makeTestDefaults())

        #expect(settings.mouseWarpAxis == .horizontal)
        #expect(settings.mouseWarpMargin == 1)
        #expect(settings.niriColumnWidthPresets == BuiltInSettingsDefaults.niriColumnWidthPresets)
        #expect(settings.gapSize == 16)
        #expect(settings.outerGapLeft == 0)
        #expect(settings.outerGapRight == 0)
        #expect(settings.outerGapTop == 0)
        #expect(settings.outerGapBottom == 0)
        #expect(settings.niriMaxWindowsPerColumn == 10)
        #expect(settings.niriAlwaysCenterSingleColumn == false)
        #expect(settings.niriSingleWindowAspectRatio == .none)
        #expect(settings.niriDefaultColumnWidth == 0.5)
        #expect(settings.workspaceConfigurations == BuiltInSettingsDefaults.workspaceConfigurations)
        #expect(settings.bordersEnabled == true)
        #expect(settings.borderWidth == 5.0)
        #expect(settings.borderColorRed == 0.084585202284378935)
        #expect(settings.borderColorGreen == 1.0)
        #expect(settings.borderColorBlue == 0.97930003794467602)
        #expect(settings.hotkeyBindings == HotkeyBindingRegistry.defaults())
        #expect(settings.workspaceBarEnabled == true)
        #expect(settings.workspaceBarShowFloatingWindows == false)
        #expect(settings.workspaceBarNotchAware == true)
        #expect(settings.workspaceBarReserveLayoutSpace == false)
        #expect(settings.appRules == BuiltInSettingsDefaults.appRules)
        #expect(settings.mouseWarpMonitorOrder.isEmpty)
        #expect(settings.preventSleepEnabled == false)
        #expect(settings.updateChecksEnabled == true)
        #expect(settings.ipcEnabled == false)
        #expect(settings.scrollSensitivity == 5.0)
        #expect(settings.statusBarShowWorkspaceName == false)
        #expect(settings.statusBarShowAppNames == false)
        #expect(settings.statusBarUseWorkspaceId == false)
        #expect(settings.clipboardHistoryEnabled == false)
        #expect(settings.clipboardMaxItems == 200)
        #expect(settings.clipboardMaxItemBytes == 8_388_608)
        #expect(settings.clipboardMaxTotalBytes == 67_108_864)
        #expect(settings.hiddenBarIsCollapsed == true)
        #expect(settings.quakeTerminalEnabled == true)
        #expect(settings.quakeTerminalPosition == .center)
        #expect(settings.quakeTerminalWidthPercent == 50.0)
        #expect(settings.quakeTerminalHeightPercent == 50.0)
        #expect(settings.quakeTerminalAutoHide == false)
        #expect(settings.quakeTerminalMonitorMode == .focusedWindow)
        #expect(settings.quakeTerminalUseCustomFrame == false)
        #expect(settings.quakeTerminalCustomFrame == nil)
        #expect(settings.appearanceMode == .dark)
    }

    @Test func settingsStoreFallbackDefaultsMatchExportDefaults() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let exportDefaults = SettingsExport.defaults()

        #expect(settings.hotkeysEnabled == exportDefaults.hotkeysEnabled)
        #expect(settings.focusFollowsMouse == exportDefaults.focusFollowsMouse)
        #expect(settings.moveMouseToFocusedWindow == exportDefaults.moveMouseToFocusedWindow)
        #expect(settings.focusFollowsWindowToMonitor == exportDefaults.focusFollowsWindowToMonitor)
        #expect(settings.mouseWarpAxis.rawValue == exportDefaults.mouseWarpAxis)
        #expect(settings.mouseWarpMargin == exportDefaults.mouseWarpMargin)
        #expect(settings.gapSize == exportDefaults.gapSize)
        #expect(settings.niriMaxWindowsPerColumn == exportDefaults.niriMaxWindowsPerColumn)
        #expect(settings.niriMaxVisibleColumns == exportDefaults.niriMaxVisibleColumns)
        #expect(settings.defaultLayoutType.rawValue == exportDefaults.defaultLayoutType)
        #expect(settings.borderWidth == exportDefaults.borderWidth)
        #expect(settings.workspaceBarShowFloatingWindows == exportDefaults.workspaceBarShowFloatingWindows)
        #expect(settings.workspaceBarPosition.rawValue == exportDefaults.workspaceBarPosition)
        #expect(settings.dwindleDefaultSplitRatio == exportDefaults.dwindleDefaultSplitRatio)
        #expect(settings.scrollModifierKey.rawValue == exportDefaults.scrollModifierKey)
        #expect(settings.gestureFingerCount.rawValue == exportDefaults.gestureFingerCount)
        #expect(settings.statusBarShowWorkspaceName == exportDefaults.statusBarShowWorkspaceName)
        #expect(settings.statusBarShowAppNames == exportDefaults.statusBarShowAppNames)
        #expect(settings.statusBarUseWorkspaceId == exportDefaults.statusBarUseWorkspaceId)
        #expect(settings.commandPaletteLastMode.rawValue == exportDefaults.commandPaletteLastMode)
        #expect(settings.clipboardHistoryEnabled == exportDefaults.clipboardHistoryEnabled)
        #expect(settings.clipboardMaxItems == exportDefaults.clipboardMaxItems)
        #expect(settings.clipboardMaxItemBytes == exportDefaults.clipboardMaxItemBytes)
        #expect(settings.clipboardMaxTotalBytes == exportDefaults.clipboardMaxTotalBytes)
        #expect(settings.hiddenBarIsCollapsed == exportDefaults.hiddenBarIsCollapsed)
        #expect(settings.updateChecksEnabled == exportDefaults.updateChecksEnabled)
        #expect(settings.ipcEnabled == exportDefaults.ipcEnabled)
        #expect(settings.quakeTerminalPosition.rawValue == exportDefaults.quakeTerminalPosition)
        #expect(settings.quakeTerminalMonitorMode.rawValue == exportDefaults.quakeTerminalMonitorMode)
        #expect(settings.appearanceMode.rawValue == exportDefaults.appearanceMode)
    }
}

struct SettingsSectionTests {
    @Test func settingsSectionsExcludeMenuSection() {
        #expect(SettingsSection.allCases.map(\.id) == [
            "general",
            "niri",
            "dwindle",
            "monitors",
            "workspaces",
            "borders",
            "bar",
            "hotkeys",
            "quakeTerminal"
        ])
    }
}

@MainActor struct RuntimeStateStoreTests {
    @Test func runtimeStateRoundTripsWindowRestoreCatalogAndUpdaterState() {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let catalog = makePersistedRestoreCatalogFixture()
        let store = RuntimeStateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store.windowRestoreCatalog = catalog
        store.updaterLastCheckedAt = now
        store.updaterSkippedReleaseTag = "0.5"
        store.flushNow()

        let reloaded = RuntimeStateStore(directory: directory)
        let state = reloaded.load()

        #expect(state.windowRestoreCatalog == catalog)
        #expect(state.updaterLastCheckedAt == now)
        #expect(state.updaterSkippedReleaseTag == "0.5")
    }
}

@MainActor struct SettingsFilePersistenceTests {
    @Test func missingFileMaterializesDefaults() {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)

        let export = persistence.load()

        #expect(export == SettingsExport.defaults())
        #expect(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    @Test func corruptFileIsRenamedAsideAndReplacedWithDefaults() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let url = directory.appendingPathComponent("settings.toml", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is =!==== not valid toml".utf8).write(to: url)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        let corruptURL = directory.appendingPathComponent("settings.toml.corrupt", isDirectory: false)

        #expect(export == SettingsExport.defaults())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }
}

@Suite(.serialized) @MainActor struct SettingsFileWatcherTests {
    @Test func externalEditsReloadLiveSettings() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        var export = settings.toExport()
        export.focusFollowsWindowToMonitor = true
        try writeSettingsExport(export, to: settings.settingsFileURL)

        let reloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.focusFollowsWindowToMonitor == true
        }

        #expect(reloaded)
    }

    @Test func externalInPlaceTruncateAndWriteReloadsLiveSettings() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        var export = settings.toExport()
        export.focusFollowsWindowToMonitor = true
        try writeSettingsExportInPlace(export, to: settings.settingsFileURL)

        let reloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.focusFollowsWindowToMonitor == true
        }

        #expect(reloaded)
    }

    @Test func externalAtomicReplacementReloadsWhenSizeAndModificationDateMatchLastWrite() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let originalModificationDate = try #require(settings.settingsFileURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        let export = try SettingsTOMLCodec.decode(originalData)
        let sameDigitGapCandidates = Array(10 ... 99).map(Double.init) + Array(0 ... 9).map(Double.init)
        var replacementExport: SettingsExport?
        var replacementData: Data?
        for gapSize in sameDigitGapCandidates where gapSize != export.gapSize {
            var candidate = export
            candidate.gapSize = gapSize
            let candidateData = try SettingsTOMLCodec.encode(candidate)
            guard candidateData.count == originalData.count else { continue }
            replacementExport = candidate
            replacementData = candidateData
            break
        }
        let unwrappedReplacementExport = try #require(replacementExport)
        let unwrappedReplacementData = try #require(replacementData)

        try atomicallyReplaceSettingsDataForTests(
            unwrappedReplacementData,
            at: settings.settingsFileURL,
            preservingModificationDate: originalModificationDate
        )

        let reloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.gapSize == unwrappedReplacementExport.gapSize
        }

        #expect(reloaded)
    }

    @Test func atomicReplacementRearmsWatcherForLaterInPlaceEdits() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        var replacementExport = settings.toExport()
        replacementExport.gapSize = 7
        try writeSettingsExport(replacementExport, to: settings.settingsFileURL)

        let replaced = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 1 && settings.gapSize == replacementExport.gapSize
        }
        #expect(replaced)

        var inPlaceExport = settings.toExport()
        inPlaceExport.focusFollowsWindowToMonitor = true
        try writeSettingsExportInPlace(inPlaceExport, to: settings.settingsFileURL)

        let inPlaceReloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            reloadCount == 2 && settings.focusFollowsWindowToMonitor == true
        }

        #expect(inPlaceReloaded)
    }

    @Test func invalidExternalEditLeavesCurrentSettingsUnchanged() async throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        let invalidPayload = "this is =!==== not valid toml"
        try Data(invalidPayload.utf8).write(to: settings.settingsFileURL, options: .atomic)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(settings.focusFollowsWindowToMonitor == SettingsExport.defaults().focusFollowsWindowToMonitor)
        #expect(reloadCount == 0)
        let rawData = try Data(contentsOf: settings.settingsFileURL)
        #expect(String(data: rawData, encoding: .utf8) == invalidPayload)
    }

    @Test func selfWriteThroughSettingsStoreDoesNotFireExternalReload() async {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory),
            runtimeState: RuntimeStateStore(directory: directory)
        )
        var reloadCount = 0
        settings.onExternalSettingsReloaded = {
            reloadCount += 1
        }

        // Self-write through the @Observable property's didSet { scheduleSave() } path.
        // scheduleSave -> Task.yield -> persistence.flushNow -> save() ->
        // refreshSettingsFileWatcher updates lastWrittenFingerprint. The subsequent
        // DispatchSource event fires, but the handler at SettingsFilePersistence.swift:211
        // short-circuits because observedFingerprint == lastWrittenFingerprint, so
        // onExternalSettingsReloaded must not fire.
        settings.focusFollowsWindowToMonitor = true
        settings.flushNow()

        // Wait for any pending DispatchSource events to drain. Pattern mirrors
        // `invalidExternalEditLeavesCurrentSettingsUnchanged` which uses the same
        // 200ms drain window before asserting reloadCount == 0.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(reloadCount == 0)
        #expect(settings.focusFollowsWindowToMonitor == true)
    }
}
