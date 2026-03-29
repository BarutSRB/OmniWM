import Foundation
import Testing

import OmniWMIPC
@testable import OmniWM

private let ipcCommandRouterSessionToken = "ipc-command-router-tests"

@MainActor
private func makeIPCCommandRouter(for controller: WMController) -> IPCCommandRouter {
    IPCCommandRouter(controller: controller, sessionToken: ipcCommandRouterSessionToken)
}

@MainActor
private func prepareIPCNiriState(
    on controller: WMController,
    assignments: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
    focusedWindowId: Int
) -> [Int: WindowHandle] {
    controller.enableNiriLayout()
    controller.syncMonitorsToNiriEngine()

    var handlesByWindowId: [Int: WindowHandle] = [:]
    var workspaceByWindowId: [Int: WorkspaceDescriptor.ID] = [:]

    for (workspaceId, windowId) in assignments {
        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            fatalError("Expected handle for seeded IPC router window")
        }
        handlesByWindowId[windowId] = handle
        workspaceByWindowId[windowId] = workspaceId
        _ = controller.workspaceManager.rememberFocus(handle, in: workspaceId)
    }

    if let focusedHandle = handlesByWindowId[focusedWindowId],
       let focusedWorkspaceId = workspaceByWindowId[focusedWindowId]
    {
        _ = controller.workspaceManager.setManagedFocus(
            focusedHandle,
            in: focusedWorkspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: focusedWorkspaceId)
        )
    }

    guard let engine = controller.niriEngine else {
        return handlesByWindowId
    }

    for workspaceId in Set(assignments.map(\.workspaceId)) {
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

    return handlesByWindowId
}

