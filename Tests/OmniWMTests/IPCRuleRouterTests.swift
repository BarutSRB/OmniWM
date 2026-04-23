// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

import OmniWMIPC
@testable import OmniWM

private let ipcRuleTestSessionToken = "ipc-rule-tests"
private let ipcRuleTestAuthorization = "ipc-rule-tests-secret"

@MainActor
private func waitUntilRuleTest(
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0..<iterations where !condition() {
        await Task.yield()
    }

    if !condition() {
        Issue.record("Timed out waiting for condition")
    }
}

private func requireRulesResult(_ response: IPCResponse) throws -> IPCRulesQueryResult {
    let result = try #require(response.result)
    guard case let .rules(rules) = result.payload else {
        Issue.record("Expected rules payload")
        throw RuleTestError.unexpectedPayload
    }
    return rules
}

private enum RuleTestError: Error {
    case unexpectedPayload
}

@MainActor
private func makeIPCRuleRouter(for controller: WMController) -> IPCRuleRouter {
    IPCRuleRouter(controller: controller, sessionToken: ipcRuleTestSessionToken)
}

@MainActor
private func seedRuleApplyWindow(
    on controller: WMController,
    pid: pid_t,
    windowId: Int,
    bundleId: String,
    appName: String = "Rule Apply App",
    focused: Bool = true
) -> WindowToken {
    let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
    controller.appInfoCache.storeInfoForTests(pid: pid, name: appName, bundleId: bundleId)
    let token = controller.workspaceManager.addWindow(
        makeLayoutPlanTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId
    )
    if focused {
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId)
    }
    return token
}

@MainActor
private func installDeferredRuleApplyRule(
    on controller: WMController,
    bundleId: String,
    layout: WindowRuleLayoutAction = .float
) async {
    controller.layoutRefreshController.resetDebugState()
    controller.layoutRefreshController.debugHooks.onFullRescan = { _ in true }
    controller.settings.appRules = [AppRule(bundleId: bundleId, layout: layout)]
    controller.updateAppRules()
    await waitForLayoutPlanRefreshWork(on: controller)
}

@Suite(.serialized) @MainActor struct IPCRuleRouterTests {
    @Test func addAppendsRuleAndTriggersFullRescan() async throws {
        let controller = makeLayoutPlanTestController()
        controller.settings.appRules = []
        var fullRescanReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            return true
        }

        let router = makeIPCRuleRouter(for: controller)
        let result = await router.handle(
            .add(
                rule: IPCRuleDefinition(
                    bundleId: "com.example.terminal",
                    titleSubstring: "Shell",
                    layout: .float,
                    assignToWorkspace: "2",
                    minWidth: 640,
                    minHeight: 480
                )
            )
        )

        guard case let .success(rules) = result else {
            Issue.record("Expected add to succeed")
            return
        }

        let storedRule = try #require(controller.settings.appRules.first)
        #expect(storedRule.bundleId == "com.example.terminal")
        #expect(rules.rules.count == 1)
        #expect(rules.rules.first?.bundleId == "com.example.terminal")
        #expect(rules.rules.first?.position == 1)

