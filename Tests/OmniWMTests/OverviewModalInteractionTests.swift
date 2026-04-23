// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Carbon
import Foundation
import Testing

@testable import OmniWM

private final class OverviewSessionRecorder {
    var activatedOmniWMCount = 0
    var restoredApplicationPIDs: [pid_t] = []
}

private let overviewSelectionActivationWaitNanoseconds: UInt64 = 5_000_000

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

@MainActor
private func addOverviewTestWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int,
    pid: pid_t,
    appName: String
) -> WindowHandle {
    controller.appInfoCache.storeInfoForTests(
        pid: pid,
        name: appName,
        bundleId: "com.example.\(appName.lowercased())"
    )
    let token = addLayoutPlanTestWindow(
        on: controller,
        workspaceId: workspaceId,
        windowId: windowId,
        pid: pid
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected overview test window handle")
    }
    return handle
}

@MainActor
private func activatePreparedOverviewSelection(
    in overview: OverviewController,
    expectedHandle: WindowHandle
) async {
    overview.onAnimationComplete(state: .open)
    overview.activateSelectedWindow()
    await Task.yield()
    try? await Task.sleep(nanoseconds: overviewSelectionActivationWaitNanoseconds)
    overview.completeCloseTransition(targetWindow: expectedHandle)
}

@MainActor
private func syncOverviewNiriState(
    on controller: WMController,
    workspaceIds: [WorkspaceDescriptor.ID]
) {
    guard let engine = controller.niriEngine else { return }

    for workspaceId in workspaceIds {
        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        let selectedNodeId = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
        let focusedHandle = controller.workspaceManager.lastFocusedHandle(in: workspaceId)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: selectedNodeId,
            focusedHandle: focusedHandle
        )

        let resolvedSelection = focusedHandle.flatMap { engine.findNode(for: $0)?.id }
            ?? engine.validateSelection(selectedNodeId, in: workspaceId)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = resolvedSelection
        }
    }
}

