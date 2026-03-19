import AppKit
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
private func makeAXEventOwnedWindow(
    frame: CGRect = CGRect(x: 80, y: 80, width: 280, height: 180)
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

@MainActor
private func makeAXEventTestController(trackedGhosttyBundleId: String? = nil) -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let settings = SettingsStore(defaults: makeAXEventTestDefaults())
    settings.workspaceConfigurations = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
    let controller = WMController(
        settings: settings,
        windowFocusOperations: operations
    )
    if let trackedGhosttyBundleId {
        controller.appInfoCache.storeInfoForTests(pid: getpid(), bundleId: trackedGhosttyBundleId)
        controller.axEventHandler.bundleIdProvider = { _ in trackedGhosttyBundleId }
    }
    controller.workspaceManager.applyMonitorConfigurationChange([makeAXEventTestMonitor()])
    return controller
}

private func currentTestBundleId() -> String {
    "com.mitchellh.ghostty"
}

private func makeAXEventWindowRuleFacts(
    bundleId: String = "com.example.app",
    appName: String? = nil,
    title: String? = nil,
    role: String? = kAXWindowRole as String,
    subrole: String? = kAXStandardWindowSubrole as String,
    hasCloseButton: Bool = true,
    hasFullscreenButton: Bool = true,
    fullscreenButtonEnabled: Bool? = true,
    hasZoomButton: Bool = true,
    hasMinimizeButton: Bool = true,
    appPolicy: NSApplication.ActivationPolicy? = .regular,
    attributeFetchSucceeded: Bool = true,
    sizeConstraints: WindowSizeConstraints? = nil
) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: appName,
        ax: AXWindowFacts(
            role: role,
            subrole: subrole,
            title: title,
            hasCloseButton: hasCloseButton,
            hasFullscreenButton: hasFullscreenButton,
            fullscreenButtonEnabled: fullscreenButtonEnabled,
            hasZoomButton: hasZoomButton,
            hasMinimizeButton: hasMinimizeButton,
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        ),
        sizeConstraints: sizeConstraints
    )
}

@MainActor
private func lastAppliedBorderWindowId(on controller: WMController) -> Int? {
    controller.borderManager.lastAppliedFocusedWindowIdForTests
}

@MainActor
private func lastAppliedBorderFrame(on controller: WMController) -> CGRect? {
    controller.borderManager.lastAppliedFocusedFrameForTests
}

@MainActor
private func waitUntilAXEventTest(
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0..<iterations where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }

    if !condition() {
        Issue.record("Timed out waiting for AX event test condition")
    }
}

