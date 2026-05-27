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

struct OmniWMStoragePathsTests {
    @Test func defaultsUseXDGFallbacksUnderHome() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = OmniWMStoragePaths.resolve(environment: [:], homeDirectory: homeDirectory)

        #expect(paths.configDirectory.path == "/Users/example/.config/omniwm")
        #expect(paths.stateDirectory.path == "/Users/example/.local/state/omniwm")
    }

    @Test func absoluteEnvironmentOverridesWin() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = OmniWMStoragePaths.resolve(
            environment: [
                "XDG_CONFIG_HOME": "/Volumes/Profile/config",
                "XDG_STATE_HOME": "/Volumes/Profile/state"
            ],
            homeDirectory: homeDirectory
        )

        #expect(paths.configDirectory.path == "/Volumes/Profile/config/omniwm")
        #expect(paths.stateDirectory.path == "/Volumes/Profile/state/omniwm")
    }

    @Test func emptyAndRelativeEnvironmentValuesFallBack() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = OmniWMStoragePaths.resolve(
            environment: [
                "XDG_CONFIG_HOME": "",
                "XDG_STATE_HOME": "relative/state"
            ],
            homeDirectory: homeDirectory
        )

        #expect(paths.configDirectory.path == "/Users/example/.config/omniwm")
        #expect(paths.stateDirectory.path == "/Users/example/.local/state/omniwm")
    }
}

@MainActor struct QuakeTerminalSettingsValidationTests {
    @Test func normalizesQuakeTerminalPercentagesOnAssignment() {
        let settings = SettingsStore(defaults: makeTestDefaults())

        settings.quakeTerminalWidthPercent = 5
        settings.quakeTerminalHeightPercent = 150

        #expect(settings.quakeTerminalWidthPercent == 10)
        #expect(settings.quakeTerminalHeightPercent == 100)

        settings.quakeTerminalWidthPercent = Double.nan
        settings.quakeTerminalHeightPercent = Double.infinity

        #expect(settings.quakeTerminalWidthPercent == 50)
        #expect(settings.quakeTerminalHeightPercent == 50)
    }

    @Test func resetsInvalidQuakeTerminalCustomFrames() {
        let settings = SettingsStore(defaults: makeTestDefaults())

        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = CGRect(x: 0, y: 0, width: 199, height: 400)

        #expect(settings.quakeTerminalUseCustomFrame == false)
        #expect(settings.quakeTerminalCustomFrame == nil)

        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = CGRect(x: 10, y: 20, width: 1200, height: 700)

        #expect(settings.quakeTerminalUseCustomFrame == true)
        #expect(settings.quakeTerminalCustomFrame == CGRect(x: 10, y: 20, width: 1200, height: 700))
    }

    @Test func normalizesInvalidQuakeTerminalValuesFromExport() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        var export = SettingsExport.defaults()
        export.quakeTerminalWidthPercent = Double.nan
        export.quakeTerminalHeightPercent = 150
        export.quakeTerminalUseCustomFrame = true
        export.quakeTerminalCustomFrame = QuakeTerminalFrameExport(x: 0, y: 0, width: 199, height: 700)

        settings.applyExport(export, monitors: [])

        #expect(settings.quakeTerminalWidthPercent == 50)
        #expect(settings.quakeTerminalHeightPercent == 100)
        #expect(settings.quakeTerminalUseCustomFrame == false)
        #expect(settings.quakeTerminalCustomFrame == nil)
    }
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
                identity: nil,
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

private struct SettingsFileSnapshot: Equatable {
    let deviceID: UInt64
    let inode: UInt64
    let modificationTimeNanoseconds: Int64
    let statusChangeTimeNanoseconds: Int64
    let fileSize: UInt64
    let contents: Data
}

