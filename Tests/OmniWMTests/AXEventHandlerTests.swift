import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

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

private enum AXEventFocusOperationEvent: Equatable {
    case order(UInt32)
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
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

@MainActor
private func configureRaycastFloatingDialogCreate(
    on controller: WMController,
    pid: pid_t,
    windowId: UInt32,
    frame: CGRect,
    isVisible: @escaping () -> Bool
) {
    let bundleId = "com.raycast-x.macos"
    let windowInfo = WindowServerInfo(id: windowId, pid: pid, level: 3, frame: frame)
    controller.windowRuleEngine.rebuild(
        rules: [
            AppRule(bundleId: bundleId, layout: .float)
        ]
    )
    controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = true
    controller.axEventHandler.windowInfoProvider = { candidateWindowId in
        guard candidateWindowId == windowId, isVisible() else { return nil }
        return windowInfo
    }
    controller.axEventHandler.axWindowRefProvider = { candidateWindowId, candidatePid in
        guard candidateWindowId == windowId, candidatePid == pid else { return nil }
        return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(candidateWindowId))
    }
    controller.axEventHandler.frameProvider = { _ in frame }
    controller.axEventHandler.windowFactsProvider = { _, _ in
        makeAXEventWindowRuleFacts(
            bundleId: bundleId,
            appName: "Raycast Beta",
            subrole: kAXSystemDialogSubrole as String,
            attributeFetchSucceeded: false,
            windowServer: windowInfo
        )
    }
    controller.axManager.frameApplyOverrideForTests = { _ in [] }
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
        parentWindowId: windowServer.flatMap { $0.parentId == 0 ? nil : $0.parentId },
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
        parentWindowId: nil,
        frame: nil
    )
    let key = PersistedWindowRestoreKey(metadata: metadata)!
    return PersistedWindowRestoreCatalog(
        entries: [
            PersistedWindowRestoreEntry(
                key: key,
                identity: nil,
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
    controller.focusBorderController.lastAppliedFocusedWindowIdForTests
}

@MainActor
private func lastAppliedBorderFrame(on controller: WMController) -> CGRect? {
    controller.focusBorderController.lastAppliedFocusedFrameForTests
}

@MainActor
@discardableResult
private func confirmFocusedBorder(
    on controller: WMController,
    token: WindowToken,
    frame: CGRect? = nil
) -> Bool {
    controller.renderKeyboardFocusBorder(
        for: controller.managedKeyboardFocusTarget(for: token),
        preferredFrame: frame,
        forceOrdering: true
    )
}

@MainActor
private func createFocusTraceEvents(on controller: WMController) -> [NiriCreateFocusTraceEvent] {
    controller.axEventHandler.niriCreateFocusTraceSnapshotForTests()
}

@MainActor
private func managedReplacementTraceEvents(
    on controller: WMController
) -> [AXEventHandler.ManagedReplacementTraceEvent] {
    controller.axEventHandler.managedReplacementTraceSnapshotForTests()
}

@MainActor
private func structuralManagedReplacementMatchedElapsedMillis(on controller: WMController) -> Int? {
    managedReplacementTraceEvents(on: controller).compactMap { event -> Int? in
        guard case let .matched(policy, elapsedMillis) = event.kind,
              policy == "structural"
        else {
            return nil
        }
        return elapsedMillis
    }.last
}

@MainActor
private func structuralManagedReplacementFlushElapsedMillis(on controller: WMController) -> [Int] {
    managedReplacementTraceEvents(on: controller).compactMap { event -> Int? in
        guard case let .flushed(policy, _, _, _, elapsedMillis) = event.kind,
              policy == "structural"
        else {
            return nil
        }
        return elapsedMillis
    }
}

@MainActor
private func waitUntilAXEventTest(
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0 ..< iterations where !condition() {
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
        guard let sourceWorkspaceId = controller.activeWorkspace()?.id,
              let ruleWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing active workspace")
            return
        }
        #expect(sourceWorkspaceId != ruleWorkspaceId)
        controller.settings.appRules = [
            AppRule(
                bundleId: "com.example.dynamic",
                titleSubstring: "Chooser",
                layout: .float,
                assignToWorkspace: "2"
            )
        ]
        var relayoutReasons: [RefreshReason] = []
        var title = "Document"
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 812),
            pid: getpid(),
            windowId: 812,
            to: sourceWorkspaceId
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
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 812)?.workspaceId == sourceWorkspaceId)
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

        // Tile/auto rules with degraded AX facts are deferred to prevent
        // tooltips and auxiliary windows from destabilizing layout.
        let entry = controller.workspaceManager.entry(forPid: getpid(), windowId: 816)
        #expect(entry == nil)
    }

    @Test @MainActor func createdWindowRetriesWhenAXWindowRefIsInitiallyUnavailableWithoutRuleReevaluation() async {
        await withAXFrameProviderIsolationForTests {
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

            let trace = createFocusTraceEvents(on: controller)
            #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 817)?.mode == .tiling)
            #expect(relayoutReasons == [.axWindowCreated])
            #expect(controller.layoutRefreshController.debugCounters.executedByReason[
                .windowRuleReevaluation,
                default: 0
            ] == 0)
            #expect(axWindowRefLookupCount >= 2)
            #expect(trace.contains { event in
                if case .createSeen(windowId: 817) = event.kind {
                    return true
                }
                return false
            })
            #expect(trace.contains { event in
                if case let .createRetryScheduled(windowId, pid, attempt) = event.kind {
                    return windowId == 817 && pid == getpid() && attempt == 1
                }
                return false
            })
            #expect(trace.contains { event in
                if case let .candidateTracked(token, _) = event.kind {
                    return token == WindowToken(pid: getpid(), windowId: 817)
                }
                return false
            })
        }
    }

    @Test @MainActor func createdWindowRetriesWhenWindowServerInfoIsInitiallyUnavailable() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeAXEventTestController()
            var relayoutReasons: [RefreshReason] = []
            var windowInfoReady = false
            var windowInfoLookupCount = 0

            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == 820 else { return nil }
                windowInfoLookupCount += 1
                guard windowInfoReady else { return nil }
                return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, _ in
                guard windowId == 820 else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(bundleId: "com.example.info-retry")
            }
            controller.layoutRefreshController.resetDebugState()
            controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
                relayoutReasons.append(reason)
                return true
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: 820, spaceId: 0)
            )
            windowInfoReady = true

            await waitUntilAXEventTest(iterations: 300) {
                controller.workspaceManager.entry(forPid: getpid(), windowId: 820) != nil &&
                    relayoutReasons == [.axWindowCreated]
            }

            #expect(windowInfoLookupCount >= 2)
            #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 820)?.mode == .tiling)
            #expect(controller.axEventHandler.pendingCreatePlacementContext(for: 820) == nil)
        }
    }

    @Test @MainActor func createdWindowRetryUsesFreshMonitorWorkspaceAfterActiveWorkspaceChanges() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeAXEventTestController()
            var axWindowRefReady = false
            guard let monitor = controller.monitorForInteraction(),
                  let laterWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
            else {
                Issue.record("Missing workspace fixture")
                return
            }

            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == 818 else { return nil }
                return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, _ in
                guard windowId == 818, axWindowRefReady else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(bundleId: "com.example.ax-retry-origin")
            }
            controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
                spaceId == 11 ? monitor.displayId : nil
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: 818, spaceId: 11)
            )
            #expect(controller.workspaceManager.setActiveWorkspace(laterWorkspaceId, on: monitor.id))
            axWindowRefReady = true

            await waitUntilAXEventTest(iterations: 300) {
                controller.workspaceManager.entry(forPid: getpid(), windowId: 818) != nil
            }

            #expect(controller.activeWorkspace()?.id == laterWorkspaceId)
            #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 818)?
                .workspaceId == laterWorkspaceId)
        }
    }

    @Test @MainActor func createdWindowStabilizationUsesFreshMonitorWorkspaceAfterActiveWorkspaceChanges() async {
        let controller = makeAXEventTestController()
        var factsReady = false
        guard let monitor = controller.monitorForInteraction(),
              let laterWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace fixture")
            return
        }

        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 819 else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == 819 else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.stabilization-origin",
                attributeFetchSucceeded: factsReady
            )
        }
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 13 ? monitor.displayId : nil
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 819, spaceId: 13)
        )
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 819) == nil)
        #expect(controller.workspaceManager.setActiveWorkspace(laterWorkspaceId, on: monitor.id))
        factsReady = true

        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 819) != nil
        }

        #expect(controller.activeWorkspace()?.id == laterWorkspaceId)
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 819)?.workspaceId == laterWorkspaceId)
        #expect(controller.axEventHandler.pendingCreatePlacementContext(for: 819) == nil)
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
        controller.setAnimationsEnabled(false, persist: false)
        controller.enableNiriLayout()
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
        _ = confirmFocusedBorder(on: controller, token: oldToken)

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

        let deferredTrace = createFocusTraceEvents(on: controller)
        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)
        #expect(deferredTrace.contains { event in
            if case let .activationDeferred(_, token, source, reason, attempt) = event.kind {
                return token == newToken &&
                    source == .workspaceDidActivateApplication &&
                    reason == .pendingFocusMismatch &&
                    attempt == 1
            }
            return false
        })

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(newWindowId))
        }
        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        let confirmedTrace = createFocusTraceEvents(on: controller)
        #expect(controller.workspaceManager.focusedToken == newToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == Int(newWindowId))
        #expect(confirmedTrace.contains { event in
            if case let .focusConfirmed(token, confirmedWorkspaceId, source) = event.kind {
                return token == newToken &&
                    confirmedWorkspaceId == workspaceId &&
                    source == .focusedWindowChanged
            }
            return false
        })

        await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()

        #expect(lastAppliedBorderWindowId(on: controller) == Int(newWindowId))
    }

    @Test @MainActor func focusConfirmationPreservesActiveViewportSpring() async {
        let controller = makeAXEventTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for active viewport focus confirmation test")
            return
        }

        controller.enableNiriLayout()
        controller.updateNiriConfig(
            maxVisibleColumns: 1,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 876),
            pid: getpid(),
            windowId: 876,
            to: workspaceId
        )
        let newToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 877),
            pid: getpid(),
            windowId: 877,
            to: workspaceId
        )
        guard let oldHandle = controller.workspaceManager.handle(for: oldToken),
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri setup for active viewport focus confirmation test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: oldHandle
        )
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 900
            column.cachedHeight = 800
        }

        guard let oldNode = engine.findNode(for: oldToken),
              let newNode = engine.findNode(for: newToken),
              let newEntry = controller.workspaceManager.entry(for: newToken)
        else {
            Issue.record("Missing Niri nodes for active viewport focus confirmation test")
            return
        }

        let springTarget = CGFloat(-700)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = oldNode.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .spring(
                SpringAnimation(
                    from: -900,
                    to: Double(springTarget),
                    initialVelocity: 9_000,
                    startTime: 0,
                    config: .snappy
                )
            )
        }

        controller.axEventHandler.handleManagedAppActivation(
            entry: newEntry,
            isWorkspaceActive: true,
            appFullscreen: false,
            source: .focusedWindowChanged
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(updatedState.selectedNodeId == newNode.id)
        #expect(updatedState.activeColumnIndex == 0)
        #expect(updatedState.viewOffsetPixels.isAnimating)
        #expect(updatedState.viewOffsetPixels.target() == springTarget)
        #expect(controller.workspaceManager.focusedToken == newToken)
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
        controller.enableNiriLayout()
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
        _ = confirmFocusedBorder(on: controller, token: oldToken)

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

        let deferredTrace = createFocusTraceEvents(on: controller)
        #expect(controller.workspaceManager.focusedToken == oldToken)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)
        #expect(deferredTrace.contains { event in
            if case let .activationDeferred(_, token, source, reason, attempt) = event.kind {
                return token == newToken &&
                    reason == .missingFocusedWindow &&
                    attempt >= 1 &&
                    (source == .focusedWindowChanged || source == .workspaceDidActivateApplication)
            }
            return false
        })
        #expect(!deferredTrace.contains { event in
            if case let .nonManagedFallbackEntered(pid, source) = event.kind {
                return pid == newPid && source == .workspaceDidActivateApplication
            }
            return false
        })

        await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()

        let settledBeforeConfirmTrace = createFocusTraceEvents(on: controller)
        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(lastAppliedBorderWindowId(on: controller) == oldToken.windowId)
        #expect(settledBeforeConfirmTrace.contains { event in
            if case let .borderReapplied(token, phase) = event.kind {
                return token == oldToken && phase == .animationSettled
            }
            return false
        })

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == newPid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(newWindowId))
        }
        controller.axEventHandler.handleAppActivation(
            pid: newPid,
            source: .focusedWindowChanged
        )

        let confirmedTrace = createFocusTraceEvents(on: controller)
        #expect(controller.workspaceManager.focusedToken == newToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == newToken)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == newNode.id)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).activeColumnIndex == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == Int(newWindowId))
        #expect(confirmedTrace.contains { event in
            if case let .focusConfirmed(token, confirmedWorkspaceId, source) = event.kind {
                return token == newToken &&
                    confirmedWorkspaceId == workspaceId &&
                    source == .focusedWindowChanged
            }
            return false
        })
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
            createFocusTraceEvents(on: controller).contains { event in
                if case let .activationDeferred(_, token, source, reason, attempt) = event.kind {
                    return token == targetToken &&
                        source == .focusedWindowChanged &&
                        reason == .pendingFocusMismatch &&
                        attempt == 1
                }
                return false
            }
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
        _ = controller.focusBridge.beginManagedRequest(
            token: pendingToken,
            workspaceId: workspaceId
        )
        _ = confirmFocusedBorder(
            on: controller,
            token: oldToken,
            frame: CGRect(x: 10, y: 10, width: 640, height: 480)
        )
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: observedToken.windowId)
        }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        let trace = createFocusTraceEvents(on: controller)
        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.focusedToken == observedToken)
        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == observedToken)
        #expect(!trace.contains { event in
            if case let .activationDeferred(_, token, source, reason, _) = event.kind {
                return token == pendingToken &&
                    source == .focusedWindowChanged &&
                    reason == .pendingFocusMismatch
            }
            return false
        })
        #expect(trace.contains { event in
            if case let .focusConfirmed(token, confirmedWorkspaceId, source) = event.kind {
                return token == observedToken &&
                    confirmedWorkspaceId == workspaceId &&
                    source == .focusedWindowChanged
            }
            return false
        })
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
        _ = controller.focusBridge.beginManagedRequest(
            token: pendingToken,
            workspaceId: workspaceId
        )
        _ = confirmFocusedBorder(
            on: controller,
            token: oldToken,
            frame: CGRect(x: 10, y: 10, width: 640, height: 480)
        )
        controller.axEventHandler.focusedWindowRefProvider = { _ in nil }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        let trace = createFocusTraceEvents(on: controller)
        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(!trace.contains { event in
            if case let .activationDeferred(_, token, source, reason, _) = event.kind {
                return token == pendingToken &&
                    source == .focusedWindowChanged &&
                    reason == .missingFocusedWindow
            }
            return false
        })
        #expect(trace.contains { event in
            if case let .nonManagedFallbackEntered(pid, source) = event.kind {
                return pid == getpid() && source == .focusedWindowChanged
            }
            return false
        })
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
        _ = controller.focusBridge.beginManagedRequest(
            token: pendingToken,
            workspaceId: workspaceId
        )
        _ = confirmFocusedBorder(
            on: controller,
            token: oldToken,
            frame: CGRect(x: 10, y: 10, width: 640, height: 480)
        )
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: observedToken.windowId)
        }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )

        let trace = createFocusTraceEvents(on: controller)
        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == observedToken)
        #expect(controller.currentKeyboardFocusTargetForRendering()?.isManaged == false)
        #expect(!trace.contains { event in
            if case let .activationDeferred(_, token, source, reason, _) = event.kind {
                return token == pendingToken &&
                    source == .focusedWindowChanged &&
                    reason == .pendingFocusUnmanagedToken
            }
            return false
        })
        #expect(trace.contains { event in
            if case let .nonManagedFallbackEntered(pid, source) = event.kind {
                return pid == getpid() && source == .focusedWindowChanged
            }
            return false
        })
    }

    @Test @MainActor func focusedUntrackedStandardWindowIsAdmittedBeforeNonManagedFallback() async {
        let controller = makeAXEventTestController(trackedBundleId: "com.google.Chrome")
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing focused-window admission fixture")
            return
        }

        controller.hasStartedServices = true

        let observedWindowId: UInt32 = 981
        let observedToken = WindowToken(pid: getpid(), windowId: Int(observedWindowId))
        let observedAXRef = AXWindowRef(
            element: AXUIElementCreateSystemWide(),
            windowId: observedToken.windowId
        )
        var subscriptions: [[UInt32]] = []
        var relayoutReasons: [RefreshReason] = []

        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == getpid() else { return nil }
            return observedAXRef
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == observedWindowId else { return nil }
            return WindowServerInfo(
                id: windowId,
                pid: getpid(),
                level: 0,
                frame: CGRect(x: 120, y: 160, width: 900, height: 700)
            )
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, pid in
            guard windowId == observedWindowId, pid == getpid() else { return nil }
            return observedAXRef
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.google.Chrome",
                appName: "Google Chrome",
                title: "Detached Tab - Google Chrome"
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

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .focusedWindowChanged
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let entry = controller.workspaceManager.entry(for: observedToken) else {
            Issue.record("Expected focused untracked Chrome window to be admitted")
            return
        }

        #expect(entry.workspaceId == workspaceId)
        #expect(entry.mode == .tiling)
        #expect(controller.workspaceManager.focusedToken == observedToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(!controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.focusBridge.focusedTarget?.token == observedToken)
        #expect(controller.focusBridge.focusedTarget?.isManaged == true)
        #expect(subscriptions == [[observedWindowId]])
        #expect(relayoutReasons.contains(.axWindowCreated))
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
        controller.enableNiriLayout()
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
        _ = controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: oldToken),
            preferredFrame: controller.preferredKeyboardFocusFrame(for: oldToken)
        )

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
        controller.focusWindow(firstPendingToken)
        await waitUntilAXEventTest(iterations: 1_000) {
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
        controller.enableNiriLayout()
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
        _ = controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: oldToken),
            preferredFrame: controller.preferredKeyboardFocusFrame(for: oldToken)
        )

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
        controller.focusWindow(firstPendingToken)
        await waitUntilAXEventTest(iterations: 1_000) {
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
        controller.focusWindow(secondPendingToken)
        await waitUntilAXEventTest(iterations: 1_000) {
            controller.workspaceManager.pendingFocusedToken == secondPendingToken
        }

        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .workspaceDidActivateApplication
        )

        let deferredTrace = createFocusTraceEvents(on: controller)
        #expect(controller.workspaceManager.pendingFocusedToken == secondPendingToken)
        #expect(deferredTrace.contains { event in
            if case let .activationDeferred(_, token, source, reason, attempt) = event.kind {
                return token == secondPendingToken &&
                    source == .workspaceDidActivateApplication &&
                    reason == .pendingFocusMismatch &&
                    attempt == 1
            }
            return false
        })

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

        controller.axEventHandler.handleAppActivation(pid: getpid())

        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
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

    @Test @MainActor func ownedUtilityWindowFrameChangeIsSkippedBeforeWindowResolution() async {
        let controller = makeAXEventTestController()
        let registry = OwnedWindowRegistry.shared
        let ownedWindow = makeAXEventOwnedWindow()

        registry.resetForTests()
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
            controller.axEventHandler.windowInfoProvider = nil
        }

        var windowInfoLookups = 0
        var relayoutReasons: [RefreshReason] = []
        controller.axEventHandler.windowInfoProvider = { _ in
            windowInfoLookups += 1
            return nil
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(ownedWindow.windowNumber))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(windowInfoLookups == 0)
        #expect(relayoutReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
    }

    @Test @MainActor func systemTextInputAgentCreateIsIgnoredWithoutFloatingLifecycle() async {
        var events: [AXEventFocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in events.append(.activate(pid)) },
            focusSpecificWindow: { pid, windowId, _ in events.append(.focus(pid, windowId)) },
            raiseWindow: { _ in events.append(.raise) },
            orderWindow: { windowId in events.append(.order(windowId)) }
        )
        let controller = makeAXEventTestController(windowFocusOperations: operations)
        let pid: pid_t = 5_823
        let windowId: UInt32 = 9_826
        let frame = CGRect(x: 240, y: 180, width: 360, height: 280)
        let windowInfo = WindowServerInfo(id: windowId, pid: pid, level: 3, frame: frame)
        var subscriptions: [[UInt32]] = []
        var frameApplyRequests = 0

        controller.axEventHandler.windowInfoProvider = { candidateWindowId in
            guard candidateWindowId == windowId else { return nil }
            return windowInfo
        }
        controller.axEventHandler.axWindowRefProvider = { candidateWindowId, candidatePid in
            guard candidateWindowId == windowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(candidateWindowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.apple.CharacterPaletteIM",
                subrole: "AXTextInputTransientPanel",
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .accessory,
                windowServer: windowInfo
            )
        }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.axManager.frameApplyOverrideForTests = { requests in
            frameApplyRequests += requests.count
            return []
        }
        defer { controller.axManager.frameApplyOverrideForTests = nil }
        controller.layoutRefreshController.resetDebugState()

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: windowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(windowId)) == nil)
        #expect(subscriptions.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
        #expect(frameApplyRequests == 0)
        #expect(events.isEmpty)
    }

    @Test @MainActor func fullscreenManagedActivationSuspendsManagedWindowAndRequestsPlaceholderRelayout() async {
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
        let unmanagedToken = WindowToken(pid: 64_803, windowId: 64_804)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: unmanagedToken,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: unmanagedToken.windowId),
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: CGRect(x: 20, y: 20, width: 400, height: 300),
            preferredFrameSource: .observed,
            forceOrdering: true
        )
        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == unmanagedToken)

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
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
        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == token)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
        _ = controller.focusBorderController.refresh(forceOrdering: true)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
        #expect(relayoutEvents.count == 1)
        #expect(relayoutEvents.first?.0 == .appActivationTransition)
        #expect(relayoutEvents.first?.1 == .immediateRelayout)
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

    @Test @MainActor func nativeFullscreenLikeDestroyWithoutRecordBypassesManagedReplacementDelay() {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        controller.hasStartedServices = true
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
        guard let originalEntry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry before speculative native fullscreen destroy")
            return
        }
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.focusBridge.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: originalEntry.axRef,
                workspaceId: workspaceId,
                isManaged: true
            ),
            preferredFrame: CGRect(x: 100, y: 120, width: 640, height: 420),
            forceOrdering: true
        )
        controller.axEventHandler.isFullscreenProvider = { _ in true }
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(
                id: windowId,
                pid: getpid(),
                level: 0,
                frame: CGRect(x: 100, y: 120, width: 640, height: 420)
            )
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String
            )
        }

        controller.axEventHandler.handleRemoved(pid: getpid(), winId: 8042)

        guard let record = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing speculative native fullscreen record")
            return
        }
        if case .enterRequested = record.transition {} else {
            Issue.record("Expected speculative record to stay in enterRequested transition")
        }
        #expect(record.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.entry(for: token)?.handle === originalEntry.handle)
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
        #expect(controller.focusBridge.activeManagedRequest == nil)
        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
    }

    @Test @MainActor func ordinaryFocusedDestroyDoesNotSpeculativelyPreserveNativeFullscreen() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8043),
            pid: getpid(),
            windowId: 8043,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.axEventHandler.isFullscreenProvider = { _ in false }

        controller.axEventHandler.handleRemoved(token: token)

        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token) == nil)
    }

    @Test @MainActor func dwindleDestroyDoesNotSpeculativelyPreserveNativeFullscreen() {
        let controller = makeAXEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        controller.enableDwindleLayout()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8044),
            pid: getpid(),
            windowId: 8044,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.axEventHandler.isFullscreenProvider = { _ in true }

        controller.axEventHandler.handleRemoved(token: token)

        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token) == nil)
    }

    @Test @MainActor func floatingDestroyDoesNotSpeculativelyPreserveNativeFullscreen() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8045),
            pid: getpid(),
            windowId: 8045,
            to: workspaceId,
            mode: .floating
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.axEventHandler.isFullscreenProvider = { _ in true }

        controller.axEventHandler.handleRemoved(token: token)

        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token) == nil)
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

        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
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

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token) == nil)
        #expect(controller.workspaceManager.entry(for: token)?.handle === originalEntry.handle)
        #expect(controller.workspaceManager.layoutReason(for: token) == .standard)
        #expect(controller.workspaceManager.focusedToken == token)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
    }

    @Test @MainActor func nativeFullscreenUnavailableReplacementRekeysManagedHandleWithoutReplacingIt() {
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

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
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
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
    }

    @Test @MainActor func nativeFullscreenSameTokenReplacementSuspensionClearsFocusedBorderAndRelayouts() async {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8049),
            pid: getpid(),
            windowId: 8049,
            to: workspaceId
        )
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing same-token native fullscreen replacement entry")
            return
        }

        controller.setBordersEnabled(true)
        controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: token),
            preferredFrame: CGRect(x: 20, y: 20, width: 640, height: 420),
            forceOrdering: true
        )
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(token)

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }

        let restored = controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
            token: token,
            windowId: UInt32(token.windowId),
            axRef: entry.axRef,
            workspaceId: workspaceId,
            appFullscreen: true
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let record = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing same-token native fullscreen record after replacement suspension")
            return
        }
        #expect(restored)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
        #expect(record.currentToken == token)
        #expect(record.availability == .present)
        if case .suspended = record.transition {} else {
            Issue.record("Expected same-token replacement to be suspended")
        }
        #expect(relayoutEvents.count == 1)
        #expect(relayoutEvents.first?.0 == .appActivationTransition)
        #expect(relayoutEvents.first?.1 == .immediateRelayout)
    }

    @Test @MainActor func nativeFullscreenRekeyedReplacementSuspensionClearsFocusedBorderAndRelayouts() async {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8050),
            pid: getpid(),
            windowId: 8050,
            to: workspaceId
        )
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing original native fullscreen replacement entry")
            return
        }

        controller.setBordersEnabled(true)
        controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: originalToken),
            preferredFrame: CGRect(x: 40, y: 40, width: 720, height: 460),
            forceOrdering: true
        )
        #expect(lastAppliedBorderWindowId(on: controller) == originalToken.windowId)
        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(originalToken)

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }

        let replacementToken = WindowToken(pid: getpid(), windowId: 8051)
        let replacementWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8051)
        let restored = controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
            token: replacementToken,
            windowId: 8051,
            axRef: replacementWindow,
            workspaceId: workspaceId,
            appFullscreen: true
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let record = controller.workspaceManager.nativeFullscreenRecord(for: replacementToken)
        else {
            Issue.record("Missing rekeyed native fullscreen replacement state")
            return
        }
        #expect(restored)
        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .nativeFullscreen)
        #expect(record.currentToken == replacementToken)
        #expect(record.availability == .present)
        if case .suspended = record.transition {} else {
            Issue.record("Expected rekeyed replacement to be suspended")
        }
        #expect(relayoutEvents.count == 1)
        #expect(relayoutEvents.first?.0 == .appActivationTransition)
        #expect(relayoutEvents.first?.1 == .immediateRelayout)
    }

    @Test @MainActor func nativeFullscreenReplacementCreateUsesSingleSuspensionRelayout() async {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8052),
            pid: getpid(),
            windowId: 8052,
            to: workspaceId
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(originalToken)

        let replacementWindowId: UInt32 = 8056
        let replacementFrame = CGRect(x: 20, y: 30, width: 900, height: 620)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == replacementWindowId else { return nil }
            return makeAXEventWindowInfo(
                id: windowId,
                pid: getpid(),
                frame: replacementFrame
            )
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == replacementWindowId else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            axRef.windowId == Int(replacementWindowId)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, pid in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.native-fullscreen",
                role: nil,
                subrole: nil,
                windowServer: makeAXEventWindowInfo(
                    id: UInt32(axRef.windowId),
                    pid: pid,
                    frame: replacementFrame
                )
            )
        }

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: replacementWindowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: Int(replacementWindowId))
        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(controller.workspaceManager.entry(for: replacementToken) != nil)
        #expect(relayoutEvents.count == 1)
        #expect(relayoutEvents.first?.0 == .appActivationTransition)
        #expect(relayoutEvents.first?.1 == .immediateRelayout)
        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.appActivationTransition] == 1)
        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.axWindowCreated] == nil)
    }

    @Test @MainActor func browserFullscreenCreateSynthesizesNativeRecordBeforeTitleRetry() async {
        let controller = makeAXEventTestController(trackedBundleId: "com.google.Chrome")
        defer {
            controller.axEventHandler.resetDebugStateForTests()
            controller.nativeFullscreenPlaceholderManager.removeAll()
        }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8067),
            pid: getpid(),
            windowId: 8067,
            to: workspaceId
        )
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing original browser fullscreen entry")
            return
        }
        let originalNode = engine.addWindow(
            token: originalToken,
            to: workspaceId,
            afterSelection: nil,
            focusedToken: originalToken
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = originalNode.id
            state.activeColumnIndex = 0
        }
        _ = controller.workspaceManager.setManagedFocus(
            originalToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let replacementWindowId: UInt32 = 8068
        let fullscreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == replacementWindowId else { return nil }
            return makeAXEventWindowInfo(
                id: windowId,
                pid: getpid(),
                title: nil,
                frame: fullscreenFrame
            )
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == replacementWindowId else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            axRef.windowId == Int(replacementWindowId)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, pid in
            makeAXEventWindowRuleFacts(
                bundleId: "com.google.Chrome",
                title: nil,
                role: kAXWindowRole as String,
                subrole: "AXFullScreenWindow",
                windowServer: makeAXEventWindowInfo(
                    id: UInt32(axRef.windowId),
                    pid: pid,
                    title: nil,
                    frame: fullscreenFrame
                )
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: replacementWindowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: Int(replacementWindowId))
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let record = controller.workspaceManager.nativeFullscreenRecord(for: replacementToken)
        else {
            Issue.record("Missing synthesized browser native fullscreen state")
            return
        }

        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(record.originalToken == originalToken)
        #expect(record.currentToken == replacementToken)
        #expect(record.availability == .present)
        if case .suspended = record.transition {} else {
            Issue.record("Expected synthesized browser fullscreen record to be suspended")
        }
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .nativeFullscreen)
        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[replacementToken] != nil)
        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.axWindowCreated] == nil)
    }

    @Test @MainActor func nativeFullscreenReplacementCreateRetriesWhenWindowServerInfoIsInitiallyUnavailable() async {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8057),
            pid: getpid(),
            windowId: 8057,
            to: workspaceId
        )
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing original native fullscreen replacement entry")
            return
        }
        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenTemporarilyUnavailable(originalToken)

        let replacementWindowId: UInt32 = 8058
        let replacementToken = WindowToken(pid: getpid(), windowId: Int(replacementWindowId))
        let replacementFrame = CGRect(x: 24, y: 36, width: 920, height: 640)
        var windowInfoReady = false
        var windowInfoLookupCount = 0
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == replacementWindowId else { return nil }
            windowInfoLookupCount += 1
            guard windowInfoReady else { return nil }
            return makeAXEventWindowInfo(
                id: windowId,
                pid: getpid(),
                frame: replacementFrame
            )
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == replacementWindowId else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            axRef.windowId == Int(replacementWindowId)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, pid in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.native-fullscreen",
                role: nil,
                subrole: nil,
                windowServer: makeAXEventWindowInfo(
                    id: UInt32(axRef.windowId),
                    pid: pid,
                    frame: replacementFrame
                )
            )
        }

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: replacementWindowId, spaceId: 0)
        )

        #expect(controller.workspaceManager.entry(for: originalToken) != nil)
        #expect(controller.workspaceManager.entry(for: replacementToken) == nil)
        #expect(controller.axEventHandler.pendingCreatePlacementContext(for: Int(replacementWindowId)) != nil)
        #expect(relayoutEvents.isEmpty)

        windowInfoReady = true
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.entry(for: replacementToken) != nil &&
                relayoutEvents.count == 1
        }

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let record = controller.workspaceManager.nativeFullscreenRecord(for: replacementToken)
        else {
            Issue.record("Missing rekeyed native fullscreen replacement state")
            return
        }

        #expect(windowInfoLookupCount >= 2)
        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(controller.workspaceManager.allEntries().filter { $0.windowId == Int(replacementWindowId) }.count == 1)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .nativeFullscreen)
        #expect(record.currentToken == replacementToken)
        #expect(record.availability == .present)
        if case .suspended = record.transition {} else {
            Issue.record("Expected rekeyed replacement to be suspended")
        }
        #expect(controller.axEventHandler.pendingCreatePlacementContext(for: Int(replacementWindowId)) == nil)
        #expect(relayoutEvents.first?.0 == .appActivationTransition)
        #expect(relayoutEvents.first?.1 == .immediateRelayout)
        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.appActivationTransition] == 1)
        #expect(controller.layoutRefreshController.debugCounters.requestedByReason[.axWindowCreated] == nil)
    }

    @Test @MainActor func nativeFullscreenPresentReplacementDoesNotStealUnrelatedFullscreenWindow() async throws {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing Niri native fullscreen placement fixture")
            return
        }

        controller.enableNiriLayout(
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8053),
            pid: getpid(),
            windowId: 8053,
            to: workspaceId
        )
        let siblingBottomToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8054),
            pid: 80_540,
            windowId: 8054,
            to: workspaceId
        )
        let siblingTopToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8055),
            pid: 80_550,
            windowId: 8055,
            to: workspaceId
        )
        guard let targetEntry = controller.workspaceManager.entry(for: targetToken),
              let engine = controller.niriEngine
        else {
            Issue.record("Missing target native fullscreen entry or Niri engine")
            return
        }

        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root
        engine.ensureMonitor(for: monitor.id, monitor: monitor).workspaceRoots[workspaceId] = root

        let column = NiriContainer()
        column.displayMode = .tabbed
        root.appendChild(column)

        let targetWindow = NiriWindow(token: targetToken)
        let siblingBottomWindow = NiriWindow(token: siblingBottomToken)
        let siblingTopWindow = NiriWindow(token: siblingTopToken)
        column.appendChild(targetWindow)
        column.appendChild(siblingBottomWindow)
        column.appendChild(siblingTopWindow)
        column.setActiveTileIdx(0)
        engine.updateTabbedColumnVisibility(column: column)

        engine.tokenToNode[targetToken] = targetWindow
        engine.tokenToNode[siblingBottomToken] = siblingBottomWindow
        engine.tokenToNode[siblingTopToken] = siblingTopWindow

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: targetWindow.id,
            focusedToken: targetToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = targetWindow.id
            state.activeColumnIndex = 0
            state.viewOffsetPixels = .static(0)
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(targetToken)

        let replacementToken = WindowToken(pid: getpid(), windowId: 8056)
        let restored = controller.axEventHandler.restoreNativeFullscreenReplacementIfNeeded(
            token: replacementToken,
            windowId: 8056,
            axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8056),
            workspaceId: workspaceId,
            appFullscreen: true
        )

        guard let preservedEntry = controller.workspaceManager.entry(for: targetToken),
              let record = controller.workspaceManager.nativeFullscreenRecord(for: targetToken),
              let preservedNode = engine.findNode(for: targetToken),
              let preservedColumn = engine.column(of: preservedNode)
        else {
            Issue.record("Missing preserved native fullscreen placement state")
            return
        }

        #expect(restored == false)
        #expect(controller.workspaceManager.entry(for: replacementToken) == nil)
        #expect(preservedEntry.handle === targetEntry.handle)
        #expect(record.currentToken == targetToken)
        #expect(record.availability == .present)
        if case .suspended = record.transition {} else {
            Issue.record("Expected native fullscreen record to stay suspended")
        }
        #expect(preservedNode.id == targetWindow.id)
        #expect(engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) } == [
            [targetToken, siblingBottomToken, siblingTopToken]
        ])
        #expect(preservedColumn.displayMode == .tabbed)
        #expect(preservedColumn.activeWindow?.token == targetToken)
        #expect(!preservedNode.isHiddenInTabbedMode)
        #expect(siblingBottomWindow.isHiddenInTabbedMode)
        #expect(siblingTopWindow.isHiddenInTabbedMode)
    }

    @Test @MainActor func nativeFullscreenPlaceholderRekeysWithManagedWindowIdentity() {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8045),
            pid: getpid(),
            windowId: 8045,
            to: workspaceId
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: [
                NativeFullscreenPlaceholderUpdate(
                    token: originalToken,
                    workspaceId: workspaceId,
                    frame: CGRect(x: 10, y: 20, width: 400, height: 300),
                    selected: true,
                    appName: "Placeholder Rekey",
                    icon: nil
                )
            ],
            in: workspaceId
        )

        let replacementToken = WindowToken(pid: getpid(), windowId: 8046)
        let replacementWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8046)
        _ = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: originalToken,
            to: replacementToken,
            windowId: 8046,
            axRef: replacementWindow
        )

        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[originalToken] == nil)
        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[replacementToken]?.frame == CGRect(
            x: 10,
            y: 20,
            width: 400,
            height: 300
        ))
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken)?.currentToken == replacementToken)
    }

    @Test @MainActor func resizePlaceholderClearsWithManagedWindowIdentityRekey() async throws {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8055),
            pid: getpid(),
            windowId: 8055,
            to: workspaceId
        )
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken),
              let context = await AppAXContext.makeForTests(processIdentifier: originalToken.pid)
        else {
            Issue.record("Failed to create AX context for resize placeholder rekey test")
            return
        }
        AppAXContext.contexts[originalToken.pid] = context
        try await context.installWindowsForTests([originalEntry.axRef])
        defer {
            AppAXContext.contexts.removeValue(forKey: originalToken.pid)
            context.destroy()
        }

        controller.workspaceManager.setResizePlaceholderState(
            ResizePlaceholderState(
                workspaceId: workspaceId,
                frame: CGRect(x: 10, y: 20, width: 260, height: 180),
                minimumSize: CGSize(width: 520, height: 360)
            ),
            for: originalToken
        )
        controller.resizePlaceholderManager.update(
            ResizePlaceholderUpdate(
                token: originalToken,
                workspaceId: workspaceId,
                frame: CGRect(x: 10, y: 20, width: 260, height: 180),
                selected: true,
                appName: "Resize Placeholder Rekey",
                icon: nil
            )
        )
        controller.axManager.suppressFrameWrites([(originalToken.pid, originalToken.windowId)])
        #expect(context.suppressedFrameWindowIds.contains(originalToken.windowId))

        let replacementToken = WindowToken(pid: getpid(), windowId: 8056)
        let replacementWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8056)
        _ = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: originalToken,
            to: replacementToken,
            windowId: 8056,
            axRef: replacementWindow
        )

        #expect(controller.workspaceManager.resizePlaceholderState(for: originalToken) == nil)
        #expect(controller.workspaceManager.resizePlaceholderState(for: replacementToken) == nil)
        #expect(controller.resizePlaceholderManager.snapshotForTests()[originalToken] == nil)
        #expect(controller.resizePlaceholderManager.snapshotForTests()[replacementToken] == nil)
        #expect(!context.suppressedFrameWindowIds.contains(originalToken.windowId))
        #expect(!context.suppressedFrameWindowIds.contains(replacementToken.windowId))

        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        #expect(relayoutReasons.contains(.axWindowCreated))
    }

    @Test @MainActor func nativeFullscreenPlaceholderPanelStaysOutOfFullscreenSpaces() {
        let controller = makeAXEventTestController()
        NativeFullscreenPlaceholderManager.materializesWindowsForTests = true
        defer {
            controller.nativeFullscreenPlaceholderManager.removeAll()
            NativeFullscreenPlaceholderManager.materializesWindowsForTests = false
            controller.axEventHandler.resetDebugStateForTests()
        }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8052),
            pid: getpid(),
            windowId: 8052,
            to: workspaceId
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: [
                NativeFullscreenPlaceholderUpdate(
                    token: token,
                    workspaceId: workspaceId,
                    frame: CGRect(x: 10, y: 20, width: 400, height: 300),
                    selected: true,
                    appName: "Fullscreen Space Policy",
                    icon: nil
                )
            ],
            in: workspaceId
        )

        guard let behavior = controller.nativeFullscreenPlaceholderManager.collectionBehaviorForTests(token) else {
            Issue.record("Missing materialized native fullscreen placeholder panel")
            return
        }

        #expect(behavior.contains(.managed))
        #expect(behavior.contains(.fullScreenNone))
        #expect(!behavior.contains(.canJoinAllSpaces))
        #expect(!behavior.contains(.fullScreenAuxiliary))
    }

    @Test @MainActor func nativeFullscreenPlaceholderPanelUsesSolidBlackBackground() {
        let controller = makeAXEventTestController()
        NativeFullscreenPlaceholderManager.materializesWindowsForTests = true
        defer {
            controller.nativeFullscreenPlaceholderManager.removeAll()
            NativeFullscreenPlaceholderManager.materializesWindowsForTests = false
            controller.axEventHandler.resetDebugStateForTests()
        }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8056),
            pid: getpid(),
            windowId: 8056,
            to: workspaceId
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: [
                NativeFullscreenPlaceholderUpdate(
                    token: token,
                    workspaceId: workspaceId,
                    frame: CGRect(x: 10, y: 20, width: 400, height: 300),
                    selected: true,
                    appName: "Solid Background",
                    icon: nil
                )
            ],
            in: workspaceId
        )

        guard let appearance = controller.nativeFullscreenPlaceholderManager.appearanceForTests(token),
              let windowColor = appearance.backgroundColor?.usingColorSpace(.deviceRGB),
              let contentColor = appearance.contentBackgroundColor?.usingColorSpace(.deviceRGB)
        else {
            Issue.record("Missing materialized native fullscreen placeholder appearance")
            return
        }

        #expect(appearance.isOpaque)
        #expect(windowColor.alphaComponent == 1)
        #expect(windowColor.redComponent == 0)
        #expect(windowColor.greenComponent == 0)
        #expect(windowColor.blueComponent == 0)
        #expect(contentColor.alphaComponent == 1)
        #expect(contentColor.redComponent == 0)
        #expect(contentColor.greenComponent == 0)
        #expect(contentColor.blueComponent == 0)
    }

    @Test @MainActor func nativeFullscreenPlaceholderCreateEventIsSkippedAsOwnedWindow() async {
        let controller = makeAXEventTestController()
        NativeFullscreenPlaceholderManager.materializesWindowsForTests = true
        defer {
            controller.nativeFullscreenPlaceholderManager.removeAll()
            NativeFullscreenPlaceholderManager.materializesWindowsForTests = false
            controller.axEventHandler.resetDebugStateForTests()
        }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8060),
            pid: getpid(),
            windowId: 8060,
            to: workspaceId
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        let frame = CGRect(x: 10, y: 20, width: 400, height: 300)
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: [
                NativeFullscreenPlaceholderUpdate(
                    token: token,
                    workspaceId: workspaceId,
                    frame: frame,
                    selected: true,
                    appName: "Owned Create",
                    icon: nil
                )
            ],
            in: workspaceId
        )
        guard let windowNumber = controller.nativeFullscreenPlaceholderManager.windowNumberForTests(token),
              let windowId = UInt32(exactly: windowNumber)
        else {
            Issue.record("Missing materialized native fullscreen placeholder window number")
            return
        }

        let tokensBefore = Set(controller.workspaceManager.entries(forPid: getpid()).map(\.token))
        var subscriptions: [[UInt32]] = []
        controller.axEventHandler.windowInfoProvider = { candidateWindowId in
            guard candidateWindowId == windowId else { return nil }
            return WindowServerInfo(id: candidateWindowId, pid: getpid(), level: 0, frame: frame)
        }
        controller.axEventHandler.axWindowRefProvider = { candidateWindowId, _ in
            guard candidateWindowId == windowId else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(candidateWindowId))
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
            didReceive: .created(windowId: windowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let tokensAfter = Set(controller.workspaceManager.entries(forPid: getpid()).map(\.token))
        #expect(tokensAfter == tokensBefore)
        #expect(subscriptions.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
    }

    @Test @MainActor func nativeFullscreenRestoreAndDestroyRemovePlaceholderSnapshot() {
        let controller = makeAXEventTestController()
        defer { controller.axEventHandler.resetDebugStateForTests() }
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let restoredToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8047),
            pid: getpid(),
            windowId: 8047,
            to: workspaceId
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(restoredToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(restoredToken)
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: [
                NativeFullscreenPlaceholderUpdate(
                    token: restoredToken,
                    workspaceId: workspaceId,
                    frame: CGRect(x: 30, y: 40, width: 420, height: 320),
                    selected: true,
                    appName: "Placeholder Restore",
                    icon: nil
                )
            ],
            in: workspaceId
        )
        guard let restoredEntry = controller.workspaceManager.entry(for: restoredToken) else {
            Issue.record("Missing native fullscreen restore entry")
            return
        }

        controller.axEventHandler.handleManagedAppActivation(
            entry: restoredEntry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[restoredToken] == nil)
        #expect(controller.workspaceManager.layoutReason(for: restoredToken) == .standard)

        let removedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8048),
            pid: getpid(),
            windowId: 8048,
            to: workspaceId
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(removedToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(removedToken)
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: [
                NativeFullscreenPlaceholderUpdate(
                    token: removedToken,
                    workspaceId: workspaceId,
                    frame: CGRect(x: 50, y: 60, width: 440, height: 340),
                    selected: false,
                    appName: "Placeholder Destroy",
                    icon: nil
                )
            ],
            in: workspaceId
        )

        controller.axEventHandler.handleRemoved(token: removedToken)

        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[removedToken] == nil)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: removedToken)?.availability == .temporarilyUnavailable)
    }

    @Test @MainActor func workspaceDidActivateApplicationRevealsRestoredManagedWindowOnInactiveWorkspace() {
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

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceTwo)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
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

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing replacement entry after restored activation")
            return
        }

        #expect(controller.activeWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.focusedToken == replacementToken)
        #expect(controller.workspaceManager.pendingFocusedToken == nil)
        #expect(controller.workspaceManager.lastFocusedToken(in: workspaceTwo) == replacementToken)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
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
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 811,
                 812:
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
        await withCGSEventObserverIsolationForTests {
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
            #expect(controller.axEventHandler.debugCounters.scopedGeometryRelayoutRequests == 1)
            #expect(
                controller.layoutRefreshController.refreshDebugSnapshot()
                    .lastAffectedWorkspaceIdsByReason[.axWindowChanged] == [workspaceId]
            )
        }
    }

    @Test @MainActor func focusedFrameChangedUsesDirectBorderUpdateAndKeepsRelayout() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 819),
            pid: getpid(),
            windowId: 819,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let observedFrame = CGRect(x: 24, y: 24, width: 640, height: 480)
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(on: controller, token: handle, frame: observedFrame)
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.focusBorderController.suppressNextRenderForTests = nil
        }

        var capturedTarget: WindowToken?
        controller.focusBorderController.suppressNextRenderForTests = { target in
            capturedTarget = target.token
            return false
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 819)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(capturedTarget == handle)
        #expect(relayoutReasons == [.axWindowChanged])
        #expect(lastAppliedBorderWindowId(on: controller) == 819)
        #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
    }

    @Test @MainActor func unmanagedFocusedFrameChangedUpdatesBorderWithoutRelayout() async {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 42_424, windowId: 821)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        let initialFrame = CGRect(x: 12, y: 14, width: 500, height: 320)
        let observedFrame = CGRect(x: 80, y: 96, width: 640, height: 400)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: initialFrame,
            preferredFrameSource: .observed,
            forceOrdering: true
        )
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: .zero)
        }
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(token.windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
    }

    @Test @MainActor func unresolvedFocusedFrameChangedDoesNotUseWindowIdFallbackForBorder() async {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 42_425, windowId: 822)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        let initialFrame = CGRect(x: 12, y: 14, width: 500, height: 320)
        let observedFrame = CGRect(x: 80, y: 96, width: 640, height: 400)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: initialFrame,
            preferredFrameSource: .observed,
            forceOrdering: true
        )
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = true
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = false
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(token.windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == initialFrame)
    }

    @Test @MainActor func unresolvedFocusedFrameChangedUsesFocusedAXConfirmationForUnmanagedBorder() async {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 42_426, windowId: 8242)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        let initialFrame = CGRect(x: 12, y: 14, width: 500, height: 320)
        let observedFrame = CGRect(x: 80, y: 96, width: 640, height: 400)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: initialFrame,
            preferredFrameSource: .observed,
            forceOrdering: true
        )
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == token.pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = true
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.focusedWindowRefProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = false
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(token.windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
    }

    @Test @MainActor func unresolvedFocusedFrameChangedRejectsDifferentFocusedAXTokenForUnmanagedBorder() async {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 42_427, windowId: 8243)
        let otherToken = WindowToken(pid: token.pid, windowId: 8244)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        let initialFrame = CGRect(x: 12, y: 14, width: 500, height: 320)
        let observedFrame = CGRect(x: 80, y: 96, width: 640, height: 400)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: initialFrame,
            preferredFrameSource: .observed,
            forceOrdering: true
        )
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == token.pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: otherToken.windowId)
        }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = true
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.focusedWindowRefProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = false
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(token.windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == initialFrame)
    }

    @Test @MainActor func unresolvedManagedFrameChangedDoesNotUseTrackedWindowIdFallbackForBorder() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 823),
            pid: getpid(),
            windowId: 823,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        let initialFrame = CGRect(x: 12, y: 14, width: 500, height: 320)
        let observedFrame = CGRect(x: 80, y: 96, width: 640, height: 400)
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(on: controller, token: token, frame: initialFrame)
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = true
        controller.mouseEventHandler.state.isResizing = true
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = false
            controller.mouseEventHandler.state.isResizing = false
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(token.windowId))
        )

        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedDuringGesture == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == initialFrame)
    }

    @Test @MainActor func unresolvedManagedFloatingFrameChangedUsesUniqueTrackedFallbackForBorderAndGeometry() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8245),
            pid: getpid(),
            windowId: 8245,
            to: workspaceId,
            mode: .floating
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        let initialFrame = CGRect(x: 12, y: 14, width: 500, height: 320)
        let observedFrame = CGRect(x: 80, y: 96, width: 640, height: 400)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: initialFrame,
                normalizedOrigin: nil,
                referenceMonitorId: controller.workspaceManager.monitorId(for: workspaceId),
                restoreToFloating: true
            ),
            for: token
        )
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(on: controller, token: token, frame: initialFrame)
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = true
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = false
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(token.windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
        #expect(controller.workspaceManager.floatingState(for: token)?.lastFrame == observedFrame)
    }

    @Test @MainActor func unresolvedManagedFloatingFrameChangedRejectsAmbiguousTrackedFallback() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let windowId = 8246
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId),
            pid: 42_428,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let focusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId),
            pid: 42_429,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        _ = controller.workspaceManager.setManagedFocus(
            focusedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        let initialFrame = CGRect(x: 12, y: 14, width: 500, height: 320)
        let observedFrame = CGRect(x: 80, y: 96, width: 640, height: 400)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: initialFrame,
                normalizedOrigin: nil,
                referenceMonitorId: controller.workspaceManager.monitorId(for: workspaceId),
                restoreToFloating: true
            ),
            for: focusedToken
        )
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(on: controller, token: focusedToken, frame: initialFrame)
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = true
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
            controller.axEventHandler.windowInfoProviderIsAuthoritativeForTests = false
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: UInt32(windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(lastAppliedBorderWindowId(on: controller) == focusedToken.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == initialFrame)
        #expect(controller.workspaceManager.floatingState(for: focusedToken)?.lastFrame == initialFrame)
    }

    @Test @MainActor func focusedFrameChangedWithPendingWriteSkipsObservedReadForBorder() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 820),
            pid: getpid(),
            windowId: 820,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            makeManagedReplacementMetadata(workspaceId: workspaceId),
            for: handle
        )

        let pendingFrame = CGRect(x: 32, y: 32, width: 640, height: 480)
        controller.axManager.frameApplyOverrideForTests = { _ in [] }
        controller.axManager.applyFramesParallel([(getpid(), 820, pendingFrame)])
        var observedReadCount = 0
        controller.axEventHandler.frameProvider = { _ in
            observedReadCount += 1
            return CGRect(x: 96, y: 96, width: 500, height: 400)
        }
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(on: controller, token: handle, frame: pendingFrame)
        defer {
            controller.axManager.frameApplyOverrideForTests = nil
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
            didReceive: .frameChanged(windowId: 820)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(observedReadCount == 0)
        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedForOwnFrameWrites == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == 820)
        #expect(lastAppliedBorderFrame(on: controller) == pendingFrame)
    }

    @Test @MainActor func nonFocusedFrameChangedWithPendingWriteDoesNotRelayout() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let focusedHandle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 824),
            pid: getpid(),
            windowId: 824,
            to: workspaceId
        )
        let targetHandle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 825),
            pid: getpid(),
            windowId: 825,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            focusedHandle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let pendingFrame = CGRect(x: 48, y: 64, width: 700, height: 460)
        controller.axManager.frameApplyOverrideForTests = { _ in [] }
        controller.axManager.applyFramesParallel([(targetHandle.pid, targetHandle.windowId, pendingFrame)])
        defer { controller.axManager.frameApplyOverrideForTests = nil }

        var observedReadCount = 0
        controller.axEventHandler.frameProvider = { _ in
            observedReadCount += 1
            return CGRect(x: 96, y: 96, width: 500, height: 400)
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
            didReceive: .frameChanged(windowId: UInt32(targetHandle.windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(observedReadCount == 0)
        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedForOwnFrameWrites == 1)
    }

    @Test @MainActor func nonFocusedFrameChangedMatchingLastAppliedFrameDoesNotRelayout() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let focusedHandle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 826),
            pid: getpid(),
            windowId: 826,
            to: workspaceId
        )
        let targetHandle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 827),
            pid: getpid(),
            windowId: 827,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            focusedHandle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let appliedFrame = CGRect(x: 52, y: 72, width: 710, height: 470)
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: AXFrameWriteResult(
                        targetFrame: request.frame,
                        observedFrame: request.frame,
                        writeOrder: AXWindowService.frameWriteOrder(
                            currentFrame: request.currentFrameHint,
                            targetFrame: request.frame
                        ),
                        sizeError: .success,
                        positionError: .success,
                        failureReason: nil
                    )
                )
            }
        }
        controller.axManager.applyFramesParallel([(targetHandle.pid, targetHandle.windowId, appliedFrame)])
        defer { controller.axManager.frameApplyOverrideForTests = nil }

        var observedReadCount = 0
        controller.axEventHandler.frameProvider = { _ in
            observedReadCount += 1
            return appliedFrame
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
            didReceive: .frameChanged(windowId: UInt32(targetHandle.windowId))
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(observedReadCount == 1)
        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedForOwnFrameWrites == 1)
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
        await withCGSEventObserverIsolationForTests {
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

            let initialFrame = CGRect(x: 8, y: 8, width: 500, height: 360)
            let observedFrame = CGRect(x: 20, y: 20, width: 640, height: 480)
            controller.axEventHandler.frameProvider = { _ in observedFrame }
            controller.axEventHandler.windowInfoProvider = { windowId in
                WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
            }
            controller.setBordersEnabled(true)
            _ = confirmFocusedBorder(
                on: controller,
                token: handle,
                frame: initialFrame
            )
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
                controller.axEventHandler.windowInfoProvider = nil
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
            #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
        }
    }

    @Test @MainActor func committedViewportGestureSuppressesFrameChangedRelayout() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 817),
            pid: getpid(),
            windowId: 817,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let initialFrame = CGRect(x: 8, y: 8, width: 500, height: 360)
        let observedFrame = CGRect(x: 20, y: 20, width: 640, height: 480)
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: handle,
            frame: initialFrame
        )
        controller.mouseEventHandler.state.gesturePhase = .committed
        controller.axEventHandler.resetDebugStateForTests()
        defer {
            controller.mouseEventHandler.state.gesturePhase = .idle
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 817)
        )

        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedDuringGesture == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == 817)
        #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
    }

    @Test @MainActor func niriScrollAnimationSuppressesFrameChangedRelayout() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing active workspace")
            return
        }

        let handle = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 818),
            pid: getpid(),
            windowId: 818,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let initialFrame = CGRect(x: 12, y: 12, width: 500, height: 360)
        let observedFrame = CGRect(x: 24, y: 24, width: 640, height: 480)
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: handle,
            frame: initialFrame
        )
        controller.axEventHandler.resetDebugStateForTests()
        #expect(controller.niriLayoutHandler.registerScrollAnimation(workspaceId, on: monitor.displayId))
        defer {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowInfoProvider = nil
        }

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 818)
        )

        #expect(relayoutReasons.isEmpty)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutRequests == 0)
        #expect(controller.axEventHandler.debugCounters.geometryRelayoutsSuppressedDuringGesture == 1)
        #expect(lastAppliedBorderWindowId(on: controller) == 818)
        #expect(lastAppliedBorderFrame(on: controller) == observedFrame)
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

        let initialFrame = CGRect(x: 12, y: 12, width: 500, height: 360)
        let fastFrame = CGRect(x: 48, y: 36, width: 620, height: 420)
        controller.axEventHandler.fastFrameProvider = { _ in fastFrame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: handle,
            frame: initialFrame
        )
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
        #expect(lastAppliedBorderFrame(on: controller) == fastFrame)
    }

    @Test @MainActor func deferredCreatedWindowsReplayOnceUsingFreshMonitorWorkspaceWhenDiscoveryEnds() async {
        let controller = makeAXEventTestController()
        guard let monitor = controller.monitorForInteraction(),
              let laterWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
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
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 19 ? monitor.displayId : nil
        }

        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = true
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 821, spaceId: 19)
        )
        #expect(controller.workspaceManager.setActiveWorkspace(laterWorkspaceId, on: monitor.id))
        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = false

        await controller.axEventHandler.drainDeferredCreatedWindows()
        await controller.axEventHandler.drainDeferredCreatedWindows()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 821)?.workspaceId == laterWorkspaceId)
        #expect(controller.workspaceManager.allEntries().filter { $0.windowId == 821 }.count == 1)
        #expect(subscriptions == [[821]])
    }

    @Test @MainActor func deferredCreatedWindowRetriesWhenWindowServerInfoIsUnavailableDuringDrain() async {
        let controller = makeAXEventTestController()
        guard let monitor = controller.monitorForInteraction(),
              let laterWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing active workspace")
            return
        }

        var subscriptions: [[UInt32]] = []
        var windowInfoReady = false
        var windowInfoLookupCount = 0
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 840 else { return nil }
            windowInfoLookupCount += 1
            guard windowInfoReady else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == 840 else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.deferred-info-retry")
        }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 20 ? monitor.displayId : nil
        }

        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = true
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 840, spaceId: 20)
        )
        #expect(controller.workspaceManager.setActiveWorkspace(laterWorkspaceId, on: monitor.id))
        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = false

        await controller.axEventHandler.drainDeferredCreatedWindows()
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 840) == nil)
        #expect(controller.axEventHandler.pendingCreatePlacementContext(for: 840) != nil)
        #expect(subscriptions.isEmpty)

        windowInfoReady = true
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 840) != nil
        }

        #expect(windowInfoLookupCount >= 2)
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 840)?.workspaceId == laterWorkspaceId)
        #expect(controller.workspaceManager.allEntries().filter { $0.windowId == 840 }.count == 1)
        #expect(subscriptions == [[840]])
        #expect(controller.axEventHandler.pendingCreatePlacementContext(for: 840) == nil)
    }

    @Test @MainActor func fullRescanUsesPendingCreateMonitorForUntrackedWindow() async {
        let controller = makeAXEventTestController()
        defer { controller.axManager.fullRescanEnumerationOverrideForTests = nil }
        guard let monitor = controller.monitorForInteraction(),
              let createWorkspaceId = controller.activeWorkspace()?.id,
              let laterWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace fixture")
            return
        }

        let parentWindowId = 818
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: parentWindowId),
            pid: getpid(),
            windowId: parentWindowId,
            to: createWorkspaceId
        )
        let windowId: UInt32 = 819
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        let windowInfo = makeAXEventWindowInfo(
            id: windowId,
            pid: getpid(),
            frame: .zero,
            parentId: UInt32(parentWindowId)
        )
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(
                windows: [(axRef, getpid(), Int(windowId))],
                failedPIDs: []
            )
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.full-rescan-origin",
                windowServer: windowInfo
            )
        }
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 17 ? monitor.displayId : nil
        }

        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = true
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: windowId, spaceId: 17)
        )
        controller.layoutRefreshController.layoutState.isFullEnumerationInProgress = false
        #expect(controller.workspaceManager.setActiveWorkspace(laterWorkspaceId, on: monitor.id))

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: Int(windowId)) != nil
        }

        #expect(controller.activeWorkspace()?.id == laterWorkspaceId)
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: Int(windowId))?
            .workspaceId == laterWorkspaceId)
        #expect(controller.axEventHandler.pendingCreatePlacementContext(for: Int(windowId)) == nil)
    }

    @Test @MainActor func fullRescanRekeysStructuralReplacementOntoOldWorkspace() async {
        let bundleId = currentTestBundleId()
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", monitorAssignment: .main)
            ]
        )
        defer { controller.axManager.fullRescanEnumerationOverrideForTests = nil }
        guard let replacementWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing replacement workspace")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 848,
            title: "repo - shell",
            frame: CGRect(x: 90, y: 120, width: 840, height: 620),
            parentId: 92
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 849,
            title: "repo - shell (replacement)",
            frame: oldInfo.frame,
            parentId: 92
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 848),
            pid: getpid(),
            windowId: 848,
            to: replacementWorkspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: replacementWorkspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )
        let replacementAXRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 849)
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(
                windows: [(replacementAXRef, getpid(), 849)],
                failedPIDs: []
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            switch axRef.windowId {
            case 849:
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    title: replacementInfo.title,
                    windowServer: replacementInfo
                )
            default:
                makeAXEventWindowRuleFacts(bundleId: bundleId)
            }
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 849) != nil
        }

        let replacementToken = WindowToken(pid: getpid(), windowId: 849)
        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(controller.workspaceManager.entry(for: replacementToken)?.workspaceId == replacementWorkspaceId)
    }

    @Test @MainActor func fullRescanUsesFrameMonitorWhenInteractionMonitorIsStale() async {
        let controller = makeAXEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        defer {
            controller.axManager.fullRescanEnumerationOverrideForTests = nil
        }
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
        #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

        let windowId = 820
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
        let windowInfo = makeAXEventWindowInfo(
            id: UInt32(windowId),
            pid: getpid(),
            frame: CGRect(
                x: secondaryMonitor.visibleFrame.minX + 120,
                y: secondaryMonitor.visibleFrame.minY + 120,
                width: 640,
                height: 420
            )
        )
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(
                windows: [(axRef, getpid(), windowId)],
                failedPIDs: []
            )
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.frame-monitor",
                windowServer: windowInfo
            )
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: windowId) != nil
        }

        #expect(controller.activeWorkspace()?.id == primaryWorkspaceId)
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: windowId)?
            .workspaceId == secondaryWorkspaceId)
    }

    @Test @MainActor func ghosttyReplacementRekeysManagedWindowWhenTabTitleChanges() async {
        let controller = makeAXEventTestController(trackedBundleId: currentTestBundleId())
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        controller.enableNiriLayout()
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
        controller.focusBorderController.observedFrameProviderForTests = { axRef in
            axRef.windowId == 842 ? observedFrame : nil
        }
        defer {
            controller.focusBorderController.observedFrameProviderForTests = nil
        }
        _ = confirmFocusedBorder(on: controller, token: oldToken, frame: plannedFrame)

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

        controller.enableNiriLayout()
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

        controller.enableNiriLayout()
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
        let matchedElapsedMillis = structuralManagedReplacementMatchedElapsedMillis(on: controller) ?? .max
        #expect(matchedElapsedMillis >= 130)
        #expect(matchedElapsedMillis < 200)
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
        let matchedElapsedMillis = structuralManagedReplacementMatchedElapsedMillis(on: controller) ?? .max
        #expect(matchedElapsedMillis >= 130)
        #expect(matchedElapsedMillis < 200)
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

        let flushElapsedMillis = structuralManagedReplacementFlushElapsedMillis(on: controller)
        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(flushElapsedMillis.count == 1)
        #expect((flushElapsedMillis.first ?? 0) >= 130)
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
              let siblingEntry = controller.workspaceManager.entry(for: siblingToken)
        else {
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
        #expect(structuralManagedReplacementMatchedElapsedMillis(on: controller) == nil)
        let flushElapsedMillis = structuralManagedReplacementFlushElapsedMillis(on: controller)
        #expect((flushElapsedMillis.last ?? 0) >= 130)
        #expect((flushElapsedMillis.last ?? .max) < 200)
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
              let monitor = controller.workspaceManager.monitors.first
        else {
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
              let replacementLeaf = engine.findNode(for: replacementToken)
        else {
            Issue.record("Missing replacement Dwindle Ghostty state")
            return
        }

        let updatedFrames = engine.calculateLayout(for: workspaceId, screen: monitor.frame)
        guard let updatedGhosttyFrame = updatedFrames[replacementToken],
              let updatedRightFrame = updatedFrames[rightToken]
        else {
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
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Missing Niri workspace setup")
            return
        }

        controller.enableNiriLayout()
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
            parentId: UInt32(oldToken.windowId)
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
              let updatedRightFrame = updatedFrames[rightToken]
        else {
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
              let monitor = controller.workspaceManager.monitors.first
        else {
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
            parentId: UInt32(oldToken.windowId)
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
              let updatedRightLeaf = engine.findNode(for: rightToken)
        else {
            Issue.record("Missing replacement Dwindle Ghostty state")
            return
        }

        let updatedFrames = engine.calculateLayout(for: workspaceId, screen: monitor.frame)
        guard let updatedGhosttyFrame = updatedFrames[replacementToken],
              let updatedRightFrame = updatedFrames[rightToken]
        else {
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

        controller.enableNiriLayout()
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
              let siblingEntry = controller.workspaceManager.entry(for: siblingToken)
        else {
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

        controller.enableNiriLayout()
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

        controller.enableNiriLayout()
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
            case 848,
                 849,
                 850:
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

        controller.enableNiriLayout()
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

    @Test @MainActor func structuralReplacementRekeysParentlessNativeTabWithCloseFrame() async {
        let bundleId = "com.example.parentless-native-tabs"
        let controller = makeAXEventTestController(trackedBundleId: bundleId)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 894),
            pid: getpid(),
            windowId: 894,
            to: workspaceId
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing parentless native-tab source entry")
            return
        }

        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil, focusedToken: oldToken)
        let oldInfo = makeAXEventWindowInfo(
            id: 894,
            title: "Finder",
            frame: CGRect(x: 80, y: 80, width: 900, height: 640)
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 895,
            title: "Finder",
            frame: CGRect(x: 104, y: 92, width: 900, height: 640)
        )
        oldEntry.managedReplacementMetadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            title: oldInfo.title,
            windowServer: oldInfo
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 894:
                oldInfo
            case 895:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info = axRef.windowId == 895 ? replacementInfo : oldInfo
            return makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: info.title,
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 894, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 895, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 895)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing parentless replacement entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle === oldEntry.handle)
        #expect(engine.findNode(for: replacementToken)?.id == oldNode.id)
    }

    @Test @MainActor func structuralReplacementDoesNotRekeyParentlessNativeTabWithFarFrame() async {
        let bundleId = "com.example.parentless-native-tabs-far"
        let controller = makeAXEventTestController(trackedBundleId: bundleId)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 896),
            pid: getpid(),
            windowId: 896,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                title: "Finder",
                windowServer: makeAXEventWindowInfo(
                    id: 896,
                    title: "Finder",
                    frame: CGRect(x: 80, y: 80, width: 900, height: 640)
                )
            )
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing parentless far-frame source entry")
            return
        }

        let replacementInfo = makeAXEventWindowInfo(
            id: 897,
            title: "Finder",
            frame: CGRect(x: 520, y: 420, width: 900, height: 640)
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 896:
                makeAXEventWindowInfo(
                    id: 896,
                    title: "Finder",
                    frame: CGRect(x: 80, y: 80, width: 900, height: 640)
                )
            case 897:
                replacementInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info = axRef.windowId == 897 ? replacementInfo : makeAXEventWindowInfo(
                id: 896,
                title: "Finder",
                frame: CGRect(x: 80, y: 80, width: 900, height: 640)
            )
            return makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: info.title,
                windowServer: info
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 896, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 897, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 897)
        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken) else {
            Issue.record("Missing far-frame replacement entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(replacementEntry.handle !== oldEntry.handle)
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
        #expect(structuralManagedReplacementMatchedElapsedMillis(on: controller) == nil)
        #expect(managedReplacementTraceEvents(on: controller).isEmpty)
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

    @Test @MainActor func createdWindowUsesNativeDisplayMonitorWhenInteractionMonitorIsStale() async {
        let controller = makeAXEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
        #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

        let createdWindowId: UInt32 = 843
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 88 ? secondaryMonitor.displayId : nil
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.native-space")
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 88)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId))?
            .workspaceId == secondaryWorkspaceId)
    }

    @Test @MainActor func createdWindowUsesNativeDisplayBeforeStaleWindowServerFrame() async {
        let bundleId = "com.example.native-before-window-frame"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "1")
            ]
        )

        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
        #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

        let pid = getpid()
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8431),
            pid: pid,
            windowId: 8431,
            to: primaryWorkspaceId
        )
        #expect(controller.workspaceManager.entry(for: siblingToken)?.workspaceId == primaryWorkspaceId)

        let createdWindowId: UInt32 = 8432
        let createdInfo = makeAXEventWindowInfo(
            id: createdWindowId,
            pid: pid,
            frame: CGRect(
                x: primaryMonitor.visibleFrame.minX + 120,
                y: primaryMonitor.visibleFrame.minY + 100,
                width: 640,
                height: 420
            )
        )
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 881 ? secondaryMonitor.displayId : nil
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return createdInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                windowServer: createdInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 881)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
            .workspaceId == secondaryWorkspaceId)
    }

    @Test @MainActor func createdWindowUsesNativeDisplayBeforeStaleFastFrame() async {
        await withAXFrameProviderIsolationForTests {
            let bundleId = "com.example.native-before-fast-frame"
            let controller = makeAXEventTestController(
                trackedBundleId: bundleId,
                workspaceConfigurations: [
                    WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                    WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
                ]
            )
            let primaryMonitor = makeAXEventTestMonitor()
            let secondaryMonitor = makeAXEventSecondaryMonitor()
            controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
            controller.windowRuleEngine.rebuild(
                rules: [
                    AppRule(bundleId: bundleId, assignToWorkspace: "1")
                ]
            )

            guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
                  let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
            else {
                Issue.record("Missing multi-monitor workspace fixture")
                return
            }

            #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
            #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
            #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

            let createdWindowId: UInt32 = 8433
            let createdInfo = makeAXEventWindowInfo(id: createdWindowId, pid: getpid(), frame: .zero)
            AXWindowService.fastFrameProviderForTests = { axRef in
                guard axRef.windowId == Int(createdWindowId) else { return nil }
                return CGRect(
                    x: primaryMonitor.visibleFrame.minX + 120,
                    y: primaryMonitor.visibleFrame.minY + 100,
                    width: 640,
                    height: 420
                )
            }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
                spaceId == 882 ? secondaryMonitor.displayId : nil
            }
            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == createdWindowId else { return nil }
                return createdInfo
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
                guard windowId == createdWindowId, candidatePid == getpid() else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    windowServer: createdInfo
                )
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: createdWindowId, spaceId: 882)
            )
            await waitUntilAXEventTest {
                controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId)) != nil
            }

            #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId))?
                .workspaceId == secondaryWorkspaceId)
        }
    }

    @Test @MainActor func fallbackWorkspaceDoesNotConstrainSameAppSiblingPlacement() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeAXEventTestController(
                workspaceConfigurations: [
                    WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                    WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
                ]
            )
            let primaryMonitor = makeAXEventTestMonitor()
            let secondaryMonitor = makeAXEventSecondaryMonitor()
            controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
                  let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
            else {
                Issue.record("Missing multi-monitor workspace fixture")
                return
            }

            #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
            #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))

            let pid = getpid()
            let siblingToken = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8434),
                pid: pid,
                windowId: 8434,
                to: secondaryWorkspaceId
            )
            #expect(controller.workspaceManager.setManagedFocus(
                siblingToken,
                in: secondaryWorkspaceId,
                onMonitor: secondaryMonitor.id
            ))

            let resolvedWorkspaceId = controller.resolveWorkspaceForNewWindow(
                workspaceName: "1",
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8435),
                pid: pid,
                preferSameAppSiblingWorkspace: true,
                createPlacementContext: nil,
                windowFrame: nil,
                fallbackWorkspaceId: primaryWorkspaceId
            )

            #expect(resolvedWorkspaceId == secondaryWorkspaceId)
        }
    }

    @Test @MainActor func createdStandardWindowOnSecondaryMonitorIgnoresCrossMonitorSiblingAndRule() async {
        let bundleId = "com.example.cross-monitor-sibling-rule"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "1")
            ]
        )

        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))

        let pid = getpid()
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 846),
            pid: pid,
            windowId: 846,
            to: primaryWorkspaceId
        )
        #expect(controller.workspaceManager.entry(for: siblingToken)?.workspaceId == primaryWorkspaceId)
        _ = controller.workspaceManager.setInteractionMonitor(secondaryMonitor.id)
        #expect(controller.workspaceManager.interactionMonitorId == secondaryMonitor.id)

        let createdWindowId: UInt32 = 847
        var createdInfo = makeAXEventWindowInfo(
            id: createdWindowId,
            pid: pid,
            frame: .zero,
            parentId: UInt32(siblingToken.windowId)
        )
        createdInfo.tags = 0x1
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 92 ? secondaryMonitor.displayId : nil
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return createdInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: "Secondary document",
                windowServer: createdInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 92)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
            .workspaceId == secondaryWorkspaceId)
    }

    @Test @MainActor func createdWindowUsesFreshMonitorWorkspaceWhenNativeDisplayResolutionSawStaleWorkspace() async {
        let controller = makeAXEventTestController()
        let monitor = makeAXEventTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let staleWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let freshWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(staleWorkspaceId, on: monitor.id))

        let createdWindowId: UInt32 = 896
        var refreshedWorkspaceBeforeAdmission = false
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 90 ? monitor.displayId : nil
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            refreshedWorkspaceBeforeAdmission = controller.workspaceManager.setActiveWorkspace(
                freshWorkspaceId,
                on: monitor.id
            )
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.native-display-fresh-workspace")
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 90)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId)) != nil
        }

        #expect(refreshedWorkspaceBeforeAdmission)
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId))?
            .workspaceId == freshWorkspaceId)
    }

    @Test @MainActor func createdWindowUsesFreshInteractionWorkspaceWhenNativeSpaceIsUnresolved() async {
        let controller = makeAXEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let freshPrimaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
        #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

        let createdWindowId: UInt32 = 895
        controller.axEventHandler.spaceDisplayResolver = { _, _ in nil }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            _ = controller.workspaceManager.setActiveWorkspace(freshPrimaryWorkspaceId, on: primaryMonitor.id)
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == getpid() else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: "com.example.native-space-fallback")
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 89)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: Int(createdWindowId))?
            .workspaceId == freshPrimaryWorkspaceId)
    }

    @Test @MainActor
    func createdWindowUsesSecondaryInteractionMonitorWhenNativeSpaceAndFrameAreUnavailable() async {
        let bundleId = "com.example.secondary-interaction-fallback"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "1")
            ]
        )

        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
        let pid = getpid()
        _ = controller.workspaceManager.setInteractionMonitor(secondaryMonitor.id)

        let createdWindowId: UInt32 = 8301
        let createdInfo = makeAXEventWindowInfo(id: createdWindowId, pid: pid, frame: .zero)
        controller.axEventHandler.spaceDisplayResolver = { _, _ in nil }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return createdInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                windowServer: createdInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 94)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
            .workspaceId == secondaryWorkspaceId)
    }

    @Test @MainActor
    func createdWindowUsesFocusedMonitorBeforeStaleInteractionWhenNativeSpaceAndFrameAreUnavailable() async {
        await withAXFrameProviderIsolationForTests {
            let bundleId = "com.example.focused-monitor-placement"
            let controller = makeAXEventTestController(
                trackedBundleId: bundleId,
                workspaceConfigurations: [
                    WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                    WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
                ]
            )
            let primaryMonitor = makeAXEventTestMonitor()
            let secondaryMonitor = makeAXEventSecondaryMonitor()
            controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
            controller.windowRuleEngine.rebuild(
                rules: [
                    AppRule(bundleId: bundleId, assignToWorkspace: "1")
                ]
            )
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
                  let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
            else {
                Issue.record("Missing multi-monitor workspace fixture")
                return
            }

            #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
            #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))

            let pid = getpid()
            let focusedToken = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8302),
                pid: pid,
                windowId: 8302,
                to: secondaryWorkspaceId
            )
            #expect(controller.workspaceManager.setManagedFocus(
                focusedToken,
                in: secondaryWorkspaceId,
                onMonitor: secondaryMonitor.id
            ))
            #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

            let createdWindowId: UInt32 = 8303
            let createdInfo = makeAXEventWindowInfo(id: createdWindowId, pid: pid, frame: .zero)
            controller.axEventHandler.spaceDisplayResolver = { _, _ in nil }
            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == createdWindowId else { return nil }
                return createdInfo
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
                guard windowId == createdWindowId, candidatePid == pid else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    windowServer: createdInfo
                )
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: createdWindowId, spaceId: 97)
            )
            await waitUntilAXEventTest {
                controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
            }

            #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
                .workspaceId == secondaryWorkspaceId)
        }
    }

    @Test @MainActor
    func createdWindowUsesPendingFocusedWorkspaceBeforeConfirmedFocusAndStaleInteraction() async {
        await withAXFrameProviderIsolationForTests {
            let bundleId = "com.example.pending-focus-placement"
            let controller = makeAXEventTestController(
                trackedBundleId: bundleId,
                workspaceConfigurations: [
                    WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                    WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
                ]
            )
            let primaryMonitor = makeAXEventTestMonitor()
            let secondaryMonitor = makeAXEventSecondaryMonitor()
            controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
            controller.windowRuleEngine.rebuild(
                rules: [
                    AppRule(bundleId: bundleId, assignToWorkspace: "1")
                ]
            )
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
                  let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
            else {
                Issue.record("Missing multi-monitor workspace fixture")
                return
            }

            #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
            #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))

            let pid = getpid()
            let primaryToken = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8304),
                pid: pid,
                windowId: 8304,
                to: primaryWorkspaceId
            )
            let secondaryToken = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8305),
                pid: pid,
                windowId: 8305,
                to: secondaryWorkspaceId
            )
            #expect(controller.workspaceManager.setManagedFocus(
                primaryToken,
                in: primaryWorkspaceId,
                onMonitor: primaryMonitor.id
            ))
            _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)
            #expect(controller.workspaceManager.interactionMonitorId == primaryMonitor.id)

            controller.focusWindow(secondaryToken)

            #expect(controller.workspaceManager.focusedToken == primaryToken)
            #expect(controller.workspaceManager.pendingFocusedToken == secondaryToken)
            #expect(controller.workspaceManager.pendingFocusedWorkspaceId == secondaryWorkspaceId)
            #expect(controller.workspaceManager.interactionMonitorId == primaryMonitor.id)

            let createdWindowId: UInt32 = 8306
            let createdInfo = makeAXEventWindowInfo(id: createdWindowId, pid: pid, frame: .zero)
            controller.axEventHandler.spaceDisplayResolver = { _, _ in nil }
            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == createdWindowId else { return nil }
                return createdInfo
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
                guard windowId == createdWindowId, candidatePid == pid else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    windowServer: createdInfo
                )
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: createdWindowId, spaceId: 98)
            )
            await waitUntilAXEventTest {
                controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
            }

            #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
                .workspaceId == secondaryWorkspaceId)
        }
    }

    @Test @MainActor
    func createdWindowUsesFocusedWorkspaceBeforePrimaryNativeSpaceAndFrame() async {
        let bundleId = "com.example.focus-before-native"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "1")
            ]
        )

        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))

        let pid = getpid()
        let focusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8307),
            pid: pid,
            windowId: 8307,
            to: secondaryWorkspaceId
        )
        #expect(controller.workspaceManager.setManagedFocus(
            focusedToken,
            in: secondaryWorkspaceId,
            onMonitor: secondaryMonitor.id
        ))
        #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

        let createdWindowId: UInt32 = 8308
        let createdInfo = makeAXEventWindowInfo(
            id: createdWindowId,
            pid: pid,
            frame: CGRect(
                x: primaryMonitor.visibleFrame.minX + 120,
                y: primaryMonitor.visibleFrame.minY + 100,
                width: 640,
                height: 420
            )
        )
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 99 ? primaryMonitor.displayId : nil
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return createdInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                windowServer: createdInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 99)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
            .workspaceId == secondaryWorkspaceId)
    }

    @Test @MainActor
    func focusedSecondaryCreateAppliesTiledFrameOnSecondaryMonitor() async {
        await withAXFrameProviderIsolationForTests {
            let bundleId = "com.example.secondary-create-frame"
            let controller = makeAXEventTestController(
                trackedBundleId: bundleId,
                workspaceConfigurations: [
                    WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                    WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
                ]
            )
            let primaryMonitor = makeAXEventTestMonitor()
            let secondaryMonitor = makeAXEventSecondaryMonitor()
            controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
            controller.windowRuleEngine.rebuild(
                rules: [
                    AppRule(bundleId: bundleId, assignToWorkspace: "1")
                ]
            )
            AXWindowService.fastFrameProviderForTests = { _ in nil }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            controller.axManager.frameApplyOverrideForTests = { requests in
                requests.map { request in
                    AXFrameApplyResult(
                        pid: request.pid,
                        windowId: request.windowId,
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        writeResult: AXFrameWriteResult(
                            targetFrame: request.frame,
                            observedFrame: request.frame,
                            writeOrder: AXWindowService.frameWriteOrder(
                                currentFrame: request.currentFrameHint,
                                targetFrame: request.frame
                            ),
                            sizeError: .success,
                            positionError: .success,
                            failureReason: nil
                        )
                    )
                }
            }
            defer { controller.axManager.frameApplyOverrideForTests = nil }

            guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
                  let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
            else {
                Issue.record("Missing multi-monitor workspace fixture")
                return
            }

            #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
            #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
            controller.enableNiriLayout()
            await controller.layoutRefreshController.waitForRefreshWorkForTests()
            controller.syncMonitorsToNiriEngine()

            let pid = getpid()
            let focusedToken = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8309),
                pid: pid,
                windowId: 8309,
                to: secondaryWorkspaceId
            )
            #expect(controller.workspaceManager.setManagedFocus(
                focusedToken,
                in: secondaryWorkspaceId,
                onMonitor: secondaryMonitor.id
            ))
            #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))

            let createdWindowId: UInt32 = 8312
            let createdInfo = makeAXEventWindowInfo(
                id: createdWindowId,
                pid: pid,
                frame: CGRect(
                    x: primaryMonitor.visibleFrame.minX + 140,
                    y: primaryMonitor.visibleFrame.minY + 120,
                    width: 640,
                    height: 420
                )
            )
            controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
                spaceId == 100 ? primaryMonitor.displayId : nil
            }
            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == createdWindowId else { return nil }
                return createdInfo
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
                guard windowId == createdWindowId, candidatePid == pid else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    windowServer: createdInfo
                )
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: createdWindowId, spaceId: 100)
            )
            await waitUntilAXEventTest(iterations: 300) {
                controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil &&
                    controller.axManager.lastAppliedFrame(for: Int(createdWindowId)) != nil
            }

            guard let entry = controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)),
                  let appliedFrame = controller.axManager.lastAppliedFrame(for: Int(createdWindowId))
            else {
                Issue.record("Expected created window entry and applied frame")
                return
            }

            #expect(entry.workspaceId == secondaryWorkspaceId)
            #expect(controller.workspaceManager.activeWorkspace(on: primaryMonitor.id)?.id == primaryWorkspaceId)
            #expect(secondaryMonitor.visibleFrame.contains(appliedFrame.center))
        }
    }

    @Test @MainActor
    func createdWindowUsesFastFrameMonitorBeforeStaleInteractionAndRule() async {
        await withAXFrameProviderIsolationForTests {
            let bundleId = "com.example.fast-frame-placement"
            let controller = makeAXEventTestController(
                trackedBundleId: bundleId,
                workspaceConfigurations: [
                    WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                    WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
                ]
            )
            let primaryMonitor = makeAXEventTestMonitor()
            let secondaryMonitor = makeAXEventSecondaryMonitor()
            controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
            controller.windowRuleEngine.rebuild(
                rules: [
                    AppRule(bundleId: bundleId, assignToWorkspace: "1")
                ]
            )

            guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
                  let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
            else {
                Issue.record("Missing multi-monitor workspace fixture")
                return
            }

            #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
            #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
            let pid = getpid()
            let siblingToken = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 8310),
                pid: pid,
                windowId: 8310,
                to: primaryWorkspaceId
            )
            #expect(controller.workspaceManager.entry(for: siblingToken)?.workspaceId == primaryWorkspaceId)

            let createdWindowId: UInt32 = 8311
            let createdInfo = makeAXEventWindowInfo(id: createdWindowId, pid: pid, frame: .zero)
            AXWindowService.fastFrameProviderForTests = { axRef in
                guard axRef.windowId == Int(createdWindowId) else { return nil }
                return CGRect(
                    x: secondaryMonitor.visibleFrame.minX + 140,
                    y: secondaryMonitor.visibleFrame.minY + 140,
                    width: 720,
                    height: 460
                )
            }
            defer { AXWindowService.fastFrameProviderForTests = nil }

            controller.axEventHandler.spaceDisplayResolver = { _, _ in nil }
            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == createdWindowId else { return nil }
                return createdInfo
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
                guard windowId == createdWindowId, candidatePid == pid else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    windowServer: createdInfo
                )
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: createdWindowId, spaceId: 95)
            )
            await waitUntilAXEventTest {
                controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
            }

            #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
                .workspaceId == secondaryWorkspaceId)
        }
    }

    @Test @MainActor
    func createdWindowRetryPreservesCreateTimeSecondaryInteractionMonitor() async {
        await withAXFrameProviderIsolationForTests {
            let bundleId = "com.example.secondary-interaction-retry"
            let controller = makeAXEventTestController(
                trackedBundleId: bundleId,
                workspaceConfigurations: [
                    WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                    WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
                ]
            )
            let primaryMonitor = makeAXEventTestMonitor()
            let secondaryMonitor = makeAXEventSecondaryMonitor()
            controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
            controller.windowRuleEngine.rebuild(
                rules: [
                    AppRule(bundleId: bundleId, assignToWorkspace: "1")
                ]
            )

            guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
                  let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
            else {
                Issue.record("Missing multi-monitor workspace fixture")
                return
            }

            #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
            #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
            _ = controller.workspaceManager.setInteractionMonitor(secondaryMonitor.id)

            let pid = getpid()
            let createdWindowId: UInt32 = 8321
            let createdInfo = makeAXEventWindowInfo(id: createdWindowId, pid: pid, frame: .zero)
            var windowInfoReady = false
            var windowInfoLookupCount = 0
            controller.axEventHandler.spaceDisplayResolver = { _, _ in nil }
            controller.axEventHandler.windowInfoProvider = { windowId in
                guard windowId == createdWindowId else { return nil }
                windowInfoLookupCount += 1
                guard windowInfoReady else { return nil }
                return createdInfo
            }
            controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
                guard windowId == createdWindowId, candidatePid == pid else { return nil }
                return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
            }
            controller.axEventHandler.windowFactsProvider = { _, _ in
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    windowServer: createdInfo
                )
            }

            controller.axEventHandler.cgsEventObserver(
                CGSEventObserver.shared,
                didReceive: .created(windowId: createdWindowId, spaceId: 96)
            )
            #expect(controller.workspaceManager.setInteractionMonitor(primaryMonitor.id))
            windowInfoReady = true

            await waitUntilAXEventTest(iterations: 300) {
                controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
            }

            #expect(windowInfoLookupCount >= 2)
            #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
                .workspaceId == secondaryWorkspaceId)
        }
    }

    @Test @MainActor
    func createdWindowUsesFrameMonitorWhenNativeSpaceIsUnresolvedAndInteractionMonitorIsStale() async {
        let bundleId = "com.example.unresolved-space-frame-monitor"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "6", monitorAssignment: .secondary)
            ]
        )
        let primaryMonitor = makeAXEventTestMonitor()
        let secondaryMonitor = makeAXEventSecondaryMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "1")
            ]
        )

        guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "6", createIfMissing: false)
        else {
            Issue.record("Missing multi-monitor workspace fixture")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id))
        #expect(controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id))
        let pid = getpid()
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 893),
            pid: pid,
            windowId: 893,
            to: primaryWorkspaceId
        )
        #expect(controller.workspaceManager.entry(for: siblingToken)?.workspaceId == primaryWorkspaceId)

        let createdWindowId: UInt32 = 894
        let createdInfo = makeAXEventWindowInfo(
            id: createdWindowId,
            pid: pid,
            frame: CGRect(
                x: secondaryMonitor.visibleFrame.minX + 180,
                y: secondaryMonitor.visibleFrame.minY + 160,
                width: 640,
                height: 420
            )
        )
        controller.axEventHandler.spaceDisplayResolver = { _, _ in nil }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return createdInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                windowServer: createdInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 93)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
            .workspaceId == secondaryWorkspaceId)
    }

    @Test @MainActor func samePidCreateWithoutRuleUsesActiveWorkspace() async {
        let bundleId = "com.example.same-pid-origin"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", monitorAssignment: .main)
            ]
        )

        guard let activeWorkspaceId = controller.activeWorkspace()?.id,
              let siblingWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing configured workspaces")
            return
        }

        let pid = getpid()
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 842),
            pid: pid,
            windowId: 842,
            to: siblingWorkspaceId
        )

        let createdWindowId: UInt32 = 843
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return WindowServerInfo(id: windowId, pid: pid, level: 0, frame: .zero)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(bundleId: bundleId)
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 0)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
            .workspaceId == activeWorkspaceId)
    }

    @Test @MainActor func niriParentedStandardCreateUsesActiveWorkspaceNotTrackedParentWorkspace() async {
        let bundleId = "com.example.parented-standard-niri"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", monitorAssignment: .main)
            ]
        )

        guard let monitor = controller.monitorForInteraction(),
              let createWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let parentWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing configured Niri placement workspaces")
            return
        }

        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(createWorkspaceId, on: monitor.id))

        let pid = getpid()
        let parentWindowId = 8060
        let parentToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: parentWindowId),
            pid: pid,
            windowId: parentWindowId,
            to: parentWorkspaceId
        )
        _ = engine.addWindow(token: parentToken, to: parentWorkspaceId, afterSelection: nil, focusedToken: parentToken)

        let createdWindowId: UInt32 = 8061
        let createdToken = WindowToken(pid: pid, windowId: Int(createdWindowId))
        var createdInfo = makeAXEventWindowInfo(
            id: createdWindowId,
            pid: pid,
            frame: .zero,
            parentId: UInt32(parentWindowId)
        )
        createdInfo.tags = 0x1
        controller.axEventHandler.spaceDisplayResolver = { spaceId, _ in
            spaceId == 91 ? monitor.displayId : nil
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return createdInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: "New document",
                windowServer: createdInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 91)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(for: createdToken) != nil
                && engine.findNode(for: createdToken) != nil
        }

        let createWorkspaceTokens = engine.columns(in: createWorkspaceId).flatMap(\.windowNodes).map(\.token)
        let parentWorkspaceTokens = engine.columns(in: parentWorkspaceId).flatMap(\.windowNodes).map(\.token)
        #expect(controller.workspaceManager.entry(for: createdToken)?.workspaceId == createWorkspaceId)
        #expect(createWorkspaceTokens.contains(createdToken))
        #expect(!parentWorkspaceTokens.contains(createdToken))
    }

    @Test @MainActor func childCreateUsesTrackedParentWorkspaceDespiteAssignRule() async {
        let bundleId = "com.example.parent-placement"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", monitorAssignment: .main)
            ]
        )
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "2")
            ]
        )

        guard let parentWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing configured workspace")
            return
        }

        let pid = getpid()
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 844),
            pid: pid,
            windowId: 844,
            to: parentWorkspaceId
        )

        let createdWindowId: UInt32 = 845
        var childInfo = makeAXEventWindowInfo(
            id: createdWindowId,
            pid: pid,
            frame: .zero,
            parentId: 844
        )
        childInfo.tags = 0x2
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return childInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                subrole: "AXDialog",
                hasFullscreenButton: false,
                hasZoomButton: false,
                windowServer: childInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 0)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))?
            .workspaceId == parentWorkspaceId)
    }

    @Test @MainActor func structuralReplacementPreservesOldWorkspaceWhenCreateOriginDiffers() {
        let bundleId = currentTestBundleId()
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", monitorAssignment: .main)
            ]
        )
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "2")
            ]
        )

        guard let replacementWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing replacement workspace")
            return
        }

        let oldInfo = makeAXEventWindowInfo(
            id: 846,
            title: "repo - shell",
            frame: CGRect(x: 90, y: 120, width: 840, height: 620),
            parentId: 91
        )
        let replacementInfo = makeAXEventWindowInfo(
            id: 847,
            title: "repo - shell (replacement)",
            frame: oldInfo.frame,
            parentId: 846
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 846),
            pid: getpid(),
            windowId: 846,
            to: replacementWorkspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: replacementWorkspaceId,
                title: oldInfo.title,
                windowServer: oldInfo
            )
        )
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken) else {
            Issue.record("Missing original replacement entry")
            return
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 846:
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
            switch axRef.windowId {
            case 847:
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    title: replacementInfo.title,
                    windowServer: replacementInfo
                )
            default:
                makeAXEventWindowRuleFacts(bundleId: bundleId)
            }
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 847, spaceId: 0)
        )
        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 847) == nil)

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 846, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()

        let replacementToken = WindowToken(pid: getpid(), windowId: 847)
        #expect(controller.workspaceManager.entry(for: oldToken) == nil)
        #expect(controller.workspaceManager.entry(for: replacementToken)?.handle === oldEntry.handle)
        #expect(controller.workspaceManager.entry(for: replacementToken)?.workspaceId == replacementWorkspaceId)
    }

    @Test @MainActor func parentedFloatingDialogDoesNotStructurallyRekeyOverParent() async {
        let bundleId = "com.example.parented-dialog-rekey"
        let controller = makeAXEventTestController(trackedBundleId: bundleId)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let parentInfo = makeAXEventWindowInfo(
            id: 848,
            title: "Parent",
            frame: CGRect(x: 120, y: 140, width: 760, height: 520)
        )
        let childInfo = makeAXEventWindowInfo(
            id: 849,
            title: "Parent Dialog",
            frame: CGRect(x: 160, y: 180, width: 700, height: 460),
            parentId: 848
        )
        let parentToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 848),
            pid: getpid(),
            windowId: 848,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                mode: .tiling,
                title: parentInfo.title,
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                windowServer: parentInfo
            )
        )
        guard let parentEntry = controller.workspaceManager.entry(for: parentToken) else {
            Issue.record("Missing parent entry")
            return
        }

        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 848:
                parentInfo
            case 849:
                childInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info = axRef.windowId == 849 ? childInfo : parentInfo
            return makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: info.title,
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                windowServer: info
            )
        }

        let childToken = WindowToken(pid: getpid(), windowId: 849)

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 848, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 849, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()

        guard let childEntry = controller.workspaceManager.entry(for: childToken) else {
            Issue.record("Missing child entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: parentToken) == nil)
        #expect(childEntry.handle !== parentEntry.handle)
        #expect(childEntry.mode == .floating)
        #expect(structuralManagedReplacementMatchedElapsedMillis(on: controller) == nil)
    }

    @Test @MainActor func degradedWindowServerChildDoesNotStructurallyRekeyOverParentBurst() async {
        let bundleId = "com.example.degraded-child-rekey"
        let controller = makeAXEventTestController(trackedBundleId: bundleId)
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, layout: .float)
            ]
        )
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let parentInfo = makeAXEventWindowInfo(
            id: 850,
            title: "Parent",
            frame: CGRect(x: 120, y: 140, width: 760, height: 520)
        )
        var childInfo = makeAXEventWindowInfo(
            id: 851,
            title: "Parent Degraded Child",
            frame: CGRect(x: 160, y: 180, width: 700, height: 460),
            parentId: 850
        )
        childInfo.tags = 0x2
        let parentToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 850),
            pid: getpid(),
            windowId: 850,
            to: workspaceId,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                mode: .tiling,
                title: parentInfo.title,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                windowServer: parentInfo
            )
        )
        guard let parentEntry = controller.workspaceManager.entry(for: parentToken) else {
            Issue.record("Missing parent entry")
            return
        }

        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 850:
                parentInfo
            case 851:
                childInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            let info = axRef.windowId == 851 ? childInfo : parentInfo
            return makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                title: info.title,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                attributeFetchSucceeded: axRef.windowId != 851,
                windowServer: info
            )
        }

        let childToken = WindowToken(pid: getpid(), windowId: 851)

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 850, spaceId: 0)
        )
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 851, spaceId: 0)
        )
        controller.axEventHandler.flushPendingManagedReplacementEventsForTests()

        guard let childEntry = controller.workspaceManager.entry(for: childToken) else {
            Issue.record("Missing child entry")
            return
        }

        #expect(controller.workspaceManager.entry(for: parentToken) == nil)
        #expect(childEntry.handle !== parentEntry.handle)
        #expect(childEntry.mode == .floating)
        #expect(childEntry.managedReplacementMetadata?.degradedWindowServerChildEvidence == true)
        #expect(structuralManagedReplacementMatchedElapsedMillis(on: controller) == nil)
    }

    @Test @MainActor func newParentedStandardWindowFollowsMovedAppWorkspaceWhileAutomaticReevaluationPreservesMove(
    ) async {
        let bundleId = "com.example.rule-workspace"
        let controller = makeAXEventTestController(
            trackedBundleId: bundleId,
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", monitorAssignment: .main)
            ]
        )
        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(bundleId: bundleId, assignToWorkspace: "2")
            ]
        )

        guard let ruleWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let movedWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing configured workspaces")
            return
        }

        let pid = getpid()
        let originalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 842),
            pid: pid,
            windowId: 842,
            to: ruleWorkspaceId
        )
        #expect(controller.workspaceManager.entry(for: originalToken)?.workspaceId == ruleWorkspaceId)
        controller.reassignManagedWindow(originalToken, to: movedWorkspaceId)
        #expect(controller.workspaceManager.entry(for: originalToken)?.workspaceId == movedWorkspaceId)

        let createdWindowId: UInt32 = 843
        var createdInfo = makeAXEventWindowInfo(
            id: createdWindowId,
            pid: pid,
            frame: .zero,
            parentId: UInt32(originalToken.windowId)
        )
        createdInfo.tags = 0x1
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == createdWindowId else { return nil }
            return createdInfo
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, candidatePid in
            guard windowId == createdWindowId, candidatePid == pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: bundleId,
                windowServer: createdInfo
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: createdWindowId, spaceId: 0)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId)) != nil
        }

        let createdEntry = controller.workspaceManager.entry(forPid: pid, windowId: Int(createdWindowId))
        #expect(controller.workspaceManager.entry(for: originalToken)?.workspaceId == movedWorkspaceId)
        #expect(createdEntry?.workspaceId == movedWorkspaceId)

        let outcome = await controller.reevaluateWindowRules(for: [.pid(pid)])
        #expect(outcome.resolvedAnyTarget)
        #expect(outcome.evaluatedAnyWindow)
        #expect(controller.workspaceManager.entry(for: originalToken)?.workspaceId == movedWorkspaceId)
        #expect(
            controller.workspaceManager.entry(
                forPid: pid,
                windowId: Int(createdWindowId)
            )?.workspaceId == movedWorkspaceId
        )
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
        try await withAXFrameProviderIsolationForTests {
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
            let primaryWorkspaceId = try #require(controller.workspaceManager.workspaceId(
                for: "1",
                createIfMissing: false
            ))
            let secondaryWorkspaceId = try #require(controller.workspaceManager.workspaceId(
                for: "6",
                createIfMissing: false
            ))
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
            controller.axEventHandler.resetDebugStateForTests()
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
            #expect(controller.workspaceManager
                .resolvedFloatingFrame(for: entry.token, preferredMonitor: secondaryMonitor) == expectedFrame)
            #expect(controller.workspaceManager.consumedBootPersistedWindowRestoreKeysForTests()
                .contains(catalog.entries[0].key))
        }
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

    @Test @MainActor func raycastFloatingDialogMissingAfterPostCreateVerificationClearsBorder() async {
        let controller = makeAXEventTestController()
        let pid: pid_t = 65_940
        let windowId: UInt32 = 82_136
        let frame = CGRect(x: 400, y: 220, width: 640, height: 420)
        var isVisible = true
        configureRaycastFloatingDialogCreate(
            on: controller,
            pid: pid,
            windowId: windowId,
            frame: frame,
            isVisible: { isVisible }
        )

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: windowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let entry = controller.workspaceManager.entry(forPid: pid, windowId: Int(windowId)) else {
            Issue.record("Expected Raycast floating dialog to be tracked")
            return
        }
        #expect(entry.mode == .floating)

        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(on: controller, token: entry.token, frame: frame)
        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == entry.token)
        #expect(lastAppliedBorderWindowId(on: controller) == Int(windowId))

        isVisible = false
        await waitUntilAXEventTest(iterations: 300) {
            controller.workspaceManager.entry(for: entry.token) == nil
        }

        #expect(controller.workspaceManager.entry(for: entry.token) == nil)
        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func raycastFloatingDialogVisibleAfterPostCreateVerificationKeepsBorder() async {
        let controller = makeAXEventTestController()
        let pid: pid_t = 65_941
        let windowId: UInt32 = 82_137
        let frame = CGRect(x: 420, y: 260, width: 620, height: 380)
        configureRaycastFloatingDialogCreate(
            on: controller,
            pid: pid,
            windowId: windowId,
            frame: frame,
            isVisible: { true }
        )

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: windowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let entry = controller.workspaceManager.entry(forPid: pid, windowId: Int(windowId)) else {
            Issue.record("Expected Raycast floating dialog to be tracked")
            return
        }

        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(on: controller, token: entry.token, frame: frame)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(controller.workspaceManager.entry(for: entry.token) != nil)
        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == entry.token)
        #expect(lastAppliedBorderWindowId(on: controller) == Int(windowId))
    }

    @Test @MainActor func postCreateVerificationCleanupDoesNotRemoveTrackedWindow() async {
        let controller = makeAXEventTestController()
        let pid: pid_t = 65_942
        let windowId: UInt32 = 82_138
        let frame = CGRect(x: 440, y: 280, width: 600, height: 360)
        var isVisible = true
        configureRaycastFloatingDialogCreate(
            on: controller,
            pid: pid,
            windowId: windowId,
            frame: frame,
            isVisible: { isVisible }
        )

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: windowId, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let entry = controller.workspaceManager.entry(forPid: pid, windowId: Int(windowId)) else {
            Issue.record("Expected Raycast floating dialog to be tracked")
            return
        }

        isVisible = false
        controller.axEventHandler.cleanup()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(controller.workspaceManager.entry(for: entry.token) != nil)
    }

    @Test @MainActor func parentedCreateWithDegradedAxFactsRemainsDeferred() async {
        let controller = makeAXEventTestController()
        var info = makeAXEventWindowInfo(
            id: 830,
            frame: CGRect(x: 180, y: 220, width: 480, height: 260),
            parentId: 410
        )
        info.tags = 0x2
        controller.axEventHandler.windowInfoProvider = { _ in info }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.frameProvider = { _ in info.frame }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.microsoft.Outlook",
                role: kAXWindowRole as String,
                subrole: "AXUnknown",
                attributeFetchSucceeded: false
            )
        }
        defer { controller.axEventHandler.frameProvider = nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 830, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 830) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 830) == nil)
    }

    @Test @MainActor func parentedFloatingTaggedCreateWithDegradedAxFactsRemainsDeferred() async {
        let controller = makeAXEventTestController()
        var info = makeAXEventWindowInfo(
            id: 833,
            frame: CGRect(x: 180, y: 220, width: 480, height: 260),
            parentId: 410
        )
        info.tags = 0x2
        controller.axEventHandler.windowInfoProvider = { _ in info }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.frameProvider = { _ in info.frame }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                role: kAXWindowRole as String,
                subrole: "AXUnknown",
                attributeFetchSucceeded: false
            )
        }
        defer { controller.axEventHandler.frameProvider = nil }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 833, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 833) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 833) == nil)
    }

    @Test @MainActor func documentShapedDegradedCreateRemainsDeferred() async {
        let controller = makeAXEventTestController()
        var info = makeAXEventWindowInfo(id: 831)
        info.tags = 0x1
        controller.axEventHandler.windowInfoProvider = { _ in info }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                attributeFetchSucceeded: false
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 831, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 831) == nil)
    }

    @Test @MainActor func helpTagShapedDegradedCreateRemainsDeferred() async {
        let controller = makeAXEventTestController()
        var info = makeAXEventWindowInfo(id: 832, parentId: 410)
        info = WindowServerInfo(
            id: info.id,
            pid: info.pid,
            level: 103,
            frame: info.frame,
            tags: info.tags,
            attributes: info.attributes,
            parentId: info.parentId,
            title: info.title
        )
        controller.axEventHandler.windowInfoProvider = { _ in info }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                role: "AXHelpTag",
                subrole: kAXStandardWindowSubrole as String,
                attributeFetchSucceeded: false
            )
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 832, spaceId: 0)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 832) == nil)
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

    @Test @MainActor func defaultFloatingCreateWithDegradedAxFactsIsTrackedAndRaised() async {
        var events: [AXEventFocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in events.append(.activate(pid)) },
            focusSpecificWindow: { pid, windowId, _ in events.append(.focus(pid, windowId)) },
            raiseWindow: { _ in events.append(.raise) },
            orderWindow: { windowId in events.append(.order(windowId)) }
        )
        let controller = makeAXEventTestController(
            windowFocusOperations: operations,
            trackedBundleId: "com.itoolab.unlockgo"
        )
        let frame = CGRect(x: 120, y: 140, width: 620, height: 420)
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: frame)
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.frameProvider = { _ in frame }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.itoolab.unlockgo",
                appName: "UnlockGo",
                title: nil,
                attributeFetchSucceeded: false
            )
        }
        defer {
            controller.axEventHandler.frameProvider = nil
            controller.axEventHandler.windowFactsProvider = nil
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 825, spaceId: 0)
        )
        await waitUntilAXEventTest {
            controller.workspaceManager.entry(forPid: getpid(), windowId: 825)?.mode == .floating
                && events == [.order(825), .activate(getpid()), .focus(getpid(), 825), .raise]
        }

        #expect(controller.workspaceManager.entry(forPid: getpid(), windowId: 825)?.mode == .floating)
        #expect(events == [.order(825), .activate(getpid()), .focus(getpid(), 825), .raise])
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

    @Test @MainActor func automaticHeuristicReevaluationDoesNotFloatExistingTiledWindow() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 826),
            pid: pid,
            windowId: 826,
            to: workspaceId,
            mode: .tiling
        )
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == 826 else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.jetbrains.rustrover",
                hasFullscreenButton: false
            )
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            Issue.record("Unexpected relayout reason: \(reason)")
            return true
        }

        let outcome = await controller.reevaluateWindowRules(for: [.window(token)])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(outcome.resolvedAnyTarget)
        #expect(outcome.evaluatedAnyWindow)
        #expect(!outcome.relayoutNeeded)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .tiling)
    }

    @Test @MainActor func automaticWorkspaceRuleFallbackDoesNotFloatExistingTiledWindow() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000008261")!,
            bundleId: "com.example.workspace-fallback",
            assignToWorkspace: "2"
        )
        controller.windowRuleEngine.rebuild(rules: [rule])
        let pid = getpid()
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 827),
            pid: pid,
            windowId: 827,
            to: workspaceId,
            mode: .tiling,
            ruleEffects: ManagedWindowRuleEffects(matchedRuleId: rule.id)
        )
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == 827 else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.workspace-fallback",
                hasFullscreenButton: false
            )
        }
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            Issue.record("Unexpected relayout reason: \(reason)")
            return true
        }

        let outcome = await controller.reevaluateWindowRules(for: [.window(token)])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(outcome.resolvedAnyTarget)
        #expect(outcome.evaluatedAnyWindow)
        #expect(!outcome.relayoutNeeded)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .tiling)
    }

    @Test @MainActor func parentedFloatingChildDoesNotRetileNiriParent() async {
        let bundleId = "com.example.parented-floating-child"
        let controller = makeAXEventTestController(trackedBundleId: bundleId)
        installSynchronousFrameApplySuccessOverride(on: controller)
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000008263")!,
            bundleId: bundleId,
            assignToWorkspace: "2"
        )
        controller.windowRuleEngine.rebuild(rules: [rule])
        controller.enableNiriLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        let parentInfo = makeAXEventWindowInfo(
            id: 830,
            title: "Browser",
            frame: CGRect(x: 80, y: 80, width: 900, height: 640)
        )
        let siblingInfo = makeAXEventWindowInfo(
            id: 831,
            title: "Sibling",
            frame: CGRect(x: 1040, y: 80, width: 700, height: 640)
        )
        var childInfo = makeAXEventWindowInfo(
            id: 832,
            title: "Browser Dialog",
            frame: CGRect(x: 160, y: 140, width: 520, height: 360),
            parentId: 830
        )
        childInfo.tags = 0x2
        let effects = ManagedWindowRuleEffects(matchedRuleId: rule.id)
        let parentToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 830),
            pid: getpid(),
            windowId: 830,
            to: workspaceId,
            mode: .tiling,
            ruleEffects: effects,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                title: parentInfo.title,
                windowServer: parentInfo
            )
        )
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 831),
            pid: getpid(),
            windowId: 831,
            to: workspaceId,
            mode: .tiling,
            managedReplacementMetadata: makeManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                title: siblingInfo.title,
                windowServer: siblingInfo
            )
        )
        guard let parentEntry = controller.workspaceManager.entry(for: parentToken) else {
            Issue.record("Missing parent entry")
            return
        }

        let parentNode = engine.addWindow(token: parentToken, to: workspaceId, afterSelection: nil, focusedToken: parentToken)
        _ = engine.addWindow(token: siblingToken, to: workspaceId, afterSelection: parentNode.id, focusedToken: parentToken)
        guard let parentColumn = engine.column(of: parentNode),
              let parentColumnIndex = engine.columnIndex(of: parentColumn, in: workspaceId)
        else {
            Issue.record("Missing parent Niri column")
            return
        }
        parentColumn.width = .fixed(620)
        parentColumn.cachedWidth = 620
        let originalParentNodeId = parentNode.id
        let originalParentColumnWidth = parentColumn.width
        let originalParentCachedWidth = parentColumn.cachedWidth
        var parentFactsLookFloating = false

        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 830:
                parentInfo
            case 831:
                siblingInfo
            case 832:
                childInfo
            default:
                nil
            }
        }
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            switch axRef.windowId {
            case 830:
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    title: parentInfo.title,
                    hasFullscreenButton: !parentFactsLookFloating,
                    windowServer: parentInfo
                )
            case 832:
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    title: childInfo.title,
                    subrole: kAXDialogSubrole as String,
                    windowServer: childInfo
                )
            default:
                makeAXEventWindowRuleFacts(
                    bundleId: bundleId,
                    title: siblingInfo.title,
                    windowServer: siblingInfo
                )
            }
        }

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: 832, spaceId: 0)
        )
        let childToken = WindowToken(pid: getpid(), windowId: 832)
        await waitUntilAXEventTest(iterations: 240) {
            controller.workspaceManager.entry(for: childToken) != nil
        }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let childEntry = controller.workspaceManager.entry(for: childToken) else {
            Issue.record("Missing child entry")
            return
        }
        #expect(childEntry.mode == .floating)
        #expect(engine.findNode(for: childToken) == nil)

        parentFactsLookFloating = true
        let floatingOutcome = await controller.reevaluateWindowRules(for: [.window(parentToken)])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let updatedParentNode = engine.findNode(for: parentToken),
              let updatedParentColumn = engine.column(of: updatedParentNode)
        else {
            Issue.record("Missing updated parent Niri state")
            return
        }
        #expect(floatingOutcome.resolvedAnyTarget)
        #expect(floatingOutcome.evaluatedAnyWindow)
        #expect(!floatingOutcome.relayoutNeeded)
        #expect(controller.workspaceManager.entry(for: parentToken)?.handle === parentEntry.handle)
        #expect(controller.workspaceManager.entry(for: parentToken)?.mode == .tiling)
        #expect(updatedParentNode.id == originalParentNodeId)
        #expect(engine.columnIndex(of: updatedParentColumn, in: workspaceId) == parentColumnIndex)
        #expect(updatedParentColumn.width == originalParentColumnWidth)
        #expect(abs(updatedParentColumn.cachedWidth - originalParentCachedWidth) < 0.5)
        #expect(engine.findNode(for: childToken) == nil)

        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .destroyed(windowId: 832, spaceId: 0)
        )
        await waitUntilAXEventTest(iterations: 240) {
            controller.workspaceManager.entry(for: childToken) == nil
        }
        parentFactsLookFloating = false
        let restoredOutcome = await controller.reevaluateWindowRules(for: [.window(parentToken)])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let finalParentNode = engine.findNode(for: parentToken),
              let finalParentColumn = engine.column(of: finalParentNode)
        else {
            Issue.record("Missing final parent Niri state")
            return
        }
        #expect(restoredOutcome.resolvedAnyTarget)
        #expect(restoredOutcome.evaluatedAnyWindow)
        #expect(!restoredOutcome.relayoutNeeded)
        #expect(controller.workspaceManager.entry(for: parentToken)?.mode == .tiling)
        #expect(finalParentNode.id == originalParentNodeId)
        #expect(engine.columnIndex(of: finalParentColumn, in: workspaceId) == parentColumnIndex)
        #expect(finalParentColumn.width == originalParentColumnWidth)
        #expect(abs(finalParentColumn.cachedWidth - originalParentCachedWidth) < 0.5)
    }

    @Test @MainActor func automaticTransientFloatingFallbackDoesNotTileExistingDialog() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000008262")!,
            bundleId: "com.example.transient-fallback",
            assignToWorkspace: "2"
        )
        controller.windowRuleEngine.rebuild(rules: [rule])
        let pid = getpid()
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 828),
            pid: pid,
            windowId: 828,
            to: workspaceId,
            mode: .floating,
            ruleEffects: ManagedWindowRuleEffects(matchedRuleId: rule.id),
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.transient-fallback",
                workspaceId: workspaceId,
                mode: .floating,
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                title: "Transient",
                windowLevel: 0,
                parentWindowId: 827,
                frame: CGRect(x: 120, y: 160, width: 420, height: 300),
                transientWindowServerEvidence: true
            )
        )
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == 828 else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.transient-fallback",
                subrole: kAXStandardWindowSubrole as String
            )
        }

        let outcome = await controller.reevaluateWindowRules(for: [.window(token)])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(outcome.resolvedAnyTarget)
        #expect(outcome.evaluatedAnyWindow)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
    }

    @Test @MainActor func explicitUserFloatReevaluationStillTransitionsExistingTiledWindow() async {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        controller.windowRuleEngine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.example.explicit-float-reeval",
                    layout: .float
                )
            ]
        )
        let pid = getpid()
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 829),
            pid: pid,
            windowId: 829,
            to: workspaceId,
            mode: .tiling
        )
        controller.axEventHandler.axWindowRefProvider = { windowId, _ in
            guard windowId == 829 else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        controller.axEventHandler.windowFactsProvider = { _, _ in
            makeAXEventWindowRuleFacts(
                bundleId: "com.example.explicit-float-reeval",
                attributeFetchSucceeded: false
            )
        }

        let outcome = await controller.reevaluateWindowRules(for: [.window(token)])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(outcome.resolvedAnyTarget)
        #expect(outcome.evaluatedAnyWindow)
        #expect(outcome.relayoutNeeded)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
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
        controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: entry.token),
            preferredFrame: CGRect(x: 10, y: 10, width: 800, height: 600),
            forceOrdering: true
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

    @Test @MainActor func handleRemovedPidPathInvalidatesCachedTitle() {
        AXWindowService.clearTitleCacheForTests()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            AXWindowService.timeSourceForTests = nil
            AXWindowService.clearTitleCacheForTests()
        }

        var lookupCount = 0
        AXWindowService.timeSourceForTests = { 100 }
        AXWindowService.titleLookupProviderForTests = { _ in
            lookupCount += 1
            return lookupCount == 1 ? "Before Remove" : "After Remove"
        }

        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
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

    @Test @MainActor func unmanagedFocusedDestroyClearsFocusedBorderTarget() {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 9_140, windowId: 9141)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: CGRect(x: 40, y: 40, width: 500, height: 400),
            preferredFrameSource: .observed,
            forceOrdering: true
        )

        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == token)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)

        controller.axEventHandler.handleRemoved(pid: token.pid, winId: token.windowId)

        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func trackedFloatingDestroyClearsFocusedBorderTarget() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9143),
            pid: 9_142,
            windowId: 9143,
            to: workspaceId,
            mode: .floating
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: token,
            frame: CGRect(x: 50, y: 56, width: 520, height: 360)
        )

        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == token)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)

        controller.axEventHandler.handleRemoved(pid: token.pid, winId: token.windowId)

        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func unmanagedAppDeactivationClearsFocusedBorderTarget() {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 9_144, windowId: 9145)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId),
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: CGRect(x: 40, y: 40, width: 500, height: 400),
            preferredFrameSource: .observed,
            forceOrdering: true
        )

        controller.axEventHandler.handleAppDeactivated(pid: token.pid)

        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func trackedFloatingAppDeactivationClearsFocusedBorderTargetWithoutChangingFocusState() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9146),
            pid: 9_145,
            windowId: 9146,
            to: workspaceId,
            mode: .floating
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: token,
            frame: CGRect(x: 50, y: 56, width: 520, height: 360)
        )

        controller.axEventHandler.handleAppDeactivated(pid: token.pid)

        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
        #expect(!controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.focusedToken == token)
        #expect(!controller.updateManagedKeyboardFocusBorder(
            token: token,
            preferredFrame: CGRect(x: 80, y: 84, width: 520, height: 360)
        ))
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func managedTiledAppDeactivationDoesNotClearFocusedBorderTarget() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9147),
            pid: 9_146,
            windowId: 9147,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: token,
            frame: CGRect(x: 50, y: 56, width: 520, height: 360)
        )

        controller.axEventHandler.handleAppDeactivated(pid: token.pid)

        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == token)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(controller.workspaceManager.focusedToken == token)
    }

    @Test @MainActor func trackedFloatingAppDeactivationDuringPendingManagedFocusOnlyClearsBorderTarget() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let floatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9148),
            pid: 9_147,
            windowId: 9148,
            to: workspaceId,
            mode: .floating
        )
        let pendingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9149),
            pid: 9_148,
            windowId: 9149,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            floatingToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            pendingToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.focusBridge.beginManagedRequest(
            token: pendingToken,
            workspaceId: workspaceId
        )
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: floatingToken,
            frame: CGRect(x: 50, y: 56, width: 520, height: 360)
        )

        controller.axEventHandler.handleAppDeactivated(pid: floatingToken.pid)

        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
        #expect(controller.workspaceManager.focusedToken == floatingToken)
        #expect(controller.workspaceManager.pendingFocusedToken == pendingToken)
        #expect(controller.focusBridge.activeManagedRequest?.token == pendingToken)
        #expect(!controller.workspaceManager.isNonManagedFocusActive)
        #expect(!controller.updateManagedKeyboardFocusBorder(
            token: floatingToken,
            preferredFrame: CGRect(x: 80, y: 84, width: 520, height: 360)
        ))
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func nonManagedActivationKeepsExistingFocusSemanticsWithoutAXContextWarmup() {
        let controller = makeAXEventTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let managedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9150),
            pid: 9_149,
            windowId: 9150,
            to: workspaceId
        )
        let unmanagedToken = WindowToken(pid: 9_151, windowId: 9152)
        var warmedPIDs: [pid_t] = []
        controller.hasStartedServices = true
        _ = controller.workspaceManager.setManagedFocus(
            managedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == unmanagedToken.pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: unmanagedToken.windowId)
        }
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.axContextWarmupHandlerForTests = { warmedPIDs.append($0) }
        defer {
            controller.hasStartedServices = false
            controller.axEventHandler.focusedWindowRefProvider = nil
            controller.axEventHandler.isFullscreenProvider = nil
            controller.axEventHandler.axContextWarmupHandlerForTests = nil
        }

        controller.axEventHandler.handleAppActivation(
            pid: unmanagedToken.pid,
            source: .workspaceDidActivateApplication
        )

        #expect(warmedPIDs.isEmpty)
        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == unmanagedToken)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.focusedToken == nil)
    }

    @Test @MainActor func unmanagedFocusedMiniaturizeClearsFocusedBorderTarget() {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 9_150, windowId: 9151)
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: CGRect(x: 40, y: 40, width: 500, height: 400),
            preferredFrameSource: .observed,
            forceOrdering: true
        )

        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == token)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)

        controller.axEventHandler.handleWindowMiniaturized(pid: token.pid, windowId: token.windowId)

        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func miniaturizeForPreviousFocusedWindowDoesNotClearReplacementBorder() {
        let controller = makeAXEventTestController()
        let oldToken = WindowToken(pid: 9_152, windowId: 9153)
        let newToken = WindowToken(pid: 9_154, windowId: 9155)
        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: oldToken,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: oldToken.windowId),
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: CGRect(x: 40, y: 40, width: 500, height: 400),
            preferredFrameSource: .observed,
            forceOrdering: true
        )
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: newToken,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: newToken.windowId),
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: CGRect(x: 80, y: 80, width: 520, height: 420),
            preferredFrameSource: .observed,
            forceOrdering: true
        )

        controller.axEventHandler.handleWindowMiniaturized(pid: oldToken.pid, windowId: oldToken.windowId)

        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == newToken)
        #expect(lastAppliedBorderWindowId(on: controller) == newToken.windowId)
    }

    @Test @MainActor func hiddenBorderRefreshClearsWhenKeyboardFocusMovedElsewhere() {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 9_160, windowId: 9161)
        let otherToken = WindowToken(pid: token.pid, windowId: 9162)
        controller.hasStartedServices = true
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == token.pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: otherToken.windowId)
        }
        defer {
            controller.hasStartedServices = false
            controller.axEventHandler.focusedWindowRefProvider = nil
        }

        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId),
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: CGRect(x: 40, y: 40, width: 500, height: 400),
            preferredFrameSource: .observed,
            forceOrdering: true
        )

        controller.focusBorderController.hide()
        _ = controller.focusBorderController.refresh(forceOrdering: true)

        #expect(controller.currentKeyboardFocusTargetForRendering() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func hiddenBorderRefreshRestoresWhenKeyboardFocusStillMatches() {
        let controller = makeAXEventTestController()
        let token = WindowToken(pid: 9_170, windowId: 9171)
        let frame = CGRect(x: 40, y: 40, width: 500, height: 400)
        controller.hasStartedServices = true
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == token.pid else { return nil }
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId)
        }
        controller.focusBorderController.observedFrameProviderForTests = { _ in frame }
        defer {
            controller.hasStartedServices = false
            controller.axEventHandler.focusedWindowRefProvider = nil
            controller.focusBorderController.observedFrameProviderForTests = nil
        }

        controller.setBordersEnabled(true)
        _ = controller.renderKeyboardFocusBorder(
            for: KeyboardFocusTarget(
                token: token,
                axRef: AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: token.windowId),
                workspaceId: nil,
                isManaged: false
            ),
            preferredFrame: frame,
            preferredFrameSource: .observed,
            forceOrdering: true
        )

        controller.focusBorderController.hide()
        _ = controller.focusBorderController.refresh(forceOrdering: true)

        #expect(controller.currentKeyboardFocusTargetForRendering()?.token == token)
        #expect(lastAppliedBorderWindowId(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrame(on: controller) == frame)
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

        let initialFrame = CGRect(x: 40, y: 40, width: 500, height: 400)
        let staleFrame = CGRect(x: 160, y: 160, width: 400, height: 300)
        let focusedFrame = CGRect(x: 72, y: 80, width: 620, height: 440)
        var observedFrame = staleFrame
        controller.axEventHandler.frameProvider = { _ in observedFrame }
        defer { controller.axEventHandler.frameProvider = nil }
        controller.setBordersEnabled(true)
        _ = confirmFocusedBorder(
            on: controller,
            token: focusedToken,
            frame: initialFrame
        )

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: stalePid, level: 0, frame: .zero)
        }
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 903)
        )
        #expect(lastAppliedBorderWindowId(on: controller) == 903)
        #expect(lastAppliedBorderFrame(on: controller) == initialFrame)

        observedFrame = focusedFrame
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: focusedPid, level: 0, frame: .zero)
        }
        controller.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .frameChanged(windowId: 903)
        )
        #expect(lastAppliedBorderWindowId(on: controller) == 903)
        #expect(lastAppliedBorderFrame(on: controller) == focusedFrame)
    }
}
