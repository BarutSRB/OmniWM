import AppKit
import Foundation
import Testing

@testable import OmniWM

private func makeStatusBarConfigWorkflowTestURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-status-bar-workflow-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("settings-\(UUID().uuidString).json")
}

@Suite(.serialized) @MainActor struct StatusBarMenuTests {
    @Test func buildMenuUsesCurrentAppAppearanceForMenuAndViews() throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)

        application.appearance = NSAppearance(named: .aqua)
        let lightMenu = builder.buildMenu()

        #expect(lightMenu.appearance?.name == .aqua)
        #expect(try #require(lightMenu.items.first?.view).appearance?.name == .aqua)
        #expect(try #require(lightMenu.items.dropFirst(3).first?.view).appearance?.name == .aqua)

        application.appearance = NSAppearance(named: .darkAqua)
        let darkMenu = builder.buildMenu()

        #expect(darkMenu.appearance?.name == .darkAqua)
        #expect(try #require(darkMenu.items.first?.view).appearance?.name == .darkAqua)
        #expect(try #require(darkMenu.items.dropFirst(3).first?.view).appearance?.name == .darkAqua)
    }

    @Test func buildMenuIncludesSettingsFileActions() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)

        let menu = builder.buildMenu()
        let labels = menu.items.compactMap(\.view).flatMap(textLabels(in:))

        #expect(labels.contains("CONFIG FILE"))
        #expect(labels.contains("Export Editable Config"))
        #expect(labels.contains("Export Compact Backup"))
        #expect(labels.contains("Import Settings"))
        #expect(labels.contains("Reveal Settings File"))
        #expect(labels.contains("Open Settings File"))
    }

    @Test func exportActionReportsSuccessAlert() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        let exportURL = makeStatusBarConfigWorkflowTestURL()
        builder.configFileURL = exportURL
        defer { try? FileManager.default.removeItem(at: exportURL) }
        var received: [(String, String)] = []
        builder.infoAlertPresenter = { title, message in
            received.append((title, message))
        }

        builder.performConfigFileAction(.export(.full))

        #expect(received.count == 1)
        #expect(received.first?.0 == "Editable Config Exported")
        #expect(received.first?.1 == exportURL.path)
    }

    @Test func revealActionCreatesFileAndReportsSuccessAlert() {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        let builder = StatusBarMenuBuilder(settings: settings, controller: controller)
        let exportURL = makeStatusBarConfigWorkflowTestURL()
        builder.configFileURL = exportURL
        var received: [(String, String)] = []
        builder.infoAlertPresenter = { title, message in
            received.append((title, message))
        }
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try? FileManager.default.removeItem(at: exportURL)

        builder.performConfigFileAction(.reveal)

        #expect(FileManager.default.fileExists(atPath: exportURL.path) == true)
        #expect(received.count == 1)
        #expect(received.first?.0 == "Settings File Revealed")
        #expect(received.first?.1 == exportURL.path)
    }

    @Test func importActionReportsSuccessAlert() throws {
        let exportURL = makeStatusBarConfigWorkflowTestURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let sourceController = makeLayoutPlanTestController()
        sourceController.settings.focusFollowsWindowToMonitor = true
        try sourceController.settings.exportSettings(to: exportURL, mode: .full)

        let targetController = makeLayoutPlanTestController()
        targetController.settings.focusFollowsWindowToMonitor = false
        let builder = StatusBarMenuBuilder(settings: targetController.settings, controller: targetController)
        builder.configFileURL = exportURL
        var received: [(String, String)] = []
        builder.infoAlertPresenter = { title, message in
            received.append((title, message))
        }

        builder.performConfigFileAction(.import)

        #expect(targetController.settings.focusFollowsWindowToMonitor == true)
        #expect(received.count == 1)
        #expect(received.first?.0 == "Settings Imported")
        #expect(received.first?.1 == exportURL.path)
    }

    @Test func exportActionReportsSharedFailureTitle() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        var received: [(String, String)] = []
        builder.infoAlertPresenter = { title, message in
            received.append((title, message))
        }
        builder.configFileActionPerformer = { _, _, _, _ in
            throw CocoaError(.fileWriteUnknown)
        }

        builder.performConfigFileAction(.export(.full))

        #expect(received.count == 1)
        #expect(received.first?.0 == ConfigFileAction.export(.full).failureAlertTitle)
    }

    @Test func openActionReportsSharedFailureTitle() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        var received: [(String, String)] = []
        builder.infoAlertPresenter = { title, message in
            received.append((title, message))
        }
        builder.configFileActionPerformer = { _, _, _, _ in
            throw CocoaError(.fileNoSuchFile)
        }

        builder.performConfigFileAction(.open)

        #expect(received.count == 1)
        #expect(received.first?.0 == ConfigFileAction.open.failureAlertTitle)
    }

    @Test func importActionReportsSharedFailureTitle() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        let exportURL = makeStatusBarConfigWorkflowTestURL()
        builder.configFileURL = exportURL
        var received: [(String, String)] = []
        builder.infoAlertPresenter = { title, message in
            received.append((title, message))
        }
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try? FileManager.default.removeItem(at: exportURL)

        builder.performConfigFileAction(.import)

        #expect(received.count == 1)
        #expect(received.first?.0 == ConfigFileAction.import.failureAlertTitle)
    }

    private func textLabels(in view: NSView) -> [String] {
        let direct = (view as? NSTextField).map(\.stringValue).map { [$0] } ?? []
        return direct + view.subviews.flatMap(textLabels(in:))
    }
}
