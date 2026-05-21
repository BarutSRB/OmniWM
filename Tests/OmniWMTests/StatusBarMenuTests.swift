import AppKit
import Foundation
@testable import OmniWM
import Testing

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

    @Test func buildMenuIncludesNiriScrollSnapControl() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)

        let menu = builder.buildMenu()
        let labels = menu.items.compactMap(\.view).flatMap(textLabels(in:))

        #expect(labels.contains("CONTROLS"))
        #expect(labels.contains("Niri Scroll Snap"))
    }

    @Test func buildMenuIncludesSettingsFileActions() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)

        let menu = builder.buildMenu()
        let labels = menu.items.compactMap(\.view).flatMap(textLabels(in:))

        #expect(labels.contains("SETTINGS FILE"))
        #expect(labels.contains("Reveal Settings File"))
        #expect(labels.contains("Edit Settings File"))
        #expect(labels.allSatisfy { !$0.localizedCaseInsensitiveContains("export") })
        #expect(labels.allSatisfy { !$0.localizedCaseInsensitiveContains("import") })
    }

    @Test func settingsFileMenuRowsDelegateExpectedActions() throws {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        let builder = StatusBarMenuBuilder(settings: settings, controller: controller)
        var performedActions: [SettingsFileAction] = []
        builder.settingsFileActionPerformer = { action, receivedSettings in
            #expect(receivedSettings.settingsFileURL == settings.settingsFileURL)
            performedActions.append(action)
            return action == .reveal ? .revealed : .opened
        }

        let menu = builder.buildMenu()

        try actionRow(in: menu, labeled: "Reveal Settings File").performActionForTests()
        try actionRow(in: menu, labeled: "Edit Settings File").performActionForTests()

        #expect(performedActions == [.reveal, .open])
    }

    @Test func buildMenuIncludesCheckForUpdatesRowAndDelegatesAction() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        var didCheckForUpdates = false
        builder.checkForUpdatesAction = {
            didCheckForUpdates = true
        }

        let menu = builder.buildMenu()
        let labels = menu.items.compactMap(\.view).flatMap(textLabels(in:))

        #expect(labels.contains("Check for Updates..."))

        builder.performCheckForUpdatesAction()

        #expect(didCheckForUpdates)
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

    @Test func revealActionDoesNotPresentPopup() {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        let builder = StatusBarMenuBuilder(settings: settings, controller: controller)
        var didPresentAlert = false
        var performedAction: SettingsFileAction?
        builder.infoAlertPresenter = { _, _ in
            didPresentAlert = true
        }
        builder.settingsFileActionPerformer = { action, receivedSettings in
            performedAction = action
            #expect(receivedSettings.settingsFileURL == settings.settingsFileURL)
            return .revealed
        }

        builder.performSettingsFileAction(.reveal)

        #expect(performedAction == .reveal)
        #expect(didPresentAlert == false)
        #expect(settings.settingsFileURL.lastPathComponent == "settings.toml")
    }

    @Test func openActionFailureDoesNotPresentPopup() {
        let controller = makeLayoutPlanTestController()
        let builder = StatusBarMenuBuilder(settings: controller.settings, controller: controller)
        var didPresentAlert = false
        builder.infoAlertPresenter = { _, _ in
            didPresentAlert = true
        }
        builder.settingsFileActionPerformer = { _, _ in
            throw CocoaError(.fileNoSuchFile)
        }

        builder.performSettingsFileAction(.open)

        #expect(didPresentAlert == false)
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

        guard let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
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

    @Test func statusBarRefreshStaysReadOnlyOnUnassignedThirdMonitor() {
        let primary = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
        let secondary = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
        let third = makeLayoutPlanSecondaryTestMonitor(slot: 2, name: "Third", x: 3840)
        let controller = makeLayoutPlanTestController(
            monitors: [primary, secondary, third],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
            ]
        )
        controller.settings.statusBarShowWorkspaceName = true

        #expect(controller.workspaceManager.setInteractionMonitor(third.id))

        var sessionChangeCount = 0
        let originalOnSessionStateChanged = controller.workspaceManager.onSessionStateChanged
        controller.workspaceManager.onSessionStateChanged = {
            sessionChangeCount += 1
            originalOnSessionStateChanged?()
        }

        let statusBarController = makeStatusBarController(for: controller)
        defer { statusBarController.cleanup() }

        sessionChangeCount = 0
        statusBarController.setup()

        #expect(sessionChangeCount == 0)
        #expect(statusBarController.statusButtonTitleForTests() == "")
        #expect(statusBarController.statusButtonImagePositionForTests() == .imageOnly)
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

    private func actionRow(in menu: NSMenu, labeled label: String) throws -> MenuActionRowView {
        try #require(
            menu.items
                .compactMap(\.view)
                .compactMap { $0 as? MenuActionRowView }
                .first { textLabels(in: $0).contains(label) }
        )
    }

    private func makeStatusBarController(for controller: WMController) -> StatusBarController {
        let statusBarController = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: HiddenBarController(settings: controller.settings)
        )
        controller.statusBarController = statusBarController
        return statusBarController
    }
}
