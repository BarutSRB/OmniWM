import CoreGraphics
import Foundation
import Testing

import OmniWMIPC
@testable import OmniWM

private let ipcQueryRouterSessionToken = "ipc-query-router-tests"
private let ipcQueryRouterAuthorization = "ipc-query-router-secret"

@MainActor
private func prepareIPCQueryRouterNiriState(
    on controller: WMController,
    assignments: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
    focusedWindowId: Int
) {
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
            fatalError("Expected handle for seeded IPC query router window")
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

    guard let engine = controller.niriEngine else { return }

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
}

@Suite(.serialized) @MainActor struct IPCQueryRouterTests {
    @Test func workspaceBarQueryPreservesBarProjectionSemantics() throws {
        let controller = makeLayoutPlanTestController()
        defer { resetSharedControllerStateForTests() }
        controller.settings.workspaceBarHideEmptyWorkspaces = true

        guard let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: 7001, name: "Tiled App", bundleId: "com.example.tiled")
        controller.appInfoCache.storeInfoForTests(pid: 7002, name: "Floating App", bundleId: "com.example.floating")
        controller.appInfoCache.storeInfoForTests(pid: 7003, name: "Hidden Floating App", bundleId: "com.example.hidden")

        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1001),
            pid: 7001,
            windowId: 1001,
            to: workspace1,
            mode: .tiling
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1002),
            pid: 7002,
            windowId: 1002,
            to: workspace1,
            mode: .floating
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1003),
            pid: 7003,
            windowId: 1003,
            to: workspace2,
            mode: .floating
        )

        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)
        let result = router.workspaceBarResult()
        let monitor = try #require(result.monitors.first)
        let workspace = try #require(monitor.workspaces.first(where: { $0.rawName == "1" }))
        let app = try #require(workspace.windows.first)

        #expect(monitor.workspaces.map(\.rawName).contains("1"))
        #expect(monitor.workspaces.map(\.rawName).contains("2") == false)
        #expect(workspace.windows.count == 1)
        #expect(workspace.windows.map(\.appName) == ["Tiled App"])
        #expect(IPCWindowOpaqueID.decode(app.id, expectingSessionToken: ipcQueryRouterSessionToken)?.pid == 7001)
    }

    @Test func activeWorkspaceQueryUsesInteractionMonitorSemantics() throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let router = IPCQueryRouter(controller: fixture.controller, sessionToken: ipcQueryRouterSessionToken)

        let primaryResult = router.activeWorkspaceResult()
        #expect(primaryResult.display?.id == "display:\(fixture.primaryMonitor.displayId)")
        #expect(primaryResult.workspace?.rawName == "1")

        _ = fixture.controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id)
        let secondaryResult = router.activeWorkspaceResult()
        #expect(secondaryResult.display?.id == "display:\(fixture.secondaryMonitor.displayId)")
        #expect(secondaryResult.workspace?.rawName == "2")
    }

    @Test func focusedMonitorQueryUsesInteractionMonitorSemantics() throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let router = IPCQueryRouter(controller: fixture.controller, sessionToken: ipcQueryRouterSessionToken)

        let primaryResult = router.focusedMonitorResult()
        #expect(primaryResult.display?.id == "display:\(fixture.primaryMonitor.displayId)")
        #expect(primaryResult.activeWorkspace?.rawName == "1")

        _ = fixture.controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id)
        let secondaryResult = router.focusedMonitorResult()
        #expect(secondaryResult.display?.id == "display:\(fixture.secondaryMonitor.displayId)")
        #expect(secondaryResult.activeWorkspace?.rawName == "2")
    }

    @Test func appsQueryReturnsManagedBundleSummaryInsteadOfFullInventory() {
        let controller = makeLayoutPlanTestController()
        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(pid: 8001, name: "Shared App", bundleId: "com.example.shared")
        controller.appInfoCache.storeInfoForTests(pid: 8002, name: "Shared App", bundleId: "com.example.shared")
        controller.appInfoCache.storeInfoForTests(pid: 8003, name: "Fullscreen App", bundleId: "com.example.fullscreen")

        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1101),
            pid: 8001,
            windowId: 1101,
            to: workspaceId
        )
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1102),
            pid: 8002,
            windowId: 1102,
            to: workspaceId
        )
        let fullscreenToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1103),
            pid: 8003,
            windowId: 1103,
            to: workspaceId
        )
        controller.workspaceManager.entry(for: fullscreenToken)?.layoutReason = .nativeFullscreen

        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)
        let result = router.appsResult()

        #expect(result.apps.count == 1)
        #expect(result.apps.first?.bundleId == "com.example.shared")
        #expect(result.apps.first?.appName == "Shared App")
    }

    @Test func focusedWindowQueryUsesManagedFocusAndFastMetadata() {
        let controller = makeLayoutPlanTestController()
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            AXWindowService.titleLookupProviderForTests = nil
            resetSharedControllerStateForTests()
        }
        controller.layoutRefreshController.resetDebugState()
        controller.resetWorkspaceBarRefreshDebugStateForTests()

        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(pid: 9001, name: "Terminal", bundleId: "com.example.terminal")
        var titleLookupCount = 0
        AXWindowService.titleLookupProviderForTests = { windowId in
            titleLookupCount += 1
            return windowId == 1201 ? "Focused Title" : nil
        }
        var fastFrameLookupCount = 0
        AXWindowService.fastFrameProviderForTests = { window in
            fastFrameLookupCount += 1
            guard window.windowId == 1201 else { return nil }
            return CGRect(x: 10, y: 20, width: 300, height: 200)
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1201),
            pid: 9001,
            windowId: 1201,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId)

        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)
        let result = router.focusedWindowResult()

        #expect(
            result.window?.id == IPCWindowOpaqueID.encode(
                pid: token.pid,
                windowId: token.windowId,
                sessionToken: ipcQueryRouterSessionToken
            )
        )
        #expect(result.window?.pid == token.pid)
        #expect(result.window?.workspace?.rawName == "1")
        #expect(result.window?.workspace?.number == 1)
        #expect(result.window?.app?.name == "Terminal")
        #expect(result.window?.app?.bundleId == "com.example.terminal")
        #expect(result.window?.title == "Focused Title")
        #expect(result.window?.frame == IPCRect(x: 10, y: 20, width: 300, height: 200))
        #expect(titleLookupCount == 1)
        #expect(fastFrameLookupCount == 1)
        #expect(controller.layoutRefreshController.refreshDebugSnapshot().relayoutExecutions == 0)
        #expect(controller.layoutRefreshController.refreshDebugSnapshot().immediateRelayoutExecutions == 0)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(controller.workspaceBarRefreshDebugState.requestCount == 0)
    }

    @Test func windowsQueryFiltersManagedInventoryAndProjectsRequestedFields() {
        let controller = makeLayoutPlanTestController()
        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(pid: 9501, name: "Terminal", bundleId: "com.example.terminal")
        controller.appInfoCache.storeInfoForTests(pid: 9502, name: "Browser", bundleId: "com.example.browser")

        let visibleToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1601),
            pid: 9501,
            windowId: 1601,
            to: workspaceId
        )
        let hiddenToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1602),
            pid: 9502,
            windowId: 1602,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: CGPoint(x: 0.5, y: 0.5),
                referenceMonitorId: controller.workspaceManager.monitor(for: workspaceId)?.id,
                reason: .scratchpad
            ),
            for: hiddenToken
        )
        controller.workspaceManager.setManualLayoutOverride(.forceFloat, for: hiddenToken)
        _ = controller.workspaceManager.setManagedFocus(visibleToken, in: workspaceId)

        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)
        let result = router.windowsResult(
            IPCQueryRequest(
                name: .windows,
                selectors: IPCQuerySelectors(visible: true),
                fields: ["id", "pid", "title", "is-visible", "app", "workspace", "display"]
            )
        )

        #expect(result.windows.count == 1)
        #expect(result.windows.first?.id == IPCWindowOpaqueID.encode(
            pid: visibleToken.pid,
            windowId: visibleToken.windowId,
            sessionToken: ipcQueryRouterSessionToken
        ))
        #expect(result.windows.first?.pid == visibleToken.pid)
        #expect(result.windows.first?.isVisible == true)
        #expect(result.windows.first?.app?.bundleId == "com.example.terminal")
        #expect(result.windows.first?.workspace?.rawName == "1")
        #expect(result.windows.first?.display?.id != nil)

        let hiddenResult = router.windowsResult(
            IPCQueryRequest(
                name: .windows,
                selectors: IPCQuerySelectors(window: IPCWindowOpaqueID.encode(
                    pid: hiddenToken.pid,
                    windowId: hiddenToken.windowId,
                    sessionToken: ipcQueryRouterSessionToken
                )),
                fields: ["id", "manual-override", "hidden-reason", "is-scratchpad", "mode"]
            )
        )
        #expect(hiddenResult.windows.count == 1)
        #expect(hiddenResult.windows.first?.manualOverride == .forceFloat)
        #expect(hiddenResult.windows.first?.hiddenReason == .scratchpad)
        #expect(hiddenResult.windows.first?.mode == .floating)
    }

    @Test func windowsQueryUsesSharedWorkspaceBarOrderingForNiriLayouts() throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        else {
            Issue.record("Missing workspace/query fixture")
            return
        }

        controller.appInfoCache.storeInfoForTests(pid: getpid(), name: "Terminal", bundleId: "com.example.terminal")
        prepareIPCQueryRouterNiriState(
            on: controller,
            assignments: [(workspaceId, 2101), (workspaceId, 2102), (workspaceId, 2103)],
            focusedWindowId: 2102
        )

        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)
        let queryResult = router.windowsResult(
            IPCQueryRequest(
                name: .windows,
                selectors: IPCQuerySelectors(workspace: "1"),
                fields: ["id"]
            )
        )
        let barItems = WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            deduplicate: false,
            hideEmpty: false,
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            niriEngine: controller.niriEngine,
            focusedToken: controller.workspaceManager.focusedToken,
            settings: controller.settings
        )
        let barWorkspace = try #require(barItems.first(where: { $0.rawName == "1" }))
        let barWindowIDs = barWorkspace.windows.map {
            IPCWindowOpaqueID.encode(
                pid: $0.id.pid,
                windowId: $0.id.windowId,
                sessionToken: ipcQueryRouterSessionToken
            )
        }

        #expect(queryResult.windows.compactMap(\.id) == barWindowIDs)
    }

    @Test func workspacesAndDisplaysQueriesExposeConfiguredAssignmentsAndCapabilities() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        fixture.controller.appInfoCache.storeInfoForTests(pid: 9701, name: "Terminal", bundleId: "com.example.terminal")
        let workspace1 = fixture.controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        let token = fixture.controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1801),
            pid: 9701,
            windowId: 1801,
            to: workspace1
        )
        _ = fixture.controller.workspaceManager.setManagedFocus(token, in: workspace1)
        let router = IPCQueryRouter(controller: fixture.controller, sessionToken: ipcQueryRouterSessionToken)

        let workspaceResult = router.workspacesResult(
            IPCQueryRequest(name: .workspaces, selectors: IPCQuerySelectors(visible: true))
        )
        let displayResult = router.displaysResult(IPCQueryRequest(name: .displays))
        let capabilities = router.capabilitiesResult()

        #expect(workspaceResult.workspaces.count == 2)
        #expect(workspaceResult.workspaces.contains { $0.rawName == "1" && $0.isVisible == true })
        #expect(workspaceResult.workspaces.contains { $0.rawName == "1" && $0.focusedWindowId != nil })
        #expect(workspaceResult.workspaces.contains {
            $0.rawName == "2" && $0.display?.name == fixture.secondaryMonitor.name
        })
        #expect(workspaceResult.workspaces.first(where: { $0.rawName == "1" })?.counts?.total == 1)
        #expect(displayResult.displays.count == 2)
        #expect(displayResult.displays.contains { $0.id == "display:\(fixture.primaryMonitor.displayId)" })
        #expect(displayResult.displays.contains { $0.activeWorkspace?.rawName == "1" })
        #expect(capabilities.authorizationRequired)
        #expect(capabilities.windowIdScope == "session")
        #expect(capabilities.queries.contains { $0.name == .focusedMonitor })
        #expect(capabilities.queries.contains { $0.name == .windows && $0.fields.contains("app") })
        #expect(capabilities.ruleActions.contains { $0.name == .add })
        #expect(capabilities.subscriptions.contains { $0.channel == .focusedMonitor })
        #expect(capabilities.subscriptions.contains { $0.channel == .windowsChanged })
    }

    @Test func queriesQueryReturnsManifestBackedDescriptorsAndMatchesCapabilities() {
        let controller = makeLayoutPlanTestController()
        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)

        let queries = router.queriesResult()
        let capabilities = router.capabilitiesResult()

        #expect(queries.queries == IPCAutomationManifest.queryDescriptors)
        #expect(queries.queries.map(\.name) == capabilities.queries.map(\.name))
        #expect(queries.queries.contains { $0.name == .queries })
    }

    @Test func ruleActionsQueryReturnsManifestBackedDescriptorsAndMatchesCapabilities() {
        let controller = makeLayoutPlanTestController()
        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)

        let ruleActions = router.ruleActionsResult()
        let capabilities = router.capabilitiesResult()

        #expect(ruleActions.ruleActions == IPCAutomationManifest.ruleActionDescriptors)
        #expect(ruleActions.ruleActions == capabilities.ruleActions)
        #expect(ruleActions.ruleActions.contains { $0.name == .apply && !$0.options.isEmpty })
    }

    @Test func rulesQueryReturnsPersistedRulesInOrderAndNormalizesLegacyFields() throws {
        let controller = makeLayoutPlanTestController()
        let invalidRuleId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let tiledRuleId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        controller.settings.appRules = [
            AppRule(
                id: invalidRuleId,
                bundleId: "com.example.float",
                appNameSubstring: " Float App ",
                titleRegex: "[",
                alwaysFloat: true,
                manage: .off,
                assignToWorkspace: " 2 "
            ),
            AppRule(
                id: tiledRuleId,
                bundleId: "com.example.tile",
                titleSubstring: " Editor ",
                layout: .tile,
                minWidth: 900,
                minHeight: 700
            ),
        ]
        controller.updateAppRules()

        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)
        let result = router.rulesResult()

        #expect(result.rules.map(\.id) == [invalidRuleId.uuidString, tiledRuleId.uuidString])
        #expect(result.rules.map(\.position) == [1, 2])
        #expect(result.rules.count == controller.settings.appRules.count)

        let invalidRule = try #require(result.rules.first)
        #expect(invalidRule.bundleId == "com.example.float")
        #expect(invalidRule.appNameSubstring == "Float App")
        #expect(invalidRule.layout == .float)
        #expect(invalidRule.assignToWorkspace == "2")
        #expect(invalidRule.isValid == false)
        #expect(invalidRule.invalidRegexMessage != nil)

        let tiledRule = try #require(result.rules.last)
        #expect(tiledRule.layout == .tile)
        #expect(tiledRule.titleSubstring == "Editor")
        #expect(tiledRule.minWidth == 900)
        #expect(tiledRule.minHeight == 700)
        #expect(tiledRule.isValid == true)
    }

    @Test func focusedWindowDecisionQueryUsesSessionScopedId() {
        let controller = makeLayoutPlanTestController()
        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1701),
            pid: 9601,
            windowId: 1701,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId)
        let router = IPCQueryRouter(controller: controller, sessionToken: ipcQueryRouterSessionToken)

        let result = router.focusedWindowDecisionResult()

        #expect(result.window?.id == IPCWindowOpaqueID.encode(
            pid: token.pid,
            windowId: token.windowId,
            sessionToken: ipcQueryRouterSessionToken
        ))
        #expect(result.window?.disposition == .undecided)
        #expect(result.window?.admissionOutcome == .deferred)
    }
}

