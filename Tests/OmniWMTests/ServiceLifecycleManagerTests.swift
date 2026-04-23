// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OmniWMIPC
import Testing

@testable import OmniWM

private let lifecycleIPCCommandRouterSessionToken = "service-lifecycle-tests"

private func makeLifecycleTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.lifecycle.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeLifecycleMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat,
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

private func makeLifecycleWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeLifecyclePermissionStream(
    initial: Bool
) -> (stream: AsyncStream<Bool>, continuation: AsyncStream<Bool>.Continuation) {
    var continuation: AsyncStream<Bool>.Continuation!
    let stream = AsyncStream<Bool> { streamContinuation in
        continuation = streamContinuation
        continuation.yield(initial)
    }
    return (stream, continuation)
}

@MainActor
private func makeLifecycleIPCCommandRouter(for controller: WMController) -> IPCCommandRouter {
    IPCCommandRouter(
        controller: controller,
        sessionToken: lifecycleIPCCommandRouterSessionToken
    )
}

@MainActor
private func waitUntilServiceLifecycleTest(
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0..<iterations where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }

    if !condition() {
        Issue.record("Timed out waiting for service lifecycle condition")
    }
}

@Suite struct ServiceLifecycleManagerTests {
    @Test @MainActor func accessibilityGrantStartsServicesAfterDeniedStartup() async {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let lifecycleManager = controller.serviceLifecycleManager
        var currentPermissionGranted = false
        let permissionStream = makeLifecyclePermissionStream(initial: false)

        lifecycleManager.accessibilityPermissionStateProviderForTests = {
            currentPermissionGranted
        }
        lifecycleManager.accessibilityPermissionStreamProviderForTests = { _ in
            permissionStream.stream
        }
        lifecycleManager.accessibilityPermissionRequestHandlerForTests = { false }
        defer {
            permissionStream.continuation.finish()
            controller.setEnabled(false)
        }

        controller.setEnabled(true)

        await waitUntilServiceLifecycleTest {
            !controller.hasStartedServices && !controller.isEnabled && !controller.hotkeysEnabled
        }

        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)
        #expect(!controller.hasStartedServices)

