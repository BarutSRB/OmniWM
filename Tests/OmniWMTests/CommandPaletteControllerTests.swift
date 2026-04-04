import AppKit
import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

private func makeCommandPaletteTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.commandpalette.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@MainActor
private func makeCommandPaletteTestWMController() -> WMController {
    WMController(settings: SettingsStore(defaults: makeCommandPaletteTestDefaults()))
}

private func makeCommandPaletteWindowItem(windowId: Int) -> CommandPaletteWindowItem {
    let handle = WindowHandle(id: WindowToken(pid: 4242, windowId: windowId))
    return CommandPaletteWindowItem(
        id: handle.id,
        handle: handle,
        title: "Window \(windowId)",
        appName: "Test App",
        appIcon: nil,
        workspaceName: "1"
    )
}

@MainActor
private func makeCommandPaletteSummonAnchor(
    wmController: WMController,
    windowId: Int = 11
) -> CommandPaletteSummonAnchor {
    guard let workspaceId = wmController.activeWorkspace()?.id else {
        fatalError("Expected active workspace for summon-anchor test fixture")
    }
    return .init(
        token: WindowToken(pid: 4343, windowId: windowId),
        workspaceId: workspaceId
    )
}

private func makeCommandPaletteAppSnapshot(
    pid: pid_t,
    bundleIdentifier: String?,
    localizedName: String?,
    isTerminated: Bool = false
) -> CommandPaletteAppSnapshot {
    CommandPaletteAppSnapshot(
        processIdentifier: pid,
        bundleIdentifier: bundleIdentifier,
        localizedName: localizedName,
        isTerminated: isTerminated
    )
}

@Suite(.serialized) @MainActor struct CommandPaletteControllerTests {
    @Test func toggleShowsPaletteWhenHidden() {
        var environment = CommandPaletteEnvironment()
        environment.activateOmniWM = {}
        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
        }

        controller.toggle(wmController: wmController)