@Suite(.serialized) @MainActor struct IPCApplicationBridgeQueryTests {
    @Test func bridgeRoutesQueryRegistryAndKeepsCapabilitiesInSync() async throws {
        let controller = makeLayoutPlanTestController()
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "1.2.3",
            sessionToken: ipcQueryRouterSessionToken,
            authorizationToken: ipcQueryRouterAuthorization
        )

        let queriesResponse = await bridge.response(
            for: IPCRequest(
                id: "query-queries",
                query: IPCQueryRequest(name: .queries),
                authorizationToken: ipcQueryRouterAuthorization
            )
        )
        let ruleActionsResponse = await bridge.response(
            for: IPCRequest(
                id: "query-rule-actions",
                query: IPCQueryRequest(name: .ruleActions),
                authorizationToken: ipcQueryRouterAuthorization
            )
        )
        let capabilitiesResponse = await bridge.response(
            for: IPCRequest(
                id: "query-capabilities",
                query: IPCQueryRequest(name: .capabilities),
                authorizationToken: ipcQueryRouterAuthorization
            )
        )

        #expect(queriesResponse.ok)
        #expect(ruleActionsResponse.ok)
        #expect(capabilitiesResponse.ok)

        guard case let .queries(queriesPayload)? = queriesResponse.result?.payload else {
            Issue.record("Expected queries payload")
            return
        }
        guard case let .ruleActions(ruleActionsPayload)? = ruleActionsResponse.result?.payload else {
            Issue.record("Expected rule-actions payload")
            return
        }
        guard case let .capabilities(capabilitiesPayload)? = capabilitiesResponse.result?.payload else {
            Issue.record("Expected capabilities payload")
            return
        }

        #expect(queriesPayload.queries == IPCAutomationManifest.queryDescriptors)
        #expect(ruleActionsPayload.ruleActions == IPCAutomationManifest.ruleActionDescriptors)
        #expect(ruleActionsPayload.ruleActions == capabilitiesPayload.ruleActions)
        #expect(queriesPayload.queries.map { $0.name } == capabilitiesPayload.queries.map { $0.name })
    }
}
