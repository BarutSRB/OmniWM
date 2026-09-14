// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import os
import XCTest

@MainActor
final class QuakeGhosttyRuntimeTests: XCTestCase {
    func testRepeatedCleanupBeforeStartupKeepsRuntimeAndWindowUninitialized() {
        let controller = makeController()
        let runtime = controller.ghosttyRuntime

        for _ in 0 ..< 2 {
            controller.cleanup()

            XCTAssertNil(controller.window)
            XCTAssertFalse(controller.visible)
            XCTAssertNil(runtime.makeSurfaceView(for: controller))
        }
    }

    func testConfigurationCreationFailureCanRetryWithoutCreatingSurfaceOrWindow() {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        var operations = QuakeGhosttyConfigOperations.live
        operations.makeConfig = {
            attempts.withLock { $0 += 1 }
            return nil
        }
        let controller = makeController(configBuilder: QuakeGhosttyConfigBuilder(operations: operations))

        for expectedAttempts in 1 ... 2 {
            XCTAssertFalse(controller.ghosttyRuntime.startIfNeeded(for: controller))
            XCTAssertEqual(attempts.withLock { $0 }, expectedAttempts)
            XCTAssertNil(controller.ghosttyRuntime.makeSurfaceView(for: controller))
            XCTAssertNil(controller.window)
            XCTAssertFalse(controller.visible)
            controller.cleanup()
        }
    }

    private func makeController(configBuilder: QuakeGhosttyConfigBuilder = QuakeGhosttyConfigBuilder())
        -> QuakeTerminalController
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeRuntimeTests-\(UUID().uuidString)", isDirectory: true)
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
        return QuakeTerminalController(
            settings: settings,
            motionPolicy: MotionPolicy(),
            ghosttyConfigBuilder: configBuilder
        )
    }
}
