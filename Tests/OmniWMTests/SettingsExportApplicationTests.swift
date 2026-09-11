// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class SettingsExportApplicationTests: XCTestCase {
    func testCallbacksObserveTheirExistingApplicationPhases() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        settings.ipcEnabled = false
        settings.focus.followsMouse = false
        settings.gestures.scrollEnabled = false
        settings.gestures.workspaceSwipeEnabled = false
        settings.appearanceMode = .light
        var events: [String] = []
        settings.onIPCEnabledChanged = { enabled in
            events.append("ipc")
            XCTAssertTrue(enabled)
            XCTAssertTrue(settings.focus.followsMouse)
            XCTAssertFalse(settings.gestures.scrollEnabled)
            XCTAssertEqual(settings.appearanceMode, .light)
        }
        settings.onTrackpadGestureAvailabilityChanged = { available in
            events.append("gestures")
            XCTAssertTrue(available)
            XCTAssertTrue(settings.gestures.scrollEnabled)
            XCTAssertEqual(settings.appearanceMode, .dark)
        }
        defer {
            settings.onIPCEnabledChanged = nil
            settings.onTrackpadGestureAvailabilityChanged = nil
        }
        var export = settings.toExport()
        export.focus.followsMouse = true
        export.ipcEnabled = true
        export.gestures.scrollEnabled = true
        export.appearanceMode = .dark

        settings.applyExport(export)

        XCTAssertEqual(events, ["ipc", "gestures"])
    }

    func testGestureNotificationsResumeAfterExportApplication() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        settings.gestures.scrollEnabled = true
        settings.gestures.workspaceSwipeEnabled = false
        var states: [Bool] = []
        settings.onTrackpadGestureAvailabilityChanged = { states.append($0) }
        var export = settings.toExport()
        export.gestures.scrollEnabled = false
        export.gestures.workspaceSwipeEnabled = true

        settings.applyExport(export)
        XCTAssertTrue(states.isEmpty)
        export.gestures.workspaceSwipeEnabled = false
        settings.applyExport(export)
        XCTAssertEqual(states, [false])
        settings.gestures.scrollEnabled = true
        XCTAssertEqual(states, [false, true])
    }

    func testScratchpadObservationRemainsBetweenIconsAndLayout() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let events = Mutex<[String]>([])
        withObservationTracking {
            _ = settings.workspaceBar.iconOverrides
        } onChange: {
            events.withLock { $0.append("icons") }
        }
        withObservationTracking {
            _ = settings.scratchpadLabels
        } onChange: {
            events.withLock { $0.append("scratchpads") }
        }
        withObservationTracking {
            _ = settings.workspaceBar.reserveLayoutSpace
        } onChange: {
            events.withLock { $0.append("layout") }
        }
        var export = settings.toExport()
        export.workspaceBar.iconOverrides = ["example.test": "X"]
        export.scratchpads.labels = ["3": "DEV"]
        export.workspaceBar.reserveLayoutSpace.toggle()

        settings.applyExport(export)

        XCTAssertEqual(events.withLock { $0 }, ["icons", "scratchpads", "layout"])
        XCTAssertEqual(settings.workspaceBar.iconOverrides, export.workspaceBar.iconOverrides)
        XCTAssertEqual(settings.scratchpadLabel(for: 3), "DEV")
    }

    private func makeSettings(directory: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
    }
}