private func settingsFileSnapshot(_ url: URL) throws -> SettingsFileSnapshot {
    var statBuffer = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
        guard let path else { return -1 }
        return Darwin.fstatat(AT_FDCWD, path, &statBuffer, 0)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    return SettingsFileSnapshot(
        deviceID: UInt64(statBuffer.st_dev),
        inode: UInt64(statBuffer.st_ino),
        modificationTimeNanoseconds: Int64(statBuffer.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(statBuffer.st_mtimespec.tv_nsec),
        statusChangeTimeNanoseconds: Int64(statBuffer.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(statBuffer.st_ctimespec.tv_nsec),
        fileSize: UInt64(statBuffer.st_size),
        contents: try Data(contentsOf: url)
    )
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

        settings.flushNow()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let fresh = RuntimeStateStore(directory: runtimeStateDirectory)

        #expect(fresh.windowRestoreCatalog == catalog)
        #expect(
            FileManager.default.fileExists(
                atPath: configurationDirectory.appendingPathComponent(RuntimeStateStore.fileName).path
            ) == false
        )
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

    @Test func settingsStoreImportsLegacyConfigSideRestoreCatalogIntoRuntimeState() {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let catalog = makePersistedRestoreCatalogFixture(workspaceName: "2")
        let legacyRuntimeState = RuntimeStateStore(directory: configurationDirectory, deferSaves: false)
        legacyRuntimeState.windowRestoreCatalog = catalog

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: configurationDirectory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        )

        #expect(settings.loadPersistedWindowRestoreCatalog() == catalog)
        #expect(RuntimeStateStore(directory: runtimeStateDirectory).windowRestoreCatalog == catalog)
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
        #expect(defaults.hyperTrigger == .default)
        #expect(defaults.workspaceBarEnabled == true)
        #expect(defaults.workspaceBarShowFloatingWindows == false)
        #expect(defaults.workspaceBarNotchAware == true)
        #expect(defaults.workspaceBarReserveLayoutSpace == false)
        #expect(defaults.appRules == BuiltInSettingsDefaults.appRules)
        #expect(defaults.preventSleepEnabled == false)
        #expect(defaults.updateChecksEnabled == true)
        #expect(defaults.ipcEnabled == false)
        #expect(defaults.scrollSensitivity == 5.0)
        #expect(defaults.mouseResizeModifierKey == MouseResizeModifierKey.option.rawValue)
        #expect(defaults.statusBarShowWorkspaceName == false)
        #expect(defaults.statusBarShowAppNames == false)
        #expect(defaults.statusBarUseWorkspaceId == false)
        #expect(defaults.clipboardHistoryEnabled == false)
        #expect(defaults.clipboardMaxItems == 200)
        #expect(defaults.clipboardMaxItemBytes == 8_388_608)
        #expect(defaults.clipboardMaxTotalBytes == 67_108_864)
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

    @Test func workspaceBarThemeColorsRoundTripThroughExportAndResolution() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Theme Test")
        let accent = SettingsColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let text = SettingsColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 1)

        settings.workspaceBarAccentColor = accent
        settings.workspaceBarTextColor = text

        let export = settings.toExport()
        #expect(export.workspaceBarAccentColor == accent)
        #expect(export.workspaceBarTextColor == text)

        let reloaded = SettingsStore(defaults: makeTestDefaults())
        reloaded.applyExport(export, monitors: [monitor])

        #expect(reloaded.workspaceBarAccentColor == accent)
        #expect(reloaded.workspaceBarTextColor == text)
        #expect(reloaded.resolvedBarSettings(for: monitor).accentColor == accent)
        #expect(reloaded.resolvedBarSettings(for: monitor).textColor == text)
    }

    @Test func workspaceBarThemeColorDefaultsUseSystemFallbacks() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let monitor = makeLayoutPlanTestMonitor(name: "Default Theme Test")
        let resolved = settings.resolvedBarSettings(for: monitor)

        #expect(settings.workspaceBarAccentColor == nil)
        #expect(settings.workspaceBarTextColor == nil)
        #expect(resolved.accentColor == nil)
        #expect(resolved.textColor == nil)
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

    @Test func hyperBindingsUseReadableAlias() throws {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: 0,
            usesHyper: true
        )

        let output = try encodeSingleHotkeyBinding(binding)

        #expect(binding.displayString == "Hyper+Space")
        #expect(binding.humanReadableString == "Hyper+Space")
        #expect(KeySymbolMapper.fromHumanReadable("Hyper+Space") == binding)
        #expect(output.contains("binding = \"Hyper+Space\""))
    }

    @Test func literalAllModifiersRemainDistinctFromSemanticHyper() {
        let literal = KeyBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: KeySymbolMapper.hyperModifiers
        )
        let semantic = KeyBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: 0,
            usesHyper: true
        )

        #expect(literal.displayString == "⌃⌥⇧⌘Space")
        #expect(literal.humanReadableString == "Control+Option+Shift+Command+Space")
        #expect(literal != semantic)
        #expect(literal.conflicts(with: semantic, hyperTrigger: .system))
    }

    @Test func hyperTriggerRoundTripsKeyboardAndMouseButtons() throws {
        var export = SettingsExport.defaults()
        export.hyperTrigger = .mouseButton(4)

        var data = try SettingsTOMLCodec.encode(export)
        var output = try #require(String(data: data, encoding: .utf8))
        var decoded = try SettingsTOMLCodec.decode(data)

        #expect(output.contains("hyperTrigger = \"MouseButton4\""))
        #expect(decoded.hyperTrigger == .mouseButton(4))

        export.hyperTrigger = .modifier(UInt32(optionKey))
        data = try SettingsTOMLCodec.encode(export)
        output = try #require(String(data: data, encoding: .utf8))
        decoded = try SettingsTOMLCodec.decode(data)

        #expect(output.contains("hyperTrigger = \"Option\""))
        #expect(decoded.hyperTrigger == .modifier(UInt32(optionKey)))

        export.hyperTrigger = .key(UInt32(kVK_F18))
        data = try SettingsTOMLCodec.encode(export)
        output = try #require(String(data: data, encoding: .utf8))
        decoded = try SettingsTOMLCodec.decode(data)

        #expect(output.contains("hyperTrigger = \"F18\""))
        #expect(decoded.hyperTrigger == .key(UInt32(kVK_F18)))
    }

    @Test func legacyWorkspaceDefaultsMigrateToSemanticHyper() throws {
        var export = SettingsExport.defaults()
        let legacySwitch = try #require(
            HotkeyBindingRegistry.makeBinding(
                id: "switchWorkspace.1",
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey))
            )
        )
        let customFocus = try #require(
            HotkeyBindingRegistry.makeBinding(
                id: "focus.left",
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(optionKey))
            )
        )
        export.hotkeyBindings = [legacySwitch, customFocus]

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))

        #expect(
            decoded.hotkeyBindings.first { $0.id == "switchWorkspace.1" }?.binding ==
                .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, usesHyper: true))
        )
        #expect(decoded.hotkeyBindings.first { $0.id == "focus.left" }?.binding == customFocus.binding)
    }

    @Test func sequenceBindingsRoundTripAsReadableStrings() throws {
        var export = SettingsExport.defaults()
        let trigger = HotkeyTrigger.sequence([
            .leader,
            .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0))
        ])
        let hotkey = try #require(HotkeyBindingRegistry.makeBinding(id: "focus.left", trigger: trigger))
        export.hotkeyBindings = [hotkey]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        let output = try #require(String(data: data, encoding: .utf8))

        #expect(output.contains("leaderKey = \"Hyper+Space\""))
        #expect(output.contains("sequenceTimeoutMilliseconds = 800"))
        #expect(output.contains("binding = \"Leader, H\""))
        #expect(decoded.hotkeyBindings == [hotkey])
    }

    @Test func sequenceBindingsWithCommaStepRoundTripAsReadableStrings() throws {
        var export = SettingsExport.defaults()
        let trigger = HotkeyTrigger.sequence([
            .leader,
            .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: 0))
        ])
        let hotkey = try #require(HotkeyBindingRegistry.makeBinding(id: "focus.left", trigger: trigger))
        export.hotkeyBindings = [hotkey]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        let output = try #require(String(data: data, encoding: .utf8))

        #expect(output.contains("binding = \"Leader, Comma\""))
        #expect(decoded.hotkeyBindings == [hotkey])
    }

    @Test func legacyCompactPunctuationBindingsStillDecode() throws {
        #expect(KeySymbolMapper.fromHumanReadable("Option+,") == KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+.") == KeyBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+-") == KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+=") == KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey)))
        #expect(KeySymbolMapper.fromHumanReadable("Option+`") == KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey)))
        #expect(HotkeyTrigger.fromHumanReadable("Option+,") == .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey))))
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
    @Test func commandPaletteLastModePersistsThroughRuntimeStateWithoutRewritingSettingsFile() throws {
        let defaults = makeTestDefaults()

        let settings = SettingsStore(defaults: defaults)
        let beforeSettings = try settingsFileSnapshot(settings.settingsFileURL)
        #expect(settings.commandPaletteLastMode == RuntimeStateStore.defaultCommandPaletteLastMode)

        settings.commandPaletteLastMode = .clipboard
        settings.flushNow()

        let afterSettings = try settingsFileSnapshot(settings.settingsFileURL)
        let runtimeState = RuntimeStateStore(directory: runtimeStateDirectoryForTests(defaults: defaults))
        #expect(afterSettings == beforeSettings)
        #expect(runtimeState.commandPaletteLastMode == .clipboard)

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
        settings.mouseResizeModifierKey = .controlCommandShift
        settings.statusBarShowWorkspaceName = true
        settings.statusBarShowAppNames = true
        settings.statusBarUseWorkspaceId = true
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
        #expect(reloaded.mouseResizeModifierKey == .controlCommandShift)
        #expect(reloaded.statusBarShowWorkspaceName == true)
        #expect(reloaded.statusBarShowAppNames == true)
        #expect(reloaded.statusBarUseWorkspaceId == true)
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
        #expect(settings.hyperTrigger == .default)
        #expect(settings.leaderKey == KeyBinding.defaultLeader)
        #expect(settings.sequenceTimeoutMilliseconds == 800)
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
        #expect(settings.mouseResizeModifierKey == .option)
        #expect(settings.statusBarShowWorkspaceName == false)
        #expect(settings.statusBarShowAppNames == false)
        #expect(settings.statusBarUseWorkspaceId == false)
        #expect(settings.clipboardHistoryEnabled == false)
        #expect(settings.clipboardMaxItems == 200)
        #expect(settings.clipboardMaxItemBytes == 8_388_608)
        #expect(settings.clipboardMaxTotalBytes == 67_108_864)
        #expect(settings.hiddenBarIsCollapsed == RuntimeStateStore.defaultHiddenBarIsCollapsed)
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
        #expect(settings.hyperTrigger == exportDefaults.hyperTrigger)
        #expect(settings.workspaceBarShowFloatingWindows == exportDefaults.workspaceBarShowFloatingWindows)
        #expect(settings.workspaceBarPosition.rawValue == exportDefaults.workspaceBarPosition)
        #expect(settings.dwindleDefaultSplitRatio == exportDefaults.dwindleDefaultSplitRatio)
        #expect(settings.scrollModifierKey.rawValue == exportDefaults.scrollModifierKey)
        #expect(settings.mouseResizeModifierKey.rawValue == exportDefaults.mouseResizeModifierKey)
        #expect(settings.gestureFingerCount.rawValue == exportDefaults.gestureFingerCount)
        #expect(settings.statusBarShowWorkspaceName == exportDefaults.statusBarShowWorkspaceName)
        #expect(settings.statusBarShowAppNames == exportDefaults.statusBarShowAppNames)
        #expect(settings.statusBarUseWorkspaceId == exportDefaults.statusBarUseWorkspaceId)
        #expect(settings.commandPaletteLastMode == RuntimeStateStore.defaultCommandPaletteLastMode)
        #expect(settings.clipboardHistoryEnabled == exportDefaults.clipboardHistoryEnabled)
        #expect(settings.clipboardMaxItems == exportDefaults.clipboardMaxItems)
        #expect(settings.clipboardMaxItemBytes == exportDefaults.clipboardMaxItemBytes)
        #expect(settings.clipboardMaxTotalBytes == exportDefaults.clipboardMaxTotalBytes)
        #expect(settings.hiddenBarIsCollapsed == RuntimeStateStore.defaultHiddenBarIsCollapsed)
        #expect(settings.updateChecksEnabled == exportDefaults.updateChecksEnabled)
        #expect(settings.ipcEnabled == exportDefaults.ipcEnabled)
        #expect(settings.quakeTerminalPosition.rawValue == exportDefaults.quakeTerminalPosition)
        #expect(settings.quakeTerminalMonitorMode.rawValue == exportDefaults.quakeTerminalMonitorMode)
        #expect(settings.appearanceMode.rawValue == exportDefaults.appearanceMode)
    }

    @Test func resetHotkeysRestoresLeaderAndSequenceTimeout() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.hyperTrigger = .mouseButton(4)
        settings.leaderKey = KeyBinding(keyCode: UInt32(kVK_F13), modifiers: 0)
        settings.sequenceTimeoutMilliseconds = 1500
        settings.updateBinding(
            for: "focus.left",
            newBinding: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(optionKey))
        )

        settings.resetHotkeysToDefaults()

        #expect(settings.hotkeyBindings == HotkeyBindingRegistry.defaults())
        #expect(settings.hyperTrigger == .default)
        #expect(settings.leaderKey == KeyBinding.defaultLeader)
        #expect(settings.sequenceTimeoutMilliseconds == 800)
    }

    @Test func capsLockHyperPresetKeepsLeaderOnHyperSpace() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.hyperTrigger = .system
        settings.leaderKey = KeyBinding(keyCode: UInt32(kVK_F13), modifiers: 0)

        settings.applyCapsLockHyperPreset()

        #expect(settings.hyperTrigger == .key(UInt32(kVK_CapsLock)))
        #expect(settings.leaderKey == KeyBinding.defaultLeader)
        #expect(!settings.leaderKey(settings.leaderKey, conflictsWith: settings.hyperTrigger))
    }

    @Test func effectiveLeaderKeyFallsBackToDefaultWhenStoredLeaderIsUnassigned() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let customLeader = KeyBinding(keyCode: UInt32(kVK_F13), modifiers: 0)

        #expect(settings.effectiveLeaderKey == KeyBinding.defaultLeader)

        settings.leaderKey = .unassigned
        #expect(settings.effectiveLeaderKey == KeyBinding.defaultLeader)

        settings.leaderKey = customLeader
        #expect(settings.effectiveLeaderKey == customLeader)
    }

    @Test func sequenceConflictChecksUseEffectiveLeaderWhenStoredLeaderIsUnassigned() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.leaderKey = .unassigned
        settings.updateBinding(for: "focus.left", newBinding: KeyBinding.defaultLeader)

        let conflicts = settings.findConflicts(
            for: .sequence([
                .leader,
                .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0))
            ]),
            excluding: "focus.right"
        )

        #expect(conflicts.map(\.id) == ["focus.left"])
    }

    @Test func defaultHotkeysDoNotRequireInputMonitoring() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let plan = HotkeyCenter.registrationPlan(
            for: settings.hotkeyBindings,
            hyperTrigger: settings.hyperTrigger,
            leaderKey: settings.leaderKey,
            sequenceEventAccessGranted: false
        )

        #expect(settings.hotkeyBindings.allSatisfy { binding in
            guard case .sequence = binding.binding else { return true }
            return false
        })
        #expect(!plan.failures.values.contains(.inputMonitoringDenied))
        #expect(plan.virtualHyperRegistrations.isEmpty)
    }

    @Test func capsLockHyperPreflightRejectsExistingCapsLockHotkey() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.updateBinding(
            for: "focus.left",
            newBinding: KeyBinding(keyCode: UInt32(kVK_CapsLock), modifiers: 0)
        )

        let plan = HotkeyCenter.registrationPlan(
            for: settings.hotkeyBindings,
            hyperTrigger: .key(UInt32(kVK_CapsLock)),
            leaderKey: KeyBinding.defaultLeader,
            sequenceEventAccessGranted: true
        )

        #expect(plan.failures[.focus(.left)] == .hyperLeaderConflict)
    }

    @Test func vimNavigationPresetCanBePreflightedBeforeMutatingBindings() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let originalBindings = settings.hotkeyBindings
        let mappings = HotkeyPreset.vimNavigation()

        let proposedBindings = settings.hotkeyBindings(applyingPreset: mappings)

        #expect(settings.hotkeyBindings == originalBindings)
        #expect(proposedBindings != originalBindings)

        let presetCommands = Set(mappings.compactMap { HotkeyBindingRegistry.command(for: $0.id) })
        let deniedPlan = HotkeyCenter.registrationPlan(
            for: proposedBindings,
            hyperTrigger: settings.hyperTrigger,
            leaderKey: settings.leaderKey,
            sequenceEventAccessGranted: false
        )
        let deniedFailures = deniedPlan.failures.filter { presetCommands.contains($0.key) }

        #expect(!deniedFailures.isEmpty)
        #expect(deniedFailures.values.allSatisfy { $0 == .inputMonitoringDenied })

        let allowedPlan = HotkeyCenter.registrationPlan(
            for: proposedBindings,
            hyperTrigger: settings.hyperTrigger,
            leaderKey: settings.leaderKey,
            sequenceEventAccessGranted: true
        )
        let allowedFailures = allowedPlan.failures.filter { presetCommands.contains($0.key) }

        #expect(allowedFailures.isEmpty)
    }

    @Test func presetClearsPhysicalOptionLeaderConflictUnderDefaultHyper() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.updateBinding(
            for: "toggleFullscreen",
            newBinding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        )

        let proposedBindings = settings.hotkeyBindings(applyingPreset: HotkeyPreset.vimNavigation())

        #expect(proposedBindings.first { $0.id == "toggleFullscreen" }?.binding == .unassigned)
    }

    @Test func capsLockHyperPresetAllowsDefaultLeaderVimSequences() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.applyCapsLockHyperPreset()

        let mappings = HotkeyPreset.vimNavigation()
        let proposedBindings = settings.hotkeyBindings(applyingPreset: mappings)
        let presetCommands = Set(mappings.compactMap { HotkeyBindingRegistry.command(for: $0.id) })
        let plan = HotkeyCenter.registrationPlan(
            for: proposedBindings,
            hyperTrigger: settings.hyperTrigger,
            leaderKey: settings.leaderKey,
            sequenceEventAccessGranted: true
        )
        let presetFailures = plan.failures.filter { presetCommands.contains($0.key) }

        #expect(presetFailures.isEmpty)
    }

    @Test func leaderRootConflictsFindDirectChordUsingCandidateLeader() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let candidateLeader = KeyBinding(keyCode: UInt32(kVK_F13), modifiers: 0)
        settings.updateBinding(for: "focus.left", newBinding: candidateLeader)
        settings.updateTrigger(
            for: "focus.right",
            newTrigger: .sequence([
                .leader,
                .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: 0))
            ])
        )

        let conflicts = settings.findLeaderRootConflicts(for: candidateLeader)

        #expect(conflicts.map(\.id) == ["focus.left"])
    }

    @Test func leaderRootConflictsUseDefaultOptionHyperCompatibility() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        settings.updateBinding(
            for: "focus.left",
            newBinding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        )
        settings.updateTrigger(
            for: "focus.right",
            newTrigger: .sequence([
                .leader,
                .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: 0))
            ])
        )

        let conflicts = settings.findLeaderRootConflicts(for: KeyBinding.defaultLeader)

        #expect(conflicts.map(\.id) == ["focus.left"])
    }

    @Test func leaderUsingHyperTriggerPhysicalKeyIsReportedAsConflict() {
        let settings = SettingsStore(defaults: makeTestDefaults())
        let rawCapsLeader = KeyBinding(keyCode: UInt32(kVK_CapsLock), modifiers: 0)
        let semanticSpaceLeader = KeyBinding(keyCode: UInt32(kVK_Space), modifiers: 0, usesHyper: true)

        #expect(settings.leaderKey(rawCapsLeader, conflictsWith: .key(UInt32(kVK_CapsLock))))
        #expect(settings.leaderKey(semanticSpaceLeader, conflictsWith: .key(UInt32(kVK_Space))))
        #expect(settings.leaderKey(
            KeyBinding(keyCode: UInt32(kVK_RightOption), modifiers: 0),
            conflictsWith: .modifier(UInt32(optionKey))
        ))
        #expect(!settings.leaderKey(
            KeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, usesHyper: true),
            conflictsWith: .key(UInt32(kVK_CapsLock))
        ))
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

    @Test func hiddenBarCollapseStateRoundTripsThroughRuntimeStateStore() {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let store = RuntimeStateStore(directory: directory)

        #expect(store.hiddenBarIsCollapsed == RuntimeStateStore.defaultHiddenBarIsCollapsed)

        store.hiddenBarIsCollapsed = false
        store.flushNow()

        let reloaded = RuntimeStateStore(directory: directory)
        #expect(reloaded.hiddenBarIsCollapsed == false)
    }

    @Test func commandPaletteLastModeRoundTripsThroughRuntimeStateStore() {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let store = RuntimeStateStore(directory: directory)

        #expect(store.commandPaletteLastMode == RuntimeStateStore.defaultCommandPaletteLastMode)

        store.commandPaletteLastMode = .clipboard
        store.flushNow()

        let reloaded = RuntimeStateStore(directory: directory)
        #expect(reloaded.commandPaletteLastMode == .clipboard)
    }

    @Test func missingHiddenBarRuntimeKeyPreservesExistingRuntimeState() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtimeURL = directory.appendingPathComponent(RuntimeStateStore.fileName, isDirectory: false)
        try Data(#"{"updaterSkippedReleaseTag":"0.5"}"#.utf8).write(to: runtimeURL)

        let reloaded = RuntimeStateStore(directory: directory)
        #expect(reloaded.hiddenBarIsCollapsed == RuntimeStateStore.defaultHiddenBarIsCollapsed)
        #expect(reloaded.updaterSkippedReleaseTag == "0.5")
    }

    @Test func runtimeStatePersistsWithPrivatePermissions() throws {
        let defaults = makeTestDefaults()
        let directory = runtimeStateDirectoryForTests(defaults: defaults)
        let store = RuntimeStateStore(directory: directory, deferSaves: false)

        store.updaterSkippedReleaseTag = "0.5"

        let fileURL = directory.appendingPathComponent(RuntimeStateStore.fileName, isDirectory: false)
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        ).intValue
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        ).intValue

        #expect(directoryMode & 0o777 == 0o700)
        #expect(fileMode & 0o777 == 0o600)
    }

    @Test func importsLegacyConfigSideWindowRestoreCatalogWhenRuntimeStateMissing() {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let catalog = makePersistedRestoreCatalogFixture(workspaceName: "2")
        let legacyRuntimeState = RuntimeStateStore(directory: configurationDirectory, deferSaves: false)
        legacyRuntimeState.windowRestoreCatalog = catalog
        legacyRuntimeState.updaterSkippedReleaseTag = "0.5"
        legacyRuntimeState.hiddenBarIsCollapsed = false

        let runtimeState = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        let imported = runtimeState.importWindowRestoreCatalogIfMissing(fromLegacyDirectory: configurationDirectory)
        let reloaded = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        let legacyFileURL = configurationDirectory.appendingPathComponent(RuntimeStateStore.fileName, isDirectory: false)

        #expect(imported)
        #expect(reloaded.windowRestoreCatalog == catalog)
        #expect(reloaded.updaterSkippedReleaseTag == nil)
        #expect(reloaded.hiddenBarIsCollapsed == RuntimeStateStore.defaultHiddenBarIsCollapsed)
        #expect(FileManager.default.fileExists(atPath: legacyFileURL.path) == false)
    }

    @Test func legacyConfigSideWindowRestoreCatalogDoesNotReplaceRuntimeStateCatalog() {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let legacyCatalog = makePersistedRestoreCatalogFixture(workspaceName: "legacy")
        let currentCatalog = makePersistedRestoreCatalogFixture(workspaceName: "current")
        let legacyRuntimeState = RuntimeStateStore(directory: configurationDirectory, deferSaves: false)
        legacyRuntimeState.windowRestoreCatalog = legacyCatalog
        let currentRuntimeState = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        currentRuntimeState.windowRestoreCatalog = currentCatalog

        let reloaded = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        let imported = reloaded.importWindowRestoreCatalogIfMissing(fromLegacyDirectory: configurationDirectory)
        let legacyFileURL = configurationDirectory.appendingPathComponent(RuntimeStateStore.fileName, isDirectory: false)

        #expect(imported == false)
        #expect(reloaded.windowRestoreCatalog == currentCatalog)
        #expect(FileManager.default.fileExists(atPath: legacyFileURL.path))
    }

    @Test func malformedLegacyRuntimeStateDoesNotImportWindowRestoreCatalog() throws {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        let legacyFileURL = configurationDirectory.appendingPathComponent(RuntimeStateStore.fileName, isDirectory: false)
        try Data("not-json".utf8).write(to: legacyFileURL)

        let runtimeState = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        let imported = runtimeState.importWindowRestoreCatalogIfMissing(fromLegacyDirectory: configurationDirectory)

        #expect(imported == false)
        #expect(runtimeState.windowRestoreCatalog == nil)
        #expect(FileManager.default.fileExists(atPath: legacyFileURL.path))
    }

    @Test func legacyRuntimeStateWithoutWindowRestoreCatalogDoesNotImportAncillaryFields() {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let legacyRuntimeState = RuntimeStateStore(directory: configurationDirectory, deferSaves: false)
        legacyRuntimeState.updaterSkippedReleaseTag = "legacy"
        legacyRuntimeState.hiddenBarIsCollapsed = false
        let currentRuntimeState = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        currentRuntimeState.updaterSkippedReleaseTag = "current"

        let reloaded = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        let imported = reloaded.importWindowRestoreCatalogIfMissing(fromLegacyDirectory: configurationDirectory)

        #expect(imported == false)
        #expect(reloaded.windowRestoreCatalog == nil)
        #expect(reloaded.updaterSkippedReleaseTag == "current")
        #expect(reloaded.hiddenBarIsCollapsed == RuntimeStateStore.defaultHiddenBarIsCollapsed)
    }
}

