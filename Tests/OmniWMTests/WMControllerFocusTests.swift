import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private enum FocusOperationEvent: Equatable {
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
}

private enum RaiseAllFloatingEvent: Equatable {
    case order(Int)
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
    case frontOwned(Int)
}

private final class RaiseAllFloatingRecorder {
    var events: [RaiseAllFloatingEvent] = []
}

private func makeFocusTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.focus-order.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeFocusTestMonitor(
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

private func makeFocusTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeExternalQuakeRestoreTarget(
    pid: pid_t,
    windowId: Int
) -> QuakeTerminalRestoreTarget {
    .external(
        KeyboardFocusTarget(
            token: WindowToken(pid: pid, windowId: windowId),
            axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId),
            workspaceId: nil,
            isManaged: false
        )
    )
}

@MainActor
private func makeRaiseAllFloatingOperations(
    recorder: RaiseAllFloatingRecorder
) -> WindowFocusOperations {
    WindowFocusOperations(
        activateApp: { pid in
            recorder.events.append(.activate(pid))
        },
        focusSpecificWindow: { pid, windowId, _ in
            recorder.events.append(.focus(pid, windowId))
        },
        raiseWindow: { _ in
            recorder.events.append(.raise)
        }
    )
}

@MainActor
private func makeRaiseAllFloatingHandler(
    controller: WMController,
    recorder: RaiseAllFloatingRecorder
) -> WindowActionHandler {
    WindowActionHandler(
        controller: controller,
        orderWindow: { windowId in
            recorder.events.append(.order(Int(windowId)))
        },
        visibleWindowInfoProvider: { [] },
        visibleOwnedWindowsProvider: { [] },
        frontOwnedWindow: { window in
            recorder.events.append(.frontOwned(window.windowNumber))
        }
    )
}

@MainActor
@discardableResult
private func addManagedTestWindow(
    on controller: WMController,
    pid: pid_t,
    windowId: Int,
    workspaceId: WorkspaceDescriptor.ID,
    mode: TrackedWindowMode = .tiling
) -> WindowHandle {
    let token = controller.workspaceManager.addWindow(
        makeFocusTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId,
        mode: mode
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected bridge handle for managed test window")
    }
    return handle
}

@MainActor
private func makeFocusOwnedWindow(
    frame: CGRect = CGRect(x: 60, y: 60, width: 260, height: 180)
) -> NSWindow {
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return window
}

private final class NotificationValueBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private func makeFocusTestController(
    windowFocusOperations: WindowFocusOperations,
    workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main)
    ]
) -> (controller: WMController, workspaceId: WorkspaceDescriptor.ID, handle: WindowHandle) {
    resetSharedControllerStateForTests()
    let settings = SettingsStore(defaults: makeFocusTestDefaults())
    settings.workspaceConfigurations = workspaceConfigurations
    let controller = WMController(settings: settings, windowFocusOperations: windowFocusOperations)
    let monitor = makeFocusTestMonitor()
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])

    guard let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false) else {
        fatalError("Expected a visible workspace for focus test setup")
    }

    let window = makeFocusTestWindow()
    let token = controller.workspaceManager.addWindow(window, pid: getpid(), windowId: window.windowId, to: workspaceId)
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected bridge handle for focus test setup")
    }
    return (controller, workspaceId, handle)
}

@MainActor
private func makeTwoMonitorFocusController(
    windowFocusOperations: WindowFocusOperations
) -> (
    controller: WMController,
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor,
    primaryWorkspaceId: WorkspaceDescriptor.ID,
    secondaryWorkspaceId: WorkspaceDescriptor.ID
) {
    resetSharedControllerStateForTests()
    let settings = SettingsStore(defaults: makeFocusTestDefaults())
    settings.workspaceConfigurations = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
    ]
    let controller = WMController(settings: settings, windowFocusOperations: windowFocusOperations)
    let primaryMonitor = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
    let secondaryMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
    controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

    guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
    else {
        fatalError("Expected two-monitor focus test fixture")
    }

    guard controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id) else {
        fatalError("Expected primary workspace to activate on the primary monitor")
    }
    _ = controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id)
    _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)

    return (controller, primaryMonitor, secondaryMonitor, primaryWorkspaceId, secondaryWorkspaceId)
}

@MainActor
private func waitForFocusRefresh(on controller: WMController) async {
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
}

