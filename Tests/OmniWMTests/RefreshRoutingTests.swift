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

@MainActor
private func makeRefreshTestController() -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let controller = WMController(
        settings: SettingsStore(defaults: makeRefreshTestDefaults()),
        windowFocusOperations: operations
    )
    let monitor = makeRefreshTestMonitor()
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    return controller
}

@MainActor
private func waitForRefreshWork(on controller: WMController) async {
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
}

@MainActor
private final class RefreshEventRecorder {
    var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
    var fullRescanReasons: [RefreshReason] = []
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
    controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
        recorder.fullRescanReasons.append(reason)
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
    recorder.fullRescanReasons.removeAll()
    installRefreshSpies(on: controller, recorder: recorder)
}

@MainActor
private func addFocusedWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int
) -> WindowHandle {
    let handle = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: windowId),
        pid: getpid(),
        windowId: windowId,
        to: workspaceId
    )
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
    controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId
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
    let controller = makeRefreshTestController()
    let primaryMonitor = makeRefreshTestMonitor()
    let secondaryMonitor = makeRefreshTestMonitor(displayId: 2, name: "Secondary", x: 1920)
    controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

    guard let primaryWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id,
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
    else {
        fatalError("Failed to create two-monitor test fixture")
    }

    controller.workspaceManager.assignWorkspaceToMonitor(secondaryWorkspaceId, monitorId: secondaryMonitor.id)
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
        let handle = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId
        )
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
        #expect(RefreshReason.appHidden.relayoutSchedulingPolicy == .plain)
    }

    @Test @MainActor func runLightSessionUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.layoutRefreshController.runLightSession {}
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
        #expect(recorder.relayoutEvents.map(\.0) == [.lightSessionCommit])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
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
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func moveFocusedWindowWithoutFollowFocusUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        guard let sourceWorkspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing source workspace")
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
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func inactiveWorkspaceAppActivationUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        guard let workspaceTwo else {
            Issue.record("Failed to create target workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 202),
            pid: getpid(),
            windowId: 202,
            to: workspaceTwo
        )
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

    @Test @MainActor func immediateRelayoutSupersedesPendingDebouncedRelayout() async {
        let controller = makeRefreshTestController()

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

    @Test @MainActor func moveCurrentWorkspaceToMonitorUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.moveCurrentWorkspaceToMonitor(direction: .right)
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func moveCurrentWorkspaceToMonitorRelativeUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.moveCurrentWorkspaceToMonitorRelative(previous: false)
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func swapCurrentWorkspaceWithMonitorUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction: .right)
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func moveColumnToMonitorUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        _ = await prepareNiriState(
            on: fixture.controller,
            assignments: [(fixture.primaryWorkspaceId, 401)],
            focusedWindowId: 401,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.moveColumnToMonitorInDirection(.right)
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
        assertNoLegacyReasons(recorder)
    }

    @Test @MainActor func moveFocusedWindowToMonitorUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        fixture.controller.settings.focusFollowsWindowToMonitor = true
        _ = await prepareNiriState(
            on: fixture.controller,
            assignments: [(fixture.primaryWorkspaceId, 402)],
            focusedWindowId: 402,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.moveFocusedWindowToMonitor(direction: .right)
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
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

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: survivorWindowId) != nil)
        #expect(controller.workspaceManager.entry(forPid: pid, windowId: removedWindowId) == nil)
        #expect(controller.workspaceManager.entries(in: workspaceId).map(\.windowId) == [survivorWindowId])
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.relayoutEvents.isEmpty)
    }
}
