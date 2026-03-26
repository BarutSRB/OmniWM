import Foundation
import Testing

@testable import OmniWM

private func makeSettingsWorkflowTestURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-settings-workflow-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("settings-\(UUID().uuidString).json")
}

@Suite(.serialized) @MainActor struct SettingsViewTests {
    @Test func exportStatusMessagesMatchConfigWorkflowCopy() {
        #expect(ExportStatus.exported(.full).message == "Editable config exported")
        #expect(ExportStatus.exported(.compact).message == "Compact backup exported")
        #expect(ExportStatus.imported.message == "Settings imported")
        #expect(ExportStatus.created.message == "Settings file created")
        #expect(ExportStatus.revealed.message == "Settings file revealed in Finder")
        #expect(ExportStatus.opened.message == "Settings file opened")
    }

    @Test func createActionWritesCanonicalSettingsFile() throws {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        let exportURL = makeSettingsWorkflowTestURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try? FileManager.default.removeItem(at: exportURL)

        let status = try ConfigFileWorkflow.perform(
            .create,
            targetURL: exportURL,
            settings: settings,
            controller: controller
        )

        #expect(status == .created)
        #expect(FileManager.default.fileExists(atPath: exportURL.path) == true)
    }

    @Test func revealActionCreatesMissingFileAndReportsRevealed() throws {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        let exportURL = makeSettingsWorkflowTestURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try? FileManager.default.removeItem(at: exportURL)
        var revealedURLs: [[URL]] = []

        let status = try ConfigFileWorkflow.perform(
            .reveal,
            targetURL: exportURL,
            settings: settings,
            controller: controller,
            revealFile: { revealedURLs.append($0) }
        )

        #expect(status == .revealed)
        #expect(FileManager.default.fileExists(atPath: exportURL.path) == true)
        #expect(revealedURLs == [[exportURL]])
    }

    @Test func openActionUsesInjectedOpenHandler() throws {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        let exportURL = makeSettingsWorkflowTestURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try? FileManager.default.removeItem(at: exportURL)
        var openedURLs: [URL] = []

        let status = try ConfigFileWorkflow.perform(
            .open,
            targetURL: exportURL,
            settings: settings,
            controller: controller,
            openFile: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(status == .opened)
        #expect(FileManager.default.fileExists(atPath: exportURL.path) == true)
        #expect(openedURLs == [exportURL])
    }

    @Test func importActionMergesSettingsFileIntoControllerSettings() throws {
        let exportURL = makeSettingsWorkflowTestURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let sourceController = makeLayoutPlanTestController()
        sourceController.settings.focusFollowsWindowToMonitor = true
        sourceController.settings.commandPaletteLastMode = .menu
        try sourceController.settings.exportSettings(to: exportURL, mode: .full)

        let targetController = makeLayoutPlanTestController()
        targetController.settings.focusFollowsWindowToMonitor = false
        targetController.settings.commandPaletteLastMode = .windows

        let status = try ConfigFileWorkflow.perform(
            .import,
            targetURL: exportURL,
            settings: targetController.settings,
            controller: targetController
        )

        #expect(status == .imported)
        #expect(targetController.settings.focusFollowsWindowToMonitor == true)
        #expect(targetController.settings.commandPaletteLastMode == .menu)
    }
}
