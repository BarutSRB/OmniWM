import Foundation
@testable import OmniWM
import OmniWMIPC
import Testing

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
            IPCWorkspaceRequest(name: .focusName, target: .rawID("2"))
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
            IPCWorkspaceRequest(name: .focusName, target: .displayName("Code"))
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
            IPCWorkspaceRequest(name: .focusName, target: .rawID("10"))
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
            IPCWorkspaceRequest(name: .focusName, target: .displayName("Code"))
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

    @Test func moveWindowDownOrToWorkspaceDownFallsBackAtColumnEdge() throws {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)
        let sourceWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let targetWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let handles = prepareIPCNiriState(
            on: controller,
            assignments: [
                (sourceWorkspaceId, 2101)
            ],
            focusedWindowId: 2101
        )
        let token = try #require(handles[2101]).id

        let result = router.handle(.moveWindowDownOrToWorkspaceDown)

        #expect(result == .executed)
        #expect(controller.workspaceManager.workspace(for: token) == targetWorkspaceId)
    }

    @Test func focusWindowOrWorkspaceDownFallsBackAtColumnEdge() throws {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)
        let sourceWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let targetWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let handles = prepareIPCNiriState(
            on: controller,
            assignments: [
                (sourceWorkspaceId, 2111)
            ],
            focusedWindowId: 2111
        )
        let token = try #require(handles[2111]).id

        let result = router.handle(.focusWindowOrWorkspaceDown)

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.id == targetWorkspaceId)
        #expect(controller.workspaceManager.workspace(for: token) == sourceWorkspaceId)
    }

    @Test func focusWindowOrWorkspaceDownFallsBackFromEmptyWorkspace() throws {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)
        let sourceWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let targetWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        controller.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        controller.workspaceManager.updateNiriViewportState(ViewportState(), for: sourceWorkspaceId)

        let result = router.handle(.focusWindowOrWorkspaceDown)

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.id == targetWorkspaceId)
    }

    @Test func focusWindowOrWorkspaceUpFallsBackFromEmptyWorkspace() throws {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)
        let targetWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let sourceWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let monitor = try #require(controller.workspaceManager.monitor(for: targetWorkspaceId))
        #expect(controller.workspaceManager.setActiveWorkspace(sourceWorkspaceId, on: monitor.id))
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)
        controller.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        controller.workspaceManager.updateNiriViewportState(ViewportState(), for: sourceWorkspaceId)

        let result = router.handle(.focusWindowOrWorkspaceUp)

        #expect(result == .executed)
        #expect(controller.activeWorkspace()?.id == targetWorkspaceId)
    }

    @Test func centerColumnCommandRecentersNiriViewport() throws {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)
        let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let handles = prepareIPCNiriState(
            on: controller,
            assignments: [
                (workspaceId, 2121),
                (workspaceId, 2122),
                (workspaceId, 2123)
            ],
            focusedWindowId: 2122
        )
        let focusedHandle = try #require(handles[2122])
        let engine = try #require(controller.niriEngine)
        let focusedNode = try #require(engine.findNode(for: focusedHandle))
        let focusedColumn = try #require(engine.column(of: focusedNode))
        let focusedColumnIndex = try #require(engine.columnIndex(of: focusedColumn, in: workspaceId))
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(400)
            column.cachedWidth = 400
        }
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = focusedNode.id
        state.activeColumnIndex = focusedColumnIndex
        state.viewOffsetPixels = .static(0)
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)

        let result = router.handle(.centerColumn)

        let updated = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(result == .executed)
        #expect(updated.activeColumnIndex == focusedColumnIndex)
        #expect(abs(updated.viewOffsetPixels.target() + 760) < 0.001)
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
            IPCWorkspaceRequest(name: .focusName, target: .rawID("2"))
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

    @Test func raiseAllFloatingWindowsReturnsIgnoredDisabledWhenControllerIsDisabled() {
        let controller = makeLayoutPlanTestController()
        controller.isEnabled = false
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(.raiseAllFloatingWindows)

        #expect(result == .ignoredDisabled)
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
            frame: CGRect(
                x: monitor.visibleFrame.minX - 1600,
                y: monitor.visibleFrame.minY - 1200,
                width: 320,
                height: 200
            ),
            for: token,
            referenceMonitor: monitor
        )

        #expect(router.handle(.rescueOffscreenWindows) == .executed)
        #expect(monitor.visibleFrame.contains(try #require(controller.axManager.lastAppliedFrame(for: token.windowId))))
        #expect(router.handle(.rescueOffscreenWindows) == .notFound)
    }

    @Test func scratchpadToggleReturnsExecutedForPendingAsyncReveal() throws {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)
        let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let monitor = try #require(controller.workspaceManager.monitor(for: workspaceId))
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 2_501)
        defer {
            controller.layoutRefreshController.cancelPendingScratchpadReveal(for: token)
        }

        let frame = CGRect(x: 180, y: 160, width: 640, height: 420)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, frame)])
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        #expect(router.handle(.scratchpadAssign) == .executed)
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: AXFrameWriteResult(
                        targetFrame: request.frame,
                        observedFrame: nil,
                        writeOrder: AXWindowService.frameWriteOrder(
                            currentFrame: request.currentFrameHint,
                            targetFrame: request.frame
                        ),
                        sizeError: .success,
                        positionError: .success,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }

        let result = router.handle(.scratchpadToggle)

        #expect(result == .executed)
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
    }

    @Test func scratchpadToggleReturnsNotFoundWhenHiddenScratchpadHasNoRestoreGeometry() async throws {
        try await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            let router = makeIPCCommandRouter(for: controller)
            let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
            let monitor = try #require(controller.workspaceManager.monitor(for: workspaceId))
            let token = controller.workspaceManager.addWindow(
                makeLayoutPlanTestWindow(windowId: 2_502),
                pid: getpid(),
                windowId: 2_502,
                to: workspaceId,
                mode: .floating
            )
            AXWindowService.fastFrameProviderForTests = { window in
                window.windowId == token.windowId ? nil : fallbackFastFrameForTests(window)
            }
            defer {
                AXWindowService.fastFrameProviderForTests = nil
            }
            _ = controller.workspaceManager.setScratchpadToken(token)
            controller.workspaceManager.setHiddenState(
                .init(
                    proportionalPosition: CGPoint(x: 0.6, y: 0.6),
                    referenceMonitorId: monitor.id,
                    reason: .scratchpad
                ),
                for: token
            )

            let result = router.handle(.scratchpadToggle)

            #expect(result == .notFound)
            #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
            #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        }
    }

    @Test func workspaceFocusNameReturnsNotFoundForUnknownWorkspace() {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCCommandRouter(for: controller)

        let result = router.handle(
            IPCWorkspaceRequest(name: .focusName, target: .rawID("999"))
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