        #expect(controller.isVisible)
    }

    @Test func toggleHidesVisiblePaletteAndClearsTransientState() {
        var environment = CommandPaletteEnvironment()
        environment.activateOmniWM = {}
        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()

        guard let workspaceId = wmController.activeWorkspace()?.id else {
            Issue.record("Missing active workspace for command palette toggle test")
            return
        }

        _ = wmController.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 707),
            pid: 4242,
            windowId: 707,
            to: workspaceId
        )

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
        }

        controller.toggle(wmController: wmController)
        controller.searchText = "Unknown"

        #expect(controller.isVisible)
        #expect(controller.filteredWindowItems.count == 1)
        #expect(controller.selectedItemID == .window(WindowToken(pid: 4242, windowId: 707)))

        controller.toggle(wmController: wmController)

        #expect(controller.isVisible == false)
        #expect(controller.searchText.isEmpty)
        #expect(controller.selectedItemID == nil)
        #expect(controller.filteredWindowItems.isEmpty)
    }

    @Test func motionToggleKeepsLivePanelAndSelectionState() throws {
        var environment = CommandPaletteEnvironment()
        environment.activateOmniWM = {}
        let motionPolicy = MotionPolicy()
        let controller = CommandPaletteController(motionPolicy: motionPolicy, environment: environment)
        let wmController = makeCommandPaletteTestWMController()

        guard let workspaceId = wmController.activeWorkspace()?.id else {
            Issue.record("Missing active workspace for command palette motion test")
            return
        }

        _ = wmController.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 808),
            pid: 4343,
            windowId: 808,
            to: workspaceId
        )

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
        }

        controller.toggle(wmController: wmController)
        let panel = try #require(controller.panelForTests)
        let contentView = try #require(panel.contentView)

        controller.searchText = "Window"
        let expectedSelection = CommandPaletteSelectionID.window(WindowToken(pid: 4343, windowId: 808))
        controller.selectedItemID = expectedSelection

        #expect(controller.selectedItemID == expectedSelection)

        motionPolicy.animationsEnabled = false

        #expect(controller.isVisible)
        #expect(controller.searchText == "Window")
        #expect(controller.selectedItemID == expectedSelection)
        #expect(controller.panelForTests === panel)
        #expect(controller.panelForTests?.contentView === contentView)
    }

    @Test func selectCurrentNavigatesSelectedWindowAfterDismiss() {
        var navigatedHandle: WindowHandle?
        var environment = CommandPaletteEnvironment()
        environment.navigateToWindow = { _, handle in
            navigatedHandle = handle
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let item = makeCommandPaletteWindowItem(windowId: 101)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [item],
            selectedItemID: .window(item.id)
        )

        controller.selectCurrent()

        #expect(navigatedHandle == item.handle)
        #expect(controller.selectedItemID == nil)
        #expect(controller.filteredWindowItems.isEmpty)
    }

    @Test func selectCurrentUsesUpdatedWindowSelection() {
        var navigatedHandle: WindowHandle?
        var environment = CommandPaletteEnvironment()
        environment.navigateToWindow = { _, handle in
            navigatedHandle = handle
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let first = makeCommandPaletteWindowItem(windowId: 101)
        let second = makeCommandPaletteWindowItem(windowId: 202)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [first, second],
            selectedItemID: .window(second.id)
        )

        controller.selectCurrent()

        #expect(navigatedHandle == second.handle)
    }

    @Test func selectCurrentSummonsSelectedWindowAfterDismiss() {
        var summonedHandle: WindowHandle?
        var summonedAnchorToken: WindowToken?
        var summonedAnchorWorkspaceId: WorkspaceDescriptor.ID?
        var environment = CommandPaletteEnvironment()
        environment.summonWindowRight = { _, handle, anchorToken, anchorWorkspaceId in
            summonedHandle = handle
            summonedAnchorToken = anchorToken
            summonedAnchorWorkspaceId = anchorWorkspaceId
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let item = makeCommandPaletteWindowItem(windowId: 303)
        let summonAnchor = makeCommandPaletteSummonAnchor(wmController: wmController)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [item],
            selectedItemID: .window(item.id),
            summonAnchor: summonAnchor
        )

        controller.selectCurrent(trigger: .summonRight)

        #expect(summonedHandle == item.handle)
        #expect(summonedAnchorToken == summonAnchor.token)
        #expect(summonedAnchorWorkspaceId == summonAnchor.workspaceId)
        #expect(controller.selectedItemID == nil)
        #expect(controller.filteredWindowItems.isEmpty)
    }

    @Test func selectCurrentDoesNotSummonWithoutAnchor() {
        var didSummon = false
        var environment = CommandPaletteEnvironment()
        environment.summonWindowRight = { _, _, _, _ in
            didSummon = true
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let item = makeCommandPaletteWindowItem(windowId: 404)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [item],
            selectedItemID: .window(item.id)
        )

        controller.selectCurrent(trigger: .summonRight)

        #expect(didSummon == false)
        #expect(controller.selectedItemID == .window(item.id))
        #expect(controller.filteredWindowItems.map(\.id) == [item.id])
    }

    @Test func resolveMenuTargetPrefersCurrentExternalApp() {
        let current = makeCommandPaletteAppSnapshot(
            pid: 200,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )
        let cached = makeCommandPaletteAppSnapshot(
            pid: 201,
            bundleIdentifier: "com.apple.TextEdit",
            localizedName: "TextEdit"
        )

        let resolved = CommandPaletteController.resolveMenuTarget(
            current: current,
            cached: cached,
            ownBundleIdentifier: "com.omniwm"
        )

        #expect(resolved == current)
    }

    @Test func resolveMenuTargetFallsBackToCachedExternalAppWhenCurrentIsOmniWM() {
        let current = makeCommandPaletteAppSnapshot(
            pid: 300,
            bundleIdentifier: "com.omniwm",
            localizedName: "OmniWM"
        )
        let cached = makeCommandPaletteAppSnapshot(
            pid: 301,
            bundleIdentifier: "com.apple.Finder",
            localizedName: "Finder"
        )

        let resolved = CommandPaletteController.resolveMenuTarget(
            current: current,
            cached: cached,
            ownBundleIdentifier: "com.omniwm"
        )

        #expect(resolved == cached)
    }

    @Test func resolveMenuTargetIgnoresTerminatedCachedApp() {
        let current = makeCommandPaletteAppSnapshot(
            pid: 400,
            bundleIdentifier: "com.omniwm",
            localizedName: "OmniWM"
        )
        let cached = makeCommandPaletteAppSnapshot(
            pid: 401,
            bundleIdentifier: "com.apple.Terminal",
            localizedName: "Terminal",
            isTerminated: true
        )

        let resolved = CommandPaletteController.resolveMenuTarget(
            current: current,
            cached: cached,
            ownBundleIdentifier: "com.omniwm"
        )

        #expect(resolved == nil)
    }

    @Test func menuModeCachesMenuItemsPerPidWithinVisibleSession() async {
        var fetchCount = 0
        var environment = CommandPaletteEnvironment()
        environment.fetchMenuItems = { pid in
            fetchCount += 1
            return [
                MenuItemModel(
                    title: "Reload \(pid)",
                    fullPath: "File > Reload",
                    keyboardShortcut: nil,
                    axElement: AXUIElementCreateSystemWide(),
                    parentTitles: ["File"]
                )
            ]
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let target = makeCommandPaletteAppSnapshot(
            pid: 410,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )

        controller.setMenuLoadingStateForTests(wmController: wmController, target: target)
        controller.loadMenuItemsForTests()
        try? await Task.sleep(for: .milliseconds(5))
        controller.loadMenuItemsForTests()
        try? await Task.sleep(for: .milliseconds(5))

        #expect(fetchCount == 1)
        #expect(controller.menuItems.count == 1)
    }

    @Test func command2SwitchesOnlyWhenMenuModeIsAvailable() {
        let controller = CommandPaletteController()
        controller.selectedMode = .windows
        controller.setMenuAvailabilityForTests(nil)

        #expect(controller.handleModeShortcutForTests("2") == false)
        #expect(controller.selectedMode == .windows)

        controller.setMenuAvailabilityForTests(
            makeCommandPaletteAppSnapshot(
                pid: 500,
                bundleIdentifier: "com.apple.Safari",
                localizedName: "Safari"
            )
        )

        #expect(controller.handleModeShortcutForTests("2") == true)
        #expect(controller.selectedMode == .menu)
    }

    @Test func command1SwitchesBackToWindowsMode() {
        let controller = CommandPaletteController()
        controller.setMenuAvailabilityForTests(
            makeCommandPaletteAppSnapshot(
                pid: 501,
                bundleIdentifier: "com.apple.Finder",
                localizedName: "Finder"
            )
        )
        controller.selectedMode = .menu

        #expect(controller.handleModeShortcutForTests("1") == true)
        #expect(controller.selectedMode == .windows)
    }

    @Test func modeHintMatchesDisplayedShortcuts() {
        #expect(
            CommandPaletteController.modeHint(for: .windows)
                == .init(title: "Windows", shortcut: "⌘1")
        )
        #expect(
            CommandPaletteController.modeHint(for: .menu)
                == .init(title: "Menu", shortcut: "⌘2")
        )
    }

    @Test func selectedWindowHintReflectsSummonAvailability() {
        #expect(
            CommandPaletteController.selectedWindowHint(isSummonRightAvailable: true)
                == .init(title: "Summon Right", shortcut: "⇧↩")
        )
        #expect(CommandPaletteController.selectedWindowHint(isSummonRightAvailable: false) == nil)
    }

    @Test func windowsStatusTextReflectsSummonAvailability() {
        #expect(
            CommandPaletteController.windowsStatusText(isSummonRightAvailable: true)
                == "Enter jumps. Shift-Enter summons right."
        )
        #expect(
            CommandPaletteController.windowsStatusText(isSummonRightAvailable: false)
                == "Enter jumps. Shift-Enter unavailable for this session."
        )
    }

    @Test func selectionTriggerHandlesReturnAndKeypadEnter() {
        let controller = CommandPaletteController()

        #expect(controller.selectionTriggerForTests(keyCode: 36, modifierFlags: []) == .primary)
        #expect(controller.selectionTriggerForTests(keyCode: 76, modifierFlags: []) == .primary)
        #expect(controller.selectionTriggerForTests(keyCode: 36, modifierFlags: .shift) == .summonRight)
        #expect(controller.selectionTriggerForTests(keyCode: 76, modifierFlags: .shift) == .summonRight)
    }

    @Test func resolveSummonAnchorFallsBackToLastFocusedMemory() {
        let wmController = makeCommandPaletteTestWMController()
        guard let workspaceId = wmController.activeWorkspace()?.id else {
            Issue.record("Missing active workspace for summon-anchor test")
            return
        }

        let handle = WindowHandle(id: WindowToken(pid: 5151, windowId: 5151))
        let token = wmController.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 5151),
            pid: handle.pid,
            windowId: handle.windowId,
            to: workspaceId
        )
        guard let storedHandle = wmController.workspaceManager.handle(for: token) else {
            Issue.record("Missing managed handle for summon-anchor test")
            return
        }

        _ = wmController.workspaceManager.rememberFocus(storedHandle, in: workspaceId)
        _ = wmController.workspaceManager.enterNonManagedFocus(appFullscreen: false)

        let anchor = CommandPaletteController.resolveSummonAnchor(for: wmController)

        #expect(anchor?.token == storedHandle.id)
        #expect(anchor?.workspaceId == workspaceId)
    }
}
