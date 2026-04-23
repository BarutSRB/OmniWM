// SPDX-License-Identifier: GPL-2.0-only
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
    makeLayoutPlanPrimaryTestMonitor(name: "Main")
}

private func makeAXEventSecondaryMonitor() -> Monitor {
    makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
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
private func makeAXEventTestController(
    windowFocusOperations: WindowFocusOperations? = nil,
    trackedBundleId: String? = nil,
    workspaceConfigurations: [WorkspaceConfiguration]? = nil,
    settings: SettingsStore? = nil
) -> WMController {
    resetSharedControllerStateForTests()
    let operations = windowFocusOperations ?? WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let providedSettings = settings != nil
    let settings = settings ?? SettingsStore(defaults: makeAXEventTestDefaults())
    if let workspaceConfigurations {
        settings.workspaceConfigurations = workspaceConfigurations
    } else if !providedSettings {
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
    }
    let controller = WMController(
        settings: settings,
        windowFocusOperations: operations
    )
    if let trackedBundleId {
        controller.appInfoCache.storeInfoForTests(pid: getpid(), bundleId: trackedBundleId)
        controller.axEventHandler.bundleIdProvider = { _ in trackedBundleId }
    }
    controller.workspaceManager.applyMonitorConfigurationChange([makeAXEventTestMonitor()])
    return controller
}

private func currentTestBundleId() -> String {
    "com.mitchellh.ghostty"
}

private func makeAXEventWindowInfo(
    id: UInt32,
    pid: pid_t = getpid(),
    title: String? = nil,
    frame: CGRect = .zero,
    parentId: UInt32? = nil
) -> WindowServerInfo {
    var info = WindowServerInfo(id: id, pid: pid, level: 0, frame: frame)
    if let parentId {
        info.parentId = parentId
    }
    info.title = title
    return info
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
    sizeConstraints: WindowSizeConstraints? = nil,
    windowServer: WindowServerInfo? = nil
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
        sizeConstraints: sizeConstraints,
        windowServer: windowServer
    )
}

private func makeManagedReplacementMetadata(
    bundleId: String = "com.example.app",
    workspaceId: WorkspaceDescriptor.ID,
    mode: TrackedWindowMode = .tiling,
    title: String? = nil,
    role: String? = kAXWindowRole as String,
    subrole: String? = kAXStandardWindowSubrole as String,
    windowServer: WindowServerInfo? = nil
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: workspaceId,
        mode: mode,
        role: role,
        subrole: subrole,
        title: title,
        windowLevel: windowServer?.level,
        parentWindowId: windowServer?.parentId,
        frame: windowServer?.frame
    )
}

