import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeAXEventTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.ax-event.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeAXEventTestMonitor() -> Monitor {
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    return Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: "Main"
    )
}

@MainActor
private func makeAXEventTestController() -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let controller = WMController(
        settings: SettingsStore(defaults: makeAXEventTestDefaults()),
        windowFocusOperations: operations
    )
    controller.workspaceManager.applyMonitorConfigurationChange([makeAXEventTestMonitor()])
    return controller
}

@MainActor
private func lastAppliedBorderWindowId(on controller: WMController) -> Int? {
    controller.borderManager.lastAppliedFocusedWindowIdForTests
}

@Suite struct AXEventHandlerTests {
    @Test @MainActor func malformedActivationPayloadFallsBackToNonManagedFocus() {
        let controller = makeAXEventTestController()
        controller.hasStartedServices = true
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 801),
            pid: getpid(),
            windowId: 801,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.axEventHandler.focusedWindowValueProvider = { _ in
            "bad-payload" as CFString
        }

        controller.axEventHandler.handleAppActivation(pid: getpid())

        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
    }

    @Test @MainActor func hiddenMoveResizeEventsAreSuppressedButVisibleOnesStillRelayout() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let visibleHandle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 811),
            pid: getpid(),
            windowId: 811,
            to: workspaceId
        )
        let hiddenHandle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 812),
            pid: getpid(),
            windowId: 812,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            visibleHandle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.workspaceManager.setHiddenState(
            .init(proportionalPosition: .zero, referenceMonitorId: nil, workspaceInactive: false),
            for: hiddenHandle
        )

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 812)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 811)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons == [.axWindowChanged])
    }

    @Test @MainActor func nativeHiddenMoveResizeEventsDoNotRelayout() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 813),
            pid: pid,
            windowId: 813,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.handleAppHidden(pid: pid)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 813)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 813)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func frameChangedBurstCoalescesToSingleRelayout() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 814),
            pid: getpid(),
            windowId: 814,
            to: workspaceId
        )

        let observer = CGSEventObserver.shared
        observer.resetDebugStateForTests()
        observer.delegate = controller.axEventHandler
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        observer.enqueueEventForTests(.frameChanged(windowId: 814))
        observer.enqueueEventForTests(.frameChanged(windowId: 814))
        observer.flushPendingCGSEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons == [.axWindowChanged])
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 1)
    }

    @Test @MainActor func interactiveGestureSuppresssFrameChangedRelayoutButKeepsBorderPath() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 815),
            pid: getpid(),
            windowId: 815,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.frameProvider = { _ in
            CGRect(x: 20, y: 20, width: 640, height: 480)
        }
        controller.setBordersEnabled(true)
        controller.mouseEventHandler.state.isResizing = true
        controller.axEventHandler.resetDebugStateForTests()

        let observer = CGSEventObserver.shared
        observer.resetDebugStateForTests()
        observer.delegate = controller.axEventHandler
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
            controller.mouseEventHandler.state.isResizing = false
            controller.axEventHandler.frameProvider = nil
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        observer.enqueueEventForTests(.frameChanged(windowId: 815))
        observer.enqueueEventForTests(.frameChanged(windowId: 815))
        observer.flushPendingCGSEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedDuringGesture == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == 815)
    }

    @Test @MainActor func deferredCreatedWindowsReplayExactlyOnceWhenDiscoveryEnds() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        var subscriptions: [[UInt32]] = []
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowTypeProvider = { _, _ in .tiling }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }

        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = true
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 821, spaceId: 0)
        )
        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = false

        await controller.axEventHandler.drainDeferredCreatedWindows()
        await controller.axEventHandler.drainDeferredCreatedWindows()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 821)?.workspaceId == workspaceId)
        #expect(controller.workspaceManager.allEntries().filter { $0.windowId == 821 }.count == 1)
        #expect(subscriptions == [[821]])
    }

    @Test @MainActor func appHideAndUnhideUseVisibilityRouteAndPreserveModelState() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 831),
            pid: pid,
            windowId: 831,
            to: workspaceId
        )

        var visibilityReasons: [RefreshReason] = []
        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            visibilityReasons.append(reason)
            return true
        }
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.handleAppHidden(pid: pid)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(visibilityReasons == [.appHidden])
        #expect(relayoutReasons.isEmpty)
        #expect(controller.hiddenAppPIDs.contains(pid))
        #expect(controller.workspaceManager.layoutReason(for: handle) == .macosHiddenApp)

        visibilityReasons.removeAll()

        controller.axEventHandler.handleAppUnhidden(pid: pid)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(visibilityReasons == [.appUnhidden])
        #expect(relayoutReasons.isEmpty)
        #expect(!controller.hiddenAppPIDs.contains(pid))
        #expect(controller.workspaceManager.layoutReason(for: handle) == .standard)
    }

    @Test @MainActor func hidingFocusedAppHidesBorderWithoutInvokingLayoutHandlers() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 832),
            pid: pid,
            windowId: 832,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        guard let entry = controller.workspaceManager.entry(for: handle) else {
            Issue.record("Missing managed entry")
            return
        }

        controller.setBordersEnabled(true)
        controller.borderManager.updateFocusedWindow(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600),
            windowId: entry.windowId
        )
        #expect(lastAppliedBorderWindowId(on: controller) == entry.windowId)

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.handleAppHidden(pid: pid)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func destroyRemovesInactiveWorkspaceEntryImmediately() {
        let controller = makeAXEventTestController()
        guard let monitorId = controller.workspaceManager.monitors.first?.id,
              let activeWorkspaceId = controller.activeWorkspace()?.id,
              let inactiveWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace setup")
            return
        }

        let pid: pid_t = 9_101
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 901),
            pid: pid,
            windowId: 901,
            to: inactiveWorkspaceId
        )
        #expect(controller.workspaceManager.setActiveWorkspace(activeWorkspaceId, on: monitorId))

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: pid, level: 0, frame: .zero)
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 901, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: 901) == nil)
    }

    @Test @MainActor func createAfterInactiveDestroyAllowsReusedWindowIdFromDifferentPid() {
        let controller = makeAXEventTestController()
        guard let monitorId = controller.workspaceManager.monitors.first?.id,
              let activeWorkspaceId = controller.activeWorkspace()?.id,
              let inactiveWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace setup")
            return
        }

        let originalPid: pid_t = 9_111
        let refreshedPid: pid_t = 9_112
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 902),
            pid: originalPid,
            windowId: 902,
            to: inactiveWorkspaceId
        )
        #expect(controller.workspaceManager.setActiveWorkspace(activeWorkspaceId, on: monitorId))

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: originalPid, level: 0, frame: .zero)
        }
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 902, spaceId: 0)
        )
        #expect(controller.workspaceManager.entry(forPid: originalPid, windowId: 902) == nil)

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: refreshedPid, level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowTypeProvider = { _, _ in .tiling }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 902, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(forPid: originalPid, windowId: 902) == nil)
        #expect(controller.workspaceManager.entry(forPid: refreshedPid, windowId: 902) != nil)
        #expect(controller.workspaceManager.allEntries().filter { $0.windowId == 902 }.count == 1)
    }

    @Test @MainActor func frameChangedUsesResolvedTokenWhenWindowIdsCollideAcrossPids() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let stalePid: pid_t = 9_121
        let focusedPid: pid_t = 9_122
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 903),
            pid: stalePid,
            windowId: 903,
            to: workspaceId
        )
        let focusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 903),
            pid: focusedPid,
            windowId: 903,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            focusedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.frameProvider = { _ in
            CGRect(x: 40, y: 40, width: 500, height: 400)
        }
        controller.setBordersEnabled(true)

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: stalePid, level: 0, frame: .zero)
        }
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 903)
        )
        #expect(lastAppliedBorderWindowId(on: controller) == nil)

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: focusedPid, level: 0, frame: .zero)
        }
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 903)
        )
        #expect(lastAppliedBorderWindowId(on: controller) == 903)
    }
}