@Suite(.serialized) struct WMControllerFocusTests {
    @Test @MainActor func toggleHiddenBarUpdatesCollapsedStateWithoutEnableGate() {
        let settings = SettingsStore(defaults: makeFocusTestDefaults())
        let controller = WMController(settings: settings)
        settings.hiddenBarIsCollapsed = false

        #expect(settings.hiddenBarIsCollapsed == false)

        controller.toggleHiddenBar()

        #expect(settings.hiddenBarIsCollapsed == true)
    }

    @Test @MainActor func applyPersistedSettingsDisablesViewportAnimationsOnColdStart() {
        let settings = SettingsStore(defaults: makeFocusTestDefaults())
        settings.animationsEnabled = false
        let controller = WMController(settings: settings)

        controller.applyPersistedSettings(settings)

        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(
            on: controller.workspaceManager.monitors[0].id
        )?.id else {
            Issue.record("Missing active workspace for cold-start animation policy test")
            return
        }

        let handle = addManagedTestWindow(
            on: controller,
            pid: 7_401,
            windowId: 901,
            workspaceId: workspaceId
        )
        _ = controller.workspaceManager.rememberFocus(handle, in: workspaceId)

        guard let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Expected Niri window state for cold-start animation policy test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: handle
        )

        guard let node = engine.findNode(for: handle),
              let column = engine.findColumn(containing: node, in: workspaceId)
        else {
            Issue.record("Expected Niri window state for cold-start animation policy test")
            return
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = node.id
        engine.toggleFullWidth(
            column,
            in: workspaceId,
            motion: controller.motionPolicy.snapshot(),
            state: &state,
            workingFrame: controller.insetWorkingFrame(for: monitor),
            gaps: CGFloat(controller.workspaceManager.gaps)
        )

        #expect(controller.motionPolicy.animationsEnabled == false)
        #expect(!column.hasWidthAnimationRunning)
        #expect(!state.viewOffsetPixels.isAnimating)
    }

    @Test @MainActor func turningAnimationsOffDoesNotForceQuakeTransitionCompletion() {
        let settings = SettingsStore(defaults: makeFocusTestDefaults())
        let controller = WMController(settings: settings)

        controller.configureQuakeTransitionForTests(visible: true, isTransitioning: true)

        #expect(controller.quakeTerminalIsTransitioningForTests())

        controller.setAnimationsEnabled(false)

        #expect(controller.motionPolicy.animationsEnabled == false)
        #expect(controller.quakeTerminalIsTransitioningForTests())
    }