        await waitUntilRuleTest { fullRescanReasons == [.appRulesChanged] }
        #expect(fullRescanReasons == [.appRulesChanged])
    }

    @Test func replaceMoveAndRemoveMutateStoredOrderAndReturnUpdatedProjection() async throws {
        let controller = makeLayoutPlanTestController()
        let firstId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        controller.settings.appRules = [
            AppRule(id: firstId, bundleId: "com.example.one"),
            AppRule(id: secondId, bundleId: "com.example.two", layout: .tile),
        ]

        var fullRescanReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            return true
        }

        let router = makeIPCRuleRouter(for: controller)

        let replaceResult = await router.handle(
            .replace(
                id: secondId.uuidString,
                rule: IPCRuleDefinition(
                    bundleId: "com.example.replaced",
                    titleSubstring: "Docs",
                    layout: .float
                )
            )
        )
        guard case let .success(replacedRules) = replaceResult else {
            Issue.record("Expected replace to succeed")
            return
        }
        #expect(replacedRules.rules.map(\.id) == [firstId.uuidString, secondId.uuidString])
        #expect(replacedRules.rules.last?.bundleId == "com.example.replaced")
        #expect(controller.settings.appRules.last?.bundleId == "com.example.replaced")
        await waitUntilRuleTest { fullRescanReasons.count == 1 }

        let moveResult = await router.handle(.move(id: secondId.uuidString, position: 1))
        guard case let .success(movedRules) = moveResult else {
            Issue.record("Expected move to succeed")
            return
        }
        #expect(movedRules.rules.map(\.id) == [secondId.uuidString, firstId.uuidString])
        #expect(controller.settings.appRules.map(\.id) == [secondId, firstId])
        await waitUntilRuleTest { fullRescanReasons.count == 2 }

        let removeResult = await router.handle(.remove(id: firstId.uuidString))
        guard case let .success(removedRules) = removeResult else {
            Issue.record("Expected remove to succeed")
            return
        }
        #expect(removedRules.rules.map(\.id) == [secondId.uuidString])
        #expect(controller.settings.appRules.map(\.id) == [secondId])
        await waitUntilRuleTest { fullRescanReasons.count == 3 }
        #expect(fullRescanReasons == [.appRulesChanged, .appRulesChanged, .appRulesChanged])
    }

    @Test func invalidRuleMutationsAreRejected() async {
        let controller = makeLayoutPlanTestController()
        let router = makeIPCRuleRouter(for: controller)

        let invalidAdd = await router.handle(
            .add(rule: IPCRuleDefinition(bundleId: "not a bundle", titleRegex: "[", layout: .auto))
        )
        let missingRemove = await router.handle(
            .remove(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!.uuidString)
        )
        let malformedMove = await router.handle(.move(id: "not-a-uuid", position: 1))

        #expect(invalidAdd == .failure(.invalidArguments))
        #expect(missingRemove == .failure(.notFound))
        #expect(malformedMove == .failure(.invalidArguments))
    }

    @Test func applyFocusedReevaluatesManagedFocusAndReturnsUpdatedRulesProjection() async throws {
        let controller = makeLayoutPlanTestController()
        let token = seedRuleApplyWindow(
            on: controller,
            pid: 9101,
            windowId: 3001,
            bundleId: "com.example.terminal"
        )
        await installDeferredRuleApplyRule(on: controller, bundleId: "com.example.terminal")
        #expect(controller.workspaceManager.entry(for: token)?.mode == .tiling)

        let router = makeIPCRuleRouter(for: controller)
        let result = await router.handle(.apply(target: .focused))

        guard case let .success(rules) = result else {
            Issue.record("Expected focused rule apply to succeed")
            return
        }

        #expect(rules.rules.count == 1)
        #expect(rules.rules.first?.bundleId == "com.example.terminal")
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
    }

    @Test func applyFocusedFallsBackToFrontmostTokenWhenManagedFocusIsClear() async {
        let controller = makeLayoutPlanTestController()
        let token = seedRuleApplyWindow(
            on: controller,
            pid: 9102,
            windowId: 3002,
            bundleId: "com.example.browser"
        )
        #expect(controller.workspaceManager.enterNonManagedFocus(appFullscreen: false))
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        await installDeferredRuleApplyRule(on: controller, bundleId: "com.example.browser")

        let router = makeIPCRuleRouter(for: controller)
        let result = await router.handle(.apply(target: .focused))

        guard case .success = result else {
            Issue.record("Expected focused fallback rule apply to succeed")
            return
        }
        #expect(controller.workspaceManager.focusedToken == nil)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
    }

    @Test func applyFocusedPrefersFrontmostTokenDuringNonManagedFocus() async {
        let controller = makeLayoutPlanTestController()
        let rememberedToken = seedRuleApplyWindow(
            on: controller,
            pid: 9106,
            windowId: 3007,
            bundleId: "com.example.remembered"
        )
        let frontmostToken = seedRuleApplyWindow(
            on: controller,
            pid: 9107,
            windowId: 3008,
            bundleId: "com.example.frontmost",
            focused: false
        )
        #expect(controller.workspaceManager.enterNonManagedFocus(appFullscreen: false))
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { frontmostToken }
        await installDeferredRuleApplyRule(on: controller, bundleId: "com.example.frontmost")

        let router = makeIPCRuleRouter(for: controller)
        let result = await router.handle(.apply(target: .focused))

        guard case .success = result else {
            Issue.record("Expected focused rule apply to prefer the frontmost non-managed window")
            return
        }
        #expect(controller.workspaceManager.entry(for: rememberedToken)?.mode == .tiling)
        #expect(controller.workspaceManager.entry(for: frontmostToken)?.mode == .floating)
    }

    @Test func applyWindowSupportsExplicitOpaqueIdsAndStableValidationFailures() async {
        let controller = makeLayoutPlanTestController()
        let token = seedRuleApplyWindow(
            on: controller,
            pid: 9103,
            windowId: 3003,
            bundleId: "com.example.notes"
        )
        await installDeferredRuleApplyRule(on: controller, bundleId: "com.example.notes")

        let router = makeIPCRuleRouter(for: controller)
        let validWindowId = IPCWindowOpaqueID.encode(
            pid: token.pid,
            windowId: token.windowId,
            sessionToken: ipcRuleTestSessionToken
        )
        let successResult = await router.handle(.apply(target: .window(windowId: validWindowId)))
        let invalidResult = await router.handle(.apply(target: .window(windowId: "not-an-opaque-id")))
        let staleResult = await router.handle(
            .apply(
                target: .window(
                    windowId: IPCWindowOpaqueID.encode(
                        pid: token.pid,
                        windowId: token.windowId,
                        sessionToken: "other-session"
                    )
                )
            )
        )

        guard case .success = successResult else {
            Issue.record("Expected explicit window rule apply to succeed")
            return
        }
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
        #expect(invalidResult == .failure(.invalidArguments))
        #expect(staleResult == .failure(.staleWindowId))
    }

    @Test func applyPidReevaluatesAllTrackedWindowsForTheProcess() async {
        let controller = makeLayoutPlanTestController()
        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(
            pid: 9104,
            name: "Shared App",
            bundleId: "com.example.shared"
        )
        let firstToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 3004),
            pid: 9104,
            windowId: 3004,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 3005),
            pid: 9104,
            windowId: 3005,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId)
        await installDeferredRuleApplyRule(on: controller, bundleId: "com.example.shared")

        let router = makeIPCRuleRouter(for: controller)
        let result = await router.handle(.apply(target: .pid(9104)))

        guard case .success = result else {
            Issue.record("Expected pid rule apply to succeed")
            return
        }
        #expect(controller.workspaceManager.entry(for: firstToken)?.mode == .floating)
        #expect(controller.workspaceManager.entry(for: secondToken)?.mode == .floating)
    }

    @Test func applyRejectsInvalidTargetsAndAllowsNoOpReevaluationSuccess() async {
        let controller = makeLayoutPlanTestController()
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { nil }
        controller.commandHandler.frontmostAppPidProvider = { -1 }
        let emptyRouter = makeIPCRuleRouter(for: controller)
        let missingFocusedResult = await emptyRouter.handle(.apply(target: .focused))
        let invalidPidResult = await emptyRouter.handle(.apply(target: .pid(0)))
        let missingPidResult = await emptyRouter.handle(.apply(target: .pid(999_999)))

        let windowController = makeLayoutPlanTestController()
        let token = seedRuleApplyWindow(
            on: windowController,
            pid: 9105,
            windowId: 3006,
            bundleId: "com.example.noop"
        )
        let router = makeIPCRuleRouter(for: windowController)
        let windowId = IPCWindowOpaqueID.encode(
            pid: token.pid,
            windowId: token.windowId,
            sessionToken: ipcRuleTestSessionToken
        )

        let noOpWindowResult = await router.handle(.apply(target: .window(windowId: windowId)))

        #expect(invalidPidResult == .failure(.invalidArguments))
        #expect(missingFocusedResult == .failure(.notFound))
        #expect(missingPidResult == .failure(.notFound))
        guard case let .success(rules) = noOpWindowResult else {
            Issue.record("Expected no-op explicit window reevaluation to succeed")
            return
        }
        #expect(rules.rules.count == controller.settings.appRules.count)
        #expect(windowController.workspaceManager.entry(for: token)?.mode == .tiling)
    }
}

