import AppKit
import Carbon
import Foundation
import Testing

@testable import OmniWM

private final class OverviewSessionRecorder {
    var activatedOmniWMCount = 0
    var restoredApplicationPIDs: [pid_t] = []
}

@MainActor
private func makeOverviewKeyEvent(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags = [],
    characters: String,
    charactersIgnoringModifiers: String
) -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        fatalError("Failed to create overview key event")
    }
    return event
}

@MainActor
private func makeOverviewTestEnvironment(
    recorder: OverviewSessionRecorder,
    frontmostPID: pid_t? = 4242
) -> OverviewEnvironment {
    var environment = OverviewEnvironment()
    environment.frontmostApplicationPID = { frontmostPID }
    environment.currentProcessID = { getpid() }
    environment.activateOmniWM = { recorder.activatedOmniWMCount += 1 }
    environment.activateApplication = { pid in
        recorder.restoredApplicationPIDs.append(pid)
    }
    environment.addLocalEventMonitor = { _, _ in NSObject() }
    environment.removeEventMonitor = { _ in }
    environment.notificationCenter = NotificationCenter()
    environment.selectionDismissDelayNanoseconds = 0
    return environment
}

@Suite @MainActor struct OverviewInputHandlerTests {
    @Test func plainTypingUpdatesSearchQuery() {
        let overview = OverviewController(wmController: makeLayoutPlanTestController())
        let inputHandler = OverviewInputHandler(controller: overview)
        overview.onAnimationComplete(state: .open)

        let event = makeOverviewKeyEvent(
            keyCode: UInt16(kVK_ANSI_A),
            characters: "a",
            charactersIgnoringModifiers: "a"
        )

        #expect(inputHandler.handleKeyDown(event) == true)
        #expect(inputHandler.searchQuery == "a")
    }

    @Test func unsupportedModifiedShortcutIsConsumed() {
        let overview = OverviewController(wmController: makeLayoutPlanTestController())
        let inputHandler = OverviewInputHandler(controller: overview)
        overview.onAnimationComplete(state: .open)

        let event = makeOverviewKeyEvent(
            keyCode: UInt16(kVK_ANSI_W),
            modifierFlags: .command,
            characters: "w",
            charactersIgnoringModifiers: "w"
        )

        #expect(inputHandler.handleKeyDown(event) == true)
        #expect(inputHandler.searchQuery.isEmpty)
    }

    @Test func supportedKeysMapToOverviewActions() {
        #expect(
            OverviewInputHandler.keyHandlingResult(
                keyCode: UInt16(kVK_Escape),
                modifierFlags: [],
                charactersIgnoringModifiers: "",
                searchQuery: ""
            ) == .init(action: .clearSearchOrDismiss, shouldConsume: true)
        )
        #expect(
            OverviewInputHandler.keyHandlingResult(
                keyCode: UInt16(kVK_Return),
                modifierFlags: [],
                charactersIgnoringModifiers: "\r",
                searchQuery: ""
            ) == .init(action: .activateSelection, shouldConsume: true)
        )
        #expect(
            OverviewInputHandler.keyHandlingResult(
                keyCode: UInt16(kVK_Tab),
                modifierFlags: .shift,
                charactersIgnoringModifiers: "\t",
                searchQuery: ""
            ) == .init(action: .navigate(.left), shouldConsume: true)
        )
        #expect(
            OverviewInputHandler.keyHandlingResult(
                keyCode: UInt16(kVK_Delete),
                modifierFlags: [],
                charactersIgnoringModifiers: "",
                searchQuery: "abc"
            ) == .init(action: .deleteBackward, shouldConsume: true)
        )
    }
}

@Suite @MainActor struct OverviewControllerModalTests {
    @Test func cancelDismissRestoresPreviousFrontmostApplication() {
        let recorder = OverviewSessionRecorder()
        let overview = OverviewController(
            wmController: makeLayoutPlanTestController(),
            environment: makeOverviewTestEnvironment(recorder: recorder)
        )

        overview.beginOwnedSession()
        overview.activateOwnedSession()
        overview.onAnimationComplete(state: .open)
        overview.dismiss(reason: .cancel, animated: false)

        #expect(recorder.activatedOmniWMCount == 1)
        #expect(recorder.restoredApplicationPIDs == [4242])
        #expect(overview.isOpen == false)
    }

    @Test func selectingWindowFocusesTargetWithoutRestoringPreviousApplication() {
        let recorder = OverviewSessionRecorder()
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(
            wmController: wmController,
            environment: makeOverviewTestEnvironment(recorder: recorder)
        )
        let workspaceId = try! #require(wmController.activeWorkspace()?.id)
        let token = addLayoutPlanTestWindow(on: wmController, workspaceId: workspaceId, windowId: 8181)
        let handle = try! #require(wmController.workspaceManager.handle(for: token))
        var activatedHandle: WindowHandle?
        var activatedWorkspaceId: WorkspaceDescriptor.ID?
        overview.onActivateWindow = { handle, workspaceId in
            activatedHandle = handle
            activatedWorkspaceId = workspaceId
        }

        overview.beginOwnedSession()
        overview.onAnimationComplete(state: .open)
        overview.dismiss(reason: .selection, targetWindow: handle, animated: false)

        #expect(recorder.restoredApplicationPIDs.isEmpty)
        #expect(activatedHandle == handle)
        #expect(activatedWorkspaceId == workspaceId)
        #expect(overview.isOpen == false)
    }

    @Test func applicationDeactivationClosesOverviewWithoutRestoringPreviousApplication() {
        let recorder = OverviewSessionRecorder()
        let overview = OverviewController(
            wmController: makeLayoutPlanTestController(),
            environment: makeOverviewTestEnvironment(recorder: recorder)
        )

        overview.beginOwnedSession()
        overview.onAnimationComplete(state: .open)
        overview.handleApplicationDidResignActive()
        overview.completeCloseTransition(targetWindow: nil)

        #expect(recorder.restoredApplicationPIDs.isEmpty)
        #expect(overview.isOpen == false)
    }
}