@MainActor struct HiddenBarRuntimeStateSettingsTests {
    @Test func hiddenBarChangesWriteRuntimeStateWithoutRewritingSettingsFile() throws {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let beforeSettings = try settingsFileSnapshot(settings.settingsFileURL)

        settings.hiddenBarIsCollapsed = false
        settings.flushNow()

        let afterSettings = try settingsFileSnapshot(settings.settingsFileURL)
        let runtimeState = RuntimeStateStore(directory: runtimeStateDirectoryForTests(defaults: defaults))

        #expect(afterSettings == beforeSettings)
        #expect(runtimeState.hiddenBarIsCollapsed == false)
    }

    @Test func hiddenBarFlushWritesDeferredRuntimeState() {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: configurationDirectory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: runtimeStateDirectory)
        )

        settings.hiddenBarIsCollapsed = false
        settings.flushNow()

        let reloaded = RuntimeStateStore(directory: runtimeStateDirectory)
        #expect(reloaded.hiddenBarIsCollapsed == false)
    }

    @Test func hiddenBarRuntimeStateSurvivesSettingsStoreReload() {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(defaults: defaults)

        settings.hiddenBarIsCollapsed = false
        settings.flushNow()

        let reloaded = SettingsStore(
            persistence: SettingsFilePersistence(directory: configurationDirectory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        )

        #expect(reloaded.hiddenBarIsCollapsed == false)
    }

    @Test func legacyStateTOMLKeysDoNotOverrideRuntimeState() throws {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        var export = SettingsExport.defaults()
        export.focusFollowsWindowToMonitor = true
        let runtimeState = RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        runtimeState.commandPaletteLastMode = .menu
        var toml = try #require(String(data: SettingsTOMLCodec.encode(export), encoding: .utf8))
        toml += "\n[state]\ncommandPaletteLastMode = \"clipboard\"\nhiddenBarIsCollapsed = false\n"
        try #require(toml.contains("hiddenBarIsCollapsed = false"))
        try #require(toml.contains("commandPaletteLastMode = \"clipboard\""))
        let settingsURL = configurationDirectory.appendingPathComponent("settings.toml", isDirectory: false)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try Data(toml.utf8).write(to: settingsURL)

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: configurationDirectory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: runtimeStateDirectory, deferSaves: false)
        )

        #expect(settings.focusFollowsWindowToMonitor)
        #expect(settings.commandPaletteLastMode == .menu)
        #expect(settings.hiddenBarIsCollapsed == RuntimeStateStore.defaultHiddenBarIsCollapsed)
    }

    @Test func externalSettingsReloadDoesNotChangeRuntimeBackedUIState() async throws {
        let defaults = makeTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let runtimeStateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: configurationDirectory),
            runtimeState: RuntimeStateStore(directory: runtimeStateDirectory)
        )
        settings.commandPaletteLastMode = .clipboard
        settings.hiddenBarIsCollapsed = false
        settings.flushNow()

        var export = settings.toExport()
        export.focusFollowsWindowToMonitor = true
        try writeSettingsExport(export, to: settings.settingsFileURL)

        let reloaded = await waitForConditionForTests(
            timeoutNanoseconds: 20_000_000_000
        ) {
            settings.focusFollowsWindowToMonitor == true
        }

        #expect(reloaded)
        #expect(settings.commandPaletteLastMode == .clipboard)
        #expect(settings.hiddenBarIsCollapsed == false)
    }
}