        currentPermissionGranted = true
        permissionStream.continuation.yield(true)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices && controller.isEnabled && controller.hotkeysEnabled
        }

        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)
        #expect(controller.hasStartedServices)
        #expect(controller.isEnabled)
        #expect(controller.hotkeysEnabled)
    }

    @Test @MainActor func accessibilityGrantRestoresEffectiveStateAfterTemporaryLoss() async {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
        let controller = WMController(settings: settings)
        let lifecycleManager = controller.serviceLifecycleManager
        let router = makeLifecycleIPCCommandRouter(for: controller)
        var currentPermissionGranted = true
        let permissionStream = makeLifecyclePermissionStream(initial: true)
        let monitor = makeLifecycleMonitor(displayId: 100, name: "Main", x: 0, y: 0)

        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected lifecycle workspaces")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitor.id))

        lifecycleManager.accessibilityPermissionStateProviderForTests = {
            currentPermissionGranted
        }
        lifecycleManager.accessibilityPermissionStreamProviderForTests = { _ in
            permissionStream.stream
        }
        lifecycleManager.accessibilityPermissionRequestHandlerForTests = { false }
        defer {
            permissionStream.continuation.finish()
            controller.setEnabled(false)
        }

        controller.setEnabled(true)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices && controller.isEnabled && controller.hotkeysEnabled
        }

        #expect(controller.commandHandler.performCommand(.focus(.left)) == .executed)
        #expect(router.handle(.setWorkspaceLayout(layout: .dwindle)) == .executed)
        #expect(settings.layoutType(for: "1") == .dwindle)

        currentPermissionGranted = false
        permissionStream.continuation.yield(false)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices && !controller.isEnabled && !controller.hotkeysEnabled
        }

        #expect(controller.commandHandler.performCommand(.focus(.left)) == .ignoredDisabled)
        #expect(router.handle(.setWorkspaceLayout(layout: .dwindle)) == .ignoredDisabled)
        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)

        currentPermissionGranted = true
        permissionStream.continuation.yield(true)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices && controller.isEnabled && controller.hotkeysEnabled
        }

        #expect(controller.workspaceManager.setActiveWorkspace(workspaceTwo, on: monitor.id))
        #expect(controller.commandHandler.performCommand(.focus(.left)) == .executed)
        #expect(router.handle(.setWorkspaceLayout(layout: .dwindle)) == .executed)
        #expect(settings.layoutType(for: "2") == .dwindle)
        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)
        #expect(controller.isEnabled)
        #expect(controller.hotkeysEnabled)
    }

    @Test @MainActor func workspaceActivationObserversUpdateFrontmostMirrorAndMetrics() async {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let lifecycleManager = controller.serviceLifecycleManager
        let currentPermissionGranted = true
        let permissionStream = makeLifecyclePermissionStream(initial: true)

        lifecycleManager.accessibilityPermissionStateProviderForTests = {
            currentPermissionGranted
        }
        lifecycleManager.accessibilityPermissionStreamProviderForTests = { _ in
            permissionStream.stream
        }
        lifecycleManager.accessibilityPermissionRequestHandlerForTests = { false }
        controller.axEventHandler.focusedWindowRefProvider = { _ in nil }
        FrontmostApplicationState.shared.setSnapshotForTests(nil)
        defer {
            permissionStream.continuation.finish()
            controller.setEnabled(false)
            FrontmostApplicationState.shared.setSnapshotForTests(nil)
        }

        let pid: pid_t = 42_424
        let bundleIdentifier = "com.example.frontmost"

        controller.setEnabled(true)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices && controller.isEnabled && controller.hotkeysEnabled
        }

        lifecycleManager.handleWorkspaceApplicationActivated(
            pid: pid,
            bundleIdentifier: bundleIdentifier
        )

        await waitUntilServiceLifecycleTest {
            FrontmostApplicationState.shared.snapshot?.pid == pid
        }

        #expect(FrontmostApplicationState.shared.snapshot?.bundleIdentifier == bundleIdentifier)

        lifecycleManager.handleWorkspaceApplicationTerminated(pid: pid)

        await waitUntilServiceLifecycleTest {
            FrontmostApplicationState.shared.snapshot == nil
        }
    }

    @Test @MainActor func secureInputSuppressionPersistsAcrossPermissionRestoreUntilSecureInputEnds() async {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let lifecycleManager = controller.serviceLifecycleManager
        var currentPermissionGranted = true
        let permissionStream = makeLifecyclePermissionStream(initial: true)

        lifecycleManager.accessibilityPermissionStateProviderForTests = {
            currentPermissionGranted
        }
        lifecycleManager.accessibilityPermissionStreamProviderForTests = { _ in
            permissionStream.stream
        }
        lifecycleManager.accessibilityPermissionRequestHandlerForTests = { false }
        defer {
            permissionStream.continuation.finish()
            controller.setEnabled(false)
        }

        controller.setEnabled(true)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices && controller.isEnabled && controller.hotkeysEnabled
        }

        lifecycleManager.handleSecureInputChangeForTests(true)

        await waitUntilServiceLifecycleTest {
            lifecycleManager.isSecureInputActive && controller.isEnabled && !controller.hotkeysEnabled
        }

        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)

        currentPermissionGranted = false
        permissionStream.continuation.yield(false)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices &&
                !controller.isEnabled &&
                !controller.hotkeysEnabled &&
                lifecycleManager.isSecureInputActive
        }

        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)

        currentPermissionGranted = true
        permissionStream.continuation.yield(true)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices &&
                controller.isEnabled &&
                !controller.hotkeysEnabled &&
                lifecycleManager.isSecureInputActive
        }

        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)
        #expect(controller.isEnabled)
        #expect(!controller.hotkeysEnabled)

        lifecycleManager.handleSecureInputChangeForTests(false)

        await waitUntilServiceLifecycleTest {
            controller.hasStartedServices &&
                controller.isEnabled &&
                controller.hotkeysEnabled &&
                !lifecycleManager.isSecureInputActive
        }

        #expect(controller.desiredEnabled)
        #expect(controller.desiredHotkeysEnabled)
        #expect(controller.isEnabled)
        #expect(controller.hotkeysEnabled)
    }

    @Test @MainActor func monitorChangeKeepsForcedWorkspaceAuthoritativeAfterRestore() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "3", monitorAssignment: .secondary)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        let oldLeft = makeLifecycleMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeLifecycleMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws3 = controller.workspaceManager.workspaceId(for: "3", createIfMissing: true) else {
            Issue.record("Failed to create expected test workspaces")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(controller.workspaceManager.setActiveWorkspace(ws3, on: oldRight.id))

        let newLeft = makeLifecycleMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeLifecycleMonitor(displayId: 100, name: "L", x: 1920, y: 0)

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [newLeft, newRight],
            performPostUpdateActions: false
        )

        let sorted = Monitor.sortedByPosition(controller.workspaceManager.monitors)
        guard let forcedTarget = MonitorDescription.secondary.resolveMonitor(sortedMonitors: sorted) else {
            Issue.record("Failed to resolve forced monitor target")
            return
        }

        #expect(forcedTarget.id == newRight.id)
        #expect(controller.workspaceManager.activeWorkspace(on: forcedTarget.id)?.id == ws3)
        #expect(controller.workspaceManager.activeWorkspace(on: newLeft.id)?.id != ws3)
    }

    @Test @MainActor func appTerminationClearsFocusMemoryAndDeadHandlesDoNotReturn() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let monitor = makeLifecycleMonitor(displayId: 100, name: "Main", x: 0, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        let pid: pid_t = 7101
        let handle1 = controller.workspaceManager.addWindow(
            makeLifecycleWindow(windowId: 7102),
            pid: pid,
            windowId: 7102,
            to: ws1
        )
        let handle2 = controller.workspaceManager.addWindow(
            makeLifecycleWindow(windowId: 7103),
            pid: pid,
            windowId: 7103,
            to: ws2
        )

        _ = controller.workspaceManager.setManagedFocus(handle1, in: ws1, onMonitor: monitor.id)
        #expect(controller.workspaceManager.setActiveWorkspace(ws2, on: monitor.id))
        _ = controller.workspaceManager.setManagedFocus(handle2, in: ws2, onMonitor: monitor.id)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            handle1,
            in: ws1,
            onMonitor: monitor.id
        )
        controller.focusBridge.applyOrchestrationState(
            nextManagedRequestId: 2,
            activeManagedRequest: ManagedFocusRequest(
                requestId: 1,
                token: handle1,
                workspaceId: ws1
            )
        )
        controller.focusBridge.setFocusedTarget(
            controller.keyboardFocusTarget(for: handle2, axRef: makeLifecycleWindow(windowId: 7103))
        )
        controller.hasStartedServices = true

        lifecycleManager.handleAppTerminated(pid: pid)

        #expect(controller.workspaceManager.entries(forPid: pid).isEmpty)
        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.lastFocusedHandle(in: ws1) == nil)
        #expect(controller.workspaceManager.lastFocusedHandle(in: ws2) == nil)
        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.focusBridge.focusedTarget == nil)

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: monitor.id))
        #expect(controller.workspaceManager.resolveWorkspaceFocus(in: ws1) == nil)
        #expect(controller.workspaceManager.setActiveWorkspace(ws2, on: monitor.id))
        #expect(controller.workspaceManager.resolveWorkspaceFocus(in: ws2) == nil)

        let survivingPid: pid_t = 7201
        let survivingToken = controller.workspaceManager.addWindow(
            makeLifecycleWindow(windowId: 7202),
            pid: survivingPid,
            windowId: 7202,
            to: ws1
        )
        controller.axEventHandler.focusedWindowRefProvider = { incomingPid in
            guard incomingPid == survivingPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: survivingToken.windowId)
        }

        controller.axEventHandler.handleAppActivation(
            pid: survivingPid,
            source: .focusedWindowChanged
        )

        #expect(controller.workspaceManager.focusedToken == survivingToken)
        #expect(controller.focusBridge.activeManagedRequest == nil)
    }

    @Test @MainActor func monitorReconnectRestorePreservesViewportState() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        let oldLeft = makeLifecycleMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeLifecycleMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(controller.workspaceManager.setActiveWorkspace(ws2, on: oldRight.id))

        let selectedNodeId = NodeId()
        controller.workspaceManager.withNiriViewportState(for: ws2) { state in
            state.activeColumnIndex = 3
            state.selectedNodeId = selectedNodeId
        }

        let newLeft = makeLifecycleMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeLifecycleMonitor(displayId: 100, name: "L", x: 1920, y: 0)
        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [newLeft, newRight],
            performPostUpdateActions: false
        )

        #expect(controller.workspaceManager.activeWorkspace(on: newRight.id)?.id == ws2)
        #expect(controller.workspaceManager.niriViewportState(for: ws2).activeColumnIndex == 3)
        #expect(controller.workspaceManager.niriViewportState(for: ws2).selectedNodeId == selectedNodeId)
    }

    @Test @MainActor func monitorDisconnectKeepsMigratedWorkspaceWindowsActiveDuringVisibilityRefresh() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        let left = makeLifecycleMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeLifecycleMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: left.id))
        #expect(controller.workspaceManager.setActiveWorkspace(ws2, on: right.id))

        _ = controller.workspaceManager.addWindow(
            makeLifecycleWindow(windowId: 9201),
            pid: 9201,
            windowId: 9201,
            to: ws1
        )
        let migratedToken = controller.workspaceManager.addWindow(
            makeLifecycleWindow(windowId: 9202),
            pid: 9202,
            windowId: 9202,
            to: ws2
        )

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [left],
            performPostUpdateActions: false
        )
        controller.layoutRefreshController.hideInactiveWorkspacesSync()

        #expect(controller.workspaceManager.activeWorkspace(on: left.id)?.id == ws2)
        #expect(controller.workspaceManager.previousWorkspace(on: left.id)?.id == ws1)
        #expect(controller.workspaceManager.entry(forWindowId: 9202, inVisibleWorkspaces: true) != nil)
        #expect(controller.workspaceManager.entry(forWindowId: 9201, inVisibleWorkspaces: true) == nil)
        #expect(!controller.axManager.inactiveWorkspaceWindowIds.contains(9202))
        #expect(controller.axManager.inactiveWorkspaceWindowIds.contains(9201))
        #expect(controller.workspaceManager.hiddenState(for: migratedToken) == nil)
    }

    @Test @MainActor func monitorConfigurationChangeRequestsFullRescanWhileDelegatingStateRestore() async {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let oldMonitor = makeLifecycleMonitor(displayId: 100, name: "Old", x: 0, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([oldMonitor])

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create expected workspace")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(workspaceId, on: oldMonitor.id))

        var recordedReason: RefreshReason?
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            recordedReason = reason
            return true
        }

        let newMonitor = makeLifecycleMonitor(displayId: 200, name: "New", x: 0, y: 0)
        lifecycleManager.applyMonitorConfigurationChanged(currentMonitors: [newMonitor])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(recordedReason == .monitorConfigurationChanged)
        #expect(controller.workspaceManager.activeWorkspace(on: newMonitor.id)?.id == workspaceId)
    }

    @Test @MainActor func monitorTopologyChangesRecomputeMouseWarpPolicyAndPreserveSavedOrder() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        let left = makeLifecycleMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeLifecycleMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        settings.mouseWarpMonitorOrder = []

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [left, right],
            performPostUpdateActions: false
        )

        #expect(controller.isMouseWarpPolicyEnabled)
        #expect(settings.mouseWarpMonitorOrder == [OutputId(from: left), OutputId(from: right)])
        #expect(settings.effectiveMouseWarpMonitorOrder(for: [left, right]) == [left.id, right.id])

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [left],
            performPostUpdateActions: false
        )

        #expect(!controller.isMouseWarpPolicyEnabled)
        #expect(settings.mouseWarpMonitorOrder == [OutputId(from: left), OutputId(from: right)])
        #expect(settings.effectiveMouseWarpMonitorOrder(for: [left]) == [left.id])

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [left, right],
            performPostUpdateActions: false
        )

        #expect(controller.isMouseWarpPolicyEnabled)
        #expect(settings.mouseWarpMonitorOrder == [OutputId(from: left), OutputId(from: right)])
        #expect(settings.effectiveMouseWarpMonitorOrder(for: [left, right]) == [left.id, right.id])
    }
}
