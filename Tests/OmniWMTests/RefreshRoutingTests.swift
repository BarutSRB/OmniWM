import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeRefreshTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.refresh-routing.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeRefreshTestMonitor(
    displayId: CGDirectDisplayID = 1,
    name: String = "Main",
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func makeRefreshTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeRefreshTestWindowFacts(
    bundleId: String = "com.example.refresh",
    title: String? = nil,
    attributeFetchSucceeded: Bool = true,
    sizeConstraints: WindowSizeConstraints? = nil
) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: "Refresh Test App",
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: title,
            hasCloseButton: true,
            hasFullscreenButton: true,
            fullscreenButtonEnabled: true,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        ),
        sizeConstraints: sizeConstraints
    )
}

@MainActor
private func makeRefreshTestController(
    workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
) -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let settings = SettingsStore(defaults: makeRefreshTestDefaults())
    settings.workspaceConfigurations = workspaceConfigurations
    let controller = WMController(
        settings: settings,
        windowFocusOperations: operations
    )
    let monitor = makeRefreshTestMonitor()
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    controller.axEventHandler.windowFactsProvider = { _, _ in
        makeRefreshTestWindowFacts()
    }
    return controller
}

@MainActor
private func cleanupRefreshTestController(_ controller: WMController) {
    controller.layoutRefreshController.resetDebugState()
    controller.layoutRefreshController.resetState()
    controller.resetWorkspaceBarRefreshDebugStateForTests()
    controller.axManager.currentWindowsAsyncOverride = nil
    controller.axEventHandler.resetDebugStateForTests()
    controller.axEventHandler.isFullscreenProvider = nil
}

@MainActor
private func configureNativeFullscreenTestState(
    on controller: WMController,
    visibleWindows: VisibleWindowsStore,
    isFullscreen: Bool = false
) {
    controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
    controller.axEventHandler.isFullscreenProvider = { _ in isFullscreen }
}

@MainActor
private func waitForRefreshWork(on controller: WMController) async {
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
}

@MainActor
private func waitForSettledRefreshWork(on controller: WMController) async {
    await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()
    await controller.waitForWorkspaceBarRefreshForTests()
}

@MainActor
private func lastAppliedBorderWindowId(on controller: WMController) -> Int? {
    controller.borderManager.lastAppliedFocusedWindowIdForTests
}

@MainActor
private final class RefreshEventRecorder {
    var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
    var visibilityReasons: [RefreshReason] = []
    var fullRescanReasons: [RefreshReason] = []
    var windowRemovalReasons: [RefreshReason] = []
}

@MainActor
private final class AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class VisibleWindowsStore {
    var value: [(AXWindowRef, pid_t, Int)]

    init(_ value: [(AXWindowRef, pid_t, Int)]) {
        self.value = value
    }
}

@MainActor
private func waitUntil(
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

@MainActor
private func installRefreshSpies(
    on controller: WMController,
    recorder: RefreshEventRecorder
) {
    controller.layoutRefreshController.resetDebugState()
    controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
        recorder.relayoutEvents.append((reason, route))
        return true
    }
    controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
        recorder.visibilityReasons.append(reason)
        return true
    }
    controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
        recorder.fullRescanReasons.append(reason)
        return true
    }
    controller.layoutRefreshController.debugHooks.onWindowRemoval = { reason, _ in
        recorder.windowRemovalReasons.append(reason)
        return true
    }
}

@MainActor
private func assertNoLegacyReasons(_ recorder: RefreshEventRecorder) {
    let observedReasons = recorder.relayoutEvents.map(\.0.rawValue) + recorder.fullRescanReasons.map(\.rawValue)
    #expect(!observedReasons.contains("legacyImmediateCallsite"))
    #expect(!observedReasons.contains("legacyCallsite"))
}

@MainActor
private func resetRefreshSpies(
    on controller: WMController,
    recorder: RefreshEventRecorder
) {
    recorder.relayoutEvents.removeAll()
    recorder.visibilityReasons.removeAll()
    recorder.fullRescanReasons.removeAll()
    recorder.windowRemovalReasons.removeAll()
    installRefreshSpies(on: controller, recorder: recorder)
}

@MainActor
private func configureWorkspaceLayouts(
    on controller: WMController,
    layoutsByName: [String: LayoutType]
) {
    controller.settings.workspaceConfigurations = layoutsByName.keys.sorted().map { name in
        WorkspaceConfiguration(
            name: name,
            layoutType: layoutsByName[name] ?? .defaultLayout
        )
    }
}

