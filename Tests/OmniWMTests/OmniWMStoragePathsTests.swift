// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class OmniWMStoragePathsTests: XCTestCase {
    func testOnlySupportedDevBundleUsesDevDirectories() {
        let home = URL(fileURLWithPath: "/Users/contributor", isDirectory: true)
        let cases: [(String?, String)] = [
            (nil, "omniwm"),
            ("com.barut.OmniWM", "omniwm"),
            ("com.example.Other.dev", "omniwm"),
            ("com.barut.OmniWM.dev", "omniwm-dev")
        ]

        for (bundleIdentifier, directory) in cases {
            let paths = OmniWMStoragePaths.resolve(
                environment: [:],
                homeDirectory: home,
                bundleIdentifier: bundleIdentifier
            )
            XCTAssertEqual(paths.configDirectory.path, "/Users/contributor/.config/\(directory)")
            XCTAssertEqual(paths.stateDirectory.path, "/Users/contributor/.local/state/\(directory)")
            XCTAssertEqual(paths.diagnosticsDirectory.path, "/Users/contributor/.local/state/\(directory)/diagnostics")
        }
    }

    func testAbsoluteXDGOverridesKeepReleaseAndDevSeparate() {
        for (bundleIdentifier, directory) in [("com.barut.OmniWM", "omniwm"), ("com.barut.OmniWM.dev", "omniwm-dev")] {
            let paths = OmniWMStoragePaths.resolve(
                environment: ["XDG_CONFIG_HOME": "/custom/config/", "XDG_STATE_HOME": "/custom/state/"],
                homeDirectory: URL(fileURLWithPath: "/Users/contributor", isDirectory: true),
                bundleIdentifier: bundleIdentifier
            )

            XCTAssertEqual(paths.configDirectory.path, "/custom/config/\(directory)")
            XCTAssertEqual(paths.stateDirectory.path, "/custom/state/\(directory)")
        }
    }

    func testInvalidXDGOverridesUseDefaultBaseDirectories() {
        for bundleIdentifier in ["com.barut.OmniWM", "com.barut.OmniWM.dev"] {
            for invalidPath in ["", "relative/path", "~/custom"] {
                let home = URL(fileURLWithPath: "/Users/contributor", isDirectory: true)
                let paths = OmniWMStoragePaths.resolve(
                    environment: ["XDG_CONFIG_HOME": invalidPath, "XDG_STATE_HOME": invalidPath],
                    homeDirectory: home,
                    bundleIdentifier: bundleIdentifier
                )
                let defaults = OmniWMStoragePaths.resolve(
                    environment: [:],
                    homeDirectory: home,
                    bundleIdentifier: bundleIdentifier
                )

                XCTAssertEqual(paths, defaults, invalidPath)
            }
        }
    }

    @MainActor
    func testReleaseAndDevPersistSettingsAndStateIndependently() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMStoragePathsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let releasePaths = OmniWMStoragePaths.resolve(environment: [:], homeDirectory: home)
        let devPaths = OmniWMStoragePaths.resolve(
            environment: [:],
            homeDirectory: home,
            bundleIdentifier: "com.barut.OmniWM.dev"
        )
        let releaseSettings = SettingsFilePersistence(
            directory: releasePaths.configDirectory, startWatching: false, deferSaves: false
        )
        let devSettings = SettingsFilePersistence(
            directory: devPaths.configDirectory, startWatching: false, deferSaves: false
        )
        var releaseExport = releaseSettings.load()
        releaseExport.gaps.size = 12
        try releaseSettings.saveImmediately(releaseExport)
        var devExport = devSettings.load()
        devExport.gaps.size = 24
        try devSettings.saveImmediately(devExport)

        XCTAssertEqual(releaseSettings.load().gaps.size, 12)
        XCTAssertEqual(devSettings.load().gaps.size, 24)

        let releaseState = RuntimeStateStore(directory: releasePaths.stateDirectory, deferSaves: false)
        releaseState.updaterSkippedReleaseTag = "release"
        let devState = RuntimeStateStore(directory: devPaths.stateDirectory, deferSaves: false)
        XCTAssertNil(devState.updaterSkippedReleaseTag)
        devState.updaterSkippedReleaseTag = "dev"

        XCTAssertEqual(
            RuntimeStateStore(directory: releasePaths.stateDirectory, deferSaves: false).updaterSkippedReleaseTag,
            "release"
        )
        XCTAssertEqual(
            RuntimeStateStore(directory: devPaths.stateDirectory, deferSaves: false).updaterSkippedReleaseTag,
            "dev"
        )
    }
}
