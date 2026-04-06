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
    displayId: CGDirectDisplayID = layoutPlanTestMainDisplayId(),
    name: String = "Main",
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    makeLayoutPlanTestMonitor(
        displayId: displayId,
        name: name,
        x: x,
        y: y,
        width: width,
        height: height
    )
}

private func makeRefreshTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeRefreshTestWindowFacts(
    bundleId: String = "com.example.refresh",
    title: String? = nil,
    attributeFetchSucceeded: Bool = true,
    sizeConstraints: WindowSizeConstraints? = nil,
    windowServer: WindowServerInfo? = nil,
    hasFullscreenButton: Bool = true,
    fullscreenButtonEnabled: Bool? = true
) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: "Refresh Test App",
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: title,
            hasCloseButton: true,
            hasFullscreenButton: hasFullscreenButton,
            fullscreenButtonEnabled: fullscreenButtonEnabled,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        ),
        sizeConstraints: sizeConstraints,
        windowServer: windowServer
    )
}

@MainActor
private func makeRefreshTestController(
    windowFocusOperations: WindowFocusOperations? = nil,
    workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
) -> WMController {
    let operations = windowFocusOperations ?? WindowFocusOperations(
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
    installSynchronousFrameApplySuccessOverride(on: controller)
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
    controller.axManager.fullRescanEnumerationOverrideForTests = nil
    controller.axManager.frameApplyOverrideForTests = nil
    controller.axEventHandler.resetDebugStateForTests()
    controller.axEventHandler.isFullscreenProvider = nil
}

@MainActor
private func makeRefreshTestStatusBarController(_ controller: WMController) -> StatusBarController {
    let statusBarController = StatusBarController(
        settings: controller.settings,
        controller: controller,
        hiddenBarController: HiddenBarController(settings: controller.settings),
        defaults: makeRefreshTestDefaults()
    )
    controller.statusBarController = statusBarController
    return statusBarController
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
private func niriColumnTokenSnapshot(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> [[WindowToken]]? {
    guard let engine = controller.niriEngine else { return nil }
    return engine.columns(in: workspaceId).map { column in
        column.windowNodes.map(\.token)
    }
}

@MainActor
private func workspaceManagerTokenSet(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> Set<WindowToken> {
    Set(controller.workspaceManager.entries(in: workspaceId).map(\.token))
}

@MainActor
private func niriTokenSet(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> Set<WindowToken> {
    controller.niriEngine?.root(for: workspaceId)?.windowIdSet ?? []
}

@MainActor
private func dwindleTokenSet(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> Set<WindowToken> {
    Set(controller.dwindleEngine?.root(for: workspaceId)?.collectAllWindows() ?? [])
}

private func replacingToken(
    _ token: WindowToken,
    with replacement: WindowToken,
    in snapshot: [[WindowToken]]
) -> [[WindowToken]] {
    snapshot.map { column in
        column.map { $0 == token ? replacement : $0 }
    }
}

@MainActor
private func workspaceBarWindowCount(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> Int? {
    guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else {
        return nil
    }
    return controller.workspaceBarItems(
        for: monitor,
        projection: WorkspaceBarProjectionOptions(
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            showFloatingWindows: controller.settings.workspaceBarShowFloatingWindows
        )
    )
    .first { $0.id == workspaceId }?
    .windows.count
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
    let existingConfigurationsByName = Dictionary(
        uniqueKeysWithValues: controller.settings.workspaceConfigurations.map { ($0.name, $0) }
    )
    controller.settings.workspaceConfigurations = layoutsByName.keys.sorted().map { name in
        let layoutType = layoutsByName[name] ?? .defaultLayout
        return existingConfigurationsByName[name]?.with(layoutType: layoutType)
            ?? WorkspaceConfiguration(name: name, layoutType: layoutType)
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
private func assertWorkspaceSwitchCommandRequestsRememberedFocus(
    prepare: ((WMController, WorkspaceDescriptor.ID, WorkspaceDescriptor.ID, Monitor) -> Void)? = nil,
    action: (WMController) -> Void
) async {
    var focusRequests: [(pid_t, UInt32)] = []
    let controller = makeRefreshTestController(
        windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusRequests.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
    )
    guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
          let monitor = controller.workspaceManager.monitors.first
    else {
        Issue.record("Failed to create workspace-switch focus fixture")
        return
    }

    let sourceToken = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: 401),
        pid: 4_101,
        windowId: 401,
        to: workspaceOne
    )
    _ = controller.workspaceManager.setManagedFocus(
        sourceToken,
        in: workspaceOne,
        onMonitor: monitor.id
    )

    let inactiveHiddenState = WindowModel.HiddenState(
        proportionalPosition: CGPoint(x: 0.2, y: 0.8),
        referenceMonitorId: monitor.id,
        reason: .workspaceInactive
    )
    let fallbackHandle = addWindow(on: controller, workspaceId: workspaceTwo, pid: 4_201, windowId: 402)
    let targetHandle = addWindow(on: controller, workspaceId: workspaceTwo, pid: 4_201, windowId: 403)
    controller.workspaceManager.setHiddenState(inactiveHiddenState, for: fallbackHandle.id)
    controller.workspaceManager.setHiddenState(inactiveHiddenState, for: targetHandle.id)
    _ = controller.workspaceManager.rememberFocus(targetHandle.id, in: workspaceTwo)

    prepare?(controller, workspaceOne, workspaceTwo, monitor)
    action(controller)
    await waitForRefreshWork(on: controller)
    await waitUntil {
        controller.activeWorkspace()?.id == workspaceTwo &&
            controller.workspaceManager.pendingFocusedToken == targetHandle.id &&
            focusRequests.contains { $0.0 == targetHandle.id.pid && $0.1 == UInt32(targetHandle.id.windowId) }
    }

    #expect(controller.activeWorkspace()?.id == workspaceTwo)
    #expect(controller.workspaceManager.pendingFocusedToken == targetHandle.id)
    #expect(focusRequests.contains { $0.0 == targetHandle.id.pid && $0.1 == UInt32(targetHandle.id.windowId) })
}

@MainActor
private func assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget(
    prepare: ((WMController, WorkspaceDescriptor.ID, WorkspaceDescriptor.ID, Monitor) -> Void)? = nil,
    action: (WMController) -> Void
) async {
    var focusRequests: [(pid_t, UInt32)] = []
    let controller = makeRefreshTestController(
        windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusRequests.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
    )
    guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
          let monitor = controller.workspaceManager.monitors.first
    else {
        Issue.record("Failed to create empty-workspace switch fixture")
        return
    }

    let sourceToken = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: 411),
        pid: 4_111,
        windowId: 411,
        to: workspaceOne
    )
    _ = controller.workspaceManager.setManagedFocus(
        sourceToken,
        in: workspaceOne,
        onMonitor: monitor.id
    )

    prepare?(controller, workspaceOne, workspaceTwo, monitor)
    action(controller)
    await waitForRefreshWork(on: controller)
    await waitUntil {
        controller.activeWorkspace()?.id == workspaceTwo &&
            controller.workspaceManager.focusedToken == nil &&
            controller.workspaceManager.pendingFocusedToken == nil &&
            controller.workspaceManager.isNonManagedFocusActive
    }

    #expect(controller.activeWorkspace()?.id == workspaceTwo)
    #expect(controller.workspaceManager.focusedToken == nil)
    #expect(controller.workspaceManager.pendingFocusedToken == nil)
    #expect(controller.workspaceManager.isNonManagedFocusActive)
    #expect(focusRequests.isEmpty)
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
    let primaryMonitor = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
    let secondaryMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
    controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

    guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
    else {
        fatalError("Failed to create two-monitor test fixture")
    }

    guard controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id) else {
        fatalError("Failed to activate primary workspace on the primary monitor")
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

@Suite(.serialized) struct RefreshRoutingTests {
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

    @Test @MainActor func focusOnlyChangesRefreshStatusBarWithoutWorkspaceBarQueue() {
        let controller = makeRefreshTestController()
        controller.settings.workspaceBarEnabled = false
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let monitor = controller.monitorForInteraction(),
              let workspaceId = controller.activeWorkspace()?.id
        else {
            Issue.record("Missing active workspace for status bar refresh routing test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 501),
            pid: 501,
            windowId: 501,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 502),
            pid: 502,
            windowId: 502,
            to: workspaceId
        )
        controller.appInfoCache.storeInfoForTests(pid: 501, name: "First App", bundleId: "com.example.first")
        controller.appInfoCache.storeInfoForTests(pid: 502, name: "Second App", bundleId: "com.example.second")
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let statusBarController = makeRefreshTestStatusBarController(controller)
        defer {
            statusBarController.cleanup()
            cleanupRefreshTestController(controller)
        }
        statusBarController.setup()
        #expect(statusBarController.statusButtonTitleForTests() == " 1 \u{2013} First App")

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        _ = controller.workspaceManager.setManagedFocus(secondToken, in: workspaceId, onMonitor: monitor.id)

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 0)
        #expect(statusBarController.statusButtonTitleForTests() == " 1 \u{2013} Second App")
    }

    @Test @MainActor func interactionMonitorChangeOnUnassignedThirdDisplayDoesNotRecurseAfterMonitorExpansion() {
        let controller = makeRefreshTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
            ]
        )
        let primary = makeRefreshTestMonitor(displayId: layoutPlanTestMainDisplayId(), name: "Primary", x: 0, y: 0)
        let secondary = makeRefreshTestMonitor(displayId: layoutPlanTestSyntheticDisplayId(1), name: "Secondary", x: 1920, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([primary, secondary])
        controller.settings.statusBarShowWorkspaceName = true

        let statusBarController = makeRefreshTestStatusBarController(controller)
        defer {
            statusBarController.cleanup()
            cleanupRefreshTestController(controller)
        }
        statusBarController.setup()

        let third = makeRefreshTestMonitor(displayId: layoutPlanTestSyntheticDisplayId(2), name: "Third", x: 3840, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([primary, secondary, third])

        var sessionChangeCount = 0
        let originalOnSessionStateChanged = controller.workspaceManager.onSessionStateChanged
        controller.workspaceManager.onSessionStateChanged = {
            sessionChangeCount += 1
            originalOnSessionStateChanged?()
        }

        #expect(controller.workspaceManager.setInteractionMonitor(third.id))
        #expect(sessionChangeCount == 1)
        #expect(statusBarController.statusButtonTitleForTests() == "")
        #expect(statusBarController.statusButtonImagePositionForTests() == .imageOnly)
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

    @Test @MainActor func reselectingActiveWorkspaceDoesNotTriggerRefreshOrClearBorder() async {
        let controller = makeRefreshTestController()
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Failed to create active workspace reselect fixture")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceOne, 352),
                (workspaceTwo, 353),
            ],
            focusedWindowId: 352,
            ensureWorkspaces: [workspaceTwo]
        )
        guard let targetHandle = handles[353] else {
            Issue.record("Missing target workspace handle")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(workspaceTwo, on: monitor.id))
        #expect(controller.workspaceManager.setManagedFocus(
            targetHandle.id,
            in: workspaceTwo,
            onMonitor: monitor.id
        ))
        primeFocusedBorder(on: controller, handle: targetHandle)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        let previousFocusedToken = controller.workspaceManager.focusedToken
        let previousBorderWindowId = lastAppliedBorderWindowId(on: controller)

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(controller.activeWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.focusedToken == previousFocusedToken)
        #expect(controller.workspaceManager.focusedToken == targetHandle.id)
        #expect(lastAppliedBorderWindowId(on: controller) == previousBorderWindowId)
        #expect(lastAppliedBorderWindowId(on: controller) == targetHandle.windowId)
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(controller.niriEngine?.monitor(for: monitor.id)?.workspaceSwitch == nil)
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.windowRemovalReasons.isEmpty)
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

    @Test @MainActor func workspaceSwitchCommandsRequestRememberedTargetFocus() async {
        await assertWorkspaceSwitchCommandRequestsRememberedFocus { controller in
            controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        }
        await assertWorkspaceSwitchCommandRequestsRememberedFocus { controller in
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        }
        await assertWorkspaceSwitchCommandRequestsRememberedFocus { controller in
            controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: 1)
        }
        await assertWorkspaceSwitchCommandRequestsRememberedFocus(
            prepare: { controller, workspaceOne, workspaceTwo, monitor in
                _ = controller.workspaceManager.setActiveWorkspace(workspaceTwo, on: monitor.id)
                _ = controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitor.id)
            }
        ) { controller in
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        }
    }

    @Test @MainActor func workspaceSwitchCommandsClearManagedFocusForEmptyTargets() async {
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget { controller in
            controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        }
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget { controller in
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        }
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget { controller in
            controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: 1)
        }
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget(
            prepare: { controller, workspaceOne, workspaceTwo, monitor in
                _ = controller.workspaceManager.setActiveWorkspace(workspaceTwo, on: monitor.id)
                _ = controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitor.id)
            }
        ) { controller in
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        }
    }

    @Test @MainActor func movingFocusedWindowUpdatesCachedFocusTargetWorkspace() async {
        let controller = makeRefreshTestController()
        controller.setBordersEnabled(true)
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create focused-target sync fixture")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceOne, 415),
            ],
            focusedWindowId: 415,
            ensureWorkspaces: [workspaceTwo]
        )
        guard let focusedHandle = handles[415] else {
            Issue.record("Missing focused window handle")
            return
        }

        controller.focusBridge.setFocusedTarget(
            controller.managedKeyboardFocusTarget(for: focusedHandle.id)
        )

        var animatingState = controller.workspaceManager.niriViewportState(for: workspaceOne)
        animatingState.viewOffsetPixels = .spring(
            SpringAnimation(
                from: 0,
                to: 120,
                startTime: 0,
                config: .snappy
            )
        )
        controller.workspaceManager.updateNiriViewportState(animatingState, for: workspaceOne)

        #expect(controller.workspaceNavigationHandler.moveWindow(handle: focusedHandle, toWorkspaceId: workspaceTwo))
        #expect(controller.focusBridge.focusedTarget?.workspaceId == workspaceTwo)
        #expect(controller.currentKeyboardFocusTargetForRendering()?.workspaceId == workspaceTwo)

        let rendered = controller.renderKeyboardFocusBorder(
            preferredFrame: CGRect(x: 20, y: 20, width: 640, height: 480),
            policy: .coordinated
        )

        #expect(rendered)
        #expect(lastAppliedBorderWindowId(on: controller) == 415)
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
        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)
        controller.settings.focusFollowsWindowToMonitor = false

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        var fullRescanReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return false
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            return false
        }

        controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)
        await waitForRefreshWork(on: controller)

        #expect(relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(fullRescanReasons.isEmpty)
        #expect(controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId) == WindowToken(pid: getpid(), windowId: 304))
        #expect(
            dwindleTokenSet(controller: controller, workspaceId: targetWorkspaceId)
                == Set([WindowToken(pid: getpid(), windowId: 304)])
        )
        let observedReasons = relayoutEvents.map(\.0.rawValue) + fullRescanReasons.map(\.rawValue)
        #expect(!observedReasons.contains("legacyImmediateCallsite"))
        #expect(!observedReasons.contains("legacyCallsite"))
    }

    @Test @MainActor func moveFocusedWindowsToInactiveDwindleWorkspaceBootstrapsRecursiveLayout() async {
        let controller = makeRefreshTestController()
        guard let sourceWorkspaceId = controller.activeWorkspace()?.id,
              let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing source or target workspace for Dwindle bootstrap test")
            return
        }

        configureWorkspaceLayouts(
            on: controller,
            layoutsByName: [
                "1": .defaultLayout,
                "2": .dwindle
            ]
        )
        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)

        let handlesByWindowId = await prepareNiriState(
            on: controller,
            assignments: [
                (sourceWorkspaceId, 3_401),
                (sourceWorkspaceId, 3_402),
                (sourceWorkspaceId, 3_403)
            ],
            focusedWindowId: 3_401,
            ensureWorkspaces: [targetWorkspaceId]
        )
        let movedTokens = Set(
            [3_401, 3_402, 3_403].compactMap { handlesByWindowId[$0]?.id }
        )
        controller.settings.focusFollowsWindowToMonitor = false

        controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)
        await waitForRefreshWork(on: controller)
        guard let secondHandle = controller.workspaceManager.resolveWorkspaceFocus(in: sourceWorkspaceId) else {
            Issue.record("Missing second source focus after first background send")
            return
        }
        _ = controller.workspaceManager.setManagedFocus(
            secondHandle,
            in: sourceWorkspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: sourceWorkspaceId)
        )

        controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)
        await waitForRefreshWork(on: controller)
        guard let thirdHandle = controller.workspaceManager.resolveWorkspaceFocus(in: sourceWorkspaceId) else {
            Issue.record("Missing third source focus after second background send")
            return
        }
        _ = controller.workspaceManager.setManagedFocus(
            thirdHandle,
            in: sourceWorkspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: sourceWorkspaceId)
        )

        controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)
        await waitForRefreshWork(on: controller)

        #expect(controller.activeWorkspace()?.id == sourceWorkspaceId)
        #expect(dwindleTokenSet(controller: controller, workspaceId: targetWorkspaceId) == movedTokens)

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForSettledRefreshWork(on: controller)

        let frames = controller.dwindleEngine?.currentFrames(in: targetWorkspaceId) ?? [:]
        let roundedHeights = Set(frames.values.map { Int($0.height.rounded()) })

        #expect(Set(frames.keys) == movedTokens)
        #expect(roundedHeights.count > 1)
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

    @Test @MainActor func nativeFullscreenSameWindowIdRestoreIgnoresFreshLifecycleModeReevaluationInNiri() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2671), getpid(), 2671),
            (makeRefreshTestWindow(windowId: 2672), getpid(), 2672)
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
        let targetToken = WindowToken(pid: getpid(), windowId: 2672)
        guard let engine = controller.niriEngine,
              let originalNode = engine.findNode(for: targetToken),
              let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
        else {
            Issue.record("Missing original Niri reevaluation placement state")
            return
        }
        guard let originalFrame = controller.axManager.lastAppliedFrame(for: 2672) else {
            Issue.record("Missing original Niri reevaluation frame")
            return
        }
        let originalColumnWidth = originalColumn.cachedWidth

        _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceId)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: targetToken)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2671), getpid(), 2671)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            if axRef.windowId == targetToken.windowId {
                return makeRefreshTestWindowFacts(
                    title: "Same window appears floating",
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: false
                )
            }
            return makeRefreshTestWindowFacts()
        }

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2671), getpid(), 2671),
            (makeRefreshTestWindow(windowId: 2672), getpid(), 2672)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredNode = engine.findNode(for: targetToken),
              let restoredColumn = engine.column(of: restoredNode),
              let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
              let restoredFrame = controller.axManager.lastAppliedFrame(for: 2672)
        else {
            Issue.record("Missing restored Niri reevaluation placement state")
            return
        }

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.windowMode(for: targetToken) == .tiling)
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

    @Test @MainActor func nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2641), getpid(), 2641),
            (makeRefreshTestWindow(windowId: 2642), getpid(), 2642),
            (makeRefreshTestWindow(windowId: 2643), getpid(), 2643),
            (makeRefreshTestWindow(windowId: 2644), getpid(), 2644),
            (makeRefreshTestWindow(windowId: 2645), getpid(), 2645)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout(maxWindowsPerColumn: 2)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2644)
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }
        guard controller.workspaceManager.entry(for: targetToken) != nil else {
            Issue.record("Missing managed entry for fullscreen target")
            return
        }
        guard let originalNode = engine.findNode(for: targetToken) else {
            Issue.record("Missing original Niri node for fullscreen target")
            return
        }
        guard let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
        else {
            Issue.record("Missing original Niri column for fullscreen target")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original Niri snapshot")
            return
        }
        guard let originalFrame = originalNode.renderedFrame ?? originalNode.frame else {
            Issue.record("Missing original Niri frame for fullscreen target")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        guard let targetEntry = controller.workspaceManager.entry(for: targetToken) else {
            Issue.record("Missing entry before native fullscreen suspension")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: targetEntry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        fullscreenWindowIds = [2644]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2644), getpid(), 2644)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2641)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2642)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2643)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2645)) != nil)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        fullscreenWindowIds.removeAll()
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2641), getpid(), 2641),
            (makeRefreshTestWindow(windowId: 2642), getpid(), 2642),
            (makeRefreshTestWindow(windowId: 2643), getpid(), 2643),
            (makeRefreshTestWindow(windowId: 2644), getpid(), 2644),
            (makeRefreshTestWindow(windowId: 2645), getpid(), 2645)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredNode = engine.findNode(for: targetToken),
              let restoredColumn = engine.column(of: restoredNode),
              let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
              let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId)
        else {
            Issue.record("Missing restored multi-column Niri same-ID state")
            return
        }
        guard let restoredFrame = restoredNode.renderedFrame ?? restoredNode.frame else {
            Issue.record("Missing restored Niri frame for fullscreen target")
            return
        }

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(restoredNode.id == originalNode.id)
        #expect(restoredColumnIndex == originalColumnIndex)
        #expect(restoredSnapshot == originalSnapshot)
        #expect(abs(restoredFrame.origin.x - originalFrame.origin.x) <= 2.0)
        #expect(abs(restoredFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(restoredFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(restoredFrame.size.height - originalFrame.size.height) < 0.5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
    }

    @Test @MainActor func nativeFullscreenUnlockRetainsMultiColumnNiriOrderWithSameWindowId() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2681), getpid(), 2681),
            (makeRefreshTestWindow(windowId: 2682), getpid(), 2682),
            (makeRefreshTestWindow(windowId: 2683), getpid(), 2683),
            (makeRefreshTestWindow(windowId: 2684), getpid(), 2684),
            (makeRefreshTestWindow(windowId: 2685), getpid(), 2685)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout(maxWindowsPerColumn: 2)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2684)
        guard controller.niriEngine != nil else {
            Issue.record("Missing Niri engine")
            return
        }
        guard controller.workspaceManager.entry(for: targetToken) != nil else {
            Issue.record("Missing managed entry for unlock fullscreen target")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original unlock Niri snapshot")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected unlock Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        guard let targetEntry = controller.workspaceManager.entry(for: targetToken) else {
            Issue.record("Missing entry before unlock fullscreen suspension")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: targetEntry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        fullscreenWindowIds = [2684]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2684), getpid(), 2684)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .unlock)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2681)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2682)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2683)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2685)) != nil)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)
    }

    @Test @MainActor func nativeFullscreenMissingFocusedWindowFallbackKeepsNiriLifecyclePreservationAcrossFullRescans() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2721), getpid(), 2721),
            (makeRefreshTestWindow(windowId: 2722), getpid(), 2722),
            (makeRefreshTestWindow(windowId: 2723), getpid(), 2723),
            (makeRefreshTestWindow(windowId: 2724), getpid(), 2724),
            (makeRefreshTestWindow(windowId: 2725), getpid(), 2725)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout(maxWindowsPerColumn: 2)
        controller.hasStartedServices = true
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2724)
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original Niri snapshot")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        guard let targetEntry = controller.workspaceManager.entry(for: targetToken) else {
            Issue.record("Missing entry before lifecycle fallback test")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: targetEntry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        fullscreenWindowIds = [2724]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2724), getpid(), 2724)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        controller.axEventHandler.focusedWindowRefProvider = { _ in nil }
        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .workspaceDidActivateApplication
        )

        #expect(controller.workspaceManager.isAppFullscreenActive)
        #expect(controller.workspaceManager.hasNativeFullscreenLifecycleContext)

        controller.layoutRefreshController.requestFullRescan(reason: .unlock)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2721)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2722)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2723)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2725)) != nil)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)
    }

    @Test @MainActor func nativeFullscreenDelayedSameTokenDestroyRoundTripPreservesNiriIdentityAndBarState() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2731), getpid(), 2731),
            (makeRefreshTestWindow(windowId: 2732), getpid(), 2732),
            (makeRefreshTestWindow(windowId: 2733), getpid(), 2733),
            (makeRefreshTestWindow(windowId: 2734), getpid(), 2734),
            (makeRefreshTestWindow(windowId: 2735), getpid(), 2735)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout(maxWindowsPerColumn: 2)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2734)
        guard let engine = controller.niriEngine,
              let originalEntry = controller.workspaceManager.entry(for: targetToken),
              let originalNode = engine.findNode(for: targetToken),
              let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId),
              let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId),
              let originalFrame = originalNode.renderedFrame ?? originalNode.frame
        else {
            Issue.record("Missing original Niri state for delayed destroy round-trip")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        controller.axEventHandler.handleRemoved(token: targetToken)

        visibleWindows.value = []
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let enterRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing delayed enter record after destroy")
            return
        }
        if case .enterRequested = enterRecord.transition {} else {
            Issue.record("Expected delayed enter record to remain enterRequested")
        }
        #expect(enterRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)
        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        fullscreenWindowIds = [2734]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2734), getpid(), 2734)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let suspendedRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing suspended record after delayed same-token fullscreen reappearance")
            return
        }
        if case .suspended = suspendedRecord.transition {} else {
            Issue.record("Expected delayed enter record to become suspended")
        }
        #expect(suspendedRecord.availability == .present)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)

        _ = controller.workspaceManager.requestNativeFullscreenExit(targetToken, initiatedByCommand: true)
        controller.axEventHandler.handleRemoved(token: targetToken)

        fullscreenWindowIds.removeAll()
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2731), getpid(), 2731),
            (makeRefreshTestWindow(windowId: 2732), getpid(), 2732),
            (makeRefreshTestWindow(windowId: 2733), getpid(), 2733),
            (makeRefreshTestWindow(windowId: 2735), getpid(), 2735)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let exitRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing delayed exit record after destroy")
            return
        }
        if case .exitRequested = exitRecord.transition {} else {
            Issue.record("Expected delayed exit record to remain exitRequested")
        }
        #expect(exitRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2731), getpid(), 2731),
            (makeRefreshTestWindow(windowId: 2732), getpid(), 2732),
            (makeRefreshTestWindow(windowId: 2733), getpid(), 2733),
            (makeRefreshTestWindow(windowId: 2734), getpid(), 2734),
            (makeRefreshTestWindow(windowId: 2735), getpid(), 2735)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredNode = engine.findNode(for: targetToken),
              let restoredColumn = engine.column(of: restoredNode),
              let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
              let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId),
              let restoredFrame = restoredNode.renderedFrame ?? restoredNode.frame
        else {
            Issue.record("Missing restored Niri state after delayed destroy round-trip")
            return
        }

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: targetToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)
        #expect(restoredNode.id == originalNode.id)
        #expect(restoredColumnIndex == originalColumnIndex)
        #expect(restoredSnapshot == originalSnapshot)
        #expect(abs(restoredFrame.origin.x - originalFrame.origin.x) <= 2.0)
        #expect(abs(restoredFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(restoredFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(restoredFrame.size.height - originalFrame.size.height) < 0.5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
    }

    @Test @MainActor func nativeFullscreenReplacementSpaceChangePreservesMultiColumnNiriOrder() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2651), getpid(), 2651),
            (makeRefreshTestWindow(windowId: 2652), getpid(), 2652),
            (makeRefreshTestWindow(windowId: 2653), getpid(), 2653),
            (makeRefreshTestWindow(windowId: 2654), getpid(), 2654),
            (makeRefreshTestWindow(windowId: 2655), getpid(), 2655)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableNiriLayout(maxWindowsPerColumn: 2)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let originalToken = WindowToken(pid: getpid(), windowId: 2654)
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing original replacement entry")
            return
        }
        guard let originalNode = engine.findNode(for: originalToken) else {
            Issue.record("Missing original replacement node")
            return
        }
        guard let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
        else {
            Issue.record("Missing original replacement column")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original replacement snapshot")
            return
        }
        guard let originalFrame = originalNode.renderedFrame ?? originalNode.frame else {
            Issue.record("Missing original Niri frame for replacement target")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        guard let originalEntryBeforeFullscreen = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing entry before native fullscreen replacement flow")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: originalEntryBeforeFullscreen,
            isWorkspaceActive: true,
            appFullscreen: true
        )
        controller.axEventHandler.handleRemoved(token: originalToken)

        visibleWindows.value = []
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: originalToken) != nil)
        #expect(controller.workspaceManager.hasPendingNativeFullscreenTransition)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        let replacementToken = WindowToken(pid: getpid(), windowId: 2656)
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2651), getpid(), 2651),
            (makeRefreshTestWindow(windowId: 2652), getpid(), 2652),
            (makeRefreshTestWindow(windowId: 2653), getpid(), 2653),
            (makeRefreshTestWindow(windowId: 2655), getpid(), 2655),
            (makeRefreshTestWindow(windowId: 2656), getpid(), 2656)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let replacementNode = engine.findNode(for: replacementToken),
              let replacementColumn = engine.column(of: replacementNode),
              let replacementColumnIndex = engine.columnIndex(of: replacementColumn, in: workspaceId),
              let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId)
        else {
            Issue.record("Missing restored multi-column replacement Niri state")
            return
        }
        guard let replacementFrame = replacementNode.renderedFrame ?? replacementNode.frame else {
            Issue.record("Missing replacement Niri frame")
            return
        }

        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(replacementNode.id == originalNode.id)
        #expect(replacementColumnIndex == originalColumnIndex)
        #expect(restoredSnapshot == replacingToken(originalToken, with: replacementToken, in: originalSnapshot))
        #expect(abs(replacementFrame.origin.x - originalFrame.origin.x) <= 2.0)
        #expect(abs(replacementFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(replacementFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(replacementFrame.size.height - originalFrame.size.height) < 0.5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
    }

    @Test @MainActor func nativeFullscreenReplacementRestoreIgnoresFreshLifecycleModeReevaluation() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2661), getpid(), 2661),
            (makeRefreshTestWindow(windowId: 2662), getpid(), 2662),
            (makeRefreshTestWindow(windowId: 2663), getpid(), 2663),
            (makeRefreshTestWindow(windowId: 2664), getpid(), 2664),
            (makeRefreshTestWindow(windowId: 2665), getpid(), 2665)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableNiriLayout(maxWindowsPerColumn: 2)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let originalToken = WindowToken(pid: getpid(), windowId: 2664)
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }
        guard controller.workspaceManager.entry(for: originalToken) != nil else {
            Issue.record("Missing original replacement reevaluation entry")
            return
        }
        guard engine.findNode(for: originalToken) != nil else {
            Issue.record("Missing original replacement reevaluation node")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original replacement reevaluation snapshot")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
        controller.axEventHandler.handleRemoved(token: originalToken)

        let replacementToken = WindowToken(pid: getpid(), windowId: 2666)
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            if axRef.windowId == replacementToken.windowId {
                return makeRefreshTestWindowFacts(
                    title: "Replacement appears floating",
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: false
                )
            }
            return makeRefreshTestWindowFacts()
        }

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2661), getpid(), 2661),
            (makeRefreshTestWindow(windowId: 2662), getpid(), 2662),
            (makeRefreshTestWindow(windowId: 2663), getpid(), 2663),
            (makeRefreshTestWindow(windowId: 2665), getpid(), 2665),
            (makeRefreshTestWindow(windowId: 2666), getpid(), 2666)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing restored Niri replacement reevaluation snapshot")
            return
        }

        #expect(controller.workspaceManager.windowMode(for: replacementToken) == .tiling)
        #expect(engine.findNode(for: replacementToken) != nil)
        #expect(restoredSnapshot == replacingToken(originalToken, with: replacementToken, in: originalSnapshot))
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

    @Test @MainActor func nativeFullscreenSameWindowIdRestoreIgnoresFreshLifecycleModeReevaluationInDwindle() async {
        let controller = makeRefreshTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2691), getpid(), 2691),
            (makeRefreshTestWindow(windowId: 2692), getpid(), 2692)
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
        let targetToken = WindowToken(pid: getpid(), windowId: 2692)
        guard let originalNode = controller.dwindleEngine?.findNode(for: targetToken),
              let originalFrame = controller.axManager.lastAppliedFrame(for: 2692)
        else {
            Issue.record("Missing original Dwindle reevaluation state")
            return
        }

        _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceId)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: targetToken)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2691), getpid(), 2691)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            if axRef.windowId == targetToken.windowId {
                return makeRefreshTestWindowFacts(
                    title: "Same Dwindle window appears floating",
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: false
                )
            }
            return makeRefreshTestWindowFacts()
        }

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2691), getpid(), 2691),
            (makeRefreshTestWindow(windowId: 2692), getpid(), 2692)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        guard let restoredNode = controller.dwindleEngine?.findNode(for: targetToken) else {
            Issue.record("Missing restored Dwindle reevaluation state")
            return
        }

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.windowMode(for: targetToken) == .tiling)
        #expect(restoredNode.id == originalNode.id)
        #expect(controller.axManager.lastAppliedFrame(for: 2692) == originalFrame)
    }

    @Test @MainActor func nativeFullscreenDelayedSameTokenDestroyRoundTripRestoresExactDwindleFrame() async {
        let controller = makeRefreshTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2695), getpid(), 2695),
            (makeRefreshTestWindow(windowId: 2696), getpid(), 2696)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableDwindleLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2696)
        guard let originalEntry = controller.workspaceManager.entry(for: targetToken),
              let originalNode = controller.dwindleEngine?.findNode(for: targetToken),
              let originalFrame = controller.axManager.lastAppliedFrame(for: 2696)
        else {
            Issue.record("Missing original Dwindle state for delayed destroy round-trip")
            return
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        controller.axEventHandler.handleRemoved(token: targetToken)

        visibleWindows.value = []
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        guard let enterRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing delayed Dwindle enter record")
            return
        }
        if case .enterRequested = enterRecord.transition {} else {
            Issue.record("Expected delayed Dwindle enter record to remain enterRequested")
        }
        #expect(enterRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)

        fullscreenWindowIds = [2696]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2696), getpid(), 2696)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        _ = controller.workspaceManager.requestNativeFullscreenExit(targetToken, initiatedByCommand: true)
        controller.axEventHandler.handleRemoved(token: targetToken)

        fullscreenWindowIds.removeAll()
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2695), getpid(), 2695)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        guard let exitRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing delayed Dwindle exit record")
            return
        }
        if case .exitRequested = exitRecord.transition {} else {
            Issue.record("Expected delayed Dwindle exit record to remain exitRequested")
        }
        #expect(exitRecord.availability == .temporarilyUnavailable)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2695), getpid(), 2695),
            (makeRefreshTestWindow(windowId: 2696), getpid(), 2696)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        guard let restoredNode = controller.dwindleEngine?.findNode(for: targetToken) else {
            Issue.record("Missing restored Dwindle state after delayed destroy round-trip")
            return
        }

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: targetToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)
        #expect(restoredNode.id == originalNode.id)
        #expect(controller.axManager.lastAppliedFrame(for: 2696) == originalFrame)
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

    @Test @MainActor func fullRescanQueuesLowerPriorityRequestsAsFollowUps() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        var fullRescanReasons: [RefreshReason] = []
        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        var postLayoutRuns = 0

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }
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
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(fullRescanReasons == [.startup])
        #expect(relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
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

    @Test @MainActor func fullRescanRemovesMissingTrackedWindowOnFirstVerifiedMiss() async {
        let controller = makeRefreshTestController()
        controller.axManager.currentWindowsAsyncOverride = { [] }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 3061
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: windowId) == nil)
    }

    @Test @MainActor func fullRescanPreservesTrackedWindowsForFailedEnumerationPIDs() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let liveHandle = addWindow(on: controller, workspaceId: workspaceId, pid: 6_101, windowId: 6_101)
        let failedHandle = addWindow(on: controller, workspaceId: workspaceId, pid: 6_102, windowId: 6_102)
        let missingHandle = addWindow(on: controller, workspaceId: workspaceId, pid: 6_103, windowId: 6_103)

        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(
                windows: [(makeRefreshTestWindow(windowId: 6_101), 6_101, 6_101)],
                failedPIDs: [6_102]
            )
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: liveHandle) != nil)
        #expect(controller.workspaceManager.entry(for: failedHandle) != nil)
        #expect(controller.workspaceManager.entry(for: missingHandle) == nil)
    }

    @Test @MainActor func activeFullRescanQueuesFollowUpRelayoutForLateNiriCreate() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let controller = fixture.controller
        defer { cleanupRefreshTestController(controller) }
        let fullRescanGate = AsyncGate()
        var fullRescanReasons: [RefreshReason] = []
        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        let primaryHandle = addWindow(on: controller, workspaceId: fixture.primaryWorkspaceId, pid: getpid(), windowId: 6_501)
        let secondaryHandle = addWindow(on: controller, workspaceId: fixture.secondaryWorkspaceId, pid: getpid(), windowId: 6_502)
        controller.axManager.currentWindowsAsyncOverride = {
            [
                (makeRefreshTestWindow(windowId: 6_501), getpid(), 6_501),
                (makeRefreshTestWindow(windowId: 6_502), getpid(), 6_502)
            ]
        }
        await waitForRefreshWork(on: controller)

        controller.niriEngine?.roots.removeValue(forKey: fixture.primaryWorkspaceId)
        controller.niriEngine?.roots.removeValue(forKey: fixture.secondaryWorkspaceId)
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return false
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            await fullRescanGate.wait()
            return false
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitUntil { fullRescanReasons == [.startup] }
        fullRescanGate.open()
        await waitUntil {
            let primaryTokenCount = niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).count
            let secondaryTokenCount = niriTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId).count
            let populatedCount = [
                primaryTokenCount,
                secondaryTokenCount
            ]
            .filter { $0 > 0 }
            .count
            return populatedCount == 1
        }

        let builtWorkspaceId: WorkspaceDescriptor.ID
        if !niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).isEmpty,
           niriTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId).isEmpty
        {
            builtWorkspaceId = fixture.primaryWorkspaceId
        } else if !niriTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId).isEmpty,
                  niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).isEmpty
        {
            builtWorkspaceId = fixture.secondaryWorkspaceId
        } else {
            Issue.record("Expected exactly one Niri workspace to be built before follow-up relayout injection")
            return
        }

        let newWindowId = builtWorkspaceId == fixture.primaryWorkspaceId ? 6_503 : 6_504
        let newToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: newWindowId),
            pid: getpid(),
            windowId: newWindowId,
            to: builtWorkspaceId
        )
        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowCreated,
            affectedWorkspaceIds: [builtWorkspaceId]
        )
        await waitForRefreshWork(on: controller)

        #expect(fullRescanReasons == [.startup])
        #expect(relayoutEvents.map(\.0) == [.axWindowCreated])
        #expect(relayoutEvents.map(\.1) == [.relayout])
        #expect(controller.workspaceManager.entry(for: newToken) != nil)
        #expect(niriTokenSet(controller: controller, workspaceId: builtWorkspaceId).contains(newToken))
        #expect(niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId) == workspaceManagerTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId))
        #expect(niriTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId) == workspaceManagerTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId))
        #expect(niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).contains(primaryHandle.id))
        #expect(niriTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId).contains(secondaryHandle.id))
    }

    @Test @MainActor func activeFullRescanQueuesFollowUpWindowRemovalForLateDwindleDestroy() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let controller = fixture.controller
        defer { cleanupRefreshTestController(controller) }
        let fullRescanGate = AsyncGate()
        var fullRescanReasons: [RefreshReason] = []
        var windowRemovalReasons: [RefreshReason] = []

        configureWorkspaceLayouts(on: controller, layoutsByName: ["1": .dwindle, "2": .dwindle])
        controller.enableDwindleLayout()

        let primaryFirst = addWindow(on: controller, workspaceId: fixture.primaryWorkspaceId, pid: getpid(), windowId: 6_601)
        let primarySecond = addWindow(on: controller, workspaceId: fixture.primaryWorkspaceId, pid: getpid(), windowId: 6_602)
        let secondaryFirst = addWindow(on: controller, workspaceId: fixture.secondaryWorkspaceId, pid: getpid(), windowId: 6_611)
        let secondarySecond = addWindow(on: controller, workspaceId: fixture.secondaryWorkspaceId, pid: getpid(), windowId: 6_612)
        controller.axManager.currentWindowsAsyncOverride = {
            [
                (makeRefreshTestWindow(windowId: 6_601), getpid(), 6_601),
                (makeRefreshTestWindow(windowId: 6_602), getpid(), 6_602),
                (makeRefreshTestWindow(windowId: 6_611), getpid(), 6_611),
                (makeRefreshTestWindow(windowId: 6_612), getpid(), 6_612)
            ]
        }
        await waitForRefreshWork(on: controller)

        controller.dwindleEngine?.removeLayout(for: fixture.primaryWorkspaceId)
        controller.dwindleEngine?.removeLayout(for: fixture.secondaryWorkspaceId)
        controller.layoutRefreshController.debugHooks.onWindowRemoval = { reason, _ in
            windowRemovalReasons.append(reason)
            return false
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            await fullRescanGate.wait()
            return false
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitUntil { fullRescanReasons == [.startup] }
        fullRescanGate.open()
        await waitUntil {
            let primaryTokenCount = dwindleTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).count
            let secondaryTokenCount = dwindleTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId).count
            let populatedCount = [
                primaryTokenCount,
                secondaryTokenCount
            ]
            .filter { $0 > 0 }
            .count
            return populatedCount == 1
        }

        let builtWorkspaceId: WorkspaceDescriptor.ID
        let removedToken: WindowToken
        let survivingToken: WindowToken
        if !dwindleTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).isEmpty,
           dwindleTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId).isEmpty
        {
            builtWorkspaceId = fixture.primaryWorkspaceId
            removedToken = primarySecond.id
            survivingToken = primaryFirst.id
        } else if !dwindleTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId).isEmpty,
                  dwindleTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).isEmpty
        {
            builtWorkspaceId = fixture.secondaryWorkspaceId
            removedToken = secondarySecond.id
            survivingToken = secondaryFirst.id
        } else {
            Issue.record("Expected exactly one Dwindle workspace to be built before follow-up removal injection")
            return
        }

        _ = controller.workspaceManager.removeWindow(pid: removedToken.pid, windowId: removedToken.windowId)
        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: builtWorkspaceId,
            layoutType: .dwindle,
            removedNodeId: nil,
            niriOldFrames: [:],
            shouldRecoverFocus: false
        )
        await waitForRefreshWork(on: controller)

        #expect(fullRescanReasons == [.startup])
        #expect(windowRemovalReasons == [.windowDestroyed])
        #expect(controller.workspaceManager.entry(for: removedToken) == nil)
        #expect(!dwindleTokenSet(controller: controller, workspaceId: builtWorkspaceId).contains(removedToken))
        #expect(dwindleTokenSet(controller: controller, workspaceId: builtWorkspaceId).contains(survivingToken))
        #expect(dwindleTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId) == workspaceManagerTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId))
        #expect(dwindleTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId) == workspaceManagerTokenSet(controller: controller, workspaceId: fixture.secondaryWorkspaceId))
    }

    @Test @MainActor func sameWorkspaceWindowRemovalPreservesMultiplePayloads() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let gate = AsyncGate()
        var observedPayloadCounts: [Int] = []
        controller.layoutRefreshController.debugHooks.onRelayout = { _, route in
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onWindowRemoval = { reason, payloads in
            if reason == .windowDestroyed {
                observedPayloadCounts.append(payloads.count)
            }
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
            layoutType: .niri,
            removedNodeId: NodeId(),
            niriOldFrames: [WindowToken(pid: getpid(), windowId: 4011): CGRect(x: 0, y: 0, width: 100, height: 100)],
            shouldRecoverFocus: false
        )
        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
            layoutType: .niri,
            removedNodeId: NodeId(),
            niriOldFrames: [WindowToken(pid: getpid(), windowId: 4012): CGRect(x: 100, y: 0, width: 100, height: 100)],
            shouldRecoverFocus: false
        )
        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(observedPayloadCounts == [2])
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
        let otherMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
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