@MainActor struct ClipboardHistoryStoragePathTests {
    @Test func controllerUsesStateDirectoryForClipboardHistory() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let stateDirectory = runtimeStateDirectoryForTests(defaults: defaults)
        let controller = WMController(settings: settings, clipboardHistoryDirectory: stateDirectory)
        let configuration = controller.clipboardHistoryConfiguration()

        #expect(configuration.storageDirectory == stateDirectory)
        #expect(
            configuration.storageURL == stateDirectory.appendingPathComponent(
                ClipboardHistoryConfiguration.fileName,
                isDirectory: false
            )
        )
        #expect(configuration.storageDirectory != settings.settingsFileURL.deletingLastPathComponent())
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

    @Test func sameExportSaveDoesNotRewriteExistingSettingsFile() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        let before = try settingsFileSnapshot(persistence.fileURL)

        try persistence.saveImmediately(export)

        let after = try settingsFileSnapshot(persistence.fileURL)
        #expect(after == before)
    }

    @Test func sameExportSaveRecreatesDeletedSettingsFile() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        try FileManager.default.removeItem(at: persistence.fileURL)

        try persistence.saveImmediately(export)

        #expect(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    @Test func sameExportSaveOverwritesUnseenExternalReplacement() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()
        var externalExport = export
        externalExport.gapSize = 31
        try writeSettingsExport(externalExport, to: persistence.fileURL)

        try persistence.saveImmediately(export)

        let decoded = try SettingsTOMLCodec.decode(Data(contentsOf: persistence.fileURL))
        #expect(decoded == export)
    }

    @Test func changedExportStillRewritesSettingsFile() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        var export = persistence.load()
        let before = try settingsFileSnapshot(persistence.fileURL)
        export.gapSize = 23

        try persistence.saveImmediately(export)

        let after = try settingsFileSnapshot(persistence.fileURL)
        let decoded = try SettingsTOMLCodec.decode(after.contents)
        #expect(after != before)
        #expect(decoded.gapSize == 23)
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