@MainActor
private func addFocusedWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int
) -> WindowHandle {
    let token = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: windowId),
        pid: getpid(),
        windowId: windowId,
        to: workspaceId
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected bridge handle for focused refresh test window")
    }
    _ = controller.workspaceManager.setManagedFocus(
        handle,
        in: workspaceId,
        onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
    )
    return handle
}

@MainActor
private func addWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    pid: pid_t,
    windowId: Int
) -> WindowHandle {
    let token = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected bridge handle for refresh test window")
    }
    return handle
}

@MainActor
private func primeFocusedBorder(on controller: WMController, handle: WindowHandle) {
    guard let entry = controller.workspaceManager.entry(for: handle) else {
        fatalError("Missing entry for focused-border priming")
    }

    controller.setBordersEnabled(true)
    controller.borderManager.updateFocusedWindow(
        frame: CGRect(x: 10, y: 10, width: 800, height: 600),
        windowId: entry.windowId
    )
}

@MainActor
private func makeTwoMonitorRefreshTestController() -> (
    controller: WMController,
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor,
    primaryWorkspaceId: WorkspaceDescriptor.ID,
    secondaryWorkspaceId: WorkspaceDescriptor.ID
) {
    let controller = makeRefreshTestController(
        workspaceConfigurations: [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
    )
    let primaryMonitor = makeRefreshTestMonitor()
    let secondaryMonitor = makeRefreshTestMonitor(displayId: 2, name: "Secondary", x: 1920)
    controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

    guard let primaryWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id,
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
    else {
        fatalError("Failed to create two-monitor test fixture")
    }

    _ = controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id)
    _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)

    return (controller, primaryMonitor, secondaryMonitor, primaryWorkspaceId, secondaryWorkspaceId)
}

