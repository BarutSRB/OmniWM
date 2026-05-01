// SPDX-License-Identifier: GPL-2.0-only
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
            IPCWorkspaceRequest(name: .focusName, target: WorkspaceTarget(parsing: "2"))
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
            IPCWorkspaceRequest(name: .focusName, target: WorkspaceTarget(parsing: "Code"))
        )

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "2")
    }

    @Test func workspaceFocusNameResolvesWorkspace10AsRawWorkspaceID() {
        let controller = makeLayoutPlanTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "10", monitorAssignment: .main)
            ]
        )
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, target: WorkspaceTarget(parsing: "10"))
        )

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "10")
    }

    @Test func workspaceFocusNameRejectsAmbiguousDisplayNames() {
        let controller = makeLayoutPlanTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", displayName: "Code", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", displayName: "Code", monitorAssignment: .main)
            ]
        )
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, target: WorkspaceTarget(parsing: "Code"))
        )

        #expect(result == .invalidArguments)
        #expect(controller.activeWorkspace()?.name == "1")
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

    @Test func switchWorkspaceSupportsWorkspace10() {
        let controller = makeLayoutPlanTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "10", monitorAssignment: .main)
            ]
        )
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            .switchWorkspace(workspaceNumber: 10)
        )

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "10")
    }

    @Test func switchWorkspaceNextRoutesRelativeCommand() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(.switchWorkspaceNext)

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.name == "2")
    }

    @Test func switchWorkspaceReturnsNotFoundWhenTargetWorkspaceIsAlreadyActive() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        #expect(router.handle(.switchWorkspace(workspaceNumber: 2)) == .executed)
        #expect(controller.activeWorkspace()?.name == "2")

        let repeatedSwitchResult = router.handle(
            .switchWorkspace(workspaceNumber: 2)
        )

        #expect(repeatedSwitchResult == .notFound)
        #expect(controller.activeWorkspace()?.name == "2")

        let backAndForthResult = router.handle(.switchWorkspaceBackAndForth)

        #expect(backAndForthResult == .executed)
        #expect(controller.activeWorkspace()?.name == "1")
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

    @Test func moveToWorkspaceMovesFocusedFloatingWindowWithoutNiriNode() throws {
        let controller = makeLayoutPlanTestController()
        controller.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let router = makeIPCCommandRouter(for: controller)
        let sourceWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let targetWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let monitor = try #require(controller.workspaceManager.monitor(for: sourceWorkspaceId))
        let floatingWindow = addFloatingLayoutPlanTestWindow(
            to: controller,
            workspaceId: sourceWorkspaceId,
            referenceMonitorId: monitor.id,
            windowId: 2002,
            frame: CGRect(x: 100, y: 120, width: 480, height: 320),
            normalizedOrigin: CGPoint(x: 0.1, y: 0.2)
        )
        _ = controller.workspaceManager.setManagedFocus(floatingWindow.token, in: sourceWorkspaceId, onMonitor: monitor.id)
        #expect(controller.niriEngine?.findNode(for: floatingWindow.token) == nil)

        let result = router.handle(
            .moveToWorkspace(workspaceNumber: 2)
        )

        let graph = controller.workspaceManager.workspaceGraphSnapshot()
        #expect(result == .executed)
        #expect(controller.workspaceManager.workspace(for: floatingWindow.token) == targetWorkspaceId)
        #expect(controller.workspaceManager.windowMode(for: floatingWindow.token) == .floating)
        #expect(controller.workspaceManager.floatingState(for: floatingWindow.token) == floatingWindow.floatingState)
        #expect(!graph.floatingMembership(in: sourceWorkspaceId).contains { $0.logicalId == floatingWindow.logicalId })
        #expect(graph.floatingMembership(in: targetWorkspaceId).contains { $0.logicalId == floatingWindow.logicalId })
        #expect(controller.workspaceManager.lastFloatingFocusedToken(in: targetWorkspaceId) == floatingWindow.token)
    }

    @Test func moveToWorkspaceSupportsWorkspace10() throws {
        let controller = makeLayoutPlanTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "10", monitorAssignment: .main)
            ]
        )
        let router = makeIPCCommandRouter(for: controller)
        let sourceWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let targetWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "10", createIfMissing: false))
        let handles = prepareIPCNiriState(
            on: controller,
            assignments: [
                (sourceWorkspaceId, 2010)
            ],
            focusedWindowId: 2010
        )
        let token = try #require(handles[2010]).id

        let result = router.handle(
            .moveToWorkspace(workspaceNumber: 10)
        )

        #expect(result == .executed)
        #expect(controller.workspaceManager.workspace(for: token) == targetWorkspaceId)
    }

    @Test func moveToWorkspaceOnMonitorRejectsWorkspaceOnWrongAdjacentMonitor() throws {
        let primaryMonitor = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
        let secondaryMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
        let controller = makeLayoutPlanTestController(
            monitors: [primaryMonitor, secondaryMonitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "10", monitorAssignment: .main)
            ]
        )
        controller.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()

        let router = makeIPCCommandRouter(for: controller)
        let sourceWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let targetWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "10", createIfMissing: false))
        let handles = prepareIPCNiriState(
            on: controller,
            assignments: [
                (sourceWorkspaceId, 2020)
            ],
            focusedWindowId: 2020
        )
        let token = try #require(handles[2020]).id

        #expect(controller.workspaceManager.monitorId(for: targetWorkspaceId) == primaryMonitor.id)

        let result = router.handle(
            .moveToWorkspaceOnMonitor(workspaceNumber: 10, direction: .right)
        )

        #expect(result == .notFound)
        #expect(controller.workspaceManager.workspace(for: token) == sourceWorkspaceId)
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

    @Test func disabledControllerRejectsColumnLayoutWindowAndUICommands() {
        let controller = makeLayoutPlanTestController()
        controller.isEnabled = false
        let router = makeIPCCommandRouter(for: controller)

        #expect(router.handle(.moveColumn(direction: .right)) == .ignoredDisabled)
        #expect(router.handle(.toggleSplit) == .ignoredDisabled)
        #expect(router.handle(.toggleFullscreen) == .ignoredDisabled)
        #expect(router.handle(.openCommandPalette) == .ignoredDisabled)
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
            IPCWorkspaceRequest(name: .focusName, target: WorkspaceTarget(parsing: "2"))
        )

        #expect(controller.isOverviewOpen())
        #expect(result == .ignoredOverview)
    }

    @Test func overviewRejectsColumnLayoutWindowAndUICommandsButAllowsToggleOverview() {
        let controller = makeLayoutPlanTestController()
        controller.setAnimationsEnabled(false, persist: false)
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
            resetSharedControllerStateForTests()
        }
        controller.toggleOverview()
        let router = makeIPCCommandRouter(for: controller)

        #expect(router.handle(.moveColumn(direction: .right)) == .ignoredOverview)
        #expect(router.handle(.toggleSplit) == .ignoredOverview)
        #expect(router.handle(.toggleFullscreen) == .ignoredOverview)
        #expect(router.handle(.openCommandPalette) == .ignoredOverview)

        let toggleResult = router.handle(.toggleOverview)
        #expect(toggleResult == .executed)
        #expect(!controller.isOverviewOpen())
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

    @Test func rescueOffscreenWindowsRoutesThroughControllerAndReturnsNotFoundWhenSettled() throws {
        let controller = makeLayoutPlanTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main)
            ]
        )
        let router = makeIPCCommandRouter(for: controller)
        let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let monitor = try #require(controller.workspaceManager.monitor(for: workspaceId))
        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 2401),
            pid: 2401,
            windowId: 2401,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: monitor.visibleFrame.minX - 1600, y: monitor.visibleFrame.minY - 1200, width: 320, height: 200),
            for: token,
            referenceMonitor: monitor
        )

        #expect(router.handle(.rescueOffscreenWindows) == .executed)
        #expect(monitor.visibleFrame.contains(try #require(controller.axManager.lastAppliedFrame(for: token.windowId))))
        #expect(router.handle(.rescueOffscreenWindows) == .notFound)
    }

    @Test func workspaceFocusNameReturnsNotFoundForUnknownWorkspace() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, target: WorkspaceTarget(parsing: "999"))
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
