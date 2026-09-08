// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalScreenSelectionTests: XCTestCase {
    func testMainMonitorSelectsLowerPrimaryDespiteUpperKeyboardFocus() {
        let primary = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let secondary = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController()

        for focusedScreen in [secondary, primary, secondary] {
            XCTAssertTrue(controller.targetScreen(screens: [primary, secondary], mainScreen: focusedScreen) === primary)
        }
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
        let builtIn = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), displayId: 1)
        let dell = Screen(frame: CGRect(x: 1440, y: 0, width: 3440, height: 1440), displayId: 2)
        let lg = Screen(frame: CGRect(x: 4880, y: 0, width: 2560, height: 1440), displayId: 3)
        let monitors = [
            makeMonitor(id: 1, x: 0, name: "Built-in Retina Display"),
            makeMonitor(id: 2, x: 1440, name: "DELL U3423WE"),
            makeMonitor(id: 3, x: 4880, name: "LG HDR 4K")
        ]
        let controller = makeController(ranking: [OutputId(from: monitors[2]), OutputId(from: monitors[1])])

        XCTAssertTrue(
            controller.targetScreen(screens: [builtIn, dell, lg], mainScreen: builtIn, monitors: monitors) === lg
        )
        XCTAssertTrue(
            controller.targetScreen(
                screens: [builtIn, dell],
                mainScreen: builtIn,
                monitors: Array(monitors.prefix(2))
            ) === dell
        )
    }

    func testMainMonitorFallsBackToFirstScreenWhenNoRankedMonitorIsConnected() {
        let builtIn = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), displayId: 1)
        let monitors = [makeMonitor(id: 1, x: 0, name: "Built-in Retina Display")]
        let controller = makeController(ranking: [OutputId(name: "LG HDR 4K")])

        XCTAssertTrue(controller.targetScreen(screens: [builtIn], mainScreen: nil, monitors: monitors) === builtIn)
    }

    func testFocusedWindowModePreservesProvidedSecondaryScreen() {
        let primary = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let secondary = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController(mode: .focusedWindow, focusedWindowScreenProvider: { secondary })

        XCTAssertTrue(controller.targetScreen(screens: [primary, secondary], mainScreen: primary) === secondary)
    }

    private func makeMonitor(id: CGDirectDisplayID, x: CGFloat, name: String) -> Monitor {
        let frame = CGRect(x: x, y: 0, width: 1440, height: 900)
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
        settings.quakeTerminalMonitorMode = mode
        settings.monitorRanking = ranking
        return QuakeTerminalController(
            settings: settings,
            motionPolicy: MotionPolicy(),
            focusedWindowScreenProvider: focusedWindowScreenProvider
        )
    }

    private final class Screen: NSScreen {
        private let screenFrame: CGRect
        private let screenDisplayId: CGDirectDisplayID?

        init(frame: CGRect, displayId: CGDirectDisplayID? = nil) {
            screenFrame = frame
            screenDisplayId = displayId
            super.init()
        }

        override var frame: CGRect {
            screenFrame
        }

        override var deviceDescription: [NSDeviceDescriptionKey: Any] {
            guard let screenDisplayId else { return [:] }
            return [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: screenDisplayId)]
        }
    }
}