@Suite @MainActor struct OverviewInputHandlerTests {
    @Test func plainTypingUpdatesSearchQuery() {
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(wmController: wmController, motionPolicy: wmController.motionPolicy)
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
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(wmController: wmController, motionPolicy: wmController.motionPolicy)
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
    @Test func crossWorkspaceDragActionScopesOverviewRelayoutToSourceAndTargetWorkspaces() async {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.settings.defaultLayoutType = .niri
        controller.enableNiriLayout(maxWindowsPerColumn: 2)
        await waitForLayoutPlanRefreshWork(on: controller)

        let sourceHandle = addOverviewTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 8_401,
            pid: 5_401,
            appName: "Source"
        )
        let targetHandle = addOverviewTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 8_402,
            pid: 5_402,
            appName: "Target"
        )
        _ = controller.workspaceManager.rememberFocus(sourceHandle, in: fixture.primaryWorkspaceId)
        _ = controller.workspaceManager.rememberFocus(targetHandle, in: fixture.secondaryWorkspaceId)
        syncOverviewNiriState(
            on: controller,
            workspaceIds: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId]
        )

        var enqueuedRefreshes: [ScheduledRefresh] = []
        controller.layoutRefreshController.debugHooks.onRefreshEnqueued = { refresh in
            enqueuedRefreshes.append(refresh)
        }
        controller.layoutRefreshController.debugHooks.onRelayout = { _, _ in
            true
        }

        let overview = OverviewController(
            wmController: controller,
            motionPolicy: controller.motionPolicy
        )
        overview.performDragActionForTests(
            handle: sourceHandle,
            workspaceId: fixture.primaryWorkspaceId,
            target: .niriWindowInsert(
                workspaceId: fixture.secondaryWorkspaceId,
                targetHandle: targetHandle,
                position: .before
            )
        )
        await waitForLayoutPlanRefreshWork(on: controller)

        guard let refresh = enqueuedRefreshes.last(where: { $0.reason == .overviewMutation }) else {
            Issue.record("Missing scoped overview mutation refresh")
            return
        }

        #expect(refresh.kind == .immediateRelayout)
        #expect(refresh.affectedWorkspaceIds == [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId])
    }

    @Test func prepareOpenStateSeedsSelectionFromFocusedWindow() async {
        let recorder = OverviewSessionRecorder()
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(
            wmController: wmController,
            motionPolicy: wmController.motionPolicy,
            environment: makeOverviewTestEnvironment(recorder: recorder)
        )
        let workspaceId = try! #require(wmController.activeWorkspace()?.id)
        let monitorId = try! #require(wmController.workspaceManager.monitors.first?.id)

        _ = addOverviewTestWindow(
            on: wmController,
            workspaceId: workspaceId,
            windowId: 8101,
            pid: 5101,
            appName: "Alpha"
        )
        let focusedHandle = addOverviewTestWindow(
            on: wmController,
            workspaceId: workspaceId,
            windowId: 8102,
            pid: 5102,
            appName: "Bravo"
        )
        _ = addOverviewTestWindow(
            on: wmController,
            workspaceId: workspaceId,
            windowId: 8103,
            pid: 5103,
            appName: "Charlie"
        )
        _ = wmController.workspaceManager.setManagedFocus(
            focusedHandle,
            in: workspaceId,
            onMonitor: monitorId
        )

        var activatedHandle: WindowHandle?
        var activatedWorkspaceId: WorkspaceDescriptor.ID?
        overview.onActivateWindow = { handle, workspaceId in
            activatedHandle = handle
            activatedWorkspaceId = workspaceId
        }

        overview.prepareOpenState()
        await activatePreparedOverviewSelection(in: overview, expectedHandle: focusedHandle)

        #expect(activatedHandle == focusedHandle)
        #expect(activatedWorkspaceId == workspaceId)
        #expect(recorder.restoredApplicationPIDs.isEmpty)
    }

    @Test func prepareOpenStateFallsBackToFirstMatchingWindowWithoutManagedFocus() async {
        let recorder = OverviewSessionRecorder()
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(
            wmController: wmController,
            motionPolicy: wmController.motionPolicy,
            environment: makeOverviewTestEnvironment(recorder: recorder)
        )
        let workspaceId = try! #require(wmController.activeWorkspace()?.id)

        let firstHandle = addOverviewTestWindow(
            on: wmController,
            workspaceId: workspaceId,
            windowId: 8201,
            pid: 5201,
            appName: "Alpha"
        )
        _ = addOverviewTestWindow(
            on: wmController,
            workspaceId: workspaceId,
            windowId: 8202,
            pid: 5202,
            appName: "Bravo"
        )
        _ = addOverviewTestWindow(
            on: wmController,
            workspaceId: workspaceId,
            windowId: 8203,
            pid: 5203,
            appName: "Charlie"
        )

        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in
            activatedHandle = handle
        }

        overview.prepareOpenState()
        await activatePreparedOverviewSelection(in: overview, expectedHandle: firstHandle)

        #expect(activatedHandle == firstHandle)
    }

    @Test func turningAnimationsOffMidOpenDoesNotForceCompletionAndFutureDismissIsInstant() {
        let recorder = OverviewSessionRecorder()
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(
            wmController: wmController,
            motionPolicy: wmController.motionPolicy,
            environment: makeOverviewTestEnvironment(recorder: recorder)
        )
        let workspaceId = try! #require(wmController.activeWorkspace()?.id)

        _ = addOverviewTestWindow(
            on: wmController,
            workspaceId: workspaceId,
            windowId: 8211,
            pid: 5211,
            appName: "Alpha"
        )

        overview.open()

        switch overview.state {
        case .opening:
            break
        default:
            Issue.record("Expected overview to begin opening with animations enabled")
            return
        }

        wmController.setAnimationsEnabled(false)

        switch overview.state {
        case .opening:
            break
        default:
            Issue.record("Toggling animations off should not force the in-flight overview open animation to complete")
            return
        }

        overview.onAnimationComplete(state: .open)
        overview.dismiss(animated: true)

        switch overview.state {
        case .closed:
            break
        default:
            Issue.record("Overview dismiss should be immediate once animations are disabled")
        }
    }

    @Test func prepareOpenStateUsesFocusedMonitorSelectionAcrossMultipleMonitors() async {
        let recorder = OverviewSessionRecorder()
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: makeOverviewTestEnvironment(recorder: recorder)
        )

        let primaryHandle = addOverviewTestWindow(
            on: fixture.controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 8301,
            pid: 5301,
            appName: "Primary"
        )
        let secondaryHandle = addOverviewTestWindow(
            on: fixture.controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 8302,
            pid: 5302,
            appName: "Secondary"
        )
        _ = fixture.controller.workspaceManager.setManagedFocus(
            secondaryHandle,
            in: fixture.secondaryWorkspaceId,
            onMonitor: fixture.secondaryMonitor.id
        )

        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in
            activatedHandle = handle
        }

        overview.prepareOpenState()
        await activatePreparedOverviewSelection(in: overview, expectedHandle: secondaryHandle)

        #expect(activatedHandle == secondaryHandle)
        #expect(activatedHandle != primaryHandle)
    }

    @Test func cancelDismissRestoresPreviousFrontmostApplication() {
        let recorder = OverviewSessionRecorder()
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(
            wmController: wmController,
            motionPolicy: wmController.motionPolicy,
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
            motionPolicy: wmController.motionPolicy,
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
        let wmController = makeLayoutPlanTestController()
        let overview = OverviewController(
            wmController: wmController,
            motionPolicy: wmController.motionPolicy,
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
