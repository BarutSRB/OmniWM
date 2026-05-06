// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import CoreGraphics
import ApplicationServices
import Carbon
import Foundation
import Testing

@testable import OmniWM

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
    height: CGFloat = 1080,
    displayUUID: String? = nil
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name,
        displayUUID: displayUUID
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

@Suite struct MonitorSettingsStoreTests {
    @Test func getReturnsNilForUnknownMonitor() {
        let settings = [MonitorNiriSettings(monitorName: "Monitor A")]
        let result = MonitorSettingsStore.get(for: "Monitor B", in: settings)
        #expect(result == nil)
    }

    @Test func updateReplacesExistingAtSameIndex() {
        var settings = [
            MonitorNiriSettings(monitorName: "A", maxVisibleColumns: 2),
            MonitorNiriSettings(monitorName: "B", maxVisibleColumns: 3),
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

    @Test func updateDoesNotReplaceDifferentDisplayUUIDWithSameName() {
        var settings = [
            MonitorNiriSettings(
                monitorName: "Studio Display",
                monitorDisplayUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                maxVisibleColumns: 2
            )
        ]
        let updated = MonitorNiriSettings(
            monitorName: "Studio Display",
            monitorDisplayUUID: "11111111-2222-3333-4444-555555555555",
            maxVisibleColumns: 5
        )

        MonitorSettingsStore.update(updated, in: &settings)

        #expect(settings.count == 2)
        #expect(settings[0].monitorDisplayUUID == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(settings[0].maxVisibleColumns == 2)
        #expect(settings[1].monitorDisplayUUID == "11111111-2222-3333-4444-555555555555")
        #expect(settings[1].maxVisibleColumns == 5)
    }

    @Test func removeDeletesAllMatches() {
        var settings = [
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "A"),
            MonitorNiriSettings(monitorName: "B"),
        ]
        MonitorSettingsStore.remove(for: "A", from: &settings)
        #expect(settings.count == 1)
        #expect(settings[0].monitorName == "B")
    }

    @Test func removeDoesNotDeleteDifferentDisplayUUIDWithSameName() {
        var settings = [
            MonitorNiriSettings(
                monitorName: "Studio Display",
                monitorDisplayUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                maxVisibleColumns: 2
            )
        ]
        let monitor = makeSettingsTestMonitor(
            displayId: 42,
            name: "Studio Display",
            displayUUID: "11111111-2222-3333-4444-555555555555"
        )

        MonitorSettingsStore.remove(for: monitor, from: &settings)

        #expect(settings.count == 1)
        #expect(settings[0].monitorDisplayUUID == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    @Test func monitorLookupPrefersDisplayIdOverNameFallback() {
        let monitor = makeSettingsTestMonitor(displayId: 42, name: "Studio Display")
        let settings = [
            MonitorNiriSettings(monitorName: "Studio Display", maxVisibleColumns: 1),
            MonitorNiriSettings(monitorName: "Studio Display", monitorDisplayId: 42, maxVisibleColumns: 3),
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.maxVisibleColumns == 3)
    }

    @Test func monitorLookupDoesNotFallbackToDifferentDisplayUUIDWithSameName() {
        let monitor = makeSettingsTestMonitor(
            displayId: 99,
            name: "Studio Display",
            displayUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        let settings = [
            MonitorNiriSettings(
                monitorName: "Studio Display",
                monitorDisplayUUID: "11111111-2222-3333-4444-555555555555",
                maxVisibleColumns: 2
            )
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result == nil)
    }

    @Test func monitorLookupPrefersDisplayUUIDAcrossReconnect() {
        let monitor = makeSettingsTestMonitor(
            displayId: 99,
            name: "",
            displayUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        let settings = [
            MonitorBarSettings(
                monitorName: "",
                monitorDisplayUUID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                enabled: false
            )
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.enabled == false)
    }

}

@Suite @MainActor struct RuntimeStateStoreTests {
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

@Suite @MainActor struct SettingsFilePersistenceTests {
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

@Suite @MainActor struct SettingsStorePersistenceTests {
    @Test func settingsChangesRoundTripThroughCanonicalSettingsFile() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let output = OutputId(
            displayUUID: "77777777-7777-7777-7777-777777777777",
            displayId: 777,
            name: "Studio Display"
        )

        settings.focusFollowsWindowToMonitor = true
        settings.mouseWarpAxis = .vertical
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "2",
                displayName: "Code",
                monitorAssignment: .specificDisplay(output),
                layoutType: .dwindle
            )
        ]
        settings.flushNow()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.focusFollowsWindowToMonitor == true)
        #expect(reloaded.mouseWarpAxis == .vertical)
        #expect(reloaded.workspaceConfigurations == settings.workspaceConfigurations)
    }

    @Test func runtimeStateSidecarKeepsRestoreCatalogOutOfSettingsFile() throws {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let runtimeState = runtimeStateStoreForTests(defaults: defaults)
        let catalog = makePersistedRestoreCatalogFixture()

        settings.savePersistedWindowRestoreCatalog(catalog)
        runtimeState.flushNow()
        settings.flushNow()

        let rawSettings = try String(contentsOf: settings.settingsFileURL, encoding: .utf8)
        let runtimeStateData = try Data(contentsOf: runtimeState.fileURL)
        let runtimeJSON = try #require(JSONSerialization.jsonObject(with: runtimeStateData) as? [String: Any])

        #expect(rawSettings.localizedCaseInsensitiveContains("restorecatalog") == false)
        #expect(runtimeJSON["windowRestoreCatalog"] != nil)
        #expect(SettingsStore(defaults: defaults).loadPersistedWindowRestoreCatalog() == catalog)
    }

    @Test func settingsStoreNormalizesWorkspaceConfigurationsLoadedFromFile() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let url = directory.appendingPathComponent("settings.toml", isDirectory: false)
        var export = SettingsExport.defaults()
        export.workspaceConfigurations = [
            WorkspaceConfiguration(name: "2", monitorAssignment: .main),
            WorkspaceConfiguration(name: "10", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", displayName: "Duplicate", monitorAssignment: .secondary),
            WorkspaceConfiguration(name: "abc", monitorAssignment: .main)
        ]
        try writeSettingsExport(export, to: url)

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.workspaceConfigurations.map(\.name) == ["2", "10"])
        #expect(settings.workspaceConfigurations.first?.monitorAssignment == .main)
    }

