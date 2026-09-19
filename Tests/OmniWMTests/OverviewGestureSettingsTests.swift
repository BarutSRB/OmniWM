// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewGestureSettingsTests: XCTestCase {
    func testRejectedOverviewEnableDoesNotChangeSettingsOrNotify() {
        withSettings { settings in
            let monitor = makeMonitor(orientation: .vertical)
            configureColumnAndOverview(settings, overviewEnabled: false)
            let original = settings.gestures.export()
            var changes = 0
            var availability: [Bool] = []
            settings.gestures.onChange = { changes += 1 }
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }
            var candidate = original
            candidate.overviewGestureEnabled = true

            let conflict = settings.updateGestureSettings(candidate, monitors: [monitor])

            XCTAssertNotNil(conflict)
            XCTAssertEqual(settings.gestures.export(), original)
            XCTAssertEqual(changes, 0)
            XCTAssertTrue(availability.isEmpty)
        }
    }

    func testRejectedOverviewFingerChangeRetainsPreviouslyValidAssignment() {
        withSettings { settings in
            configureColumnAndOverview(settings)
            settings.gestures.overviewGestureFingerCount = .three
            var candidate = settings.gestures.export()
            candidate.overviewGestureFingerCount = .four

            XCTAssertNotNil(settings.updateGestureSettings(candidate, monitors: [makeMonitor(orientation: .vertical)]))
            XCTAssertEqual(settings.gestures.overviewGestureFingerCount, .three)
        }
    }

    func testRejectedWorkspaceEditsRetainEnabledFingerAndAxisValues() {
        withSettings { settings in
            settings.gestures.scrollEnabled = false
            settings.gestures.overviewGestureEnabled = true
            settings.gestures.overviewGestureFingerCount = .four
            settings.gestures.workspaceSwipeEnabled = false
            settings.gestures.workspaceSwipeFingerCount = .four
            settings.gestures.workspaceSwipeAxis = .vertical
            var candidate = settings.gestures.export()
            candidate.workspaceSwipeEnabled = true
            XCTAssertNotNil(settings.updateGestureSettings(candidate, monitors: []))
            XCTAssertFalse(settings.gestures.workspaceSwipeEnabled)

            settings.gestures.workspaceSwipeFingerCount = .three
            settings.gestures.workspaceSwipeEnabled = true
            candidate = settings.gestures.export()
            candidate.workspaceSwipeFingerCount = .four
            XCTAssertNotNil(settings.updateGestureSettings(candidate, monitors: []))
            XCTAssertEqual(settings.gestures.workspaceSwipeFingerCount, .three)

            settings.gestures.workspaceSwipeAxis = .horizontal
            settings.gestures.workspaceSwipeFingerCount = .four
            candidate = settings.gestures.export()
            candidate.workspaceSwipeAxis = .vertical
            XCTAssertNotNil(settings.updateGestureSettings(candidate, monitors: []))
            XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .horizontal)
        }
    }

    func testColumnEnableCannotForceWorkspaceSwipeIntoOverviewAssignment() {
        withSettings { settings in
            configureColumnAndOverview(settings)
            settings.gestures.scrollEnabled = false
            settings.gestures.workspaceSwipeEnabled = true
            settings.gestures.workspaceSwipeFingerCount = .four
            settings.gestures.workspaceSwipeAxis = .horizontal
            let original = settings.gestures.export()
            var candidate = original
            candidate.scrollEnabled = true

            XCTAssertNotNil(settings.updateGestureSettings(
                candidate,
                monitors: [makeMonitor(orientation: .horizontal)]
            ))
            XCTAssertEqual(settings.gestures.export(), original)
        }
    }

    func testHorizontalColumnAndOverviewCanShareFingers() {
        withSettings { settings in
            configureColumnAndOverview(settings, overviewEnabled: false)
            var candidate = settings.gestures.export()
            candidate.overviewGestureEnabled = true

            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: [makeMonitor(orientation: .horizontal)]))
            XCTAssertEqual(settings.gestures.export(), candidate)
        }
    }

    func testRejectedOrientationOverrideDoesNotChangeSettingsOrNotify() {
        withSettings { settings in
            let monitor = makeMonitor(orientation: .horizontal)
            configureColumnAndOverview(settings)
            let original = settings.monitors.orientationOverrides
            var changes = 0
            var availability: [Bool] = []
            settings.monitors.onChange = { changes += 1 }
            settings.gestures.onChange = { changes += 1 }
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

            XCTAssertNotNil(settings.updateMonitorOrientation(.vertical, for: monitor, monitors: [monitor]))
            XCTAssertEqual(settings.monitors.orientationOverrides, original)
            XCTAssertEqual(changes, 0)
            XCTAssertTrue(availability.isEmpty)
        }
    }

    func testRejectedResetToAutoRetainsHorizontalOverride() {
        withSettings { settings in
            let monitor = makeMonitor(orientation: .vertical)
            configureColumnAndOverview(settings)
            settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(monitorName: monitor.name, orientation: .horizontal),
                for: monitor
            )
            let original = settings.monitors.orientationOverrides
            var changes = 0
            settings.monitors.onChange = { changes += 1 }

            XCTAssertNotNil(settings.updateMonitorOrientation(nil, for: monitor, monitors: [monitor]))
            XCTAssertEqual(settings.monitors.orientationOverrides, original)
            XCTAssertEqual(changes, 0)
        }
    }

    func testValidOrientationOverrideAndResetApplyOnceEach() {
        withSettings { settings in
            let monitor = makeMonitor(orientation: .horizontal)
            configureColumnAndOverview(settings)
            settings.gestures.overviewGestureFingerCount = .three
            var changes = 0
            settings.monitors.onChange = { changes += 1 }

            XCTAssertNil(settings.updateMonitorOrientation(.vertical, for: monitor, monitors: [monitor]))
            XCTAssertEqual(settings.monitors.effectiveOrientation(for: monitor), .vertical)
            XCTAssertEqual(changes, 1)
            XCTAssertNil(settings.updateMonitorOrientation(nil, for: monitor, monitors: [monitor]))
            XCTAssertEqual(settings.monitors.effectiveOrientation(for: monitor), .horizontal)
            XCTAssertTrue(settings.monitors.orientationOverrides.isEmpty)
            XCTAssertEqual(changes, 2)
        }
    }

    func testDisableThenReassignRemainsPossible() {
        withSettings { settings in
            let monitors = [makeMonitor(orientation: .vertical)]
            configureColumnAndOverview(settings)
            settings.gestures.overviewGestureFingerCount = .three
            var availability: [Bool] = []
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }
            var candidate = settings.gestures.export()
            candidate.overviewGestureEnabled = false
            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: monitors))
            candidate.overviewGestureFingerCount = .four
            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: monitors))
            candidate.scrollEnabled = false
            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: monitors))
            candidate.overviewGestureEnabled = true
            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: monitors))
            XCTAssertEqual(settings.gestures.export(), candidate)
            XCTAssertEqual(availability, [false, true])
        }
    }

    func testDisablingGestureIsAllowedWhenChangedMonitorContextHasAnotherConflict() {
        withSettings { settings in
            configureColumnAndOverview(settings)
            settings.gestures.workspaceSwipeEnabled = true
            settings.gestures.workspaceSwipeFingerCount = .three
            var candidate = settings.gestures.export()
            candidate.workspaceSwipeEnabled = false

            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: [makeMonitor(orientation: .vertical)]))
            XCTAssertFalse(settings.gestures.workspaceSwipeEnabled)
            candidate.overviewGestureEnabled = false
            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: [makeMonitor(orientation: .vertical)]))
            XCTAssertFalse(settings.gestures.overviewGestureEnabled)
        }
    }

    private func configureColumnAndOverview(_ settings: SettingsStore, overviewEnabled: Bool = true) {
        settings.gestures.scrollEnabled = true
        settings.gestures.fingerCount = .four
        settings.gestures.workspaceSwipeEnabled = false
        settings.gestures.overviewGestureEnabled = overviewEnabled
        settings.gestures.overviewGestureFingerCount = .four
    }

    private func withSettings(_ body: (SettingsStore) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
        body(settings)
    }

    private func makeMonitor(orientation: Monitor.Orientation) -> Monitor {
        let frame = CGRect(
            x: 0,
            y: 0,
            width: orientation == .horizontal ? 1920 : 1080,
            height: orientation == .horizontal ? 1080 : 1920
        )
        return Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Display"
        )
    }
}
