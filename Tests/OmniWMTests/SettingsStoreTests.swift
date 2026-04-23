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
    to url: URL,
    preserveVersion: Bool = false
) throws {
    var canonical = export
    if !preserveVersion {
        canonical.version = SettingsFilePersistence.configVersion
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try SettingsTOMLCodec.encode(canonical).write(to: url, options: .atomic)
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

    @Test func monitorLookupPrefersDisplayIdOverNameFallback() {
        let monitor = makeSettingsTestMonitor(displayId: 42, name: "Studio Display")
        let settings = [
            MonitorNiriSettings(monitorName: "Studio Display", maxVisibleColumns: 1),
            MonitorNiriSettings(monitorName: "Studio Display", monitorDisplayId: 42, maxVisibleColumns: 3),
        ]

        let result = MonitorSettingsStore.get(for: monitor, in: settings)
        #expect(result?.maxVisibleColumns == 3)
    }

    @Test func rebindPromotesLegacyNameEntryToDisplayId() {
        let monitor = makeSettingsTestMonitor(displayId: 99, name: "Legacy")
        let settings = [
            MonitorNiriSettings(monitorName: "Legacy", maxVisibleColumns: 2),
        ]

        let rebound = MonitorSettingsStore.rebound(settings, to: [monitor])
        #expect(rebound.first?.monitorDisplayId == 99)
        #expect(rebound.first?.monitorName == "Legacy")
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

    @Test func unsupportedSchemaVersionIsRenamedAsideAndReplacedWithDefaults() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        let url = directory.appendingPathComponent("settings.toml", isDirectory: false)
        var export = SettingsExport.defaults()
        export.version = SettingsFilePersistence.configVersion + 1
        try writeSettingsExport(export, to: url, preserveVersion: true)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let loaded = persistence.load()
        let corruptURL = directory.appendingPathComponent("settings.toml.corrupt", isDirectory: false)

        #expect(loaded == SettingsExport.defaults())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
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

    @Test func legacySettingsJsonIsIgnoredWhenTomlMissing() throws {
        let defaults = makeTestDefaults()
        let directory = configurationDirectoryForTests(defaults: defaults)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJsonURL = directory.appendingPathComponent("settings.json", isDirectory: false)
        let tomlURL = directory.appendingPathComponent("settings.toml", isDirectory: false)
        let legacyJsonPayload = #"{"version": 4, "hotkeysEnabled": false}"#
        try Data(legacyJsonPayload.utf8).write(to: legacyJsonURL)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let export = persistence.load()

        #expect(export == SettingsExport.defaults())
        #expect(FileManager.default.fileExists(atPath: tomlURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyJsonURL.path))
        let legacyContents = try String(contentsOf: legacyJsonURL, encoding: .utf8)
        #expect(legacyContents == legacyJsonPayload)
    }
}

@Suite @MainActor struct SettingsStorePersistenceTests {
    @Test func settingsChangesRoundTripThroughCanonicalSettingsFile() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let output = OutputId(displayId: 777, name: "Studio Display")

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

    @Test func missingCanonicalFileIgnoresLegacyDefaultsKeys() {
        let defaults = makeTestDefaults()
        defaults.set(true, forKey: "settings.focusFollowsWindowToMonitor")
        defaults.set(false, forKey: "settings.hotkeysEnabled")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.focusFollowsWindowToMonitor == SettingsExport.defaults().focusFollowsWindowToMonitor)
        #expect(settings.hotkeysEnabled == SettingsExport.defaults().hotkeysEnabled)
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

    @Test func rebindMonitorReferencesUpdatesMouseWarpMonitorOrderToReplacementOutputIdentity() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let original = OutputId(displayId: 10, name: "Studio Display")
        let replacement = makeSettingsTestMonitor(displayId: 20, name: "Studio Display", x: 0)

        settings.mouseWarpMonitorOrder = [original]
        settings.rebindMonitorReferences(to: [replacement])

        #expect(settings.mouseWarpMonitorOrder == [OutputId(from: replacement)])
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

@Suite struct CodableBackwardCompatTests {
    @Test func monitorNiriDecodesLegacyStringFields() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "centerFocusedColumn": "always",
            "singleWindowAspectRatio": "4:3"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorNiriSettings.self, from: Data(json.utf8))
        #expect(decoded.centerFocusedColumn == .always)
        #expect(decoded.singleWindowAspectRatio == .ratio4x3)
    }

    @Test func monitorNiriDecodesUnknownEnumAsNil() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "centerFocusedColumn": "futureValue",
            "singleWindowAspectRatio": "99:1"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorNiriSettings.self, from: Data(json.utf8))
        #expect(decoded.centerFocusedColumn == nil)
        #expect(decoded.singleWindowAspectRatio == nil)
    }

    @Test func monitorBarDecodesUnknownPositionAsNil() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "position": "unknownPosition",
            "windowLevel": "unknownLevel"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorBarSettings.self, from: Data(json.utf8))
        #expect(decoded.position == nil)
        #expect(decoded.windowLevel == nil)
    }

    @Test func monitorDwindleDecodesUnknownRatioAsNil() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "monitorName": "Test",
            "singleWindowAspectRatio": "unknownRatio"
        }
        """
        let decoded = try JSONDecoder().decode(MonitorDwindleSettings.self, from: Data(json.utf8))
        #expect(decoded.singleWindowAspectRatio == nil)
    }
}