@Suite(.serialized) @MainActor struct IPCApplicationBridgeRuleTests {
    @Test func bridgeRoutesRuleLifecycleAndRulesQuery() async throws {
        let controller = makeLayoutPlanTestController()
        controller.settings.appRules = []
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "1.2.3",
            sessionToken: ipcRuleTestSessionToken,
            authorizationToken: ipcRuleTestAuthorization
        )

        let addResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-add",
                rule: .add(
                    rule: IPCRuleDefinition(
                        bundleId: "com.example.terminal",
                        titleSubstring: "Shell",
                        layout: .float
                    )
                ),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(addResponse.ok)
        #expect(addResponse.kind == .rule)
        let addedRules = try requireRulesResult(addResponse)
        let ruleId = try #require(addedRules.rules.first?.id)

        let queryResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-query",
                query: IPCQueryRequest(name: .rules),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(queryResponse.ok)
        let queriedRules = try requireRulesResult(queryResponse)
        #expect(queriedRules.rules.map(\.id) == [ruleId])

        let replaceResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-replace",
                rule: .replace(
                    id: ruleId,
                    rule: IPCRuleDefinition(
                        bundleId: "com.example.browser",
                        titleSubstring: "Docs",
                        layout: .tile
                    )
                ),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(replaceResponse.ok)
        #expect(try requireRulesResult(replaceResponse).rules.first?.bundleId == "com.example.browser")