private func makeAXEventPersistedRestoreCatalog(
    workspaceName: String,
    monitor: Monitor,
    title: String,
    bundleId: String = "com.example.restore",
    floatingFrame: CGRect
) -> PersistedWindowRestoreCatalog {
    let metadata = ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: UUID(),
        mode: .floating,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: title,
        windowLevel: 0,
        parentWindowId: 0,
        frame: nil
    )
    let key = PersistedWindowRestoreKey(metadata: metadata)!
    return PersistedWindowRestoreCatalog(
        entries: [
            PersistedWindowRestoreEntry(
                key: key,
                restoreIntent: PersistedRestoreIntent(
                    workspaceName: workspaceName,
                    topologyProfile: TopologyProfile(monitors: [monitor]),
                    preferredMonitor: DisplayFingerprint(monitor: monitor),
                    floatingFrame: floatingFrame,
                    normalizedFloatingOrigin: CGPoint(x: 0.18, y: 0.16),
                    restoreToFloating: true,
                    rescueEligible: true
                )
            )
        ]
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

    @Test @MainActor func createdPictureInPictureWindowRetriesWhenTitleIsInitiallyMissing() async {
        let controller = makeAXEventTestController()
        var relayoutReasons: [RefreshReason] = []
        var title: String?

        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 814 else { return nil }
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

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 814, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 814) == nil)

        title = "Picture-in-Picture"
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 814)?.mode == .floating
                && relayoutReasons == [.windowRuleReevaluation]
        }

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 814)?.mode == .floating)
        #expect(relayoutReasons == [.windowRuleReevaluation])
    }

    @Test @MainActor func createdWindowRetriesWhenAxFactsAreInitiallyIncomplete() async {
        let controller = makeAXEventTestController()
        var relayoutReasons: [RefreshReason] = []
        var attributeFetchSucceeded = false

        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 815 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.partial-ax",
                attributeFetchSucceeded: attributeFetchSucceeded
            )
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 815, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 815) == nil)

        attributeFetchSucceeded = true
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 815)?.mode == .tiling
                && relayoutReasons == [.windowRuleReevaluation]
        }

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 815)?.mode == .tiling)
        #expect(relayoutReasons == [.windowRuleReevaluation])
    }

    @Test @MainActor func createdWindowWithDegradedAxFactsDefersUntilAttributesAvailable() async {
        let controller = makeAXEventTestController(trackedBundleId: "dentalplus-air")
        controller.settings.appRules = [
            AppRule(
                bundleId: "dentalplus-air",
                assignToWorkspace: "2"
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

        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 816 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "dentalplus-air",
                appName: "DentalPlus Client",
                attributeFetchSucceeded: false
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 816, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()



        let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 816)
        #expect(entry == nil)
    }

    @Test @MainActor func createdWindowRetriesWhenAXWindowRefIsInitiallyUnavailableWithoutRuleReevaluation() async {
        let controller = makeAXEventTestController()
        var relayoutReasons: [RefreshReason] = []
        var axWindowRefReady = false
        var axWindowRefLookupCount = 0

        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 817 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == 817 else { return nil }
            axWindowRefLookupCount += 1
            guard axWindowRefReady else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.ax-retry")
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 817, spaceId: 0)
        )
        axWindowRefReady = true

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 817) == nil)

        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 817) != nil &&
                relayoutReasons == [.axWindowCreated]
        }

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 817)?.mode == .tiling)
        #expect(relayoutReasons == [.axWindowCreated])
        #expect(controller.layoutRefreshController.debugCounters.executedByReason[.windowRuleReevaluation, default: 0] == 0)
        #expect(axWindowRefLookupCount >= 2)
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
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
    }

    @Test @MainActor func sameAppNewWindowCreateDefersAppActivationUntilAuthoritativeFocusConfirmation() async throws {
        var focusedWindows: [(pid_t, UInt32)] = []
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusedWindows.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
        let controller = makeAXEventTestController(windowFocusOperations: operations)
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for same-app new-window focus regression test")
            return
        }

        controller.hasStartedServices = true
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.updateNiriConfig(
            maxVisibleColumns: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(1.0), .proportion(1.0)]

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 881),
            pid: getpid(),
            windowId: 881,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        focusedWindows.removeAll()
        controller.axEventHandler.resetDebugStateForTests()

        let newWindowId: UInt32 = 882
        let newToken = WindowToken(pid: getpid(), windowId: Int(newWindowId))
        let newWindowInfo = WindowServerInfo(
            id: newWindowId,
            pid: getpid(),
            level: 0,
            frame: CGRect(x: 120, y: 80, width: 1400, height: 900)
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == newWindowId else { return nil }
            return newWindowInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, pid in
            guard windowId == newWindowId, pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            guard axRef.windowId == Int(newWindowId) else {
                return makeAXEventWindowRuleFacts(bundleId: "com.example.same-app")
            }
            return makeAXEventWindowRuleFacts(
                bundleId: "com.example.same-app",
                title: "Same PID new window",
                windowServer: newWindowInfo
            )
        }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: newWindowId, spaceId: 0)
        )

        await waitUntilAXEventTest(iterations: 300) {
            guard let nodeId = controller.niriEngine?.findNode(for: newToken)?.id else {
                return false
            }
            let state = controller.workspaceManager.niriViewportState(for: workspaceId)
            return controller.workspaceManager.entry(for: newToken) != nil &&
                controller.workspaceManager.pendingFocusedToken == newToken &&
                state.selectedNodeId == nodeId &&
                state.activeColumnIndex == 1 &&
                lastAppliedBorderWindowId(on: controller) == oldToken.windowId
        }

        guard let newNode = controller.niriEngine?.findNode(for: newToken) else {
            Issue.record("Expected Niri node for same-app new-window focus regression test")
            return
        }

        #expect(focusedWindows.contains { $0.0 == getpid() && $0.1 == newWindowId })
        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .workspaceDidActivateApplication
        )

        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(newWindowId))
        }
        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        #expect(controller.workspaceManager.focusedToken == newToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == Int(newWindowId))

        await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()

        #expect(lastAppliedBorderWindowId(on: controller) == Int(newWindowId))
    }

    @Test @MainActor func newAppActivationWaitsForFocusedWindowBeforeLeavingManagedFocus() async throws {
        var focusedWindows: [(pid_t, UInt32)] = []
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusedWindows.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
        let controller = makeAXEventTestController(windowFocusOperations: operations)
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for new-app focus regression test")
            return
        }

        controller.hasStartedServices = true
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.updateNiriConfig(
            maxVisibleColumns: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.niriEngine?.presetColumnWidths = [.proportion(1.0), .proportion(1.0)]

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 891),
            pid: 9_501,
            windowId: 891,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        focusedWindows.removeAll()
        controller.axEventHandler.resetDebugStateForTests()

        let newPid: pid_t = 9_502
        let newWindowId: UInt32 = 892
        let newToken = WindowToken(pid: newPid, windowId: Int(newWindowId))
        let newWindowInfo = WindowServerInfo(
            id: newWindowId,
            pid: newPid,
            level: 0,
            frame: CGRect(x: 100, y: 60, width: 1400, height: 900)
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == newWindowId else { return nil }
            return newWindowInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, pid in
            guard windowId == newWindowId, pid == newPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, pid in
            guard axRef.windowId == Int(newWindowId), pid == newPid else {
                return makeAXEventWindowRuleFacts(bundleId: "com.example.old-app")
            }
            return makeAXEventWindowRuleFacts(
                bundleId: "com.example.new-app",
                title: "New app window",
                windowServer: newWindowInfo
            )
        }
        controller.axEventHandler.focusedWindowRefProvider = { _ in nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: newWindowId, spaceId: 0)
        )

        await waitUntilAXEventTest(iterations: 300) {
            guard let nodeId = controller.niriEngine?.findNode(for: newToken)?.id else {
                return false
            }
            let state = controller.workspaceManager.niriViewportState(for: workspaceId)
            return controller.workspaceManager.entry(for: newToken) != nil &&
                controller.workspaceManager.pendingFocusedToken == newToken &&
                state.selectedNodeId == nodeId &&
                state.activeColumnIndex == 1 &&
                lastAppliedBorderWindowId(on: controller) == oldToken.windowId
        }

        guard let newNode = controller.niriEngine?.findNode(for: newToken) else {
            Issue.record("Expected Niri node for new-app focus regression test")
            return
        }

        #expect(focusedWindows.contains { $0.0 == newPid && $0.1 == newWindowId })
        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)

        controller.axEventHandler.handleAppActivation(
            pid: newPid,
            source: .workspaceDidActivateApplication
        )

        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)

        await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()

        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == newPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(newWindowId))
        }
        controller.axEventHandler.handleAppActivation(
            pid: newPid,
            source: .focusedWindowChanged
        )

        #expect(controller.workspaceManager.focusedToken == newToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == Int(newWindowId))
    }

    @Test @MainActor func workspaceSwitchIgnoresStaleOldAppActivationWhileTargetRequestIsPending() async {
        var focusedWindows: [(pid_t, UInt32)] = []
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusedWindows.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
        let controller = makeAXEventTestController(windowFocusOperations: operations)
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Missing workspace-switch focus fixture")
            return
        }

        controller.hasStartedServices = true

        let oldPid: pid_t = 9_601
        let targetPid: pid_t = 9_602
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 961),
            pid: oldPid,
            windowId: 961,
            to: workspaceOne
        )
        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceOne,
            onMonitor: monitor.id
        )

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 962),
            pid: targetPid,
            windowId: 962,
            to: workspaceTwo
        )
        _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceTwo)

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            switch pid {
            case oldPid:
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
            case targetPid:
                nil
            default:
                nil
            }
        }

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)

        await waitUntilAXEventTest(iterations: 300) {
            controller.activeWorkspace()?.id == workspaceTwo &&
                controller.workspaceManager.pendingFocusedToken == targetToken &&
                focusedWindows.contains { $0.0 == targetPid && $0.1 == UInt32(targetToken.windowId) }
        }

        controller.axEventHandler.handleAppActivation(
            pid: oldPid,
            source: .workspaceDidActivateApplication
        )

        #expect(controller.activeWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.pendingFocusedToken == targetToken)
        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.focusBridge.activeManagedRequest?.token == targetToken)

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == targetPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: targetToken.windowId)
        }
        controller.axEventHandler.handleAppActivation(
            pid: targetPid,
            source: .focusedWindowChanged
        )

        #expect(controller.activeWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.focusedToken == targetToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
    }

    @Test @MainActor func workspaceDidActivateApplicationRevealsManagedWindowOnInactiveWorkspace() async {
        let controller = makeAXEventTestController()
        controller.hasStartedServices = true
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Missing inactive-workspace activation fixture")
            return
        }

        let sourceToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 971),
            pid: 9_701,
            windowId: 971,
            to: workspaceOne
        )
        _ = controller.workspaceManager.setManagedFocus(
            sourceToken,
            in: workspaceOne,
            onMonitor: monitor.id
        )

        let targetPid: pid_t = 9_702
        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 972),
            pid: targetPid,
            windowId: 972,
            to: workspaceTwo
        )
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == targetPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: targetToken.windowId)
        }

        #expect(controller.activeWorkspace()?.id == workspaceOne)
        #expect(controller.workspaceManager.focusedToken == sourceToken)

        controller.axEventHandler.handleAppActivation(
            pid: targetPid,
            source: .workspaceDidActivateApplication
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.activeWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.focusedToken == targetToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.lastFocusedToken(in: workspaceTwo) == targetToken)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
    }

    @Test @MainActor func cgsFrontAppChangedRevealsManagedWindowOnInactiveWorkspace() async {
        let controller = makeAXEventTestController()
        controller.hasStartedServices = true
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Missing inactive-workspace CGS activation fixture")
            return
        }

        let sourceToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 981),
            pid: 9_801,
            windowId: 981,
            to: workspaceOne
        )
        _ = controller.workspaceManager.setManagedFocus(
            sourceToken,
            in: workspaceOne,
            onMonitor: monitor.id
        )

        let targetPid: pid_t = 9_802
        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 982),
            pid: targetPid,
            windowId: 982,
            to: workspaceTwo
        )
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == targetPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: targetToken.windowId)
        }

        #expect(controller.activeWorkspace()?.id == workspaceOne)
        #expect(controller.workspaceManager.focusedToken == sourceToken)

        controller.axEventHandler.handleAppActivation(
            pid: targetPid,
            source: .cgsFrontAppChanged
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.activeWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.focusedToken == targetToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.lastFocusedToken(in: workspaceTwo) == targetToken)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
    }

    @Test @MainActor func frontingProbeRetriesUntilFocusedWindowMatchesPendingRequest() async {
        var focusedWindows: [(pid_t, UInt32)] = []
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusedWindows.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
        let controller = makeAXEventTestController(windowFocusOperations: operations)
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing probe-retry focus fixture")
            return
        }

        controller.hasStartedServices = true

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 971),
            pid: getpid(),
            windowId: 971,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 972),
            pid: getpid(),
            windowId: 972,
            to: workspaceId
        )

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
        }

        controller.focusWindow(targetToken)

        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.pendingFocusedToken == targetToken
        }

        #expect(controller.workspaceManager.pendingFocusedToken == targetToken)
        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(focusedWindows.contains { $0.0 == getpid() && $0.1 == UInt32(targetToken.windowId) })

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: targetToken.windowId)
        }

        await waitUntilAXEventTest(iterations: 400) {
            controller.workspaceManager.focusedToken == targetToken &&
                controller.workspaceManager.pendingFocusedToken == nil
        }

        #expect(controller.workspaceManager.focusedToken == targetToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
    }

    @Test @MainActor func externalFocusedWindowChangeCancelsConflictingPendingRequestAndAdoptsObservedManagedWindow() {
        let controller = makeAXEventTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing managed activation fixture")
            return
        }

        controller.hasStartedServices = true

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 973),
            pid: getpid(),
            windowId: 973,
            to: workspaceId
        )
        let pendingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 974),
            pid: getpid(),
            windowId: 974,
            to: workspaceId
        )
        let observedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 975),
            pid: getpid(),
            windowId: 975,
            to: workspaceId
        )

        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            pendingToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.focusBridge.applyOrchestrationState(
            nextManagedRequestId: 2,
            activeManagedRequest: ManagedFocusRequest(
                requestId: 1,
                token: pendingToken,
                workspaceId: workspaceId
            )
        )
        controller.focusBridge.setFocusedTarget(
            controller.keyboardFocusTarget(
                for: oldToken,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
            )
        )
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: observedToken.windowId)
        }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.focusedToken == observedToken)
        #expect(controller.focusBridge.focusedTarget?.token == observedToken)
    }

    @Test @MainActor func externalFocusedWindowChangeWithNoObservedWindowCancelsPendingRequestAndFallsBackToNonManaged() {
        let controller = makeAXEventTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing missing-window fallback fixture")
            return
        }

        controller.hasStartedServices = true

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 976),
            pid: getpid(),
            windowId: 976,
            to: workspaceId
        )
        let pendingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 977),
            pid: getpid(),
            windowId: 977,
            to: workspaceId
        )

        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            pendingToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.focusBridge.applyOrchestrationState(
            nextManagedRequestId: 2,
            activeManagedRequest: ManagedFocusRequest(
                requestId: 1,
                token: pendingToken,
                workspaceId: workspaceId
            )
        )
        controller.focusBridge.setFocusedTarget(
            controller.keyboardFocusTarget(
                for: oldToken,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
            )
        )
        controller.axEventHandler.focusedWindowRefProvider = { _ in nil }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.focusBridge.focusedTarget == nil)
    }

    @Test @MainActor func externalFocusedWindowChangeWithObservedUnmanagedWindowCancelsPendingRequestAndFallsBackToNonManaged() {
        let controller = makeAXEventTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing unmanaged-window fallback fixture")
            return
        }

        controller.hasStartedServices = true

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 978),
            pid: getpid(),
            windowId: 978,
            to: workspaceId
        )
        let pendingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 979),
            pid: getpid(),
            windowId: 979,
            to: workspaceId
        )
        let observedToken = WindowToken(pid: getpid(), windowId: 980)

        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            pendingToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.focusBridge.applyOrchestrationState(
            nextManagedRequestId: 2,
            activeManagedRequest: ManagedFocusRequest(
                requestId: 1,
                token: pendingToken,
                workspaceId: workspaceId
            )
        )
        controller.focusBridge.setFocusedTarget(
            controller.keyboardFocusTarget(
                for: oldToken,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
            )
        )
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: observedToken.windowId)
        }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.focusBridge.focusedTarget?.token == observedToken)
        #expect(controller.focusBridge.focusedTarget?.isManaged == false)
    }

    @Test @MainActor func activationRetryExhaustionClearsPendingFocusAndRestoresConfirmedBorder() async throws {
        let controller = makeAXEventTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for activation retry exhaustion test")
            return
        }

        controller.hasStartedServices = true
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.updateNiriConfig(
            maxVisibleColumns: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 901),
            pid: getpid(),
            windowId: 901,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let firstPendingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 902),
            pid: getpid(),
            windowId: 902,
            to: workspaceId
        )
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
        }

        let firstPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(firstPlans)
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.pendingFocusedToken == firstPendingToken &&
                lastAppliedBorderWindowId(on: controller) == oldToken.windowId
        }

        for _ in 0 ... 5 {
            controller.axEventHandler.handleAppActivation(
                pid: getpid(),
                source: .workspaceDidActivateApplication
            )
        }

        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)
    }

    @Test @MainActor func secondSamePIDFocusRequestGetsFreshRetryBudgetAfterFirstExhausts() async throws {
        let controller = makeAXEventTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for same-PID retry budget test")
            return
        }

        controller.hasStartedServices = true
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.updateNiriConfig(
            maxVisibleColumns: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 911),
            pid: getpid(),
            windowId: 911,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: monitor.id
        )

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId)
        }

        let firstPendingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 912),
            pid: getpid(),
            windowId: 912,
            to: workspaceId
        )
        let firstPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(firstPlans)
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.pendingFocusedToken == firstPendingToken
        }

        for _ in 0 ... 5 {
            controller.axEventHandler.handleAppActivation(
                pid: getpid(),
                source: .workspaceDidActivateApplication
            )
        }

        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)

        controller.axEventHandler.resetDebugStateForTests()

        let secondPendingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 913),
            pid: getpid(),
            windowId: 913,
            to: workspaceId
        )
        let secondPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(secondPlans)
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.pendingFocusedToken == secondPendingToken
        }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .workspaceDidActivateApplication
        )

        #expect(controller.workspaceManager.pendingFocusedToken == secondPendingToken)

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: secondPendingToken.windowId)
        }
        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        #expect(controller.workspaceManager.focusedToken == secondPendingToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == secondPendingToken.windowId)
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

        let externalToken = WindowToken(pid: getpid() + 100, windowId: 1802)
        let externalRequest = ManagedFocusRequest(
            requestId: 41,
            token: externalToken,
            workspaceId: workspaceId
        )
        controller.focusBridge.applyOrchestrationState(
            nextManagedRequestId: 42,
            activeManagedRequest: externalRequest
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            externalToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.handleAppActivation(pid: getpid())

        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
        #expect(controller.focusBridge.activeManagedRequest == externalRequest)
        #expect(controller.workspaceManager.pendingFocusedToken == externalToken)
    }

    @Test @MainActor func ownedUtilityWindowCreateIsSkipped() async {
        let controller = makeAXEventTestController()
        let registry = OwnedWindowRegistry.shared
        let ownedWindow = makeAXEventOwnedWindow()
        var subscriptions: [[UInt32]] = []

        registry.resetForTests()
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
        }

        let ownedWindowId = UInt32(ownedWindow.windowNumber)
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: Bundle.main.bundleIdentifier ?? "com.example.omniwm")
        }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.layoutRefreshController.resetDebugState()

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: ownedWindowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: Int(ownedWindowId)) == nil)
        #expect(subscriptions.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
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

    @Test @MainActor func missingFocusedWindowFallbackPreservesNativeFullscreenLifecycleContext() {
        let controller = makeAXEventTestController()
        controller.hasStartedServices = true
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8031),
            pid: getpid(),
            windowId: 8031,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        controller.axEventHandler.focusedWindowRefProvider = { _ in nil }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .workspaceDidActivateApplication
        )

        guard let record = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing native fullscreen record after fallback")
            return
        }
        if case .suspended = record.transition {} else {
            Issue.record("Expected native fullscreen record to remain suspended")
        }
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive)
        #expect(controller.workspaceManager.hasNativeFullscreenLifecycleContext)
        #expect(controller.workspaceManager.focusedToken == nil)
    }

    @Test @MainActor func nativeFullscreenEnterDestroySurvivesFollowupBeforeDelayedSameTokenActivation() async {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        controller.hasStartedServices = true
        controller.axManager.currentWindowsAsyncOverride = { [] }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8041),
            pid: getpid(),
            windowId: 8041,
            to: workspaceId
        )
        guard let originalEntry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry before native fullscreen enter destroy")
            return
        }
        controller.recordManagedRestoreGeometry(
            for: token,
            frame: CGRect(x: 80, y: 120, width: 680, height: 520)
        )

        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        controller.axEventHandler.handleRemoved(token: token)
        controller.axEventHandler.flushPendingNativeFullscreenFollowupsForTests()
        await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()

        guard let unavailableRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing temporarily unavailable native fullscreen record")
            return
        }
        if case .enterRequested = unavailableRecord.transition {} else {
            Issue.record("Expected delayed enter record to remain enterRequested before activation")
        }
        #expect(unavailableRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.entry(for: token)?.handle === originalEntry.handle)

        guard let delayedEntry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing delayed entry for same-token fullscreen activation")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: delayedEntry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        guard let suspendedRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing suspended native fullscreen record after delayed activation")
            return
        }
        if case .suspended = suspendedRecord.transition {} else {
            Issue.record("Expected delayed enter record to become suspended after activation")
        }
        #expect(suspendedRecord.availability == .present)
        #expect(controller.workspaceManager.entry(for: token)?.handle === originalEntry.handle)
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
        #expect(controller.workspaceManager.isAppFullscreenActive)
    }

    @Test @MainActor func nativeFullscreenExitDestroySurvivesFollowupBeforeDelayedSameTokenRestoreActivation() async {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        controller.hasStartedServices = true
        controller.axManager.currentWindowsAsyncOverride = { [] }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8042),
            pid: getpid(),
            windowId: 8042,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        guard let originalEntry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry before native fullscreen exit destroy")
            return
        }

        let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: CGRect(x: 40, y: 50, width: 400, height: 300),
            topologyProfile: controller.workspaceManager.topologyProfile
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(
            token,
            in: workspaceId,
            restoreSnapshot: restoreSnapshot
        )
        _ = controller.workspaceManager.markNativeFullscreenSuspended(
            token,
            restoreSnapshot: restoreSnapshot
        )
        _ = controller.workspaceManager.requestNativeFullscreenExit(token, initiatedByCommand: true)
        controller.axEventHandler.handleRemoved(token: token)
        controller.axEventHandler.flushPendingNativeFullscreenFollowupsForTests()
        await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()

        guard let unavailableRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing temporarily unavailable exit record")
            return
        }
        if case .exitRequested = unavailableRecord.transition {} else {
            Issue.record("Expected delayed exit record to remain exitRequested before activation")
        }
        #expect(unavailableRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.entry(for: token)?.handle === originalEntry.handle)

        guard let delayedEntry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing delayed entry for same-token fullscreen restore")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: delayedEntry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        guard let restoringRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing restoring record before delayed restore relayout commit")
            return
        }
        if case .restoring = restoringRecord.transition {} else {
            Issue.record("Expected delayed restore activation to keep record in restoring until layout commit")
        }
        #expect(controller.workspaceManager.entry(for: token)?.handle === originalEntry.handle)
        #expect(controller.workspaceManager.layoutReason(for: token) == .standard)
        #expect(
            controller.workspaceManager.pendingFocusedToken == token
                || controller.workspaceManager.focusedToken == token
        )
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
    }

    @Test @MainActor func nativeFullscreenUnavailableReplacementRekeysManagedHandleWithoutReplacingIt() async {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8043),
            pid: getpid(),
            windowId: 8043,
            to: workspaceId
        )
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing original native fullscreen replacement entry")
            return
        }

        let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: CGRect(x: 60, y: 70, width: 420, height: 320),
            topologyProfile: controller.workspaceManager.topologyProfile
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(
            originalToken,
            in: workspaceId,
            restoreSnapshot: restoreSnapshot
        )
        _ = controller.workspaceManager.markNativeFullscreenSuspended(
            originalToken,
            restoreSnapshot: restoreSnapshot
        )
        controller.axEventHandler.handleRemoved(token: originalToken)

        let replacementToken = WindowToken(pid: getpid(), windowId: 8044)
        let replacementWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8044)
        let restored = controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
            token: replacementToken,
            windowId: 8044,
            axRef: replacementWindow,
            workspaceId: workspaceId,
            appFullscreen: false
        )

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing rekeyed replacement entry")
            return
        }

        #expect(restored)
        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        guard let restoringRecord = controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) else {
            Issue.record("Missing restoring replacement record before relayout commit")
            return
        }
        if case .restoring = restoringRecord.transition {} else {
            Issue.record("Expected replacement restore to remain restoring until relayout commit")
        }
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
    }

    @Test @MainActor func workspaceDidActivateApplicationRevealsRestoredManagedWindowOnInactiveWorkspace() async {
        let controller = makeAXEventTestController()
        controller.hasStartedServices = true
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Missing restored inactive-workspace activation fixture")
            return
        }

        let sourceToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 983),
            pid: 9_803,
            windowId: 983,
            to: workspaceOne
        )
        _ = controller.workspaceManager.setManagedFocus(
            sourceToken,
            in: workspaceOne,
            onMonitor: monitor.id
        )

        let targetPid: pid_t = 9_804
        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 984),
            pid: targetPid,
            windowId: 984,
            to: workspaceTwo
        )
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing original restored-entry fixture")
            return
        }

        let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: CGRect(x: 80, y: 90, width: 440, height: 340),
            topologyProfile: controller.workspaceManager.topologyProfile
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(
            originalToken,
            in: workspaceTwo,
            restoreSnapshot: restoreSnapshot
        )
        _ = controller.workspaceManager.markNativeFullscreenSuspended(
            originalToken,
            restoreSnapshot: restoreSnapshot
        )
        controller.axEventHandler.handleRemoved(token: originalToken)

        let replacementToken = WindowToken(pid: targetPid, windowId: 985)
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == targetPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: replacementToken.windowId)
        }

        #expect(controller.activeWorkspace()?.id == workspaceOne)
        #expect(controller.workspaceManager.focusedToken == nil)

        controller.axEventHandler.handleAppActivation(
            pid: targetPid,
            source: .workspaceDidActivateApplication
        )

        guard let restoringRecord = controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) else {
            Issue.record("Missing restoring inactive-workspace record before relayout commit")
            return
        }
        if case .restoring = restoringRecord.transition {} else {
            Issue.record("Expected inactive-workspace native fullscreen restore to stay restoring until commit")
        }

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement entry after restored activation")
            return
        }

        #expect(controller.activeWorkspace()?.id == workspaceTwo)
        #expect(
            controller.workspaceManager.pendingFocusedToken == replacementToken
                || controller.workspaceManager.focusedToken == replacementToken
        )
        #expect(controller.workspaceManager.lastFocusedToken(in: workspaceTwo) == replacementToken)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        guard let postActivationRecord = controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) else {
            Issue.record("Missing post-activation restoring record")
            return
        }
        if case .restoring = postActivationRecord.transition {} else {
            Issue.record("Expected inactive-workspace native fullscreen restore to remain restoring before commit")
        }
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
    }

    @Test @MainActor func nativeFullscreenCommandRoundTripsThroughObservedStateTransitions() async {
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
        let managedFrame = CGRect(x: 120, y: 160, width: 720, height: 540)
        controller.recordManagedRestoreGeometry(for: token, frame: managedFrame)

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
        #expect(enterRecord.restoreSnapshot?.frame == managedFrame)
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

        guard let restoringRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing restoring command round-trip record before relayout commit")
            return
        }
        if case .restoring = restoringRecord.transition {} else {
            Issue.record("Expected command round-trip restore to stay restoring until layout commit")
        }
        #expect(controller.workspaceManager.layoutReason(for: token) == .standard)
        #expect(
            controller.workspaceManager.pendingFocusedToken == token
                || controller.workspaceManager.focusedToken == token
        )
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive)
    }

    @Test @MainActor func managedRestoreGeometryBackfillsSnapshotMetadataBeforeFetchingFacts() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 805),
            pid: getpid(),
            windowId: 805,
            to: workspaceId
        )
        let cachedFrame = CGRect(x: 110, y: 150, width: 700, height: 520)
        let refreshedFrame = CGRect(x: 130, y: 170, width: 720, height: 540)
        let cachedMetadata = ManagedReplacementMetadata(
            bundleId: "com.example.app",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Cached Title",
            windowLevel: 19,
            parentWindowId: 42,
            frame: cachedFrame
        )
        let partialLiveMetadata = ManagedReplacementMetadata(
            bundleId: "com.example.app",
            workspaceId: workspaceId,
            mode: .tiling,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: refreshedFrame
        )
        _ = controller.workspaceManager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: token,
                workspaceId: workspaceId,
                frame: cachedFrame,
                topologyProfile: controller.workspaceManager.topologyProfile,
                niriState: nil,
                replacementMetadata: cachedMetadata
            ),
            for: token
        )
        _ = controller.workspaceManager.setManagedReplacementMetadata(partialLiveMetadata, for: token)

        var factFetchCount = 0
        controller.axEventHandler.windowFactsProvider = { _, _ in
            factFetchCount += 1
            return makeAXEventWindowRuleFacts(
                bundleId: "com.example.app",
                title: "Fetched Title",
                windowServer: WindowServerInfo(id: 805, pid: getpid(), level: 23, frame: refreshedFrame)
            )
        }
        defer { controller.axEventHandler.windowFactsProvider = nil }

        controller.recordManagedRestoreGeometry(for: token, frame: refreshedFrame)

        let replacementMetadata = controller.workspaceManager.managedRestoreSnapshot(for: token)?.replacementMetadata
        #expect(factFetchCount == 0)
        #expect(replacementMetadata?.title == "Cached Title")
        #expect(replacementMetadata?.windowLevel == 19)
        #expect(replacementMetadata?.parentWindowId == 42)
        #expect(replacementMetadata?.frame == refreshedFrame)
    }

    @Test @MainActor func managedRestoreGeometrySkipsMetadataRefreshWhenSnapshotSemanticsAreUnchangedWithinTolerance() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 806),
            pid: getpid(),
            windowId: 806,
            to: workspaceId
        )
        let cachedFrame = CGRect(x: 180, y: 160, width: 760, height: 540)
        let jitteredFrame = cachedFrame.offsetBy(dx: 0.2, dy: -0.2)
        let cachedMetadata = ManagedReplacementMetadata(
            bundleId: "com.example.app",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Stable Title",
            windowLevel: 8,
            parentWindowId: nil,
            frame: cachedFrame
        )
        _ = controller.workspaceManager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: token,
                workspaceId: workspaceId,
                frame: cachedFrame,
                topologyProfile: controller.workspaceManager.topologyProfile,
                niriState: nil,
                replacementMetadata: cachedMetadata
            ),
            for: token
        )


        var factFetchCount = 0
        controller.axEventHandler.windowFactsProvider = { _, _ in
            factFetchCount += 1
            return makeAXEventWindowRuleFacts(
                bundleId: "com.example.app",
                title: "Fetched Title",
                windowServer: WindowServerInfo(id: 806, pid: getpid(), level: 11, frame: jitteredFrame)
            )
        }
        defer { controller.axEventHandler.windowFactsProvider = nil }

        controller.recordManagedRestoreGeometry(for: token, frame: jitteredFrame)

        #expect(factFetchCount == 0)
        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == cachedFrame)
    }

    @Test @MainActor func workspaceMovePersistsManagedRestoreSnapshotWithoutWaitingForFrameConfirmation() {
        let controller = makeAXEventTestController()
        guard let sourceWorkspaceId = controller.activeWorkspace()?.id,
              let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace fixture")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 807),
            pid: getpid(),
            windowId: 807,
            to: sourceWorkspaceId
        )
        let frame = CGRect(x: 190, y: 170, width: 760, height: 540)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.example.workspace-move",
                workspaceId: sourceWorkspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Workspace Move Window",
                windowLevel: 11,
                parentWindowId: nil,
                frame: frame
            ),
            for: token
        )
        controller.recordManagedRestoreGeometry(for: token, frame: frame)


        controller.reassignManagedWindow(token, to: targetWorkspaceId)

        let snapshot = controller.workspaceManager.managedRestoreSnapshot(for: token)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(snapshot?.workspaceId == targetWorkspaceId)
        #expect(snapshot?.replacementMetadata?.workspaceId == targetWorkspaceId)
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
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 811, 812:
                WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
            default:
                nil
            }
        }

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

    @Test @MainActor func floatingFrameChangedRetriesWorkspaceHideAfterFreshFrameWakeup() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeAXEventTestController()
        AXWindowService.fastFrameProviderForTests = { _ in nil }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            controller.axEventHandler.frameProvider = nil
        }
        guard let monitor = controller.workspaceManager.monitors.first,
              let inactiveWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing monitor or inactive workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8142),
            pid: getpid(),
            windowId: 8142,
            to: inactiveWorkspaceId,
            mode: .floating
        )
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for fresh-frame wakeup test")
            return
        }

        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )
        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )

        #expect(controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        controller.axEventHandler.frameProvider = { _ in
            CGRect(x: 120, y: 140, width: 360, height: 240)
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 8142)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons == [.axWindowChanged])
        #expect(!controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))
        #expect(
            controller.workspaceManager.floatingState(for: token)?.lastFrame
                == CGRect(x: 120, y: 140, width: 360, height: 240)
        )
    }

    @Test @MainActor func pendingManagedFrameWriteSuppressesRelayoutAndCachesObservedFrame() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8144),
            pid: getpid(),
            windowId: 8144,
            to: workspaceId
        )
        let observedFrame = CGRect(x: 220, y: 160, width: 720, height: 480)
        let cachedMetadataFrame = CGRect(x: 80, y: 60, width: 600, height: 420)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.example.app",
                workspaceId: workspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Pinned Metadata",
                windowLevel: 5,
                parentWindowId: nil,
                frame: cachedMetadataFrame
            ),
            for: token
        )

        controller.axManager.setPendingFrameWriteForTests(windowId: token.windowId, frame: observedFrame)
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        defer {
            controller.axManager.setPendingFrameWriteForTests(windowId: token.windowId, frame: nil)
            controller.axEventHandler.frameProvider = nil
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 8144)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == observedFrame)
        #expect(controller.workspaceManager.managedReplacementMetadata(for: token)?.frame == cachedMetadataFrame)
    }

    @Test @MainActor func interactiveGestureDoesNotConsumeWorkspaceHideFreshFrameWakeup() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeAXEventTestController()
        AXWindowService.fastFrameProviderForTests = { _ in nil }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            controller.axEventHandler.frameProvider = nil
            controller.mouseEventHandler.state.isResizing = false
        }
        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing active workspace or monitor")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8143),
            pid: getpid(),
            windowId: 8143,
            to: workspaceId
        )
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for gesture wakeup test")
            return
        }

        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )
        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )

        #expect(controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        controller.axEventHandler.frameProvider = { _ in
            CGRect(x: 200, y: 160, width: 480, height: 320)
        }
        controller.mouseEventHandler.state.isResizing = true

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 8143)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))
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

        controller.axEventHandler.drainDeferredCreatedWindows()
        controller.axEventHandler.drainDeferredCreatedWindows()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 821)?.workspaceId == workspaceId)
        #expect(controller.workspaceManager.allEntries().filter { $0.windowId == 821 }.count == 1)
        #expect(subscriptions == [[821]])
    }

    @Test @MainActor func ghosttyReplacementRekeysManagedWindowWhenTabTitleChanges() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
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
        let replacementFrame = CGRect(x: 80, y: 80, width: 900, height: 640)
        let oldInfo = makeAXEventWindowInfo(
            id: 841,
            title: "repo - shell",
            frame: replacementFrame,
            parentId: 41
        )
        let newInfo = makeAXEventWindowInfo(
            id: 842,
            title: "repo - shell (2)",
            frame: replacementFrame,
            parentId: 41
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 841:
                oldInfo
            case 842:
                newInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo = switch axRef.windowId {
            case 841:
                oldInfo
            case 842:
                newInfo
            default:
                makeAXEventWindowInfo(id: UInt32(axRef.windowId))
            }
            return makeAXEventWindowRuleFacts(
                bundleId: currentTestBundleId(),
                title: info.title,
                windowServer: info
            )
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
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
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

    @Test @MainActor func ghosttyReplacementRekeysManagedWindowWhenReplacementWouldBeTrackedFloating() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
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
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 853),
            pid: getpid(),
            windowId: 853,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original Ghostty entry")
            return
        }

        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = oldNode.id
            state.activeColumnIndex = 0
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

        var relayoutReasons: [RefreshReason] = []
        let ghosttyFrame = CGRect(x: 96, y: 88, width: 920, height: 660)
        let oldInfo = makeAXEventWindowInfo(
            id: 853,
            title: "repo - shell",
            frame: ghosttyFrame,
            parentId: 51
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 854,
            title: "repo - shell (new tab)",
            frame: ghosttyFrame,
            parentId: 51
        )
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 853:
                oldInfo
            case 854:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            switch axRef.windowId {
            case 853:
                makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: oldInfo.title,
                    windowServer: oldInfo
                )
            case 854:
                makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: replacementInfo.title,
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    windowServer: replacementInfo
                )
            default:
                makeAXEventWindowRuleFacts(bundleId: currentTestBundleId())
            }
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 853, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 854, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 854)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement Ghostty entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(replacementEntry.mode == .tiling)
        #expect(controller.workspaceManager.floatingState(for: replacementToken) == nil)
        #expect(engine.findNode(for: oldToken) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == oldNode.id)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func ghosttyReplacementUsesCachedDestroyMetadataWhenClosingFactsDegrade() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
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

        let oldInfo = makeAXEventWindowInfo(
            id: 855,
            title: "repo - shell",
            frame: CGRect(x: 96, y: 88, width: 920, height: 660),
            parentId: 55
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 856,
            title: "repo - shell (closed tab)",
            frame: oldInfo.frame,
            parentId: 55
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 855),
            pid: getpid(),
            windowId: 855,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: currentTestBundleId(),
                workspaceId: workspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original Ghostty entry")
            return
        }
        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)

        var relayoutReasons: [RefreshReason] = []
        var factLookupWindowIds: [Int] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 855:
                oldInfo
            case 856:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            factLookupWindowIds.append(axRef.windowId)
            switch axRef.windowId {
            case 855:
                return makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: nil,
                    role: nil,
                    subrole: nil,
                    attributeFetchSucceeded: false,
                    windowServer: oldInfo
                )
            case 856:
                return makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: replacementInfo.title,
                    windowServer: replacementInfo
                )
            default:
                return makeAXEventWindowRuleFacts(bundleId: currentTestBundleId())
            }
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 855, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 856, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 856)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement Ghostty entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(engine.findNode(for: replacementToken)?.id == oldNode.id)
        #expect(relayoutReasons.isEmpty)
        #expect(factLookupWindowIds.contains(856))
        #expect(!factLookupWindowIds.contains(855))
    }

    @Test @MainActor func structuralReplacementDestroyThenCreateFlushesWithinSingleGraceWindow() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 878,
            title: "repo - shell",
            frame: CGRect(x: 96, y: 88, width: 920, height: 660),
            parentId: 101
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 879,
            title: "repo - shell (retabbed)",
            frame: oldInfo.frame,
            parentId: 101
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 878),
            pid: getpid(),
            windowId: 878,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: currentTestBundleId(),
                workspaceId: workspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original Ghostty entry")
            return
        }

        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 878:
                oldInfo
            case 879:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo = switch axRef.windowId {
            case 878:
                oldInfo
            case 879:
                replacementInfo
            default:
                makeAXEventWindowInfo(id: UInt32(axRef.windowId))
            }
            return makeAXEventWindowRuleFacts(
                bundleId: currentTestBundleId(),
                title: info.title,
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 878, spaceId: 0)
        )
        try? await Task.sleep(for: .milliseconds(60))
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 879, spaceId: 0)
        )

        let replacementToken = WindowToken(pid: getpid(), windowId: 879)
        await waitUntilAXEventTest(iterations: 120) {
            controller.workspaceManager.entry(for: replacementToken) != nil
        }

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement Ghostty entry after timed flush")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
    }

    @Test @MainActor func structuralReplacementCreateBeforeDestroyStillRekeysWithinSingleGraceWindow() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 880,
            title: "repo - shell",
            frame: CGRect(x: 96, y: 88, width: 920, height: 660),
            parentId: 103
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 881,
            title: "repo - shell (new tab)",
            frame: oldInfo.frame,
            parentId: 103
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 880),
            pid: getpid(),
            windowId: 880,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: currentTestBundleId(),
                workspaceId: workspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original Ghostty entry")
            return
        }

        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 880:
                oldInfo
            case 881:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo = switch axRef.windowId {
            case 880:
                oldInfo
            case 881:
                replacementInfo
            default:
                makeAXEventWindowInfo(id: UInt32(axRef.windowId))
            }
            return makeAXEventWindowRuleFacts(
                bundleId: currentTestBundleId(),
                title: info.title,
                windowServer: info
            )
        }

        let replacementToken = WindowToken(pid: getpid(), windowId: 881)
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 881, spaceId: 0)
        )

        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.workspaceManager.entry(for: replacementToken) == nil)

        try? await Task.sleep(for: .milliseconds(40))
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 880, spaceId: 0)
        )

        await waitUntilAXEventTest(iterations: 120) {
            controller.workspaceManager.entry(for: replacementToken) != nil
        }

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement Ghostty entry after create-before-destroy burst")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
    }

    @Test @MainActor func structuralReplacementUnmatchedDestroyUsesSingleGraceWindowBeforeRemoval() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 882,
            title: "repo - shell",
            frame: CGRect(x: 96, y: 88, width: 920, height: 660),
            parentId: 105
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 882),
            pid: getpid(),
            windowId: 882,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: currentTestBundleId(),
                workspaceId: workspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )

        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 882 else { return nil }
            return oldInfo
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 882, spaceId: 0)
        )

        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.workspaceManager.entry(for: token) != nil)

        await waitUntilAXEventTest(iterations: 120) {
            controller.workspaceManager.entry(for: token) == nil
        }

        #expect(controller.workspaceManager.entry(for: token) == nil)
    }

    @Test @MainActor func structuralReplacementAmbiguousMultiCreateBurstFlushesWithoutRekeying() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 883,
            title: "repo - shell",
            frame: CGRect(x: 80, y: 80, width: 900, height: 640),
            parentId: 107
        )
        let siblingInfo = makeAXEventWindowInfo(
            id: 884,
            title: "repo - shell sibling",
            frame: CGRect(x: 220, y: 120, width: 900, height: 640),
            parentId: 108
        )
        let firstReplacementInfo = makeAXEventWindowInfo(
            id: 885,
            title: "repo - shell (candidate 1)",
            frame: oldInfo.frame,
            parentId: 107
        )
        let secondReplacementInfo = makeAXEventWindowInfo(
            id: 886,
            title: "repo - shell (candidate 2)",
            frame: oldInfo.frame,
            parentId: 107
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 883),
            pid: getpid(),
            windowId: 883,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: currentTestBundleId(),
                workspaceId: workspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 884),
            pid: getpid(),
            windowId: 884,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: currentTestBundleId(),
                workspaceId: workspaceId,
                title: siblingInfo.title,
                windowServer: siblingInfo
            )
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken),
              let siblingEntry = controller.workspaceManager.entry(for: siblingToken) else {
            Issue.record("Missing original Ghostty entries")
            return
        }

        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 883:
                oldInfo
            case 884:
                siblingInfo
            case 885:
                firstReplacementInfo
            case 886:
                secondReplacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo = switch axRef.windowId {
            case 883:
                oldInfo
            case 884:
                siblingInfo
            case 885:
                firstReplacementInfo
            case 886:
                secondReplacementInfo
            default:
                makeAXEventWindowInfo(id: UInt32(axRef.windowId))
            }
            return makeAXEventWindowRuleFacts(
                bundleId: currentTestBundleId(),
                title: info.title,
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 883, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 885, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 886, spaceId: 0)
        )

        await waitUntilAXEventTest(iterations: 120) {
            controller.workspaceManager.entry(for: oldToken) == nil
                && controller.workspaceManager.entry(forPid: getpid(), windowId: 885) != nil
                && controller.workspaceManager.entry(forPid: getpid(), windowId: 886) != nil
        }

        guard let firstNewEntry = controller.workspaceManager.entry(forPid: getpid(), windowId: 885),
              let secondNewEntry = controller.workspaceManager.entry(forPid: getpid(), windowId: 886),
              let siblingCurrentEntry = controller.workspaceManager.entry(for: siblingToken)
        else {
            Issue.record("Missing replayed Ghostty entries for timed ambiguous burst")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(siblingCurrentEntry.handle === siblingEntry.handle)
        #expect(firstNewEntry.handle !== oldEntry.handle)
        #expect(firstNewEntry.handle !== siblingEntry.handle)
        #expect(secondNewEntry.handle !== oldEntry.handle)
        #expect(secondNewEntry.handle !== siblingEntry.handle)
    }

    @Test @MainActor func ghosttyReplacementKeepsDwindleLeafAndRightNeighborStable() async {
        let controller = makeAXEventTestController(
            trackedBundleId: currentTestBundleId(),
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitors.first else {
            Issue.record("Missing Dwindle workspace setup")
            return
        }

        controller.enableDwindleLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.dwindleEngine else {
            Issue.record("Missing Dwindle engine")
            return
        }

        let leftToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 861),
            pid: 9_101,
            windowId: 861,
            to: workspaceId
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 862),
            pid: getpid(),
            windowId: 862,
            to: workspaceId
        )
        let rightToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 863),
            pid: 9_102,
            windowId: 863,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original Dwindle Ghostty entry")
            return
        }

        let leftNode = engine.addWindow(token: leftToken, to: workspaceId, activeWindowFrame: nil)
        engine.setSelectedNode(leftNode, in: workspaceId)
        engine.setPreselection(.right, in: workspaceId)
        _ = engine.addWindow(token: oldToken, to: workspaceId, activeWindowFrame: nil)
        guard let oldLeaf = engine.findNode(for: oldToken) else {
            Issue.record("Missing original Dwindle Ghostty leaf")
            return
        }
        engine.setSelectedNode(oldLeaf, in: workspaceId)
        engine.setPreselection(.right, in: workspaceId)
        _ = engine.addWindow(token: rightToken, to: workspaceId, activeWindowFrame: nil)

        let initialFrames = engine.calculateLayout(for: workspaceId, screen: monitor.frame)
        guard let originalGhosttyFrame = initialFrames[oldToken],
              let originalRightFrame = initialFrames[rightToken],
              let originalGhosttyLeaf = engine.findNode(for: oldToken)
        else {
            Issue.record("Missing initial Dwindle layout frames")
            return
        }

        engine.setSelectedNode(originalGhosttyLeaf, in: workspaceId)
        #expect(engine.moveFocus(direction: .right, in: workspaceId) == rightToken)
        engine.setSelectedNode(originalGhosttyLeaf, in: workspaceId)

        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        var relayoutReasons: [RefreshReason] = []
        let oldInfo = makeAXEventWindowInfo(
            id: 862,
            title: "repo - shell",
            frame: originalGhosttyFrame,
            parentId: 61
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 864,
            title: "repo - shell (2)",
            frame: originalGhosttyFrame,
            parentId: 61
        )
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 862:
                oldInfo
            case 864:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo = switch axRef.windowId {
            case 862:
                oldInfo
            case 864:
                replacementInfo
            default:
                makeAXEventWindowInfo(id: UInt32(axRef.windowId))
            }
            return makeAXEventWindowRuleFacts(
                bundleId: currentTestBundleId(),
                title: info.title,
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 862, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 864, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 864)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let replacementLeaf = engine.findNode(for: replacementToken) else {
            Issue.record("Missing replacement Dwindle Ghostty state")
            return
        }

        let updatedFrames = engine.calculateLayout(for: workspaceId, screen: monitor.frame)
        guard let updatedGhosttyFrame = updatedFrames[replacementToken],
              let updatedRightFrame = updatedFrames[rightToken] else {
            Issue.record("Missing updated Dwindle layout frames")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(replacementLeaf.id == originalGhosttyLeaf.id)
        #expect(updatedGhosttyFrame.approximatelyEqual(to: originalGhosttyFrame, tolerance: 0.5))
        #expect(updatedRightFrame.approximatelyEqual(to: originalRightFrame, tolerance: 0.5))
        engine.setSelectedNode(replacementLeaf, in: workspaceId)
        #expect(engine.moveFocus(direction: .right, in: workspaceId) == rightToken)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func structuralReplacementLateCreateWithinGraceKeepsNiriNodeAndRightColumnStable() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitors.first else {
            Issue.record("Missing Niri workspace setup")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 865),
            pid: getpid(),
            windowId: 865,
            to: workspaceId
        )
        let rightToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 866),
            pid: getpid(),
            windowId: 866,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original Niri Ghostty entry")
            return
        }

        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)
        _ = engine.addWindow(token: rightToken, to: workspaceId, afterSelection: oldNode.id, focusedToken: oldToken)
        guard let originalRightNode = engine.findNode(for: rightToken) else {
            Issue.record("Missing original Niri right neighbor")
            return
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = oldNode.id
            state.activeColumnIndex = 0
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

        let gap = CGFloat(controller.workspaceManager.gaps)
        let initialFrames = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: monitor.frame,
            gaps: (horizontal: gap, vertical: gap)
        )
        guard let originalGhosttyFrame = initialFrames[oldToken],
              let originalRightFrame = initialFrames[rightToken]
        else {
            Issue.record("Missing initial Niri layout frames")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 865,
            title: "repo - shell",
            frame: originalGhosttyFrame,
            parentId: 71
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 867,
            title: "repo - shell (tab closed)",
            frame: originalGhosttyFrame,
            parentId: 71
        )
        oldEntry.managedReplacementMetadata = makeManagedReplacementMetadata(
            bundleId: currentTestBundleId(),
            workspaceId: workspaceId,
            title: oldInfo.title,
            windowServer: oldInfo
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 865:
                oldInfo
            case 867:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            switch axRef.windowId {
            case 865:
                makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: nil,
                    role: nil,
                    subrole: nil,
                    attributeFetchSucceeded: false,
                    windowServer: oldInfo
                )
            case 867:
                makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: replacementInfo.title,
                    windowServer: replacementInfo
                )
            default:
                makeAXEventWindowRuleFacts(bundleId: currentTestBundleId())
            }
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 865, spaceId: 0)
        )
        try? await Task.sleep(for: .milliseconds(60))

        #expect(controller.workspaceManager.entry(for: oldToken) != nil)
        #expect(engine.findNode(for: oldToken)?.id == oldNode.id)

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 867, spaceId: 0)
        )
        let replacementToken = WindowToken(pid: getpid(), windowId: 867)
        await waitUntilAXEventTest(iterations: 240) {
            controller.workspaceManager.entry(for: replacementToken) != nil
        }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let replacementNode = engine.findNode(for: replacementToken),
              let rightNode = engine.findNode(for: rightToken)
        else {
            Issue.record("Missing replacement Niri Ghostty state")
            return
        }

        let updatedFrames = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: monitor.frame,
            gaps: (horizontal: gap, vertical: gap)
        )
        guard let updatedGhosttyFrame = updatedFrames[replacementToken],
              let updatedRightFrame = updatedFrames[rightToken] else {
            Issue.record("Missing updated Niri layout frames")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(replacementNode.id == oldNode.id)
        #expect(rightNode.id == originalRightNode.id)
        #expect(engine.columns(in: workspaceId).count == 2)
        #expect(updatedGhosttyFrame.approximatelyEqual(to: originalGhosttyFrame, tolerance: 0.5))
        #expect(updatedRightFrame.approximatelyEqual(to: originalRightFrame, tolerance: 0.5))
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == oldNode.id)
    }

    @Test @MainActor func structuralReplacementLateCreateWithinGraceKeepsDwindleLeafAndRightNeighborStable() async {
        let controller = makeAXEventTestController(
            trackedBundleId: currentTestBundleId(),
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitors.first else {
            Issue.record("Missing Dwindle workspace setup")
            return
        }

        controller.enableDwindleLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.dwindleEngine else {
            Issue.record("Missing Dwindle engine")
            return
        }

        let leftToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 869),
            pid: 9_201,
            windowId: 869,
            to: workspaceId
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 870),
            pid: getpid(),
            windowId: 870,
            to: workspaceId
        )
        let rightToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 871),
            pid: getpid(),
            windowId: 871,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original Dwindle Ghostty entry")
            return
        }

        let leftNode = engine.addWindow(token: leftToken, to: workspaceId, activeWindowFrame: nil)
        engine.setSelectedNode(leftNode, in: workspaceId)
        engine.setPreselection(.right, in: workspaceId)
        _ = engine.addWindow(token: oldToken, to: workspaceId, activeWindowFrame: nil)
        guard let oldLeaf = engine.findNode(for: oldToken) else {
            Issue.record("Missing original Dwindle Ghostty leaf")
            return
        }
        engine.setSelectedNode(oldLeaf, in: workspaceId)
        engine.setPreselection(.right, in: workspaceId)
        _ = engine.addWindow(token: rightToken, to: workspaceId, activeWindowFrame: nil)

        let initialFrames = engine.calculateLayout(for: workspaceId, screen: monitor.frame)
        guard let originalGhosttyFrame = initialFrames[oldToken],
              let originalRightFrame = initialFrames[rightToken],
              let originalGhosttyLeaf = engine.findNode(for: oldToken),
              let originalRightLeaf = engine.findNode(for: rightToken)
        else {
            Issue.record("Missing initial Dwindle layout frames")
            return
        }

        engine.setSelectedNode(originalGhosttyLeaf, in: workspaceId)
        #expect(engine.moveFocus(direction: .right, in: workspaceId) == rightToken)
        engine.setSelectedNode(originalGhosttyLeaf, in: workspaceId)

        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let oldInfo = makeAXEventWindowInfo(
            id: 870,
            title: "repo - shell",
            frame: originalGhosttyFrame,
            parentId: 81
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 872,
            title: "repo - shell (tab closed)",
            frame: originalGhosttyFrame,
            parentId: 81
        )
        oldEntry.managedReplacementMetadata = makeManagedReplacementMetadata(
            bundleId: currentTestBundleId(),
            workspaceId: workspaceId,
            title: oldInfo.title,
            windowServer: oldInfo
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 870:
                oldInfo
            case 872:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            switch axRef.windowId {
            case 870:
                makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: nil,
                    role: nil,
                    subrole: nil,
                    attributeFetchSucceeded: false,
                    windowServer: oldInfo
                )
            case 872:
                makeAXEventWindowRuleFacts(
                    bundleId: currentTestBundleId(),
                    title: replacementInfo.title,
                    windowServer: replacementInfo
                )
            default:
                makeAXEventWindowRuleFacts(bundleId: currentTestBundleId())
            }
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 870, spaceId: 0)
        )
        try? await Task.sleep(for: .milliseconds(60))

        #expect(controller.workspaceManager.entry(for: oldToken) != nil)
        #expect(engine.findNode(for: oldToken)?.id == originalGhosttyLeaf.id)

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 872, spaceId: 0)
        )
        let replacementToken = WindowToken(pid: getpid(), windowId: 872)
        await waitUntilAXEventTest(iterations: 240) {
            controller.workspaceManager.entry(for: replacementToken) != nil
        }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let replacementLeaf = engine.findNode(for: replacementToken),
              let updatedRightLeaf = engine.findNode(for: rightToken) else {
            Issue.record("Missing replacement Dwindle Ghostty state")
            return
        }

        let updatedFrames = engine.calculateLayout(for: workspaceId, screen: monitor.frame)
        guard let updatedGhosttyFrame = updatedFrames[replacementToken],
              let updatedRightFrame = updatedFrames[rightToken] else {
            Issue.record("Missing updated Dwindle layout frames")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(replacementLeaf.id == originalGhosttyLeaf.id)
        #expect(updatedRightLeaf.id == originalRightLeaf.id)
        #expect(updatedGhosttyFrame.approximatelyEqual(to: originalGhosttyFrame, tolerance: 0.5))
        #expect(updatedRightFrame.approximatelyEqual(to: originalRightFrame, tolerance: 0.5))
        engine.setSelectedNode(replacementLeaf, in: workspaceId)
        #expect(engine.moveFocus(direction: .right, in: workspaceId) == rightToken)
    }

    @Test @MainActor func ghosttyAmbiguousReplacementBurstDoesNotStealSiblingHandle() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
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
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 874),
            pid: getpid(),
            windowId: 874,
            to: workspaceId
        )
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 875),
            pid: getpid(),
            windowId: 875,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken),
              let siblingEntry = controller.workspaceManager.entry(for: siblingToken) else {
            Issue.record("Missing original Ghostty entries")
            return
        }

        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)
        _ = engine.addWindow(token: siblingToken, to: workspaceId, afterSelection: oldNode.id, focusedToken: oldToken)
        guard let siblingNode = engine.findNode(for: siblingToken) else {
            Issue.record("Missing Ghostty sibling node")
            return
        }

        let replacementFrame = CGRect(x: 80, y: 80, width: 900, height: 640)
        let oldInfo = makeAXEventWindowInfo(
            id: 874,
            title: "repo - shell",
            frame: replacementFrame,
            parentId: 91
        )
        let firstReplacementInfo = makeAXEventWindowInfo(
            id: 876,
            title: "repo - shell (candidate 1)",
            frame: replacementFrame,
            parentId: 91
        )
        let secondReplacementInfo = makeAXEventWindowInfo(
            id: 877,
            title: "repo - shell (candidate 2)",
            frame: replacementFrame,
            parentId: 91
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 874:
                oldInfo
            case 876:
                firstReplacementInfo
            case 877:
                secondReplacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo = switch axRef.windowId {
            case 874:
                oldInfo
            case 876:
                firstReplacementInfo
            case 877:
                secondReplacementInfo
            default:
                makeAXEventWindowInfo(id: UInt32(axRef.windowId))
            }
            return makeAXEventWindowRuleFacts(
                bundleId: currentTestBundleId(),
                title: info.title,
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 874, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 876, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 877, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let firstNewEntry = controller.workspaceManager.entry(forPid: getpid(), windowId: 876),
              let secondNewEntry = controller.workspaceManager.entry(forPid: getpid(), windowId: 877),
              let siblingCurrentEntry = controller.workspaceManager.entry(for: siblingToken)
        else {
            Issue.record("Missing replayed Ghostty entries for ambiguous replacement burst")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(siblingCurrentEntry.handle === siblingEntry.handle)
        #expect(firstNewEntry.handle !== oldEntry.handle)
        #expect(firstNewEntry.handle !== siblingEntry.handle)
        #expect(secondNewEntry.handle !== oldEntry.handle)
        #expect(secondNewEntry.handle !== siblingEntry.handle)
        #expect(engine.findNode(for: siblingToken)?.id == siblingNode.id)
        #expect(engine.findNode(for: oldToken) == nil)
    }

    @Test @MainActor func browserReplacementRekeysManagedWindowWithoutGrowingColumnsOrBarEntries() async {
        let controller = makeAXEventTestController(trackedBundleId: "com.google.Chrome")
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
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 845),
            pid: getpid(),
            windowId: 845,
            to: workspaceId
        )
        let peerToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 846),
            pid: 9_001,
            windowId: 846,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original browser entry")
            return
        }

        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)
        _ = engine.addWindow(token: peerToken, to: workspaceId, afterSelection: oldNode.id, focusedToken: oldToken)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = oldNode.id
            state.activeColumnIndex = 0
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

        let browserFrame = CGRect(x: 80, y: 80, width: 900, height: 640)
        var oldInfo = WindowServerInfo(id: 845, pid: getpid(), level: 0, frame: browserFrame)
        oldInfo.parentId = 77
        oldInfo.title = "Inbox - Chrome"
        var replacementInfo = WindowServerInfo(id: 847, pid: getpid(), level: 0, frame: browserFrame)
        replacementInfo.parentId = 77
        replacementInfo.title = "Inbox - Chrome"

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 845:
                oldInfo
            case 847:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo? = switch axRef.windowId {
            case 845:
                oldInfo
            case 847:
                replacementInfo
            default:
                nil
            }
            return makeAXEventWindowRuleFacts(
                bundleId: "com.google.Chrome",
                title: "Inbox - Chrome",
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 845, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 847, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 847)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement browser entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(engine.findNode(for: oldToken) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == oldNode.id)
        #expect(controller.workspaceManager.tiledEntries(in: workspaceId).count == 2)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 2)
        #expect(engine.columns(in: workspaceId).count == 2)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func browserReplacementDoesNotCoalesceAmbiguousMultipleCreates() async {
        let controller = makeAXEventTestController(trackedBundleId: "com.google.Chrome")
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
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 848),
            pid: getpid(),
            windowId: 848,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing ambiguous replacement source entry")
            return
        }
        _ = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)

        let browserFrame = CGRect(x: 96, y: 96, width: 920, height: 660)
        func makeBrowserInfo(id: UInt32) -> WindowServerInfo {
            var info = WindowServerInfo(id: id, pid: getpid(), level: 0, frame: browserFrame)
            info.parentId = 91
            info.title = "Inbox - Chrome"
            return info
        }

        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 848, 849, 850:
                makeBrowserInfo(id: windowId)
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.google.Chrome",
                title: "Inbox - Chrome",
                windowServer: makeBrowserInfo(id: UInt32(axRef.windowId))
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 848, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 849, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 850, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(for: oldToken) != nil)

        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let firstNewEntry = controller.workspaceManager.entry(forPid: getpid(), windowId: 849),
              let secondNewEntry = controller.workspaceManager.entry(forPid: getpid(), windowId: 850)
        else {
            Issue.record("Missing replayed browser entries for ambiguous replacement burst")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(firstNewEntry.handle !== oldEntry.handle)
        #expect(secondNewEntry.handle !== oldEntry.handle)
        #expect(controller.workspaceManager.tiledEntries(in: workspaceId).count == 2)
        #expect(engine.columns(in: workspaceId).count == 2)
    }

    @Test @MainActor func structuralReplacementRekeysUnlistedAppWithoutAllowlist() async {
        let bundleId = "com.example.native-tabs"
        let controller = makeAXEventTestController(trackedBundleId: bundleId)
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
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 890),
            pid: getpid(),
            windowId: 890,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original unlisted-app entry")
            return
        }

        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = oldNode.id
            state.activeColumnIndex = 0
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 890,
            title: "Inbox",
            frame: CGRect(x: 80, y: 80, width: 900, height: 640),
            parentId: 121
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 891,
            title: "Inbox (2)",
            frame: oldInfo.frame,
            parentId: 121
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 890:
                oldInfo
            case 891:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info: WindowServerInfo = switch axRef.windowId {
            case 890:
                oldInfo
            case 891:
                replacementInfo
            default:
                makeAXEventWindowInfo(id: UInt32(axRef.windowId))
            }
            return makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: info.title,
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 890, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 891, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 891)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement entry for unlisted native-tab app")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(engine.findNode(for: oldToken) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == oldNode.id)
    }

    @Test @MainActor func structuralReplacementDoesNotRekeyWhenOnlyTitleMatches() async {
        let bundleId = "com.example.title-only"
        let controller = makeAXEventTestController(trackedBundleId: bundleId)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 892),
            pid: getpid(),
            windowId: 892,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                title: "Inbox",
                windowServer: nil
            )
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing weak-metadata source entry")
            return
        }

        let replacementInfo = makeAXEventWindowInfo(
            id: 893,
            title: "Inbox",
            frame: CGRect(x: 360, y: 220, width: 800, height: 600)
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            windowId == 893 ? replacementInfo : nil
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: "Inbox",
                windowServer: nil
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 892, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 893, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 893)
        await waitUntilAXEventTest(iterations: 120) {
            controller.workspaceManager.entry(for: oldToken) == nil
                && controller.workspaceManager.entry(for: replacementToken) != nil
        }

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement entry for weak-metadata test")
            return
        }

        #expect(replacementEntry.handle !== oldEntry.handle)
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

    @Test @MainActor func unmatchedStructuralDestroyRemovesAfterSingleFlushWindow() {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 843,
            title: "repo - shell",
            frame: CGRect(x: 96, y: 88, width: 920, height: 660),
            parentId: 131
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 843),
            pid: getpid(),
            windowId: 843,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: currentTestBundleId(),
                workspaceId: workspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 843 else { return nil }
            return oldInfo
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 843, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(for: token) != nil)

        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()

        #expect(controller.workspaceManager.entry(for: token) == nil)
    }

    @Test @MainActor func ghosttyCreateWithMissingButtonsAdmitsAsTrackedFloating() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())

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
            makeAXEventWindowRuleFacts(
                bundleId: currentTestBundleId(),
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false
            )
        }
        controller.resetWorkspaceBarRefreshDebugStateForTests()

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 844, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await controller.waitForWorkspaceBarRefreshForTests()

        guard let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 844) else {
            Issue.record("Expected tracked Ghostty entry")
            return
        }

        #expect(entry.mode == .floating)
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
        #expect(controller.axManager.lastAppliedFrame(for: 822) == nil)
        #expect(subscriptions == [[822]])
        #expect(relayoutReasons == [.axWindowCreated])
    }

    @Test @MainActor func floatingCreatedWindowAssignedToSecondaryMonitorAppliesFrameOnTargetMonitor() async {
        let controller = makeAXEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        installSynchronousFrameApplySuccessOverride(on: controller)
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(
                    bundleId: "dentalplus-air",
                    layout: .float,
                    assignToWorkspace: "6"
                )
            ]
        )

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
            makeAXEventWindowRuleFacts(
                bundleId: "dentalplus-air",
                appName: "DentalPlus Client",
                attributeFetchSucceeded: false
            )
        }
        defer { controller.axEventHandler.frameProvider = nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 827, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false),
              let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 827),
              let appliedFrame = controller.axManager.lastAppliedFrame(for: 827)
        else {
            Issue.record("Expected tracked secondary-monitor floating entry")
            return
        }

        #expect(entry.workspaceId == workspaceId)
        #expect(entry.mode == .floating)
        #expect(secondaryMonitor.visibleFrame.contains(appliedFrame.center))
    }

    @Test @MainActor func floatingCreatedWindowUsesHydratedWorkspaceAndPersistedRestoreFrame() async throws {
        let bundleId = "com.example.restore"
        let settings = SettingsStore(defaults: makeAXEventTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
        ]
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        let expectedFrame = CGRect(
            x: secondaryMonitor.visibleFrame.minX + 260,
            y: secondaryMonitor.visibleFrame.minY + 180,
            width: 480,
            height: 320
        )
        let catalog = makeAXEventPersistedRestoreCatalog(
            workspaceName: "6",
            monitor: secondaryMonitor,
            title: "Hydrated Restore",
            bundleId: bundleId,
            floatingFrame: expectedFrame
        )
        settings.savePersistedWindowRestoreCatalog(catalog)

        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            settings: settings
        )
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "1")
            ]
        )
        let primaryWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let secondaryWorkspaceId = try #require(controller.workspaceManager.workspaceId(for: "6", createIfMissing: false))
        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
        installSynchronousFrameApplySuccessOverride(on: controller)
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
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: "Hydrated Restore"
            )
        }
        defer { controller.axEventHandler.frameProvider = nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 826, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 826) != nil
                && controller.axManager.lastAppliedFrame(for: 826) != nil
        }

        guard let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 826),
              let appliedFrame = controller.axManager.lastAppliedFrame(for: 826)
        else {
            if let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 826) {
                Issue.record(
                    "Hydrated entry present mode=\(entry.mode) workspace=\(entry.workspaceId.uuidString) metadata=\(String(describing: entry.managedReplacementMetadata)) resolved=\(String(describing: controller.workspaceManager.resolvedFloatingFrame(for: entry.token, preferredMonitor: secondaryMonitor))) applied=\(String(describing: controller.axManager.lastAppliedFrame(for: 826)))"
                )
            }
            Issue.record("Expected hydrated floating restore entry")
            return
        }

        #expect(entry.workspaceId == secondaryWorkspaceId)
        #expect(entry.mode == .floating)
        #expect(appliedFrame == expectedFrame)
        #expect(controller.workspaceManager.resolvedFloatingFrame(for: entry.token, preferredMonitor: secondaryMonitor) == expectedFrame)
        #expect(controller.workspaceManager.consumedBootPersistedWindowRestoreKeysForTests().contains(catalog.entries[0].key))
    }

    @Test @MainActor func activeFloatingCreateRetriesFrameApplyAfterContextUnavailable() async {
        let controller = makeAXEventTestController()
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.example.retry",
                    layout: .float,
                    assignToWorkspace: "1"
                )
            ]
        )

        var applyAttempts = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            applyAttempts += 1
            let shouldFail = applyAttempts == 1
            return requests.map { request in
                AXFrameApplyResult(
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: AXFrameWriteResult(
                        targetFrame: request.frame,
                        observedFrame: shouldFail ? nil : request.frame,
                        writeOrder: AXWindowService.frameWriteOrder(
                            currentFrame: request.currentFrameHint,
                            targetFrame: request.frame
                        ),
                        sizeError: .success,
                        positionError: .success,
                        failureReason: shouldFail ? .contextUnavailable : nil
                    )
                )
            }
        }
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
            makeAXEventWindowRuleFacts(bundleId: "com.example.retry")
        }
        defer { controller.axEventHandler.frameProvider = nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 828, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await waitUntilAXEventTest {
            controller.axManager.lastAppliedFrame(for: 828) != nil
        }

        #expect(applyAttempts >= 2)
        #expect(controller.axManager.lastAppliedFrame(for: 828) != nil)
    }

    @Test @MainActor func floatingCreateWithDegradedAxFactsStillAppliesFloatRule() async {
        let controller = makeAXEventTestController()
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.example.float",
                    layout: .float,
                    assignToWorkspace: "2"
                )
            ]
        )

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.frameProvider = { _ in
            CGRect(x: 160, y: 180, width: 500, height: 320)
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.float",
                attributeFetchSucceeded: false
            )
        }
        defer { controller.axEventHandler.frameProvider = nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 829, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 829)
        else {
            Issue.record("Expected degraded-AX floating entry")
            return
        }

        #expect(entry.workspaceId == workspaceId)
        #expect(entry.mode == .floating)
        #expect(controller.workspaceManager.floatingState(for: entry.token) != nil)
    }

    @Test @MainActor func browserHelperSurfaceWithAutoAssignRuleStaysTrackedAtCreateTime() async {
        let controller = makeAXEventTestController(trackedBundleId: "com.google.Chrome")
        controller.settings.appRules = [
            AppRule(
                bundleId: "com.google.Chrome",
                assignToWorkspace: "2"
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

        var subscriptions: [[UInt32]] = []
        var relayoutReasons: [RefreshReason] = []
        var relayoutRoutes: [LayoutRefreshController.RefreshRoute] = []
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 826 else { return nil }
            return WindowServerInfo(
                id: windowId,
                pid: getpid(),
                level: 0,
                frame: CGRect(x: 140, y: 220, width: 260, height: 32)
            )
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.google.Chrome",
                title: nil,
                role: "AXHelpTag",
                subrole: kAXStandardWindowSubrole as String
            )
        }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutReasons.append(reason)
            relayoutRoutes.append(route)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 826, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 826)
        else {
            Issue.record("Expected tracked browser helper entry")
            return
        }

        #expect(entry.workspaceId == workspaceId)
        #expect(entry.mode == .tiling)
        #expect(relayoutReasons == [.axWindowCreated])
        #expect(relayoutRoutes == [.relayout])
        #expect(controller.activeWorkspace()?.id != workspaceId)
        #expect(subscriptions == [[826]])
    }

    @Test @MainActor func forceTileRuleAdmitsFloatingCreateCandidateAndCachesRuleEffects() async {
        let controller = makeAXEventTestController(trackedBundleId: "com.adobe.illustrator")
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

    @Test @MainActor func evaluateWindowDispositionAppliesManualOverrideOutsideKernel() {
        let controller = makeAXEventTestController(trackedBundleId: "com.example.manual")
        let pid = getpid()
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 907)
        let token = WindowToken(pid: pid, windowId: 907)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        _ = controller.workspaceManager.addWindow(axRef, pid: pid, windowId: token.windowId, to: workspaceId)
        controller.workspaceManager.setCachedConstraints(.unconstrained, for: token)
        controller.workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.manual", appName: "Manual Override Test")
        }
        defer { controller.axEventHandler.windowFactsProvider = nil }

        let evaluation = controller.evaluateWindowDisposition(axRef: axRef, pid: pid)
        let baseDecision = controller.windowRuleEngine.decision(
            for: evaluation.facts,
            token: token,
            appFullscreen: evaluation.appFullscreen
        )

        #expect(baseDecision.disposition == .managed)
        #expect(baseDecision.source == .heuristic)
        #expect(evaluation.manualOverride == .forceFloat)
        #expect(evaluation.decision.disposition == .floating)
        #expect(evaluation.decision.source == .manualOverride)
        #expect(evaluation.decision.layoutDecisionKind == .explicitLayout)
        #expect(evaluation.decision.heuristicReasons.isEmpty)
        #expect(evaluation.decision.deferredReason == nil)
    }

    @Test @MainActor func builtInFloatingCreatePreservesUserWorkspaceAssignmentAndRuleEffects() async {
        let controller = makeAXEventTestController(trackedBundleId: "com.apple.calculator")
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000164")!,
                    bundleId: "com.apple.calculator",
                    assignToWorkspace: "2",
                    minWidth: 510,
                    minHeight: 410
                )
            ]
        )

        var relayoutReasons: [RefreshReason] = []
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.apple.calculator",
                appName: "Calculator",
                title: "Calculator"
            )
        }
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 824, spaceId: 0)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 824) != nil &&
                relayoutReasons == [.axWindowCreated]
        }

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 824)
        else {
            Issue.record("Missing managed Calculator entry for built-in floating rule test")
            return
        }

        #expect(entry.workspaceId == workspaceId)
        #expect(entry.mode == .floating)
        #expect(entry.ruleEffects.minWidth == 510)
        #expect(entry.ruleEffects.minHeight == 410)
        #expect(relayoutReasons == [.axWindowCreated])
    }

    @Test @MainActor func cleanShotCaptureOverlayCreateIsTrackedAsFloating() async {
        let controller = makeAXEventTestController()
        let pid: pid_t = 5821
        var subscriptions: [[UInt32]] = []
        var relayoutReasons: [RefreshReason] = []

        controller.appInfoCache.storeInfoForTests(
            pid: pid,
            bundleId: WindowRuleEngine.cleanShotBundleId,
            activationPolicy: .accessory
        )
        controller.axEventHandler.bundleIdProvider = { _ in
            WindowRuleEngine.cleanShotBundleId
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 824 else { return nil }
            return WindowServerInfo(id: windowId, pid: pid, level: 103, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: WindowRuleEngine.cleanShotBundleId,
                subrole: kAXStandardWindowSubrole as String,
                appPolicy: .accessory
            )
        }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 824, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let entry = controller.workspaceManager.entry(forPid: pid, windowId: 824) else {
            Issue.record("Expected tracked CleanShot overlay entry")
            return
        }

        #expect(entry.mode == .floating)
        #expect(relayoutReasons == [.axWindowCreated])
        #expect(subscriptions == [[824]])
    }

    @Test @MainActor func reevaluateWindowRulesRetainsTrackedCleanShotCaptureOverlayAsFloating() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid: pid_t = 5822
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 825),
            pid: pid,
            windowId: 825,
            to: workspaceId
        )
        var relayoutReasons: [RefreshReason] = []

        controller.appInfoCache.storeInfoForTests(
            pid: pid,
            bundleId: WindowRuleEngine.cleanShotBundleId,
            activationPolicy: .accessory
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 825 else { return nil }
            return WindowServerInfo(id: windowId, pid: pid, level: 103, frame: .zero)
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: WindowRuleEngine.cleanShotBundleId,
                subrole: kAXStandardWindowSubrole as String,
                appPolicy: .accessory
            )
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        let outcome = await controller.reevaluateWindowRules(for: [.window(token)])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(outcome.resolvedAnyTarget)
        #expect(outcome.evaluatedAnyWindow)
        #expect(outcome.relayoutNeeded)
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Expected reevaluated CleanShot entry")
            return
        }

        #expect(entry.mode == .floating)
        #expect(relayoutReasons == [.windowRuleReevaluation])
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

    @Test @MainActor func minimizingFocusedWindowHidesBorderAndRestoreRerendersIt() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 833)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: 833,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let frame = CGRect(x: 24, y: 32, width: 820, height: 620)

        controller.setBordersEnabled(true)
        controller.axEventHandler.frameProvider = { _ in frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 833 else { return nil }
            return makeAXEventWindowInfo(
                id: windowId,
                pid: pid,
                frame: frame
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeAXEventWindowRuleFacts(
                title: "minimized-window",
                windowServer: makeAXEventWindowInfo(
                    id: UInt32(axRef.windowId),
                    pid: pid,
                    title: "minimized-window",
                    frame: frame
                )
            )
        }
        controller.borderCoordinator.minimizedProviderForTests = { _ in false }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
        #expect(
            controller.renderKeyboardFocusBorder(
                for: target,
                preferredFrame: frame,
                policy: .direct,
                source: .manualRender
            )
        )
        #expect(lastAppliedBorderWindowId(on: controller) == 833)

        controller.borderCoordinator.minimizedProviderForTests = { _ in true }
        controller.axEventHandler.handleWindowMinimizedChanged(
            pid: pid,
            windowId: 833,
            isMinimized: true
        )

        #expect(lastAppliedBorderWindowId(on: controller) == nil)
        #expect(controller.borderCoordinator.ownerStateSnapshotForTests().owner == .none)

        controller.borderCoordinator.minimizedProviderForTests = { _ in false }
        controller.axEventHandler.handleWindowMinimizedChanged(
            pid: pid,
            windowId: 833,
            isMinimized: false
        )

        let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(lastAppliedBorderWindowId(on: controller) == 833)
        #expect(ownerState.owner == .managed(token: token, wid: 833, workspaceId: workspaceId))
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

    @Test @MainActor func handleRemovedPidPathInvalidatesCachedTitle() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        AXWindowService.clearTitleCacheForTests()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            AXWindowService.timeSourceForTests = nil
            AXWindowService.clearTitleCacheForTests()
        }

        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        var lookupCount = 0
        AXWindowService.timeSourceForTests = { 100 }
        AXWindowService.titleLookupProviderForTests = { _ in
            lookupCount += 1
            return lookupCount == 1 ? "Before Remove" : "After Remove"
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 905),
            pid: getpid(),
            windowId: 905,
            to: workspaceId
        )

        #expect(AXWindowService.titlePreferFast(windowId: 905) == "Before Remove")

        controller.axEventHandler.handleRemoved(pid: getpid(), winId: 905)

        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(AXWindowService.titlePreferFast(windowId: 905) == "After Remove")
        #expect(lookupCount == 2)
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
