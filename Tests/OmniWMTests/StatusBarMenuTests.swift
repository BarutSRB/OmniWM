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

private func makeStatusBarMenuTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-status-bar-menu-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
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

    @Test func buildMenuIncludesIPCSectionAndCLIInstallActionWhenEnabled() throws {
        let root = makeStatusBarMenuTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let userBin = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        let appURL = root.appendingPathComponent("OmniWM.app", isDirectory: true)
        let macOSDirectory = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let bundledCLIURL = macOSDirectory.appendingPathComponent("omniwmctl", isDirectory: false)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundledCLIURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLIURL.path)

        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        builder.ipcMenuEnabled = true
        builder.cliManager = AppCLIManager(
            environmentProvider: { ["PATH": userBin.path] },
            bundleURLProvider: { appURL },
            homeDirectoryURLProvider: { homeDirectory },
            homebrewLinkURLsProvider: { [] }
        )

        let menu = builder.buildMenu()
        let labels = menu.items.compactMap(\.view).flatMap(textLabels(in:))

        #expect(labels.contains("IPC / CLI"))
        #expect(labels.contains("Enable IPC"))
        #expect(labels.contains("Install CLI to PATH…"))
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

    @Test func statusBarTitleUsesInteractionMonitorWorkspaceAndFocusedApp() {
        let primary = makeLayoutPlanTestMonitor(displayId: 100, name: "Primary")
        let secondary = makeLayoutPlanTestMonitor(displayId: 200, name: "Secondary", x: 1920)
        let controller = makeLayoutPlanTestController(
            monitors: [primary, secondary],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", displayName: "Mail", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", displayName: "Code", monitorAssignment: .secondary)
            ]
        )
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false) else {
            Issue.record("Missing secondary workspace for status bar monitor test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 202),
            pid: 202,
            windowId: 202,
            to: secondaryWorkspaceId
        )
        controller.appInfoCache.storeInfoForTests(
            pid: 202,
            name: "Secondary App",
            bundleId: "com.example.secondary"
        )
        _ = controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondary.id)
        _ = controller.workspaceManager.setManagedFocus(token, in: secondaryWorkspaceId, onMonitor: secondary.id)

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }
        statusBarController.setup()

        #expect(statusBarController.statusButtonTitleForTests() == " Code \u{2013} Secondary App")
        #expect(statusBarController.statusButtonImagePositionForTests() == .imageLeft)
    }

    @Test func statusBarTitleUsesDisplayNameOrRawNameAndTruncatesFocusedApp() {
        let monitor = makeLayoutPlanTestMonitor()
        let controller = makeLayoutPlanTestController(
            monitors: [monitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "2", displayName: "Code", monitorAssignment: .main)
            ]
        )
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false) else {
            Issue.record("Missing workspace for status bar formatting test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 303),
            pid: 303,
            windowId: 303,
            to: workspaceId
        )
        let longAppName = "VeryLongFocusedApplication"
        let expectedTruncated = StatusBarController.truncatedStatusBarAppName(longAppName)
        controller.appInfoCache.storeInfoForTests(
            pid: 303,
            name: longAppName,
            bundleId: "com.example.long"
        )
        _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }
        statusBarController.setup()

        #expect(statusBarController.statusButtonTitleForTests() == " Code \u{2013} \(expectedTruncated)")

        controller.settings.statusBarUseWorkspaceId = true
        controller.refreshStatusBar()

        #expect(statusBarController.statusButtonTitleForTests() == " 2 \u{2013} \(expectedTruncated)")
    }

    @Test func statusBarTitleIncludesFocusedFloatingWindowApp() {
        let controller = makeLayoutPlanTestController()
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let monitor = controller.monitorForInteraction(),
              let workspaceId = controller.activeWorkspace()?.id
        else {
            Issue.record("Missing active workspace for floating status bar test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 404),
            pid: 404,
            windowId: 404,
            to: workspaceId,
            mode: .floating
        )
        controller.appInfoCache.storeInfoForTests(
            pid: 404,
            name: "Floating App",
            bundleId: "com.example.floating"
        )
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }
        statusBarController.setup()

        #expect(statusBarController.statusButtonTitleForTests() == " 1 \u{2013} Floating App")
    }

    private func textLabels(in view: NSView) -> [String] {
        let direct = (view as? NSTextField).map(\.stringValue).map { [$0] } ?? []
        return direct + view.subviews.flatMap(textLabels(in:))
    }

    private func makeStatusBarController(for controller: WMController) -> StatusBarController {
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: HiddenBarController(settings: controller.settings),
            defaults: makeLayoutPlanTestDefaults()
        )
        controller.statusBarController = statusBarController
        return statusBarController
    }
}
