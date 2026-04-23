// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) @MainActor struct SettingsViewTests {
    @Test func settingsStoreMaterializesCanonicalSettingsFileOnInit() {
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)

        #expect(FileManager.default.fileExists(atPath: settings.settingsFileURL.path))
    }

    @Test func flushingSettingsWritesLatestChangesToSettingsFile() throws {
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.focusFollowsWindowToMonitor = true
        settings.commandPaletteLastMode = .menu

        settings.flushNow()

        let rawData = try Data(contentsOf: settings.settingsFileURL)
        let export = try SettingsTOMLCodec.decode(rawData)

        #expect(export.focusFollowsWindowToMonitor == true)
        #expect(export.commandPaletteLastMode == CommandPaletteMode.menu.rawValue)
    }
}
