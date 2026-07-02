// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ConfigDiagnosticsTests: XCTestCase {
    @MainActor
    func testDefaultConfigHasNoUnknownKeys() throws {
        let data = try SettingsTOMLCodec.encode(makeExport())
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: data), [])
    }

    @MainActor
    func testBogusKeyDetected() throws {
        let base = String(decoding: try SettingsTOMLCodec.encode(makeExport()), as: UTF8.self)
        let data = Data(("bogusKey = 1\n" + base).utf8)
        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: data).contains("bogusKey"))
    }

    func testEmptyDataHasNoUnknownKeys() {
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: Data()), [])
    }

    @MainActor
    func testUnknownKeyInsideAppRuleArrayDetected() {
        let toml = """
        [[appRules]]
        bundleId = "com.example.app"
        bogusRuleKey = true
        """
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: Data(toml.utf8)), ["appRules[0].bogusRuleKey"])
    }

    @MainActor
    private func makeExport() -> SettingsExport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMConfigDiagTests-\(UUID().uuidString)", isDirectory: true)
        let store = SettingsStore(
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
        return store.toExport()
    }
}
