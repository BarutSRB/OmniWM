// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalScreenSelectionTests: XCTestCase {
    func testMainMonitorSelectsLowerPrimaryDespiteUpperKeyboardFocus() {
        let primary = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let secondary = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController()
        var monitorSnapshotCalls = 0
        func monitorSnapshot() -> [Monitor] {
            monitorSnapshotCalls += 1
            return []
        }

        for focusedScreen in [secondary, primary, secondary] {
            XCTAssertTrue(
                controller.targetScreen(
                    screens: [primary, secondary],
                    mainScreen: focusedScreen,
                    monitors: monitorSnapshot()
                ) === primary
            )
        }
        XCTAssertEqual(monitorSnapshotCalls, 0)
    }

    func testMainMonitorUsesUpdatedPrimaryScreenOrder() {
        let first = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let second = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController()

        XCTAssertTrue(controller.targetScreen(screens: [first, second], mainScreen: first) === first)
        XCTAssertTrue(controller.targetScreen(screens: [second, first], mainScreen: first) === second)
    }

    func testMainMonitorSelectsOnlyScreenWithoutKeyboardFocus() {
        let screen = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = makeController()

        XCTAssertTrue(controller.targetScreen(screens: [screen], mainScreen: nil) === screen)
    }

    func testMainMonitorFallsBackWhenScreenListIsUnavailable() {
        let screen = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = makeController()

        XCTAssertTrue(controller.targetScreen(screens: [], mainScreen: screen) === screen)
    }

    func testMainMonitorFollowsMonitorRankingWhenSet() {
        let builtIn = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let dell = Screen(frame: CGRect(x: 1440, y: 0, width: 3440, height: 1440))
        let lg = Screen(frame: CGRect(x: 4880, y: 0, width: 2560, height: 1440))
        let monitors = [
            makeMonitor(id: 1, frame: builtIn.frame, name: "Built-in Retina Display"),
            makeMonitor(id: 2, frame: dell.frame, name: "DELL U3423WE"),
            makeMonitor(id: 3, frame: lg.frame, name: "LG HDR 4K")
        ]
        let controller = makeController(ranking: [OutputId(from: monitors[2]), OutputId(from: monitors[1])])
        var connectedMonitors = monitors
        var monitorSnapshotCalls = 0
        func monitorSnapshot() -> [Monitor] {
            monitorSnapshotCalls += 1
            return connectedMonitors
        }

        XCTAssertTrue(
            controller
                .targetScreen(screens: [builtIn, dell, lg], mainScreen: builtIn, monitors: monitorSnapshot()) === lg
        )
        XCTAssertEqual(monitorSnapshotCalls, 1)

        connectedMonitors = Array(monitors.prefix(2))
        XCTAssertTrue(
            controller.targetScreen(
                screens: [builtIn, dell],
                mainScreen: builtIn,
                monitors: monitorSnapshot()
            ) === dell
        )
        XCTAssertEqual(monitorSnapshotCalls, 2)
    }

    func testMainMonitorFallsBackToFirstScreenWhenNoRankedMonitorIsConnected() {
        let builtIn = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let monitors = [makeMonitor(id: 1, frame: builtIn.frame, name: "Built-in Retina Display")]
        let controller = makeController(ranking: [OutputId(name: "LG HDR 4K")])

        XCTAssertTrue(controller.targetScreen(screens: [builtIn], mainScreen: nil, monitors: monitors) === builtIn)
    }

    func testFocusedWindowModePreservesProvidedSecondaryScreen() {
        let primary = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let secondary = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController(mode: .focusedWindow, focusedWindowScreenProvider: { secondary })
        var monitorSnapshotCalls = 0
        func monitorSnapshot() -> [Monitor] {
            monitorSnapshotCalls += 1
            return []
        }

        XCTAssertTrue(
            controller.targetScreen(
                screens: [primary, secondary],
                mainScreen: primary,
                monitors: monitorSnapshot()
            ) === secondary
        )
        XCTAssertEqual(monitorSnapshotCalls, 0)
    }

    func testMouseAndFocusedFallbackModesReadMonitorSnapshotOnce() {
        let screen = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))

        for mode in [QuakeTerminalMonitorMode.mouseCursor, .focusedWindow] {
            let controller = makeController(mode: mode)
            var monitorSnapshotCalls = 0
            func monitorSnapshot() -> [Monitor] {
                monitorSnapshotCalls += 1
                return []
            }

            XCTAssertTrue(
                controller.targetScreen(screens: [screen], mainScreen: screen, monitors: monitorSnapshot()) === screen
            )
            XCTAssertEqual(monitorSnapshotCalls, 1, "\(mode)")
        }
    }

    private func makeMonitor(id: CGDirectDisplayID, frame: CGRect, name: String) -> Monitor {
        return Monitor(
            id: Monitor.ID(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func makeController(
        mode: QuakeTerminalMonitorMode = .mainMonitor,
        ranking: [OutputId] = [],
        focusedWindowScreenProvider: @escaping @MainActor () -> NSScreen? = { nil }
    ) -> QuakeTerminalController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeScreenTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
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
        settings.quakeTerminal.monitorMode = mode
        settings.monitors.ranking = ranking
        return QuakeTerminalController(
            settings: settings,
            motionPolicy: MotionPolicy(),
            focusedWindowScreenProvider: focusedWindowScreenProvider
        )
    }

    private final class Screen: NSScreen {
        private let screenFrame: CGRect

        init(frame: CGRect) {
            screenFrame = frame
            super.init()
        }

        override var frame: CGRect {
            screenFrame
        }
    }
}