    @Test @MainActor func toggleWorkspaceBarVisibilityHidesOnlyInteractionMonitorAndPreservesSettings() async {
        let primaryMonitor = Monitor(
            id: Monitor.ID(displayId: 31),
            displayId: 31,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 772),
            hasNotch: false,
            name: "Primary"
        )
        let secondaryMonitor = Monitor(
            id: Monitor.ID(displayId: 32),
            displayId: 32,
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 772),
            hasNotch: false,
            name: "Secondary"
        )
        let controller = makeLayoutPlanTestController(
            monitors: [primaryMonitor, secondaryMonitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
            ]
        )
        controller.configureWorkspaceBarManagerForTests(monitors: [primaryMonitor, secondaryMonitor])
        controller.settings.workspaceBarPosition = .overlappingMenuBar
        controller.settings.workspaceBarHeight = 24
        controller.settings.workspaceBarReserveLayoutSpace = true
        _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)
        controller.setWorkspaceBarEnabled(true)
        defer { controller.cleanupUIOnStop() }

        #expect(controller.activeWorkspaceBarCountForTests() == 2)
        #expect(controller.insetWorkingFrame(for: primaryMonitor).height == 748)
        #expect(controller.insetWorkingFrame(for: secondaryMonitor).height == 748)

        #expect(controller.toggleWorkspaceBarVisibility() == true)
        await waitForFocusRefresh(on: controller)

        #expect(controller.settings.workspaceBarEnabled == true)
        #expect(controller.isWorkspaceBarRuntimeHiddenForTests(on: primaryMonitor.id) == true)
        #expect(controller.isWorkspaceBarRuntimeHiddenForTests(on: secondaryMonitor.id) == false)
        #expect(controller.activeWorkspaceBarCountForTests() == 1)
        #expect(controller.insetWorkingFrame(for: primaryMonitor) == primaryMonitor.visibleFrame)
        #expect(controller.insetWorkingFrame(for: secondaryMonitor).height == 748)

        #expect(controller.toggleWorkspaceBarVisibility() == true)
        await waitForFocusRefresh(on: controller)

        #expect(controller.isWorkspaceBarRuntimeHiddenForTests(on: primaryMonitor.id) == false)
        #expect(controller.activeWorkspaceBarCountForTests() == 2)
        #expect(controller.insetWorkingFrame(for: primaryMonitor).height == 748)
    }

    @Test @MainActor func focusWindowPerformsActivatePrivateFocusAndRaiseInOrder() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)

        controller.focusWindow(handle)

        #expect(events == [
            .activate(getpid()),
            .focus(getpid(), 101),
            .raise
        ])
    }

    @Test @MainActor func restoreQuakeTerminalFocusRoutesManagedTargetThroughManagedFronting() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)

        controller.restoreQuakeTerminalFocus(to: .managed(handle.id))

        #expect(events == [
            .activate(getpid()),
            .focus(getpid(), 101),
            .raise
        ])
    }

    @Test @MainActor func restoreQuakeTerminalFocusFrontsExternalWindowWhenLiveRefExists() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, _) = makeFocusTestController(windowFocusOperations: operations)
        let target = makeExternalQuakeRestoreTarget(pid: getpid(), windowId: 181)
        controller.axEventHandler.axWindowRefProvider = { windowId, pid in
            guard pid == getpid(), windowId == 181 else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }

        controller.restoreQuakeTerminalFocus(to: target)

        #expect(events == [
            .activate(getpid()),
            .focus(getpid(), 181),
            .raise
        ])
    }

    @Test @MainActor func restoreQuakeTerminalFocusFallsBackToAppActivationWhenExternalWindowDisappears() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, _) = makeFocusTestController(windowFocusOperations: operations)

        controller.restoreQuakeTerminalFocus(
            to: makeExternalQuakeRestoreTarget(pid: getpid(), windowId: 182)
        )

        #expect(events == [
            .activate(getpid())
        ])
    }

    @Test @MainActor func restoreQuakeTerminalFocusDoesNothingWhenExternalAppIsGone() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, _) = makeFocusTestController(windowFocusOperations: operations)

        controller.restoreQuakeTerminalFocus(
            to: makeExternalQuakeRestoreTarget(pid: getpid() + 999_999, windowId: 183)
        )

        #expect(events.isEmpty)
    }

    @Test @MainActor func focusWindowStartsPendingFocusButDoesNotConfirmDurableFocus() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)

        controller.focusWindow(handle)

        #expect(controller.workspaceManager.pendingFocusedHandle == handle)
        #expect(controller.workspaceManager.pendingFocusedWorkspaceId == workspaceId)
        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive == true)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == handle)
    }

    @Test @MainActor func focusWindowLeavesConfirmedSessionStateUntouchedUntilActivation() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        controller.focusWindow(handle)

        #expect(controller.workspaceManager.pendingFocusedHandle == handle)
        #expect(controller.workspaceManager.isAppFullscreenActive == true)
        #expect(controller.workspaceManager.isNonManagedFocusActive == true)
    }

    @Test @MainActor func focusWindowIsNoOpForNativeFullscreenSuspendedWindow() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: handle)

        controller.focusWindow(handle)

        #expect(events.isEmpty)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(controller.workspaceManager.focusedHandle == nil)
    }

    @Test @MainActor func relayoutDoesNotRefocusManagedWindowWhileOwnedUtilityWindowIsFrontmost() async {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        let registry = OwnedWindowRegistry.shared
        let ownedWindow = makeFocusOwnedWindow()
        registry.resetForTests()
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
        }

        controller.enableDwindleLayout()
        await waitForFocusRefresh(on: controller)
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.enterNonManagedFocus(
            appFullscreen: false,
            preserveFocusedToken: true
        )
        events.removeAll()

        controller.updateDwindleConfig(smartSplit: false)
        await waitForFocusRefresh(on: controller)

        #expect(events.isEmpty)
        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.isNonManagedFocusActive == true)
    }

    @Test @MainActor func workspaceManagerOwnsDurableControllerFocusState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        let monitorId = controller.workspaceManager.monitorId(for: workspaceId)

        _ = controller.workspaceManager.setManagedFocus(handle, in: workspaceId, onMonitor: monitorId)

        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == handle)
        #expect(controller.workspaceManager.interactionMonitorId == monitorId)
    }

    @Test @MainActor func focusNotificationsTrackWorkspaceManagerOwnedState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let fixture = makeTwoMonitorFocusController(windowFocusOperations: operations)
        let controller = fixture.controller

        let window1 = makeFocusTestWindow(windowId: 201)
        let handle1Token = controller.workspaceManager.addWindow(
            window1,
            pid: getpid(),
            windowId: window1.windowId,
            to: fixture.primaryWorkspaceId
        )
        let window2 = makeFocusTestWindow(windowId: 202)
        let handle2Token = controller.workspaceManager.addWindow(
            window2,
            pid: getpid(),
            windowId: window2.windowId,
            to: fixture.secondaryWorkspaceId
        )
        guard let handle1 = controller.workspaceManager.handle(for: handle1Token),
              let handle2 = controller.workspaceManager.handle(for: handle2Token)
        else {
            Issue.record("Missing bridge handle for focus notification test")
            return
        }

        let focusToken = NotificationValueBox<WindowToken?>(nil)
        let workspaceIdBox = NotificationValueBox<WorkspaceDescriptor.ID?>(nil)
        let monitorDisplayIdBox = NotificationValueBox<CGDirectDisplayID?>(nil)

        let center = NotificationCenter.default
        let focusObserver = center.addObserver(
            forName: .omniwmFocusChanged,
            object: controller,
            queue: nil
        ) { notification in
            focusToken.value = notification.userInfo?[OmniWMFocusNotificationKey.newWindowToken] as? WindowToken
        }
        let workspaceObserver = center.addObserver(
            forName: .omniwmFocusedWorkspaceChanged,
            object: controller,
            queue: nil
        ) { notification in
            workspaceIdBox.value = notification.userInfo?[OmniWMFocusNotificationKey.newWorkspaceId] as? WorkspaceDescriptor.ID
        }
        let monitorObserver = center.addObserver(
            forName: .omniwmFocusedMonitorChanged,
            object: controller,
            queue: nil
        ) { notification in
            monitorDisplayIdBox.value = notification.userInfo?[OmniWMFocusNotificationKey.newMonitorIndex] as? CGDirectDisplayID
        }

        defer {
            center.removeObserver(focusObserver)
            center.removeObserver(workspaceObserver)
            center.removeObserver(monitorObserver)
        }

        _ = controller.workspaceManager.setManagedFocus(
            handle1,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle2,
            in: fixture.secondaryWorkspaceId,
            onMonitor: fixture.secondaryMonitor.id
        )

        #expect(focusToken.value == handle2.id)
        #expect(workspaceIdBox.value == fixture.secondaryWorkspaceId)
        #expect(monitorDisplayIdBox.value == fixture.secondaryMonitor.displayId)
    }

    @Test @MainActor func unmanagedAppActivationClearsManagedFocusState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        controller.hasStartedServices = true
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.handleAppActivation(pid: 999_999)

        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == handle)
    }

    @Test @MainActor func focusLastMonitorRestoresPreviousMonitorFocusOwnerState() async {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let fixture = makeTwoMonitorFocusController(windowFocusOperations: operations)
        let primaryToken = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 301),
            pid: getpid(),
            windowId: 301,
            to: fixture.primaryWorkspaceId
        )
        let secondaryToken = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 302),
            pid: getpid(),
            windowId: 302,
            to: fixture.secondaryWorkspaceId
        )
        guard let primaryHandle = fixture.controller.workspaceManager.handle(for: primaryToken),
              let secondaryHandle = fixture.controller.workspaceManager.handle(for: secondaryToken)
        else {
            Issue.record("Missing bridge handles for focus restoration test")
            return
        }

        _ = fixture.controller.workspaceManager.setManagedFocus(
            primaryHandle,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        _ = fixture.controller.workspaceManager.setManagedFocus(
            secondaryHandle,
            in: fixture.secondaryWorkspaceId,
            onMonitor: fixture.secondaryMonitor.id
        )

        fixture.controller.workspaceNavigationHandler.focusLastMonitor()
        await waitForFocusRefresh(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.primaryMonitor.id)
        #expect(fixture.controller.workspaceManager.previousInteractionMonitorId == fixture.secondaryMonitor.id)
        #expect(fixture.controller.workspaceManager.focusedHandle == secondaryHandle)
        #expect(fixture.controller.workspaceManager.pendingFocusedHandle == primaryHandle)
    }

    @Test @MainActor func managedActivationConfirmsPendingFocusAtomically() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let fixture = makeTwoMonitorFocusController(windowFocusOperations: operations)
        let primaryToken = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 351),
            pid: getpid(),
            windowId: 351,
            to: fixture.primaryWorkspaceId
        )
        let secondaryToken = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 352),
            pid: getpid(),
            windowId: 352,
            to: fixture.secondaryWorkspaceId
        )
        guard let primaryHandle = fixture.controller.workspaceManager.handle(for: primaryToken),
              let secondaryHandle = fixture.controller.workspaceManager.handle(for: secondaryToken)
        else {
            Issue.record("Missing bridge handles for managed activation test")
            return
        }

        _ = fixture.controller.workspaceManager.setManagedFocus(
            primaryHandle,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        fixture.controller.focusWindow(secondaryHandle)
        #expect(fixture.controller.workspaceManager.pendingFocusedHandle == secondaryHandle)
        #expect(fixture.controller.workspaceManager.focusedHandle == primaryHandle)

        guard let entry = fixture.controller.workspaceManager.entry(for: secondaryHandle) else {
            Issue.record("Missing secondary entry")
            return
        }

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        #expect(fixture.controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(fixture.controller.workspaceManager.focusedHandle == secondaryHandle)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.secondaryMonitor.id)
        #expect(fixture.controller.workspaceManager.lastFocusedHandle(in: fixture.secondaryWorkspaceId) == secondaryHandle)
    }

    @Test @MainActor func managedActivationClearsStalePendingRequestWhenConfirmationDiffers() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, confirmedHandle) = makeFocusTestController(windowFocusOperations: operations)
        let pendingToken = controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 353),
            pid: getpid(),
            windowId: 353,
            to: workspaceId
        )
        guard let pendingHandle = controller.workspaceManager.handle(for: pendingToken) else {
            Issue.record("Missing pending bridge handle")
            return
        }

        _ = controller.workspaceManager.setManagedFocus(
            confirmedHandle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.focusWindow(pendingHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == pendingHandle)

        guard let entry = controller.workspaceManager.entry(for: confirmedHandle) else {
            Issue.record("Missing confirmed entry")
            return
        }

        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(controller.workspaceManager.focusedHandle == confirmedHandle)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == confirmedHandle)
        #expect(controller.workspaceManager.preferredFocusHandle(in: workspaceId) == confirmedHandle)
    }

    @Test @MainActor func managedActivationPublishesCoherentCrossMonitorNotifications() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let fixture = makeTwoMonitorFocusController(windowFocusOperations: operations)
        let primaryToken = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 401),
            pid: getpid(),
            windowId: 401,
            to: fixture.primaryWorkspaceId
        )
        let secondaryToken = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 402),
            pid: getpid(),
            windowId: 402,
            to: fixture.secondaryWorkspaceId
        )
        guard let primaryHandle = fixture.controller.workspaceManager.handle(for: primaryToken),
              let secondaryHandle = fixture.controller.workspaceManager.handle(for: secondaryToken)
        else {
            Issue.record("Missing bridge handles for notification test")
            return
        }
        _ = fixture.controller.workspaceManager.setManagedFocus(
            primaryHandle,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        let focusInfo = NotificationValueBox<[AnyHashable: Any]?>(nil)
        let workspaceInfo = NotificationValueBox<[AnyHashable: Any]?>(nil)
        let monitorInfo = NotificationValueBox<[AnyHashable: Any]?>(nil)

        let center = NotificationCenter.default
        let focusObserver = center.addObserver(
            forName: .omniwmFocusChanged,
            object: fixture.controller,
            queue: nil
        ) { notification in
            focusInfo.value = notification.userInfo
        }
        let workspaceObserver = center.addObserver(
            forName: .omniwmFocusedWorkspaceChanged,
            object: fixture.controller,
            queue: nil
        ) { notification in
            workspaceInfo.value = notification.userInfo
        }
        let monitorObserver = center.addObserver(
            forName: .omniwmFocusedMonitorChanged,
            object: fixture.controller,
            queue: nil
        ) { notification in
            monitorInfo.value = notification.userInfo
        }

        defer {
            center.removeObserver(focusObserver)
            center.removeObserver(workspaceObserver)
            center.removeObserver(monitorObserver)
        }

        guard let entry = fixture.controller.workspaceManager.entry(for: secondaryHandle) else {
            Issue.record("Missing secondary entry")
            return
        }

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        #expect(fixture.controller.workspaceManager.focusedHandle == secondaryHandle)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.secondaryMonitor.id)
        #expect(focusInfo.value?[OmniWMFocusNotificationKey.oldWindowToken] as? WindowToken == primaryHandle.id)
        #expect(focusInfo.value?[OmniWMFocusNotificationKey.newWindowToken] as? WindowToken == secondaryHandle.id)
        #expect(focusInfo.value?[OmniWMFocusNotificationKey.oldHandleId] as? WindowToken == primaryHandle.id)
        #expect(focusInfo.value?[OmniWMFocusNotificationKey.newHandleId] as? WindowToken == secondaryHandle.id)
        #expect(workspaceInfo.value?[OmniWMFocusNotificationKey.oldWorkspaceId] as? WorkspaceDescriptor.ID == fixture.primaryWorkspaceId)
        #expect(workspaceInfo.value?[OmniWMFocusNotificationKey.newWorkspaceId] as? WorkspaceDescriptor.ID == fixture.secondaryWorkspaceId)
        #expect(monitorInfo.value?[OmniWMFocusNotificationKey.oldMonitorIndex] as? CGDirectDisplayID == fixture.primaryMonitor.displayId)
        #expect(monitorInfo.value?[OmniWMFocusNotificationKey.newMonitorIndex] as? CGDirectDisplayID == fixture.secondaryMonitor.displayId)
    }

    @Test @MainActor func removingFocusedWindowRecoversPendingFocusToRemainingWindow() async {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, survivor) = makeFocusTestController(windowFocusOperations: operations)
        let removedWindow = makeFocusTestWindow(windowId: 502)
        let removedToken = controller.workspaceManager.addWindow(
            removedWindow,
            pid: getpid(),
            windowId: removedWindow.windowId,
            to: workspaceId
        )
        guard let removedHandle = controller.workspaceManager.handle(for: removedToken) else {
            Issue.record("Missing removed bridge handle")
            return
        }

        _ = controller.workspaceManager.setManagedFocus(
            removedHandle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.handleRemoved(pid: getpid(), winId: removedWindow.windowId)
        await waitForFocusRefresh(on: controller)

        #expect(controller.workspaceManager.entry(for: removedHandle) == nil)
        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.pendingFocusedHandle == survivor)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == survivor)
    }

    @Test @MainActor func focusWindowIsNoOpWhileLocked() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)
        controller.isLockScreenActive = true

        controller.focusWindow(handle)

        #expect(events.isEmpty)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(controller.workspaceManager.focusedHandle == nil)
    }

    @Test @MainActor func raiseAllFloatingWindowsOrdersVisibleFloatingWindowsAcrossMonitors() {
        let recorder = RaiseAllFloatingRecorder()
        let fixture = makeTwoMonitorFocusController(
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        let primaryHandle = addManagedTestWindow(
            on: fixture.controller,
            pid: 10,
            windowId: 701,
            workspaceId: fixture.primaryWorkspaceId,
            mode: .floating
        )
        let secondaryHandle = addManagedTestWindow(
            on: fixture.controller,
            pid: 20,
            windowId: 702,
            workspaceId: fixture.secondaryWorkspaceId,
            mode: .floating
        )
        _ = primaryHandle
        _ = secondaryHandle
        let handler = makeRaiseAllFloatingHandler(controller: fixture.controller, recorder: recorder)

        handler.raiseAllFloatingWindows()

        #expect(recorder.events == [
            .order(701),
            .activate(10),
            .focus(10, 701),
            .raise,
            .order(702),
            .activate(20),
            .focus(20, 702),
            .raise
        ])
    }

    @Test @MainActor func raiseAllFloatingWindowsUsesTrackedFloatingModeInsteadOfFloatingState() {
        let recorder = RaiseAllFloatingRecorder()
        let settings = SettingsStore(defaults: makeFocusTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        let monitor = makeFocusTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else {
            Issue.record("Expected a visible workspace for raise-all tracked-mode test")
            return
        }

        let tiledHandle = addManagedTestWindow(
            on: controller,
            pid: 30,
            windowId: 711,
            workspaceId: workspaceId
        )
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 10, y: 10, width: 400, height: 300),
                normalizedOrigin: .zero,
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: tiledHandle.id
        )
        _ = addManagedTestWindow(
            on: controller,
            pid: 40,
            windowId: 712,
            workspaceId: workspaceId,
            mode: .floating
        )
        let handler = makeRaiseAllFloatingHandler(controller: controller, recorder: recorder)

        handler.raiseAllFloatingWindows()

        #expect(recorder.events == [
            .order(712),
            .activate(40),
            .focus(40, 712),
            .raise
        ])
    }

    @Test @MainActor func raiseAllFloatingWindowsProcessesFocusedFloatingWindowLast() {
        let recorder = RaiseAllFloatingRecorder()
        let fixture = makeTwoMonitorFocusController(
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        let interactionFloating = addManagedTestWindow(
            on: fixture.controller,
            pid: 20,
            windowId: 721,
            workspaceId: fixture.primaryWorkspaceId,
            mode: .floating
        )
        let focusedFloating = addManagedTestWindow(
            on: fixture.controller,
            pid: 10,
            windowId: 722,
            workspaceId: fixture.secondaryWorkspaceId,
            mode: .floating
        )

        _ = fixture.controller.workspaceManager.setManagedFocus(
            interactionFloating,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        _ = fixture.controller.workspaceManager.setManagedFocus(
            focusedFloating,
            in: fixture.secondaryWorkspaceId,
            onMonitor: fixture.secondaryMonitor.id
        )
        _ = fixture.controller.workspaceManager.setInteractionMonitor(fixture.primaryMonitor.id)
        let handler = makeRaiseAllFloatingHandler(controller: fixture.controller, recorder: recorder)

        handler.raiseAllFloatingWindows()

        let focusEvents = recorder.events.compactMap { event -> RaiseAllFloatingEvent? in
            if case .focus = event {
                return event
            }
            return nil
        }
        #expect(focusEvents == [
            .focus(20, 721),
            .focus(10, 722)
        ])
    }

    @Test @MainActor func raiseAllFloatingWindowsIsNoOpWhileLocked() {
        let recorder = RaiseAllFloatingRecorder()
        let (controller, workspaceId, _) = makeFocusTestController(
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        _ = addManagedTestWindow(
            on: controller,
            pid: 50,
            windowId: 731,
            workspaceId: workspaceId,
            mode: .floating
        )
        controller.isLockScreenActive = true
        let handler = makeRaiseAllFloatingHandler(controller: controller, recorder: recorder)

        handler.raiseAllFloatingWindows()

        #expect(recorder.events.isEmpty)
    }

    @Test @MainActor func raiseAllFloatingWindowsIncludesVisibleOwnedUtilityWindows() {
        let recorder = RaiseAllFloatingRecorder()
        let (controller, _, _) = makeFocusTestController(
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let ownedWindow = makeFocusOwnedWindow()
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
        }

        let handler = WindowActionHandler(
            controller: controller,
            orderWindow: { windowId in
                recorder.events.append(.order(Int(windowId)))
            },
            visibleWindowInfoProvider: { [] },
            frontOwnedWindow: { window in
                recorder.events.append(.frontOwned(window.windowNumber))
            }
        )

        handler.raiseAllFloatingWindows()

        #expect(recorder.events == [
            .order(ownedWindow.windowNumber),
            .frontOwned(ownedWindow.windowNumber)
        ])
    }

    @Test @MainActor func raiseAllFloatingWindowsPrefersOwnedUtilityWindowLastWhenMixedWithManagedFloaters() {
        let recorder = RaiseAllFloatingRecorder()
        let (controller, workspaceId, _) = makeFocusTestController(
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        _ = addManagedTestWindow(
            on: controller,
            pid: getpid() + 1_000,
            windowId: 751,
            workspaceId: workspaceId,
            mode: .floating
        )
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let ownedWindow = makeFocusOwnedWindow()
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
        }

        let handler = WindowActionHandler(
            controller: controller,
            orderWindow: { windowId in
                recorder.events.append(.order(Int(windowId)))
            },
            visibleWindowInfoProvider: { [] },
            frontOwnedWindow: { window in
                recorder.events.append(.frontOwned(window.windowNumber))
            }
        )

        handler.raiseAllFloatingWindows()

        #expect(recorder.events == [
            .order(751),
            .activate(getpid() + 1_000),
            .focus(getpid() + 1_000, 751),
            .raise,
            .order(ownedWindow.windowNumber),
            .frontOwned(ownedWindow.windowNumber)
        ])
    }

    @Test @MainActor func raiseAllFloatingWindowsIncludesVisibleUntrackedModalFloatingWindows() {
        let recorder = RaiseAllFloatingRecorder()
        let (controller, _, _) = makeFocusTestController(
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        let windowInfo = WindowServerInfo(
            id: 761,
            pid: 90,
            level: 8,
            frame: .zero,
            tags: 0x8000_0002,
            attributes: 0,
            parentId: 0
        )
        let handler = WindowActionHandler(
            controller: controller,
            orderWindow: { windowId in
                recorder.events.append(.order(Int(windowId)))
            },
            visibleWindowInfoProvider: { [windowInfo] },
            axWindowRefProvider: { windowId, pid in
                guard windowId == 761, pid == 90 else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            },
            visibleOwnedWindowsProvider: { [] },
            frontOwnedWindow: { window in
                recorder.events.append(.frontOwned(window.windowNumber))
            }
        )

        handler.raiseAllFloatingWindows()

        #expect(recorder.events == [
            .order(761),
            .activate(90),
            .focus(90, 761),
            .raise
        ])
    }

    @Test @MainActor func raiseAllFloatingWindowsIgnoresNonUtilityOwnedSurfaces() {
        let recorder = RaiseAllFloatingRecorder()
        let (controller, _, _) = makeFocusTestController(
            windowFocusOperations: makeRaiseAllFloatingOperations(recorder: recorder)
        )
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        let panel = NSPanel(
            contentRect: CGRect(x: 120, y: 90, width: 280, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.orderFrontRegardless()
        registry.register(
            panel,
            surfaceId: "raise-all-workspace-bar-test",
            policy: SurfacePolicy(
                kind: .workspaceBar,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: false
            )
        )
        defer {
            registry.unregister(surfaceId: "raise-all-workspace-bar-test")
            panel.close()
            registry.resetForTests()
        }

        let handler = WindowActionHandler(
            controller: controller,
            orderWindow: { windowId in
                recorder.events.append(.order(Int(windowId)))
            },
            visibleWindowInfoProvider: { [] },
            frontOwnedWindow: { window in
                recorder.events.append(.frontOwned(window.windowNumber))
            }
        )

        handler.raiseAllFloatingWindows()

        #expect(recorder.events.isEmpty)
    }

    @Test @MainActor func toggleFocusedWindowFloatingRetilesTrackedGhosttyFloatingWindow() async {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, _) = makeFocusTestController(windowFocusOperations: operations)
        let ghosttyHandle = addManagedTestWindow(
            on: controller,
            pid: 60,
            windowId: 741,
            workspaceId: workspaceId,
            mode: .floating
        )
        controller.appInfoCache.storeInfoForTests(pid: 60, bundleId: "com.mitchellh.ghostty")
        controller.axEventHandler.windowFactsProvider = { _, pid in
            guard pid == 60 else {
                return WindowRuleFacts(
                    appName: "Example",
                    ax: AXWindowFacts(
                        role: kAXWindowRole as String,
                        subrole: kAXStandardWindowSubrole as String,
                        title: "Example",
                        hasCloseButton: true,
                        hasFullscreenButton: true,
                        fullscreenButtonEnabled: true,
                        hasZoomButton: true,
                        hasMinimizeButton: true,
                        appPolicy: .regular,
                        bundleId: "com.example.app",
                        attributeFetchSucceeded: true
                    ),
                    sizeConstraints: nil,
                    windowServer: nil
                )
            }

            return WindowRuleFacts(
                appName: "Ghostty",
                ax: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "ghostty",
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: .regular,
                    bundleId: "com.mitchellh.ghostty",
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: nil
            )
        }
        defer { controller.axEventHandler.windowFactsProvider = nil }

        _ = controller.workspaceManager.setManagedFocus(
            ghosttyHandle.id,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.toggleFocusedWindowFloating()
        await waitForFocusRefresh(on: controller)

        guard let ghosttyEntry = controller.workspaceManager.entry(for: ghosttyHandle) else {
            Issue.record("Expected tracked Ghostty entry after toggle")
            return
        }

        #expect(ghosttyEntry.mode == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: ghosttyHandle.id) == .forceTile)
        #expect(controller.workspaceManager.tiledEntries(in: workspaceId).contains { $0.token == ghosttyHandle.id })
    }
}