@Suite(.serialized) struct AXEventHandlerTests {
    @Test @MainActor func titleChangedQueuesWorkspaceBarRefreshWithoutRelayout() async {
        let controller = makeAXEventTestController()

        var relayoutReasons: [RefreshReason] = []
        controller.resetWorkspaceBarRefreshDebugStateForTests()
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .titleChanged(windowId: 811)
        )

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(controller.workspaceBarRefreshDebugState.isQueued)

        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func titleChangedQueuesRuleReevaluationWhenDynamicRulesExist() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        controller.settings.appRules = [
            AppRule(
                bundleId: "com.example.dynamic",
                titleSubstring: "Chooser",
                layout: .float
            )
        ]
        var relayoutReasons: [RefreshReason] = []
        var title = "Document"
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 812),
            pid: getpid(),
            windowId: 812,
            to: workspaceId
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 812 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.dynamic",
                title: title
            )
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            if reason == .appRulesChanged {
                return true
            }
            Issue.record("Unexpected full rescan reason: \(reason)")
            return true
        }
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }
        controller.updateAppRules()

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        title = "Chooser"

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .titleChanged(windowId: 812)
        )

        await controller.waitForWorkspaceBarRefreshForTests()
        await waitUntilAXEventTest { relayoutReasons == [.windowRuleReevaluation] }

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(relayoutReasons == [.windowRuleReevaluation])
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 812)?.mode == .floating)
    }

    @Test @MainActor func titleChangedQueuesRuleReevaluationForBuiltInPictureInPictureRule() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        var relayoutReasons: [RefreshReason] = []
        var title = "Document"
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 813),
            pid: getpid(),
            windowId: 813,
            to: workspaceId
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 813 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "org.mozilla.firefox",
                title: title
            )
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        title = "Picture-in-Picture"
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .titleChanged(windowId: 813)
        )

        await controller.waitForWorkspaceBarRefreshForTests()
        await waitUntilAXEventTest { relayoutReasons == [.windowRuleReevaluation] }

        #expect(relayoutReasons == [.windowRuleReevaluation])
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 813)?.mode == .floating)
    }

    @Test @MainActor func malformedActivationPayloadFallsBackToNonManagedFocus() {
        let controller = makeAXEventTestController()
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
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

    @Test @MainActor func ownedUtilityWindowActivationPreservesManagedFocus() {
        let controller = makeAXEventTestController()
        controller.hasStartedServices = true
        let registry = OwnedWindowRegistry.shared
        let ownedWindow = makeAXEventOwnedWindow()
        registry.resetForTests()
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
        }

        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 802),
            pid: getpid(),
            windowId: 802,
            to: workspaceId
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            Issue.record("Missing handle for owned utility focus test")
            return
        }
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        #expect(registry.contains(window: ownedWindow))
        #expect(controller.hasVisibleOwnedWindow)

        controller.axEventHandler.handleAppActivation(pid: getpid())

        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
    }

    @Test @MainActor func fullscreenManagedActivationSuspendsManagedWindowWithoutRelayout() async {
        let controller = makeAXEventTestController()
        controller.hasStartedServices = true
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 803),
            pid: getpid(),
            windowId: 803,
            to: workspaceId
        )
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry")
            return
        }
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: true
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive)
        #expect(controller.workspaceManager.focusedToken == nil)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func nativeFullscreenCommandRoundTripsThroughObservedStateTransitions() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 804),
            pid: getpid(),
            windowId: 804,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        var fullscreenStates: [Int: Bool] = [804: false]
        var fullscreenWrites: [(Int, Bool)] = []
        controller.commandHandler.nativeFullscreenStateProvider = { axRef in
            fullscreenStates[axRef.windowId] ?? false
        }
        controller.commandHandler.nativeFullscreenSetter = { axRef, fullscreen in
            fullscreenWrites.append((axRef.windowId, fullscreen))
            fullscreenStates[axRef.windowId] = fullscreen
            return true
        }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }

        controller.commandHandler.handleCommand(.toggleNativeFullscreen)

        guard let enterRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing native fullscreen enter request")
            return
        }
        #expect(fullscreenWrites.count == 1)
        #expect(fullscreenWrites.first?.0 == 804)
        #expect(fullscreenWrites.first?.1 == true)
        #expect(controller.workspaceManager.layoutReason(for: token) == .standard)
        if case .enterRequested = enterRecord.transition {} else {
            Issue.record("Expected native fullscreen record to remain enterRequested until activation")
        }

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry after native fullscreen request")
            return
        }

        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive)
        #expect(controller.workspaceManager.focusedToken == nil)

        controller.commandHandler.handleCommand(.toggleNativeFullscreen)

        guard let exitRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing native fullscreen exit request")
            return
        }
        #expect(fullscreenWrites.count == 2)
        #expect(fullscreenWrites[1].0 == 804)
        #expect(fullscreenWrites[1].1 == false)
        if case .exitRequested = exitRecord.transition {} else {
            Issue.record("Expected native fullscreen record to switch to exitRequested")
        }

        guard let exitEntry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry before native fullscreen restore")
            return
        }

        controller.axEventHandler.handleManagedAppActivation(
            entry: exitEntry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token) == nil)
        #expect(controller.workspaceManager.layoutReason(for: token) == .standard)
        #expect(controller.workspaceManager.focusedToken == token)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
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

    @Test @MainActor func floatingFrameChangedUpdatesGeometryWithoutRelayout() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8141),
            pid: getpid(),
            windowId: 8141,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 10, y: 10, width: 300, height: 200),
                normalizedOrigin: nil,
                referenceMonitorId: controller.workspaceManager.monitorId(for: workspaceId),
                restoreToFloating: true
            ),
            for: token
        )
        controller.axEventHandler.frameProvider = { _ in
            CGRect(x: 120, y: 140, width: 360, height: 240)
        }
        defer { controller.axEventHandler.frameProvider = nil }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 8141)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(
            controller.workspaceManager.floatingState(for: token)?.lastFrame
                == CGRect(x: 120, y: 140, width: 360, height: 240)
        )
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

    @Test @MainActor func interactiveGestureUsesFastFrameProviderWhenPrimaryProviderIsMissing() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 816),
            pid: getpid(),
            windowId: 816,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.fastFrameProvider = { _ in
            CGRect(x: 48, y: 36, width: 620, height: 420)
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.setBordersEnabled(true)
        controller.mouseEventHandler.state.isResizing = true
        controller.axEventHandler.resetDebugStateForTests()
        defer {
            controller.axEventHandler.fastFrameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.mouseEventHandler.state.isResizing = false
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 816)
        )

        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedDuringGesture == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == 816)
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
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.app")
        }
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

    @Test @MainActor func ghosttyReplacementRekeysManagedWindowInsteadOfRemovingAndReadding() async {
        let controller = makeAXEventTestController(trackedGhosttyBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 841),
            pid: getpid(),
            windowId: 841,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing managed entry")
            return
        }

        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)
        let plannedFrame = CGRect(x: 80, y: 80, width: 900, height: 640)
        let observedFrame = CGRect(x: 80, y: 56, width: 900, height: 664)
        oldNode.frame = plannedFrame
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = oldNode.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(-1440)
        }

        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            oldToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { axRef in
            axRef.windowId == 842 ? observedFrame : nil
        }
        defer {
            controller.borderCoordinator.observedFrameProviderForTests = nil
        }

        var relayoutReasons: [RefreshReason] = []
        var subscriptions: [[UInt32]] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 841, 842:
                WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: currentTestBundleId())
        }
        controller.resetWorkspaceBarRefreshDebugStateForTests()
        relayoutReasons.removeAll()
        subscriptions.removeAll()

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 841, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 842, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await controller.waitForWorkspaceBarRefreshForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 842)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(replacementEntry.workspaceId == workspaceId)
        #expect(controller.workspaceManager.focusedToken == replacementToken)
        #expect(controller.workspaceManager.pendingFocusedToken == replacementToken)
        #expect(controller.workspaceManager.lastFocusedToken(in: workspaceId) == replacementToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == oldNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 0)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).viewOffsetPixels.current() == -1440)
        #expect(engine.findNode(for: oldToken) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == oldNode.id)
        #expect(relayoutReasons.isEmpty)
        #expect(subscriptions == [[842], [842]])
        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == 842)
        #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
    }

    @Test @MainActor func samePidCreateDoesNotStealAwaitingNativeFullscreenReplacementFromDifferentWorkspace() {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }

        guard let workspace1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        else {
            Issue.record("Missing expected workspace")
            return
        }

        let pid: pid_t = 5501
        let suspendedToken1 = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 851),
            pid: pid,
            windowId: 851,
            to: workspace1
        )
        let suspendedToken2 = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 852),
            pid: pid,
            windowId: 852,
            to: workspace1
        )
        guard let suspendedEntry1 = controller.workspaceManager.entry(for: suspendedToken1),
              let suspendedEntry2 = controller.workspaceManager.entry(for: suspendedToken2)
        else {
            Issue.record("Missing suspended entries")
            return
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(suspendedToken1, in: workspace1)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(suspendedToken1)
        controller.axEventHandler.handleRemoved(token: suspendedToken1)
        _ = controller.workspaceManager.requestNativeFullscreenEnter(suspendedToken2, in: workspace1)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(suspendedToken2)
        controller.axEventHandler.handleRemoved(token: suspendedToken2)

        let unrelatedToken = WindowToken(pid: pid, windowId: 853)
        let unrelatedWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 853)
        let restored = controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
            token: unrelatedToken,
            windowId: 853,
            axRef: unrelatedWindow,
            workspaceId: workspace1,
            appFullscreen: false
        )
        _ = controller.workspaceManager.addWindow(
            unrelatedWindow,
            pid: pid,
            windowId: 853,
            to: workspace1
        )

        guard let unrelatedEntry = controller.workspaceManager.entry(for: unrelatedToken) else {
            Issue.record("Missing unrelated created entry")
            return
        }

        #expect(restored == false)
        #expect(controller.workspaceManager.entry(for: suspendedToken1)?.handle === suspendedEntry1.handle)
        #expect(controller.workspaceManager.entry(for: suspendedToken2)?.handle === suspendedEntry2.handle)
        #expect(unrelatedEntry.handle !== suspendedEntry1.handle)
        #expect(unrelatedEntry.handle !== suspendedEntry2.handle)
        #expect(unrelatedEntry.workspaceId == workspace1)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: suspendedToken1) != nil)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: suspendedToken2) != nil)
        #expect(controller.workspaceManager.layoutReason(for: suspendedToken1) == .nativeFullscreen)
        #expect(controller.workspaceManager.layoutReason(for: suspendedToken2) == .nativeFullscreen)
    }

    @Test @MainActor func unmatchedGhosttyDestroyRemovesAfterFlushWindow() {
        let controller = makeAXEventTestController(trackedGhosttyBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 843),
            pid: getpid(),
            windowId: 843,
            to: workspaceId
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 843 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 843, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(for: token) != nil)

        controller.axEventHandler.flushPendingGhosttyReplacementEventsForTests()

        #expect(controller.workspaceManager.entry(for: token) == nil)
    }

    @Test @MainActor func unmatchedGhosttyCreateAdmitsAfterFlushWindow() async {
        let controller = makeAXEventTestController(trackedGhosttyBundleId: currentTestBundleId())

        var subscriptions: [[UInt32]] = []
        controller.layoutRefreshController.resetDebugState()
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 844 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: currentTestBundleId())
        }
        controller.resetWorkspaceBarRefreshDebugStateForTests()

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 844, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 844) == nil)

        controller.axEventHandler.flushPendingGhosttyReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 844) != nil)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.executedByReason[.axWindowCreated] == 1)
        #expect(subscriptions == [[844]])
        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
    }

    @Test @MainActor func floatingCreatedWindowStaysTrackedAndKeepsWorkspaceAssignment() async {
        let controller = makeAXEventTestController()
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.example.app",
                    layout: .float,
                    assignToWorkspace: "2"
                )
            ]
        )

        var subscriptions: [[UInt32]] = []
        var relayoutReasons: [RefreshReason] = []
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.frameProvider = { _ in
            CGRect(x: 120, y: 160, width: 420, height: 300)
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.app")
        }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        defer { controller.axEventHandler.frameProvider = nil }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 822, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 822)
        else {
            Issue.record("Expected tracked floating entry")
            return
        }

        #expect(entry.workspaceId == workspaceId)
        #expect(entry.mode == .floating)
        #expect(controller.workspaceManager.floatingState(for: entry.token) != nil)
        #expect(subscriptions == [[822]])
        #expect(relayoutReasons == [.axWindowCreated])
    }

    @Test @MainActor func forceTileRuleAdmitsFloatingCreateCandidateAndCachesRuleEffects() async {
        let controller = makeAXEventTestController(trackedGhosttyBundleId: "com.adobe.illustrator")
        controller.settings.appRules = [
            AppRule(
                bundleId: "com.adobe.illustrator",
                layout: .tile,
                assignToWorkspace: "2",
                minWidth: 880,
                minHeight: 640
            )
        ]
        var fullRescanReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            return true
        }
        controller.updateAppRules()
        await waitUntilAXEventTest { fullRescanReasons == [.appRulesChanged] }

        var relayoutReasons: [RefreshReason] = []
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.adobe.illustrator",
                appName: "Adobe Illustrator",
                title: "Untitled-1",
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil
            )
        }
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 823, spaceId: 0)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 823) != nil &&
                relayoutReasons == [.axWindowCreated]
        }

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 823)
        else {
            Issue.record("Missing managed entry for force-tile admission test")
            return
        }

        #expect(entry.workspaceId == workspaceId)
        #expect(entry.ruleEffects.minWidth == 880)
        #expect(entry.ruleEffects.minHeight == 640)
        #expect(relayoutReasons == [.axWindowCreated])
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
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.app")
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 902, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(forPid: originalPid, windowId: 902) == nil)
        #expect(controller.workspaceManager.entry(forPid: refreshedPid, windowId: 902) != nil)
        #expect(controller.workspaceManager.allEntries().filter { $0.windowId == 902 }.count == 1)
    }

    @Test @MainActor func destroyRemovesEntryOwnedManualOverride() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let token = WindowToken(pid: getpid(), windowId: 903)
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 903),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )
        controller.workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 903 else { return nil }
            return WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: .zero)
        }
        defer { controller.axEventHandler.windowInfoProvider = nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 903, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(controller.workspaceManager.manualLayoutOverride(for: token) == nil)
    }

    @Test @MainActor func axDestroyPrefersHintedPidWhenWindowIdIsReused() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let stalePid: pid_t = 9_113
        let livePid: pid_t = 9_114
        let staleToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 904),
            pid: stalePid,
            windowId: 904,
            to: workspaceId
        )
        let liveToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 904),
            pid: livePid,
            windowId: 904,
            to: workspaceId
        )

        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 904 else { return nil }
            return WindowServerInfo(id: windowId, pid: livePid, level: 0, frame: .zero)
        }

        controller.axEventHandler.handleRemoved(pid: stalePid, winId: 904)

        #expect(controller.workspaceManager.entry(for: staleToken) == nil)
        #expect(controller.workspaceManager.entry(for: liveToken) != nil)
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