@Suite @MainActor struct IPCCommandRouterTests {
    @Test func workspaceFocusNameExecutesAgainstExistingWorkspace() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, workspaceName: "2")
        )

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "2")
    }

    @Test func workspaceFocusNameAcceptsConfiguredDisplayName() {
        let controller = makeLayoutPlanTestController()
        controller.settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", displayName: "Main"),
            WorkspaceConfiguration(name: "2", displayName: "Code")
        ]
        controller.workspaceManager.applySettings()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, workspaceName: "Code")
        )

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "2")
    }

    @Test func switchWorkspaceTranslatesOneBasedNumbersBeforeRouting() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            .switchWorkspace(workspaceNumber: 2)
        )

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "2")
    }

    @Test func switchWorkspaceNextRoutesRelativeCommand() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(.switchWorkspaceNext)

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "2")
    }

    @Test func switchWorkspaceBackAndForthReturnsToPreviousWorkspace() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        #expect(router.handle(.switchWorkspaceNext) == .executed)

        let result = router.handle(.switchWorkspaceBackAndForth)

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "1")
    }

    @Test func moveToWorkspaceTranslatesOneBasedNumbersBeforeRouting() throws {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)
        let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)!
        let handles = prepareIPCNiriState(
            on: controller,
            assignments: [
                (sourceWorkspaceId, 2001)
            ],
            focusedWindowId: 2001
        )
        let token = try #require(handles[2001]).id

        let result = router.handle(
            .moveToWorkspace(workspaceNumber: 2)
        )

        #expect(result == .executed)
        #expect(controller.workspaceManager.workspace(for: token) == targetWorkspaceId)
    }

    @Test func focusCommandReturnsIgnoredDisabledWhenControllerIsDisabled() {
        let controller = makeLayoutPlanTestController()
        controller.isEnabled = false
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            .focus(direction: .left)
        )

        #expect(result == .ignoredDisabled)
    }

    @Test func setWorkspaceLayoutUpdatesActiveWorkspaceConfiguration() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            .setWorkspaceLayout(layout: .dwindle)
        )

        #expect(result == .executed)
        #expect(controller.settings.layoutType(for: "1") == .dwindle)
    }

    @Test func workspaceFocusNameReturnsIgnoredOverviewWhenOverviewIsOpen() {
        let controller = makeLayoutPlanTestController()
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
            resetSharedControllerStateForTests()
        }
        controller.toggleOverview()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, workspaceName: "2")
        )

        #expect(controller.isOverviewOpen())
        #expect(result == .ignoredOverview)
    }

    @Test func switchWorkspaceRejectsNonPositiveNumbers() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            .switchWorkspace(workspaceNumber: 0)
        )

        #expect(result == .invalidArguments)
    }

    @Test func setWorkspaceLayoutDefaultClearsExplicitOverride() {
        let controller = makeLayoutPlanTestController()
        controller.settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", layoutType: .dwindle),
            WorkspaceConfiguration(name: "2")
        ]
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(.setWorkspaceLayout(layout: .defaultLayout))

        #expect(result == .executed)
        #expect(controller.settings.workspaceConfigurations.first?.layoutType == .defaultLayout)
    }

    @Test func raiseAllFloatingWindowsReturnsNotFoundWithoutPlan() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(.raiseAllFloatingWindows)

        #expect(result == .notFound)
    }

    @Test func workspaceFocusNameReturnsNotFoundForUnknownWorkspace() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, workspaceName: "999")
        )

        #expect(result == .notFound)
    }

    @Test func windowCommandsRejectInvalidOpaqueIdentifiers() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWindowRequest(name: .focus, windowId: "not-an-opaque-id")
        )

        #expect(result == .invalidArguments)
    }

    @Test func windowCommandsReturnNotFoundForMissingTrackedWindow() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWindowRequest(
                name: .focus,
                windowId: IPCWindowOpaqueID.encode(
                    pid: 4242,
                    windowId: 73,
                    sessionToken: ipcCommandRouterSessionToken
                )
            )
        )

        #expect(result == .notFound)
    }

    @Test func windowCommandsRejectOpaqueIdentifiersFromDifferentSession() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWindowRequest(
                name: .focus,
                windowId: IPCWindowOpaqueID.encode(pid: 9001, windowId: 901, sessionToken: "different-session")
            )
        )

        #expect(result == .staleWindowId)
    }

    @Test func windowFocusUsesTrackedWindowRoute() {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 901,
            pid: 9001
        )
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWindowRequest(
                name: .focus,
                windowId: IPCWindowOpaqueID.encode(
                    pid: token.pid,
                    windowId: token.windowId,
                    sessionToken: ipcCommandRouterSessionToken
                )
            )
        )

        #expect(result == .executed)
    }

    @Test func windowNavigateUsesWindowActionHandlerRoute() throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let handles = prepareIPCNiriState(
            on: fixture.controller,
            assignments: [
                (fixture.primaryWorkspaceId, 404),
                (fixture.secondaryWorkspaceId, 405)
            ],
            focusedWindowId: 404
        )
        let targetHandle = try #require(handles[405])
        let router = makeIPCCommandRouter(for: fixture.controller)

        let result = router.handle(
            IPCWindowRequest(
                name: .navigate,
                windowId: IPCWindowOpaqueID.encode(
                    pid: targetHandle.id.pid,
                    windowId: targetHandle.id.windowId,
                    sessionToken: ipcCommandRouterSessionToken
                )
            )
        )

        #expect(result == .executed)
        #expect(fixture.controller.activeWorkspace()?.id == fixture.secondaryWorkspaceId)
    }

    @Test func windowSummonRightUsesWindowActionHandlerRoute() throws {
        let controller = makeLayoutPlanTestController()
        let targetWorkspaceId = try #require(controller.activeWorkspace()?.id)
        let handles = prepareIPCNiriState(
            on: controller,
            assignments: [
                (targetWorkspaceId, 9101),
                (targetWorkspaceId, 9102),
                (targetWorkspaceId, 9103)
            ],
            focusedWindowId: 9101
        )
        let summonedHandle = try #require(handles[9102])
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWindowRequest(
                name: .summonRight,
                windowId: IPCWindowOpaqueID.encode(
                    pid: summonedHandle.id.pid,
                    windowId: summonedHandle.id.windowId,
                    sessionToken: ipcCommandRouterSessionToken
                )
            )
        )

        #expect(result == .executed)
        #expect(controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId)?.windowId == 9102)
    }
}

@Suite struct IPCApplicationBridgeResponseTests {
    @Test func ignoredLayoutMismatchMapsToStableIgnoredResponse() {
        let response = IPCApplicationBridge.response(
            for: .ignoredLayoutMismatch,
            id: "cmd-1",
            kind: .command
        )

        #expect(response.kind == .command)
        #expect(response.ok == false)
        #expect(response.status == .ignored)
        #expect(response.code == .layoutMismatch)
    }
}