@MainActor
private func prepareNiriState(
    on controller: WMController,
    assignments: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
    focusedWindowId: Int,
    ensureWorkspaces: Set<WorkspaceDescriptor.ID> = []
) async -> [Int: WindowHandle] {
    controller.enableNiriLayout()
    await waitForRefreshWork(on: controller)
    controller.syncMonitorsToNiriEngine()

    var handlesByWindowId: [Int: WindowHandle] = [:]
    var workspaceByWindowId: [Int: WorkspaceDescriptor.ID] = [:]

    for (workspaceId, windowId) in assignments {
        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            fatalError("Expected bridge handle for seeded refresh window")
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

    let workspaceIds = Set(assignments.map(\.workspaceId)).union(ensureWorkspaces)
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

    return handlesByWindowId
}

@Suite struct RefreshRoutingTests {
    @Test func relayoutPoliciesAreExplicit() {
        #expect(RefreshReason.axWindowChanged.relayoutSchedulingPolicy == .debounced(
            nanoseconds: 8_000_000,
            dropWhileBusy: true
        ))
        #expect(RefreshReason.axWindowCreated.relayoutSchedulingPolicy == .debounced(
            nanoseconds: 4_000_000,
            dropWhileBusy: false
        ))
        #expect(RefreshReason.gapsChanged.relayoutSchedulingPolicy == .plain)
        #expect(RefreshReason.workspaceTransition.relayoutSchedulingPolicy == .plain)
        #expect(RefreshReason.windowRuleReevaluation.relayoutSchedulingPolicy == .plain)
    }

    @Test func refreshRoutesAreExplicit() {
        #expect(RefreshReason.appLaunched.requestRoute == .fullRescan)
        #expect(RefreshReason.gapsChanged.requestRoute == .relayout)
        #expect(RefreshReason.workspaceTransition.requestRoute == .immediateRelayout)
        #expect(RefreshReason.appHidden.requestRoute == .visibilityRefresh)
        #expect(RefreshReason.appUnhidden.requestRoute == .visibilityRefresh)
        #expect(RefreshReason.windowDestroyed.requestRoute == .windowRemoval)
        #expect(RefreshReason.windowRuleReevaluation.requestRoute == .relayout)
    }

    @Test @MainActor func workspaceBarRefreshRequestsCoalesceOnNextMainTurn() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 3)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(controller.workspaceBarRefreshDebugState.isQueued)

        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
        #expect(!controller.workspaceBarRefreshDebugState.isQueued)
    }

    @Test @MainActor func workspaceBarRefreshRunsAfterPostLayoutActions() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        var eventOrder: [String] = []
        var executionCountDuringPostLayout = -1
        controller.workspaceBarRefreshExecutionHookForTests = {
            eventOrder.append("workspaceBar")
        }

        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition
        ) {
            executionCountDuringPostLayout = controller.workspaceBarRefreshDebugState.executionCount
            eventOrder.append("postLayout")
        }

        await waitForRefreshWork(on: controller)

        #expect(executionCountDuringPostLayout == 0)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(controller.workspaceBarRefreshDebugState.isQueued)

        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(eventOrder == ["postLayout", "workspaceBar"])
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
    }

    @Test @MainActor func queuedWorkspaceBarRefreshIsCanceledDuringUICleanup() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        controller.requestWorkspaceBarRefresh()
        #expect(controller.workspaceBarRefreshDebugState.isQueued)

        controller.cleanupUIOnStop()
        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(!controller.workspaceBarRefreshDebugState.isQueued)
    }

    @Test @MainActor func unlockAndWorkspaceConfigUseSingleDeferredWorkspaceBarRefresh() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        lifecycleManager.handleUnlockDetected()
        await waitForRefreshWork(on: controller)
        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        controller.updateWorkspaceConfig()
        await waitForRefreshWork(on: controller)
        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
    }

    @Test @MainActor func niriConfigAndEnableUseRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
        #expect(recorder.relayoutEvents.map(\.0) == [.layoutConfigChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)

        resetRefreshSpies(on: controller, recorder: recorder)

        controller.updateNiriConfig(maxWindowsPerColumn: 4)
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
        #expect(recorder.relayoutEvents.map(\.0) == [.layoutConfigChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func dwindleConfigAndEnableUseRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
        #expect(recorder.relayoutEvents.map(\.0) == [.layoutConfigChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)

        resetRefreshSpies(on: controller, recorder: recorder)

        controller.updateDwindleConfig(smartSplit: false)
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
        #expect(recorder.relayoutEvents.map(\.0) == [.layoutConfigChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func monitorSettingsUseRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.updateMonitorOrientations()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.monitorSettingsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)

        resetRefreshSpies(on: controller, recorder: recorder)

        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)
        resetRefreshSpies(on: controller, recorder: recorder)

        controller.updateMonitorNiriSettings()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.monitorSettingsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)

        resetRefreshSpies(on: controller, recorder: recorder)

        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)
        resetRefreshSpies(on: controller, recorder: recorder)

        controller.updateMonitorDwindleSettings()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.monitorSettingsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func workspaceLayoutToggleUsesRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.commandHandler.handleCommand(.toggleWorkspaceLayout)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceLayoutToggled])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func workspaceTransitionFlowsUseImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.focusWorkspaceFromBar(named: "2")
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func workspaceSwitchUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func crossMonitorWorkspaceSwitchSkipsAnimationWhenTargetIsAlreadyVisible() async {
        let fixture = makeTwoMonitorRefreshTestController()
        _ = await prepareNiriState(
            on: fixture.controller,
            assignments: [
                (fixture.primaryWorkspaceId, 350),
                (fixture.secondaryWorkspaceId, 351),
            ],
            focusedWindowId: 350,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )

        fixture.controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: fixture.controller)

        #expect(fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.secondaryMonitor.displayId] == nil)
        #expect(fixture.controller.niriEngine?.monitor(for: fixture.secondaryMonitor.id)?.workspaceSwitch == nil)
    }

    @Test @MainActor func sameMonitorWorkspaceSwitchStartsAnimationWhenTargetWasHidden() async {
        let controller = makeRefreshTestController()
        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Failed to create single-monitor workspace switch fixture")
            return
        }

        _ = await prepareNiriState(
            on: controller,
            assignments: [
                (ws1, 352),
                (ws2, 353),
            ],
            focusedWindowId: 352,
            ensureWorkspaces: [ws2]
        )

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == ws2)
        #expect(controller.niriEngine?.monitor(for: monitor.id)?.workspaceSwitch?.toWorkspaceId == ws2)
    }

    @Test @MainActor func workspaceRelativeSwitchUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func focusWorkspaceAnywhereUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func workspaceBackAndForthUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.workspaceBackAndForth()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func moveFocusedWindowFollowFocusUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        guard let sourceWorkspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing source workspace")
            return
        }
        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Missing target workspace")
            return
        }
        _ = addFocusedWindow(on: controller, workspaceId: sourceWorkspaceId, windowId: 303)
        controller.settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "2", layoutType: .dwindle)
        ]
        controller.settings.focusFollowsWindowToMonitor = true

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId)?.windowId == 303)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func moveFocusedWindowWithoutFollowFocusUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        guard let sourceWorkspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing source workspace")
            return
        }
        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Missing target workspace")
            return
        }
        _ = addFocusedWindow(on: controller, workspaceId: sourceWorkspaceId, windowId: 304)
        controller.settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "2", layoutType: .dwindle)
        ]
        controller.settings.focusFollowsWindowToMonitor = false

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId) == nil)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func summonWindowRightIntoNiriUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        guard let targetWorkspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing target workspace for Niri summon-right test")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9101),
                (workspaceId: targetWorkspaceId, windowId: 9102),
                (workspaceId: targetWorkspaceId, windowId: 9103)
            ],
            focusedWindowId: 9101
        )
        guard let summonedHandle = handles[9102] else {
            Issue.record("Missing summoned handle for Niri summon-right test")
            return
        }

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.windowActionHandler.summonWindowRight(handle: summonedHandle)
        await waitForRefreshWork(on: controller)

        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine after summon-right test setup")
            return
        }

        let orderedWindowIds = engine.columns(in: targetWorkspaceId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(recorder.relayoutEvents.map(\.0) == [.layoutCommand])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId)?.windowId == 9102)
        #expect(orderedWindowIds == [9101, 9102, 9103])
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func paletteSummonWindowRightIntoNiriUsesCapturedAnchorWhenManagedFocusIsNil() async {
        let controller = makeRefreshTestController()
        guard let targetWorkspaceId = controller.activeWorkspace()?.id,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace for palette summon-right Niri test")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9301),
                (workspaceId: targetWorkspaceId, windowId: 9303),
                (workspaceId: sourceWorkspaceId, windowId: 9302),
            ],
            focusedWindowId: 9301
        )
        guard let anchorHandle = handles[9301],
              let summonedHandle = handles[9302]
        else {
            Issue.record("Missing handles for palette summon-right Niri test")
            return
        }

        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.windowActionHandler.summonWindowRight(
            handle: summonedHandle,
            anchorToken: anchorHandle.id,
            anchorWorkspaceId: targetWorkspaceId
        )
        await waitForRefreshWork(on: controller)

        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine after palette summon-right test")
            return
        }

        let orderedWindowIds = engine.columns(in: targetWorkspaceId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(recorder.relayoutEvents.map(\.0) == [.layoutCommand])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(controller.workspaceManager.workspace(for: summonedHandle.id) == targetWorkspaceId)
        #expect(controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId)?.windowId == 9302)
        #expect(orderedWindowIds == [9301, 9302, 9303])
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func paletteSummonWindowRightIntoNiriNoOpsWhenAnchorDisappears() async {
        let controller = makeRefreshTestController()
        guard let targetWorkspaceId = controller.activeWorkspace()?.id,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace for stale-anchor Niri test")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9401),
                (workspaceId: sourceWorkspaceId, windowId: 9402),
            ],
            focusedWindowId: 9401
        )
        guard let anchorHandle = handles[9401],
              let summonedHandle = handles[9402]
        else {
            Issue.record("Missing handles for stale-anchor Niri test")
            return
        }

        _ = controller.workspaceManager.removeWindow(
            pid: anchorHandle.pid,
            windowId: anchorHandle.windowId
        )

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.windowActionHandler.summonWindowRight(
            handle: summonedHandle,
            anchorToken: anchorHandle.id,
            anchorWorkspaceId: targetWorkspaceId
        )
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(controller.workspaceManager.workspace(for: summonedHandle.id) == sourceWorkspaceId)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func summonWindowRightIntoDwindleUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        guard let targetWorkspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing target workspace for Dwindle summon-right test")
            return
        }

        configureWorkspaceLayouts(
            on: controller,
            layoutsByName: ["1": .dwindle]
        )
        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)

        let anchorHandle = addFocusedWindow(on: controller, workspaceId: targetWorkspaceId, windowId: 9201)
        _ = addWindow(on: controller, workspaceId: targetWorkspaceId, pid: getpid(), windowId: 9202)
        let summonedHandle = addWindow(
            on: controller,
            workspaceId: targetWorkspaceId,
            pid: getpid(),
            windowId: 9203
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await waitForRefreshWork(on: controller)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.windowActionHandler.summonWindowRight(handle: summonedHandle)
        await waitForRefreshWork(on: controller)

        guard let monitor = controller.workspaceManager.monitor(for: targetWorkspaceId),
              let frames = controller.dwindleEngine?.calculateLayout(
                  for: targetWorkspaceId,
                  screen: monitor.visibleFrame
              ),
              let anchorFrame = frames[anchorHandle.id],
              let summonedFrame = frames[summonedHandle.id]
        else {
            Issue.record("Missing Dwindle frames after summon-right")
            return
        }

        #expect(recorder.relayoutEvents.map(\.0) == [.layoutCommand])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId)?.windowId == 9203)
        #expect(summonedFrame.minX >= anchorFrame.maxX - 1.0)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func inactiveWorkspaceAppActivationUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        guard let workspaceTwo else {
            Issue.record("Failed to create target workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 202),
            pid: getpid(),
            windowId: 202,
            to: workspaceTwo
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            Issue.record("Failed to create bridge handle")
            return
        }
        guard let entry = controller.workspaceManager.entry(for: handle) else {
            Issue.record("Failed to create managed entry")
            return
        }

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: false,
            appFullscreen: false
        )
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.appActivationTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func activeSpaceChangeDoesNotFrameWriteNativeFullscreenSuspendedWindowInNiri() async {
        let controller = makeRefreshTestController()
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        controller.axManager.currentWindowsAsyncOverride = { [] }
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 2601),
            pid: getpid(),
            windowId: 2601,
            to: workspaceId
        )
        _ = controller.workspaceManager.rememberFocus(token, in: workspaceId)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: token)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        lifecycleManager.handleActiveSpaceDidChange()
        await waitForRefreshWork(on: controller)

        #expect(controller.axManager.lastAppliedFrame(for: 2601) == nil)
        #expect(controller.workspaceManager.entry(for: token) != nil)
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
    }

    @Test @MainActor func nativeFullscreenExitRestoresPriorManagedFrameInNiri() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2611), getpid(), 2611),
            (makeRefreshTestWindow(windowId: 2612), getpid(), 2612)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2612)
        guard let engine = controller.niriEngine,
              let originalNode = engine.findNode(for: targetToken),
              let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
        else {
            Issue.record("Missing original Niri placement state")
            return
        }
        guard let originalFrame = controller.axManager.lastAppliedFrame(for: 2612) else {
            Issue.record("Missing original applied frame")
            return
        }
        let originalColumnWidth = originalColumn.cachedWidth

        _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceId)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: targetToken)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2611), getpid(), 2611)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2611), getpid(), 2611),
            (makeRefreshTestWindow(windowId: 2612), getpid(), 2612)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredNode = engine.findNode(for: targetToken),
              let restoredColumn = engine.column(of: restoredNode),
              let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
              let restoredFrame = controller.axManager.lastAppliedFrame(for: 2612)
        else {
            Issue.record("Missing restored Niri placement state")
            return
        }

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(restoredNode.id == originalNode.id)
        #expect(restoredColumnIndex == originalColumnIndex)
        #expect(abs(restoredColumn.cachedWidth - originalColumnWidth) < 0.5)
        #expect(abs(restoredFrame.origin.x - originalFrame.origin.x) <= 4.0)
        #expect(abs(restoredFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(restoredFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(restoredFrame.size.height - originalFrame.size.height) < 0.5)
    }

    @Test @MainActor func nativeFullscreenExitWithReplacementWindowIdPreservesNiriIdentity() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2615), getpid(), 2615),
            (makeRefreshTestWindow(windowId: 2616), getpid(), 2616)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let originalToken = WindowToken(pid: getpid(), windowId: 2616)
        guard let engine = controller.niriEngine,
              let originalEntry = controller.workspaceManager.entry(for: originalToken),
              let originalNode = engine.findNode(for: originalToken),
              let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId),
              let originalFrame = controller.axManager.lastAppliedFrame(for: 2616)
        else {
            Issue.record("Missing original Niri replacement state")
            return
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
        controller.axEventHandler.handleRemoved(token: originalToken)

        let replacementToken = WindowToken(pid: getpid(), windowId: 2617)
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2615), getpid(), 2615),
            (makeRefreshTestWindow(windowId: 2617), getpid(), 2617)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let replacementNode = engine.findNode(for: replacementToken),
              let replacementColumn = engine.column(of: replacementNode),
              let replacementColumnIndex = engine.columnIndex(of: replacementColumn, in: workspaceId),
              let replacementFrame = controller.axManager.lastAppliedFrame(for: 2617)
        else {
            Issue.record("Missing replacement Niri restore state")
            return
        }

        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(replacementNode.id == originalNode.id)
        #expect(replacementColumnIndex == originalColumnIndex)
        #expect(abs(replacementFrame.origin.x - originalFrame.origin.x) <= 2.0)
        #expect(abs(replacementFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(replacementFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(replacementFrame.size.height - originalFrame.size.height) < 0.5)
    }

    @Test @MainActor func nativeFullscreenExitRestoresPriorManagedFrameInDwindle() async {
        let controller = makeRefreshTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2621), getpid(), 2621),
            (makeRefreshTestWindow(windowId: 2622), getpid(), 2622)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2622)
        guard let originalFrame = controller.axManager.lastAppliedFrame(for: 2622) else {
            Issue.record("Missing original applied frame")
            return
        }

        _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceId)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: targetToken)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2621), getpid(), 2621)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2621), getpid(), 2621),
            (makeRefreshTestWindow(windowId: 2622), getpid(), 2622)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.axManager.lastAppliedFrame(for: 2622) == originalFrame)
    }

    @Test @MainActor func nativeFullscreenExitWithReplacementWindowIdPreservesDwindleIdentity() async {
        let controller = makeRefreshTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2625), getpid(), 2625),
            (makeRefreshTestWindow(windowId: 2626), getpid(), 2626)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let originalToken = WindowToken(pid: getpid(), windowId: 2626)
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken),
              let originalNode = controller.dwindleEngine?.findNode(for: originalToken),
              let originalFrame = controller.axManager.lastAppliedFrame(for: 2626)
        else {
            Issue.record("Missing original Dwindle replacement state")
            return
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
        controller.axEventHandler.handleRemoved(token: originalToken)

        let replacementToken = WindowToken(pid: getpid(), windowId: 2627)
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2625), getpid(), 2625),
            (makeRefreshTestWindow(windowId: 2627), getpid(), 2627)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let replacementNode = controller.dwindleEngine?.findNode(for: replacementToken)
        else {
            Issue.record("Missing replacement Dwindle restore state")
            return
        }

        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(replacementNode.id == originalNode.id)
        #expect(controller.axManager.lastAppliedFrame(for: 2627) == originalFrame)
    }

    @Test @MainActor func fullRescanExitClearsFullscreenSessionFlagsAndRecoversFocusedBorder() async {
        let controller = makeRefreshTestController()
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2631), getpid(), 2631),
            (makeRefreshTestWindow(windowId: 2632), getpid(), 2632)
        ])
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.setBordersEnabled(true)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2632)
        _ = controller.workspaceManager.setManagedFocus(
            targetToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(targetToken)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2631), getpid(), 2631)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2631), getpid(), 2631),
            (makeRefreshTestWindow(windowId: 2632), getpid(), 2632)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: targetToken) == nil)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
        #expect(controller.workspaceManager.hasPendingNativeFullscreenTransition == false)
        guard let recoveredToken = controller.workspaceManager.pendingFocusedToken else {
            Issue.record("Expected managed focus recovery to resume after native fullscreen restore")
            return
        }

        if let engine = controller.niriEngine {
            await waitUntil {
                !engine.hasAnyWindowAnimationsRunning(in: workspaceId)
                    && !engine.hasAnyColumnAnimationsRunning(in: workspaceId)
            }
        }
        controller.focusWindow(recoveredToken)

        #expect(controller.workspaceManager.pendingFocusedToken == recoveredToken)
    }

    @Test @MainActor func gapsChangedUsesRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        lifecycleManager.handleGapsChanged()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.gapsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func appHideAndUnhideUseVisibilityRefreshOnly() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: getpid(), windowId: 305)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.axEventHandler.handleAppHidden(pid: getpid())
        await waitForRefreshWork(on: controller)

        #expect(recorder.visibilityReasons == [.appHidden])
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.windowRemovalReasons.isEmpty)
        assertNoLegacyReasons(recorder)

        resetRefreshSpies(on: controller, recorder: recorder)

        controller.axEventHandler.handleAppUnhidden(pid: getpid())
        await waitForRefreshWork(on: controller)

        #expect(recorder.visibilityReasons == [.appUnhidden])
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.windowRemovalReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func fullRescanRemainsStickyUnderLowerPriorityRequests() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        var fullRescanReasons: [RefreshReason] = []
        var postLayoutRuns = 0

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            await gate.wait()
            return true
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitUntil { !fullRescanReasons.isEmpty }

        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition) {
            postLayoutRuns += 1
        }

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 0)
        #expect(fullRescanReasons == [.startup])
        #expect(postLayoutRuns == 1)
    }

    @Test @MainActor func hiddenAppsSurviveVisibleOnlyFullRescansAndRestoreOnUnhide() async {
        let controller = makeRefreshTestController()
        controller.axManager.currentWindowsAsyncOverride = { [] }
        controller.axEventHandler.windowSubscriptionHandler = { _ in }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 306
        let handle = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)

        controller.axEventHandler.handleAppHidden(pid: pid)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)
        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.entry(forPid: pid, windowId: windowId)?.workspaceId == workspaceId)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)
        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.layoutReason(for: handle) == .macosHiddenApp)

        controller.axEventHandler.handleAppUnhidden(pid: pid)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.layoutReason(for: handle) == .standard)
    }

    @Test @MainActor func immediateRelayoutSupersedesPendingDebouncedRelayout() async {
        let controller = makeRefreshTestController()
        controller.layoutRefreshController.resetDebugState()

        controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
    }

    @Test @MainActor func appLifecycleUsesFullRescan() async {
        let controller = makeRefreshTestController()
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        lifecycleManager.handleAppLaunched()
        await waitForRefreshWork(on: controller)

        #expect(recorder.fullRescanReasons == [.appLaunched])
        #expect(recorder.relayoutEvents.isEmpty)
        assertNoLegacyReasons(recorder)

        resetRefreshSpies(on: controller, recorder: recorder)
        lifecycleManager.handleAppTerminated(pid: getpid())
        await waitForRefreshWork(on: controller)

        #expect(recorder.fullRescanReasons == [.appTerminated])
        #expect(recorder.relayoutEvents.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func swapCurrentWorkspaceWithMonitorDoesNotRelayoutAcrossFixedHomes() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction: .right)
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func moveWindowToWorkspaceOnMonitorUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        fixture.controller.settings.focusFollowsWindowToMonitor = true
        _ = await prepareNiriState(
            on: fixture.controller,
            assignments: [(fixture.primaryWorkspaceId, 403)],
            focusedWindowId: 403,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
            workspaceIndex: 1,
            monitorDirection: .right
        )
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func navigateToWindowInternalUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let handlesByWindowId = await prepareNiriState(
            on: fixture.controller,
            assignments: [
                (fixture.primaryWorkspaceId, 404),
                (fixture.secondaryWorkspaceId, 405),
            ],
            focusedWindowId: 404,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )
        guard let targetHandle = handlesByWindowId[405] else {
            Issue.record("Missing target window handle")
            return
        }

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.windowActionHandler.navigateToWindowInternal(
            handle: targetHandle,
            workspaceId: fixture.secondaryWorkspaceId
        )
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func conservativeLifecycleAndPolicyCallersUseFullRescan() async {
        let controller = makeRefreshTestController()
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        lifecycleManager.performStartupRefresh()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.startup])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleAppLaunched()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.appLaunched])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleUnlockDetected()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.unlock])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleActiveSpaceDidChange()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.activeSpaceChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        let otherMonitor = makeRefreshTestMonitor(displayId: 2, name: "Secondary", x: 1920)
        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [otherMonitor],
            performPostUpdateActions: true
        )
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.monitorConfigurationChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        controller.updateWorkspaceConfig()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.workspaceConfigChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        controller.updateAppRules()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.appRulesChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleAppTerminated(pid: getpid())
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.appTerminated])
        #expect(recorder.relayoutEvents.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test func destroyNotificationRefconRoundTripsWindowId() {
        let windowId = 6202
        let refcon = AppAXContext.destroyNotificationRefcon(for: windowId)

        #expect(refcon != nil)
        #expect(AppAXContext.destroyNotificationWindowId(from: refcon) == windowId)
        #expect(AppAXContext.destroyNotificationWindowId(from: nil) == nil)
    }

    @Test @MainActor func destroyCallbackDispatchesEncodedWindowId() async {
        let pid = getpid()
        let windowId = 6302
        var delivered: (pid_t, Int)?

        AppAXContext.handleWindowDestroyedCallback(
            pid: pid,
            refcon: AppAXContext.destroyNotificationRefcon(for: windowId),
            handler: { callbackPid, callbackWindowId in
                delivered = (callbackPid, callbackWindowId)
            }
        )
        await waitUntil { delivered != nil }

        #expect(delivered?.0 == pid)
        #expect(delivered?.1 == windowId)
    }

    @Test @MainActor func exactDestroyCallbackRemovesClosedWindowWithoutFullRescan() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let survivorWindowId = 6401
        let removedWindowId = 6402
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: survivorWindowId)
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: removedWindowId)

        AppAXContext.handleWindowDestroyedCallback(
            pid: pid,
            refcon: AppAXContext.destroyNotificationRefcon(for: removedWindowId),
            handler: { [weak controller] callbackPid, callbackWindowId in
                controller?.axEventHandler.handleRemoved(pid: callbackPid, winId: callbackWindowId)
            }
        )
        await waitUntil {
            controller.workspaceManager.entry(forPid: pid, windowId: removedWindowId) == nil
        }
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: survivorWindowId) != nil)
        #expect(controller.workspaceManager.entry(forPid: pid, windowId: removedWindowId) == nil)
        #expect(controller.workspaceManager.entries(in: workspaceId).map(\.windowId) == [survivorWindowId])
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.windowRemovalReasons == [.windowDestroyed])
    }

    @Test @MainActor func frameChangedBurstReachesRefreshSchedulingAsSingleRelayout() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        _ = addWindow(on: controller, workspaceId: workspaceId, pid: getpid(), windowId: 6403)

        let observer = CGSEventObserver.shared
        observer.resetDebugStateForTests()
        observer.delegate = controller.axEventHandler
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        observer.enqueueEventForTests(.frameChanged(windowId: 6403))
        observer.enqueueEventForTests(.frameChanged(windowId: 6403))
        observer.flushPendingCGSEventsForTests()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.axWindowChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.visibilityReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func relayoutQueuedBehindActiveImmediateRelayoutStillExecutes() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
    }

    @Test @MainActor func visibilityRefreshCoalescesWhilePending() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.visibilityReasons == [.appUnhidden])
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 1)
    }

    @Test @MainActor func pendingVisibilityRefreshUpgradesToRelayout() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
    }

    @Test @MainActor func pendingVisibilityRefreshUpgradesToFullRescan() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            recorder.fullRescanReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
        controller.layoutRefreshController.requestFullRescan(reason: .startup)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.fullRescanReasons == [.startup])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
    }

    @Test @MainActor func activeFullRescanAbsorbsVisibilityReconciliation() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = addFocusedWindow(on: controller, workspaceId: workspaceId, windowId: 307)
        primeFocusedBorder(on: controller, handle: handle)
        #expect(lastAppliedBorderWindowId(on: controller) == 307)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            recorder.fullRescanReasons.append(reason)
            await gate.wait()
            return true
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitUntil { recorder.fullRescanReasons == [.startup] }
        controller.axEventHandler.handleAppHidden(pid: pid)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.fullRescanReasons == [.startup])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func pendingRelayoutAbsorbsVisibilityReconciliation() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = addFocusedWindow(on: controller, workspaceId: workspaceId, windowId: 308)
        primeFocusedBorder(on: controller, handle: handle)
        #expect(lastAppliedBorderWindowId(on: controller) == 308)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)
        controller.axEventHandler.handleAppHidden(pid: pid)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func pendingWindowRemovalAbsorbsVisibilityReconciliation() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = addFocusedWindow(on: controller, workspaceId: workspaceId, windowId: 309)
        primeFocusedBorder(on: controller, handle: handle)
        #expect(lastAppliedBorderWindowId(on: controller) == 309)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onWindowRemoval = { reason, _ in
            recorder.windowRemovalReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
            layoutType: .dwindle,
            removedNodeId: nil,
            niriOldFrames: [:],
            shouldRecoverFocus: false
        )
        controller.axEventHandler.handleAppHidden(pid: pid)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.windowRemovalReasons == [.windowDestroyed])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func visibilityQueuedBehindActiveImmediateRelayoutStillExecutes() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.visibilityReasons == [.appHidden])
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 1)
    }

    @Test @MainActor func canceledImmediateRelayoutPreservesPostLayoutActionsWhenUpgradedToFullRescan() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        var fullRescanReasons: [RefreshReason] = []
        var postLayoutRuns = 0

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { _, route in
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition) {
            postLayoutRuns += 1
        }
        await waitUntil { controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1 }
        controller.layoutRefreshController.requestFullRescan(reason: .startup)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(fullRescanReasons == [.startup])
        #expect(postLayoutRuns == 1)
    }
}