    @Test func quakeTerminalPercentSettingsNormalizeOnAssignmentAndImport() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.quakeTerminalWidthPercent = 5
        settings.quakeTerminalHeightPercent = 150

        #expect(settings.quakeTerminalWidthPercent == 10)
        #expect(settings.quakeTerminalHeightPercent == 100)

        var export = SettingsExport.defaults()
        export.quakeTerminalWidthPercent = Double.nan
        export.quakeTerminalHeightPercent = -Double.infinity
        settings.applyExport(export, monitors: [])

        #expect(settings.quakeTerminalWidthPercent == 50)
        #expect(settings.quakeTerminalHeightPercent == 50)
    }

    @Test func importedPartialHotkeyListKeepsNewUnassignedCatalogActionsVisible() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        var export = SettingsExport.defaults()
        export.hotkeyBindings = [
            HotkeyBinding(
                id: "focus.left",
                command: .focus(.left),
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
            )
        ]

        settings.applyExport(export, monitors: [])

        #expect(settings.hotkeyBindings.contains { $0.id == "focus.left" })
        #expect(settings.hotkeyBindings.contains { $0.id == "cycleMonitors" })
        #expect(settings.hotkeyBindings.first { $0.id == "cycleMonitors" }?.binding == .unassigned)
    }

    @Test func quakeTerminalCustomFrameRejectsInvalidPersistedGeometry() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 300)

        #expect(settings.quakeTerminalUseCustomFrame == false)
        #expect(settings.quakeTerminalCustomFrame == nil)

        var export = SettingsExport.defaults()
        export.quakeTerminalUseCustomFrame = true
        export.quakeTerminalCustomFrame = QuakeTerminalFrameExport(
            x: 0,
            y: 0,
            width: 70_000,
            height: 300
        )
        settings.applyExport(export, monitors: [])

        #expect(settings.quakeTerminalUseCustomFrame == false)
        #expect(settings.quakeTerminalCustomFrame == nil)
    }

    @Test func mouseWarpAxisRoundTripsThroughCanonicalSettingsFile() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.mouseWarpAxis = .vertical
        settings.flushNow()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.mouseWarpAxis == .vertical)
    }

    @Test func persistEffectiveMouseWarpMonitorOrderResolvesConnectedDisplaysWithoutMutatingStoredEntries() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let right = makeSettingsTestMonitor(displayId: 2, name: "Right", x: 1920)
        let left = makeSettingsTestMonitor(displayId: 1, name: "Left", x: 0)

        settings.mouseWarpMonitorOrder = [
            OutputId(displayId: 999, name: "Disconnected"),
            OutputId(from: left)
        ]

        let resolved = settings.persistEffectiveMouseWarpMonitorOrder(for: [right, left])

        #expect(settings.mouseWarpMonitorOrder == [
            OutputId(displayId: 999, name: "Disconnected"),
            OutputId(from: left)
        ])
        #expect(resolved == [left.id, right.id])
        #expect(settings.effectiveMouseWarpMonitorOrder(for: [left]) == [left.id])
    }

    @Test func effectiveMouseWarpMonitorOrderKeepsDuplicateNamesDistinctByOutputId() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let left = makeSettingsTestMonitor(displayId: 10, name: "Studio Display", x: 0)
        let right = makeSettingsTestMonitor(displayId: 20, name: "Studio Display", x: 1920)

        settings.mouseWarpMonitorOrder = [OutputId(from: right), OutputId(from: left)]

        #expect(settings.effectiveMouseWarpMonitorOrder(for: [left, right]) == [right.id, left.id])
    }

    @Test func rebindMonitorReferencesPreservesPersistedMouseWarpIdentityAcrossReconnect() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let stableUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let original = OutputId(displayUUID: stableUUID, displayId: 10, name: "Studio Display")
        let replacement = makeSettingsTestMonitor(
            displayId: 20,
            name: "Studio Display",
            x: 0,
            displayUUID: stableUUID
        )

        settings.mouseWarpMonitorOrder = [original]
        settings.rebindMonitorReferences(to: [replacement])

        #expect(settings.mouseWarpMonitorOrder == [original])
        #expect(settings.effectiveMouseWarpMonitorOrder(for: [replacement]) == [replacement.id])
    }

    @Test func outputIdEqualityIgnoresRuntimeDisplayIdWhenDisplayUUIDIsStable() {
        let first = OutputId(displayUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", displayId: 13, name: "")
        let second = OutputId(displayUUID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", displayId: 14, name: "DELL U2723QE")

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    @Test func topologyReconnectDoesNotMutateMouseWarpMonitorOrderOrSettingsFile() throws {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let stableUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let original = OutputId(displayUUID: stableUUID, displayId: 13, name: "")
        settings.mouseWarpMonitorOrder = [original]
        settings.flushNow()
        let before = try String(contentsOf: settings.settingsFileURL, encoding: .utf8)

        let manager = WorkspaceManager(settings: settings)
        let reconnected = makeSettingsTestMonitor(displayId: 14, name: "", displayUUID: stableUUID)
        manager.applyMonitorConfigurationChange([reconnected])
        settings.flushNow()
        let after = try String(contentsOf: settings.settingsFileURL, encoding: .utf8)

        #expect(settings.mouseWarpMonitorOrder == [original])
        #expect(settings.effectiveMouseWarpMonitorOrder(for: [reconnected]) == [reconnected.id])
        #expect(after == before)
    }

    @Test func rebindMonitorReferencesDoesNotCollapseDuplicateNamedOutputsOntoOneMonitor() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let first = OutputId(displayId: 10, name: "Studio Display")
        let second = OutputId(displayId: 20, name: "Studio Display")
        let replacement = makeSettingsTestMonitor(displayId: 30, name: "Studio Display", x: 0)

        settings.mouseWarpMonitorOrder = [first, second]
        settings.rebindMonitorReferences(to: [replacement])

        #expect(settings.mouseWarpMonitorOrder == [OutputId(from: replacement), second])
    }

    @Test func commitMouseWarpMonitorOrderPreservesDisconnectedEntriesInPlace() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let left = makeSettingsTestMonitor(displayId: 1, name: "Left", x: 0)
        let right = makeSettingsTestMonitor(displayId: 2, name: "Right", x: 1920)

        settings.mouseWarpMonitorOrder = [
            OutputId(from: left),
            OutputId(displayId: 999, name: "Disconnected"),
            OutputId(from: right)
        ]

        settings.commitMouseWarpMonitorOrder(
            orderedMonitorIds: [right.id, left.id],
            connectedMonitors: [left, right]
        )

        #expect(settings.mouseWarpMonitorOrder == [
            OutputId(from: right),
            OutputId(displayId: 999, name: "Disconnected"),
            OutputId(from: left)
        ])
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
        let originalModificationDate = try #require(
            settings.settingsFileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )

        let export = try SettingsTOMLCodec.decode(originalData)
        let sameDigitGapCandidates = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(Double.init)
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
}
