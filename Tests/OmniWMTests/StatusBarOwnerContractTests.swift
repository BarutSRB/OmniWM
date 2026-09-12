// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Observation
@testable import OmniWM
import SwiftUI
import Synchronization
import XCTest

@MainActor
final class StatusBarOwnerContractTests: XCTestCase {
    func testBindingsUpdateOnlyTheirFieldAndSaveSynchronously() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let workspace = workspaceBinding(settings)
        let appNames = appNamesBinding(settings)
        let workspaceId = workspaceIdBinding(settings)
        let changes = Mutex<[String]>([])
        withObservationTracking {
            _ = settings.statusBar.showWorkspaceName
        } onChange: {
            changes.withLock { $0.append("workspace") }
        }
        withObservationTracking {
            _ = settings.statusBar.showAppNames
        } onChange: {
            changes.withLock { $0.append("appNames") }
        }
        withObservationTracking {
            _ = settings.statusBar.useWorkspaceId
        } onChange: {
            changes.withLock { $0.append("workspaceId") }
        }

        workspace.wrappedValue = true
        XCTAssertEqual(changes.withLock { $0 }, ["workspace"])
        XCTAssertFalse(appNames.wrappedValue)
        XCTAssertFalse(workspaceId.wrappedValue)
        XCTAssertEqual(try savedExport(settings), settings.toExport())
        appNames.wrappedValue = true
        XCTAssertEqual(changes.withLock { $0 }, ["workspace", "appNames"])
        XCTAssertFalse(workspaceId.wrappedValue)
        XCTAssertEqual(try savedExport(settings), settings.toExport())
        workspaceId.wrappedValue = true
        XCTAssertEqual(changes.withLock { $0 }, ["workspace", "appNames", "workspaceId"])
        XCTAssertEqual(try savedExport(settings), settings.toExport())
    }

    func testRetainedBindingsReadImportedValuesBeforeTheNextSynchronousSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let workspace = workspaceBinding(settings)
        let appNames = appNamesBinding(settings)
        let workspaceId = workspaceIdBinding(settings)
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        var desired = settings.toExport()
        desired.statusBar = SettingsExport.StatusBar(
            showWorkspaceName: true,
            showAppNames: true,
            useWorkspaceId: true
        )

        settings.applyExport(desired)

        XCTAssertTrue(workspace.wrappedValue)
        XCTAssertTrue(appNames.wrappedValue)
        XCTAssertTrue(workspaceId.wrappedValue)
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
        workspaceId.wrappedValue = false
        desired.statusBar.useWorkspaceId = false
        XCTAssertEqual(try savedExport(settings), desired)
    }

    func testBindingRetainsItsMutationOwnerUntilReleased() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var owner: SettingsStore?
        var binding: Binding<Bool>?
        var fileURL: URL?
        do {
            let settings = makeSettings(directory: directory)
            owner = settings
            fileURL = settings.settingsFileURL
            binding = workspaceBinding(settings)
        }

        XCTAssertNotNil(owner)
        XCTAssertEqual(binding?.wrappedValue, false)
        binding?.wrappedValue = true
        let saved = try SettingsTOMLCodec.decode(Data(contentsOf: XCTUnwrap(fileURL)))
        XCTAssertTrue(saved.statusBar.showWorkspaceName)
        binding = nil
        XCTAssertNil(owner)
    }

    func testBindingObserverInvalidatesBeforeTheSynchronousSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let binding = workspaceBinding(settings)
        let fileURL = settings.settingsFileURL
        let originalData = try Data(contentsOf: fileURL)
        let observedData = Mutex<Data?>(nil)
        withObservationTracking {
            _ = settings.statusBar.showWorkspaceName
        } onChange: {
            observedData.withLock { $0 = try? Data(contentsOf: fileURL) }
        }

        binding.wrappedValue = true

        XCTAssertEqual(observedData.withLock { $0 }, originalData)
        XCTAssertTrue(try savedExport(settings).statusBar.showWorkspaceName)
    }

    private func workspaceBinding(_ settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { [settings] in settings.statusBar.showWorkspaceName },
            set: { [settings] in settings.setStatusBarShowWorkspaceName($0) }
        )
    }

    private func appNamesBinding(_ settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { [settings] in settings.statusBar.showAppNames },
            set: { [settings] in settings.setStatusBarShowAppNames($0) }
        )
    }

    private func workspaceIdBinding(_ settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { [settings] in settings.statusBar.useWorkspaceId },
            set: { [settings] in settings.setStatusBarUseWorkspaceId($0) }
        )
    }

    private func savedExport(_ settings: SettingsStore) throws -> SettingsExport {
        try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
    }

    private func makeSettings(directory: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: true
        )
    }
}
