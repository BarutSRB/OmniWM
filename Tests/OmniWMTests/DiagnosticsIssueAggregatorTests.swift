// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DiagnosticsIssueAggregatorTests: XCTestCase {
    private let commandPaletteAdvisoryID = "hotkey-advisory:openCommandPalette"

    func testAggregatorSurfacesHotkeyAdvisoryAtDefaultsAndDropsWhenUnassigned() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        settings.hotkeyBindings = HotkeyBindingRegistry.defaults()
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)

        let atDefaults = DiagnosticsIssueAggregator.applicableIssues(controller: controller)
        XCTAssertTrue(atDefaults.contains { $0.id == commandPaletteAdvisoryID })

        var reassigned = HotkeyBindingRegistry.defaults()
        if let index = reassigned.firstIndex(where: { $0.id == "openCommandPalette" }) {
            reassigned[index].binding = .unassigned
        }
        settings.hotkeyBindings = reassigned

        let afterUnassign = DiagnosticsIssueAggregator.applicableIssues(controller: controller)
        XCTAssertFalse(afterUnassign.contains { $0.id == commandPaletteAdvisoryID })
    }

    func testUpdatingHotkeyBindingsRefreshesStoredAdvisory() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        settings.hotkeyBindings = HotkeyBindingRegistry.defaults()
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)

        controller.refreshDiagnosticsIssues()
        XCTAssertTrue(controller.diagnosticsIssues.contains { $0.id == commandPaletteAdvisoryID })

        settings.updateTrigger(
            for: "openCommandPalette",
            newTrigger: .chord(
                KeyBinding(
                    keyCode: UInt32(kVK_ANSI_P),
                    modifiers: UInt32(controlKey | optionKey)
                )
            )
        )
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        XCTAssertFalse(controller.diagnosticsIssues.contains { $0.id == commandPaletteAdvisoryID })

        settings.resetBindings(for: "openCommandPalette")
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        XCTAssertTrue(controller.diagnosticsIssues.contains { $0.id == commandPaletteAdvisoryID })
    }

    func testAggregatorIsDeterministicAcrossCalls() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let first = DiagnosticsIssueAggregator.applicableIssues(controller: controller)
        let second = DiagnosticsIssueAggregator.applicableIssues(controller: controller)
        XCTAssertEqual(first, second)
    }

    func testRefreshDiagnosticsIssuesMatchesAggregator() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        XCTAssertTrue(controller.diagnosticsIssues.isEmpty)
        controller.refreshDiagnosticsIssues()
        XCTAssertEqual(
            controller.diagnosticsIssues,
            DiagnosticsIssueAggregator.applicableIssues(controller: controller)
        )
    }

    private func makeDiagnosticsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsAggregator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