        let moveResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-move",
                rule: .move(id: ruleId, position: 1),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(moveResponse.ok)
        #expect(try requireRulesResult(moveResponse).rules.first?.position == 1)

        let removeResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-remove",
                rule: .remove(id: ruleId),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(removeResponse.ok)
        #expect(try requireRulesResult(removeResponse).rules.isEmpty)
    }

    @Test func bridgeRoutesRuleApplyAcrossFocusedWindowExplicitWindowAndPidTargets() async throws {
        let controller = makeLayoutPlanTestController()
        let token = seedRuleApplyWindow(
            on: controller,
            pid: 9201,
            windowId: 3101,
            bundleId: "com.example.bridge"
        )
        #expect(controller.workspaceManager.enterNonManagedFocus(appFullscreen: false))
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        await installDeferredRuleApplyRule(on: controller, bundleId: "com.example.bridge")
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "1.2.3",
            sessionToken: ipcRuleTestSessionToken,
            authorizationToken: ipcRuleTestAuthorization
        )

        let focusedResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-focused",
                rule: .apply(target: .focused),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(focusedResponse.ok)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
        #expect(try requireRulesResult(focusedResponse).rules.first?.bundleId == "com.example.bridge")

        _ = controller.workspaceManager.setWindowMode(.tiling, for: token)
        let windowResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-window",
                rule: .apply(
                    target: .window(
                        windowId: IPCWindowOpaqueID.encode(
                            pid: token.pid,
                            windowId: token.windowId,
                            sessionToken: ipcRuleTestSessionToken
                        )
                    )
                ),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(windowResponse.ok)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)

        _ = controller.workspaceManager.setWindowMode(.tiling, for: token)
        let pidResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-pid",
                rule: .apply(target: .pid(token.pid)),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        #expect(pidResponse.ok)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
    }

    @Test func bridgeMapsRuleApplyValidationFailuresToStableCodes() async {
        let controller = makeLayoutPlanTestController()
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { nil }
        controller.commandHandler.frontmostAppPidProvider = { -1 }
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "1.2.3",
            sessionToken: ipcRuleTestSessionToken,
            authorizationToken: ipcRuleTestAuthorization
        )

        let invalidWindowResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-invalid-window",
                rule: .apply(target: .window(windowId: "not-an-opaque-id")),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        let staleWindowResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-stale-window",
                rule: .apply(
                    target: .window(
                        windowId: IPCWindowOpaqueID.encode(pid: 7, windowId: 9, sessionToken: "other-session")
                    )
                ),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        let invalidPidResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-invalid-pid",
                rule: .apply(target: .pid(0)),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        let missingFocusedResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-missing-focused",
                rule: .apply(target: .focused),
                authorizationToken: ipcRuleTestAuthorization
            )
        )
        let missingPidResponse = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-missing-pid",
                rule: .apply(target: .pid(999_999)),
                authorizationToken: ipcRuleTestAuthorization
            )
        )

        #expect(invalidWindowResponse.ok == false)
        #expect(invalidWindowResponse.code == .invalidArguments)
        #expect(staleWindowResponse.ok == false)
        #expect(staleWindowResponse.code == .staleWindowId)
        #expect(invalidPidResponse.ok == false)
        #expect(invalidPidResponse.code == .invalidArguments)
        #expect(missingFocusedResponse.ok == false)
        #expect(missingFocusedResponse.code == .notFound)
        #expect(missingPidResponse.ok == false)
        #expect(missingPidResponse.code == .notFound)
    }

    @Test func bridgeAllowsNoOpExplicitWindowRuleApplyToSucceed() async throws {
        let controller = makeLayoutPlanTestController()
        let token = seedRuleApplyWindow(
            on: controller,
            pid: 9202,
            windowId: 3102,
            bundleId: "com.example.bridge-noop"
        )
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "1.2.3",
            sessionToken: ipcRuleTestSessionToken,
            authorizationToken: ipcRuleTestAuthorization
        )

        let response = await bridge.response(
            for: IPCRequest(
                id: "rule-apply-noop-window",
                rule: .apply(
                    target: .window(
                        windowId: IPCWindowOpaqueID.encode(
                            pid: token.pid,
                            windowId: token.windowId,
                            sessionToken: ipcRuleTestSessionToken
                        )
                    )
                ),
                authorizationToken: ipcRuleTestAuthorization
            )
        )

        #expect(response.ok)
        let rules = try requireRulesResult(response)
        #expect(rules.rules.count == controller.settings.appRules.count)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .tiling)
    }
}
