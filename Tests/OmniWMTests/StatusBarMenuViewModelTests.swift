import AppKit
import Foundation
import Testing

@testable import OmniWM

private func makeStatusBarMenuTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.statusbar-menu.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@MainActor
private func makeStatusBarMenuTestController(defaults: UserDefaults) -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    return WMController(
        settings: SettingsStore(defaults: defaults),
        windowFocusOperations: operations
    )
}

private func makeKeyEvent(
    keyCode: UInt16,
    characters: String,
    modifierFlags: NSEvent.ModifierFlags = []
) -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        fatalError("Failed to create key event for tests")
    }

    return event
}

@Suite @MainActor struct StatusBarMenuViewModelTests {
    @Test func tabArrowHomeAndEndMoveFocusAcrossInteractiveItems() {
        let defaults = makeStatusBarMenuTestDefaults()
        let controller = makeStatusBarMenuTestController(defaults: defaults)
        let viewModel = StatusBarMenuViewModel(settings: controller.settings, controller: controller)

        #expect(viewModel.focusedItemID == .focusFollowsMouse)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 48, characters: "\t")))
        #expect(viewModel.focusedItemID == .followWindowToWorkspace)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 48, characters: "\t", modifierFlags: .shift)))
        #expect(viewModel.focusedItemID == .focusFollowsMouse)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 126, characters: "")))
        #expect(viewModel.focusedItemID == .quit)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 125, characters: "")))
        #expect(viewModel.focusedItemID == .focusFollowsMouse)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 119, characters: "")))
        #expect(viewModel.focusedItemID == .quit)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 115, characters: "")))
        #expect(viewModel.focusedItemID == .focusFollowsMouse)
    }

    @Test func spaceAndEnterToggleFocusedSwitchAndUpdateControllerState() {
        let defaults = makeStatusBarMenuTestDefaults()
        let controller = makeStatusBarMenuTestController(defaults: defaults)
        let settings = controller.settings
        settings.focusFollowsMouse = false

        let viewModel = StatusBarMenuViewModel(settings: settings, controller: controller)
        viewModel.focus(.focusFollowsMouse)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 49, characters: " ")))
        #expect(settings.focusFollowsMouse)
        #expect(controller.focusFollowsMouseEnabled)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r")))
        #expect(settings.focusFollowsMouse == false)
        #expect(controller.focusFollowsMouseEnabled == false)
    }

    @Test func escapeRequestsDismissWithFocusRestore() {
        let defaults = makeStatusBarMenuTestDefaults()
        let controller = makeStatusBarMenuTestController(defaults: defaults)
        let viewModel = StatusBarMenuViewModel(settings: controller.settings, controller: controller)

        var dismissRestoreFocus: Bool?
        viewModel.setDismissHandler { restoreFocus in
            dismissRestoreFocus = restoreFocus
        }

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 53, characters: "")))
        #expect(dismissRestoreFocus == true)
    }

    @Test func unhandledKeysAreIgnored() {
        let defaults = makeStatusBarMenuTestDefaults()
        let controller = makeStatusBarMenuTestController(defaults: defaults)
        let viewModel = StatusBarMenuViewModel(settings: controller.settings, controller: controller)

        #expect(viewModel.handleKeyDown(makeKeyEvent(keyCode: 0, characters: "a")) == false)
        #expect(viewModel.focusedItemID == .focusFollowsMouse)
    }

    @Test func modifiedAccessibilityShortcutsPassThrough() {
        let defaults = makeStatusBarMenuTestDefaults()
        let controller = makeStatusBarMenuTestController(defaults: defaults)
        let viewModel = StatusBarMenuViewModel(settings: controller.settings, controller: controller)

        #expect(
            viewModel.handleKeyDown(
                makeKeyEvent(keyCode: 126, characters: "", modifierFlags: [.control, .option])
            ) == false
        )
        #expect(
            viewModel.handleKeyDown(
                makeKeyEvent(keyCode: 49, characters: " ", modifierFlags: [.control, .option])
            ) == false
        )
        #expect(viewModel.focusedItemID == .focusFollowsMouse)
    }
}
