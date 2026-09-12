// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class StatusBarOwnerLifetimeTests: XCTestCase {
    func testRetainedReadOnlySectionOutlivesStoreWithoutRetainingIt() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var releasedStore: SettingsStore?
        let section: StatusBarSettings
        do {
            let settings = SettingsStore(
                persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
                runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
                autosaveEnabled: false
            )
            settings.setStatusBarShowWorkspaceName(true)
            releasedStore = settings
            section = settings.statusBar
        }

        XCTAssertNil(releasedStore)
        XCTAssertTrue(section.showWorkspaceName)
        XCTAssertTrue(section.export().showWorkspaceName)
    }
}
