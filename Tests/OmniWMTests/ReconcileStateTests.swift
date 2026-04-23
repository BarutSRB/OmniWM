// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

private func makeReconcilePersistedRestoreCatalog(
    workspaceName: String,
    monitor: Monitor,
    title: String,
    bundleId: String = "com.example.editor",
    floatingFrame: CGRect = CGRect(x: 280, y: 180, width: 760, height: 520)
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
                restoreIntent: PersistedRestoreIntent(
                    workspaceName: workspaceName,
                    topologyProfile: TopologyProfile(monitors: [monitor]),
                    preferredMonitor: DisplayFingerprint(monitor: monitor),
                    floatingFrame: floatingFrame,
                    normalizedFloatingOrigin: CGPoint(x: 0.22, y: 0.18),
                    restoreToFloating: true,
                    rescueEligible: true
                )
            )
        ]
    )
}

@MainActor
private func makeReconcileRemovalTestManager() -> (
    manager: WorkspaceManager,
    monitor: Monitor,
    workspaceId: WorkspaceDescriptor.ID
) {
    let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
    settings.workspaceConfigurations = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main)
    ]
    let manager = WorkspaceManager(settings: settings)
    let monitor = makeLayoutPlanPrimaryTestMonitor()
    manager.applyMonitorConfigurationChange([monitor])

    guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
        fatalError("Failed to create reconcile removal test workspace")
    }

    return (manager, monitor, workspaceId)
}

private func makeReconcileKernelSnapshot(monitors: [Monitor]) -> ReconcileSnapshot {
    ReconcileSnapshot(
        topologyProfile: TopologyProfile(monitors: monitors),
        focusSession: FocusSessionSnapshot(
            focusedToken: nil,
            pendingManagedFocus: .empty,
            focusLease: nil,
            isNonManagedFocusActive: false,
            isAppFullscreenActive: false,
            interactionMonitorId: nil,
            previousInteractionMonitorId: nil
        ),
        windows: []
    )
}

@Suite @MainActor struct ReconcileStateTests {
    @Test func windowAdmissionSeedsReconcileSlices() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9001),
            pid: getpid(),
            windowId: 9001,
            to: workspaceId,
            mode: .floating
        )

        let entry = try #require(manager.entry(for: token))
        #expect(entry.lifecyclePhase == .floating)
        #expect(entry.observedState.workspaceId == workspaceId)
        #expect(entry.desiredState.workspaceId == workspaceId)
        #expect(entry.desiredState.disposition == .floating)
        #expect(entry.restoreIntent?.topologyProfile.displays.count == 1)
    }

    @Test func rekeyWindowStoresBoundedReplacementCorrelation() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([makeLayoutPlanPrimaryTestMonitor()])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9101),
            pid: 9101,
            windowId: 9101,
            to: workspaceId
        )
        let newToken = WindowToken(pid: 9101, windowId: 9102)
        let replacementMetadata = ManagedReplacementMetadata(
            bundleId: "com.example.browser",
            workspaceId: workspaceId,
            mode: .tiling,
            role: nil,
            subrole: nil,
            title: "Tabbed Replacement",
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )

        let entry = try #require(
            manager.rekeyWindow(
                from: token,
                to: newToken,
                newAXRef: makeLayoutPlanTestWindow(windowId: 9102),
                managedReplacementMetadata: replacementMetadata
            )
        )

        #expect(entry.token == newToken)
        #expect(entry.replacementCorrelation?.previousToken == token)
        #expect(entry.replacementCorrelation?.nextToken == newToken)
        #expect(entry.replacementCorrelation?.reason == .managedReplacement)
    }

    @Test func omissionRemovalMatchesExplicitRemoval() throws {
        let explicitFixture = makeReconcileRemovalTestManager()
        let explicitToken = explicitFixture.manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9151),
            pid: 9_151,
            windowId: 9151,
            to: explicitFixture.workspaceId,
            mode: .floating
        )
        #expect(explicitFixture.manager.restoreIntent(for: explicitToken) != nil)

        _ = explicitFixture.manager.removeWindow(pid: explicitToken.pid, windowId: explicitToken.windowId)

        #expect(explicitFixture.manager.entry(for: explicitToken) == nil)

        let omissionFixture = makeReconcileRemovalTestManager()
        let omissionToken = omissionFixture.manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9152),
            pid: 9_152,
            windowId: 9152,
            to: omissionFixture.workspaceId,
            mode: .floating
        )
        #expect(omissionFixture.manager.restoreIntent(for: omissionToken) != nil)

        omissionFixture.manager.removeMissing(keys: [], requiredConsecutiveMisses: 1)

        #expect(omissionFixture.manager.entry(for: omissionToken) == nil)
    }

    @Test func focusPolicyBlocksFocusFollowsMouseDuringNativeMenuLease() {
        var now = Date()
        let engine = FocusPolicyEngine(nowProvider: { now })

        engine.beginLease(
            owner: .nativeMenu,
            reason: "menu_anywhere",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )

        #expect(engine.evaluate(.focusFollowsMouse).allowsFocusChange == false)
        #expect(engine.evaluate(.managedAppActivation(source: .workspaceDidActivateApplication)).allowsFocusChange == false)
        #expect(engine.evaluate(.managedAppActivation(source: .focusedWindowChanged)).allowsFocusChange)

        engine.endLease(owner: .nativeMenu)
        now = now.addingTimeInterval(1)
        #expect(engine.evaluate(.focusFollowsMouse).allowsFocusChange)
    }

    @Test func focusPolicyRetainsNativeMenuSuppressionAfterAppSwitchLeaseExpires() {
        var now = Date()
        let engine = FocusPolicyEngine(nowProvider: { now })
        var observedLeaseOwners: [FocusPolicyLeaseOwner?] = []
        engine.onLeaseChanged = { observedLeaseOwners.append($0?.owner) }

        engine.beginLease(
            owner: .nativeMenu,
            reason: "menu_anywhere",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )
        engine.beginLease(
            owner: .nativeAppSwitch,
            reason: "app_switch",
            suppressesFocusFollowsMouse: true,
            duration: 0.4
        )

        #expect(engine.activeLease?.owner == .nativeMenu)

        now = now.addingTimeInterval(0.5)

        #expect(engine.activeLease?.owner == .nativeMenu)
        #expect(engine.evaluate(.focusFollowsMouse).allowsFocusChange == false)
        #expect(engine.evaluate(.managedAppActivation(source: .workspaceDidActivateApplication)).allowsFocusChange == false)
        #expect(engine.evaluate(.managedAppActivation(source: .focusedWindowChanged)).allowsFocusChange)

        engine.endLease(owner: .nativeMenu)

        #expect(engine.activeLease == nil)
        #expect(engine.evaluate(.focusFollowsMouse).allowsFocusChange)
        #expect(engine.evaluate(.managedAppActivation(source: .workspaceDidActivateApplication)).allowsFocusChange)
        #expect(observedLeaseOwners == [.nativeMenu, nil])
    }

    @Test func rescueOffscreenWindowsClampsTrackedFloatingFramesWhenLiveFrameUnavailableAndRaisesWindow() throws {
        var raiseCount = 0
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in
                raiseCount += 1
            }
        )
        let controller = makeLayoutPlanTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main)
            ],
            windowFocusOperations: operations
        )
        let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let monitor = try #require(controller.workspaceManager.monitor(for: workspaceId))

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9201),
            pid: 9201,
            windowId: 9201,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: monitor.visibleFrame.minX - 3000, y: monitor.visibleFrame.minY - 2000, width: 320, height: 200),
            for: token,
            referenceMonitor: monitor
        )

        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)

        let rescued = controller.rescueOffscreenWindows()
        let appliedFrame = try #require(controller.axManager.lastAppliedFrame(for: token.windowId))

        #expect(rescued == 1)
        #expect(monitor.visibleFrame.contains(appliedFrame))
        #expect(controller.workspaceManager.resolvedFloatingFrame(for: token, preferredMonitor: monitor) == appliedFrame)
        #expect(raiseCount == 1)
        #expect(controller.rescueOffscreenWindows() == 0)
        #expect(raiseCount == 1)
    }

    @Test func rescueOffscreenWindowsDoesNotSurfaceWorkspaceInactiveFloatingWindowOnHiddenWorkspace() throws {
        let controller = makeLayoutPlanTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
            ]
        )
        let workspace1 = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let workspace2 = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let monitor = try #require(controller.workspaceManager.monitor(for: workspace1))

        #expect(controller.workspaceManager.setActiveWorkspace(workspace1, on: monitor.id))
        #expect(controller.workspaceManager.visibleWorkspaceIds().contains(workspace1))
        #expect(!controller.workspaceManager.visibleWorkspaceIds().contains(workspace2))

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9202),
            pid: 9202,
            windowId: 9202,
            to: workspace2,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: monitor.visibleFrame.maxX + 2200, y: monitor.visibleFrame.maxY + 1600, width: 320, height: 200),
            for: token,
            referenceMonitor: monitor
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: monitor
        )

        let rescued = controller.rescueOffscreenWindows()

        #expect(rescued == 0)
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
    }

    @Test func bootstrapHydratesPersistedRestoreAndAppliesFloatingModeWhenInitialModeDiffers() throws {
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        let catalog = makeReconcilePersistedRestoreCatalog(
            workspaceName: "1",
            monitor: monitor,
            title: "Bootstrap Restore"
        )
        settings.savePersistedWindowRestoreCatalog(catalog)

        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        #expect(manager.bootPersistedWindowRestoreCatalogForTests() == catalog)

        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9301),
            pid: 9301,
            windowId: 9301,
            to: workspaceId,
            mode: .tiling,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.editor",
                workspaceId: workspaceId,
                mode: .tiling,
                role: "AXWindow",
                subrole: "AXStandardWindow",
                title: "Bootstrap Restore",
                windowLevel: 0,
                parentWindowId: nil,
                frame: nil
            )
        )

        let restoredFrame = try #require(manager.resolvedFloatingFrame(for: token, preferredMonitor: monitor))
        let restoreIntent = try #require(manager.restoreIntent(for: token))
        let floatingState = try #require(manager.floatingState(for: token))

        #expect(manager.windowMode(for: token) == .floating)
        #expect(restoredFrame == CGRect(x: 280, y: 180, width: 760, height: 520))
        #expect(restoreIntent.rescueEligible == true)
        #expect(floatingState.normalizedOrigin == restoreIntent.normalizedFloatingOrigin)
        #expect(floatingState.referenceMonitorId == monitor.id)
        #expect(floatingState.restoreToFloating == restoreIntent.restoreToFloating)
        #expect(manager.consumedBootPersistedWindowRestoreKeysForTests().contains(catalog.entries[0].key))
    }

    @Test func hydrationRetriesAfterMetadataBecomesRicher() throws {
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        let catalog = makeReconcilePersistedRestoreCatalog(
            workspaceName: "2",
            monitor: monitor,
            title: "Needs Title"
        )
        settings.savePersistedWindowRestoreCatalog(catalog)

        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([monitor])

        let workspace1 = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let workspace2 = try #require(manager.workspaceId(for: "2", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9302),
            pid: 9302,
            windowId: 9302,
            to: workspace1,
            mode: .tiling,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.editor",
                workspaceId: workspace1,
                mode: .tiling,
                role: "AXWindow",
                subrole: "AXStandardWindow",
                title: nil,
                windowLevel: 0,
                parentWindowId: nil,
                frame: nil
            )
        )

        #expect(manager.workspace(for: token) == workspace1)
        #expect(manager.windowMode(for: token) == .tiling)
        #expect(manager.consumedBootPersistedWindowRestoreKeysForTests().isEmpty)

        _ = manager.updateManagedReplacementTitle("Needs Title", for: token)

        #expect(manager.workspace(for: token) == workspace2)
        #expect(manager.windowMode(for: token) == .floating)
        #expect(manager.replacementCorrelation(for: token) == nil)
        #expect(manager.consumedBootPersistedWindowRestoreKeysForTests() == Set(catalog.entries.map(\.key)))
        let enrichedWindow = try #require(manager.reconcileSnapshot().windows.first { $0.token == token })
        #expect(enrichedWindow.workspaceId == workspace2)
        #expect(enrichedWindow.desiredState.workspaceId == workspace2)
        #expect(enrichedWindow.desiredState.disposition == .floating)
    }

    @Test func topologyChangeRefreshesMonitorReferencesInsideSingleTransaction() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        let oldMonitor = makeLayoutPlanPrimaryTestMonitor(name: "Old Primary")
        manager.applyMonitorConfigurationChange([oldMonitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9601),
            pid: 9601,
            windowId: 9601,
            to: workspaceId
        )

        let newMonitor = makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(9),
            name: "New Primary",
            x: 0,
            y: 0
        )
        manager.applyMonitorConfigurationChange([newMonitor])

        let snapshot = manager.reconcileSnapshot()
        let reconciledWindow = try #require(snapshot.windows.first { $0.token == token })

        #expect(snapshot.topologyProfile == TopologyProfile(monitors: [newMonitor]))
        #expect(manager.observedState(for: token)?.monitorId == newMonitor.id)
        #expect(manager.desiredState(for: token)?.monitorId == newMonitor.id)
        #expect(reconciledWindow.observedState.monitorId == newMonitor.id)
        #expect(reconciledWindow.desiredState.monitorId == newMonitor.id)
    }

    @Test func topologyChangeTracksVisibleAssignmentsAndDisconnectedCacheTogether() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
        let manager = WorkspaceManager(settings: settings)
        let primary = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
        let secondary = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
        manager.applyMonitorConfigurationChange([primary, secondary])

        _ = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        _ = try #require(manager.workspaceId(for: "2", createIfMissing: true))

        manager.applyMonitorConfigurationChange([primary])

        let snapshot = manager.reconcileSnapshot()

        #expect(snapshot.topologyProfile == TopologyProfile(monitors: [primary]))
    }

    @Test func runtimeStoreRecordsNormalizedEvent() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9401),
            pid: 9401,
            windowId: 9401,
            to: workspaceId
        )

        let txn = manager.recordReconcileEvent(
            .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                mode: .tiling,
                source: .command
            )
        )

        if case let .windowModeChanged(_, _, monitorId, _, _) = txn.normalizedEvent {
            #expect(monitorId == monitor.id)
        } else {
            Issue.record("Expected normalized window mode change event")
        }
    }

    @Test func rekeyMigratesFocusedAndPendingManagedFocusTokens() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([makeLayoutPlanPrimaryTestMonitor()])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9701),
            pid: 9701,
            windowId: 9701,
            to: workspaceId
        )

        #expect(manager.setManagedFocus(token, in: workspaceId))
        #expect(manager.beginManagedFocusRequest(token, in: workspaceId))

        let newToken = WindowToken(pid: 9701, windowId: 9702)
        _ = try #require(
            manager.rekeyWindow(
                from: token,
                to: newToken,
                newAXRef: makeLayoutPlanTestWindow(windowId: 9702)
            )
        )

        let focusSession = manager.reconcileSnapshot().focusSession
        #expect(focusSession.focusedToken == newToken)
        #expect(focusSession.pendingManagedFocus.token == newToken)
    }

    @Test func workspaceAssignmentAndModeChangeUpdateObservedAndDesiredState() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary),
        ]
        let manager = WorkspaceManager(settings: settings)
        let primary = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
        let secondary = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
        manager.applyMonitorConfigurationChange([primary, secondary])

        let workspace1 = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let workspace2 = try #require(manager.workspaceId(for: "2", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9703),
            pid: 9703,
            windowId: 9703,
            to: workspace1
        )

        manager.setWorkspace(for: token, to: workspace2)
        #expect(manager.observedState(for: token)?.workspaceId == workspace2)
        #expect(manager.observedState(for: token)?.monitorId == secondary.id)
        #expect(manager.desiredState(for: token)?.workspaceId == workspace2)
        #expect(manager.desiredState(for: token)?.monitorId == secondary.id)

        #expect(manager.setWindowMode(.floating, for: token))
        #expect(manager.lifecyclePhase(for: token) == .floating)
        #expect(manager.desiredState(for: token)?.disposition == .floating)
        #expect(manager.desiredState(for: token)?.rescueEligible == true)
    }

    @Test func hiddenStateAndNativeFullscreenTransitionsPreserveLifecycleSemantics() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9704),
            pid: 9704,
            windowId: 9704,
            to: workspaceId,
            mode: .floating
        )

        manager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: CGPoint(x: 0.15, y: 0.25),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )
        #expect(manager.lifecyclePhase(for: token) == .hidden)
        #expect(manager.observedState(for: token)?.isVisible == false)

        manager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: CGPoint(x: 0.8, y: 0.4),
                referenceMonitorId: monitor.id,
                workspaceInactive: false,
                offscreenSide: .left
            ),
            for: token
        )
        #expect(manager.lifecyclePhase(for: token) == .offscreen)
        #expect(manager.observedState(for: token)?.isVisible == false)

        manager.setHiddenState(nil, for: token)
        #expect(manager.lifecyclePhase(for: token) == .floating)
        #expect(manager.observedState(for: token)?.isVisible == true)

        manager.setLayoutReason(.nativeFullscreen, for: token)
        #expect(manager.lifecyclePhase(for: token) == .nativeFullscreen)
        #expect(manager.observedState(for: token)?.isNativeFullscreen == true)

        manager.setLayoutReason(.standard, for: token)
        #expect(manager.lifecyclePhase(for: token) == .floating)
        #expect(manager.observedState(for: token)?.isNativeFullscreen == false)
    }

    @Test func focusLifecycleEventsMutatePendingFocusAndNonManagedState() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        manager.applyMonitorConfigurationChange([monitor])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9705),
            pid: 9705,
            windowId: 9705,
            to: workspaceId
        )

        #expect(manager.beginManagedFocusRequest(token, in: workspaceId, onMonitor: monitor.id))
        var focusSession = manager.reconcileSnapshot().focusSession
        #expect(focusSession.pendingManagedFocus.token == token)
        #expect(focusSession.pendingManagedFocus.workspaceId == workspaceId)
        #expect(focusSession.pendingManagedFocus.monitorId == monitor.id)

        #expect(
            manager.confirmManagedFocus(
                token,
                in: workspaceId,
                onMonitor: monitor.id,
                appFullscreen: true,
                activateWorkspaceOnMonitor: false
            )
        )
        focusSession = manager.reconcileSnapshot().focusSession
        #expect(focusSession.focusedToken == token)
        #expect(focusSession.pendingManagedFocus == .empty)
        #expect(focusSession.isNonManagedFocusActive == false)
        #expect(focusSession.isAppFullscreenActive == true)

        #expect(manager.beginManagedFocusRequest(token, in: workspaceId))
        #expect(manager.cancelManagedFocusRequest(matching: token, workspaceId: workspaceId))
        focusSession = manager.reconcileSnapshot().focusSession
        #expect(focusSession.pendingManagedFocus == .empty)

        #expect(manager.enterNonManagedFocus(appFullscreen: false, preserveFocusedToken: false))
        focusSession = manager.reconcileSnapshot().focusSession
        #expect(focusSession.focusedToken == nil)
        #expect(focusSession.pendingManagedFocus == .empty)
        #expect(focusSession.isNonManagedFocusActive == true)
        #expect(focusSession.isAppFullscreenActive == false)
    }

    @Test func eventNormalizerAppliesFallbacksAndStringNormalization() throws {
        let workspaceId = UUID()
        let fallbackMonitor = makeLayoutPlanPrimaryTestMonitor(name: "Fallback")
        let otherMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Other", x: 1920)
        let token = WindowToken(pid: 9706, windowId: 9706)
        let entry = WindowModel.Entry(
            handle: WindowHandle(id: token),
            axRef: makeLayoutPlanTestWindow(windowId: 9706),
            workspaceId: workspaceId,
            mode: .floating,
            observedState: ObservedWindowState(
                frame: nil,
                workspaceId: workspaceId,
                monitorId: otherMonitor.id,
                isVisible: true,
                isFocused: false,
                hasAXReference: true,
                isNativeFullscreen: false
            ),
            desiredState: DesiredWindowState(
                workspaceId: workspaceId,
                monitorId: fallbackMonitor.id,
                disposition: .floating,
                floatingFrame: CGRect(x: 40, y: 50, width: 320, height: 200),
                rescueEligible: true
            ),
            managedReplacementMetadata: nil,
            floatingState: WindowModel.FloatingState(
                lastFrame: CGRect(x: 60, y: 70, width: 340, height: 220),
                normalizedOrigin: CGPoint(x: 0.3, y: 0.4),
                referenceMonitorId: otherMonitor.id,
                restoreToFloating: true
            ),
            manualLayoutOverride: nil,
            ruleEffects: .none,
            hiddenProportionalPosition: nil
        )

        let normalizedRemoved = EventNormalizer.normalize(
            event: .windowRemoved(
                token: token,
                workspaceId: nil,
                source: .command
            ),
            existingEntry: entry,
            monitors: [fallbackMonitor, otherMonitor]
        )
        if case let .windowRemoved(_, workspaceId, _) = normalizedRemoved {
            #expect(workspaceId == entry.workspaceId)
        } else {
            Issue.record("Expected normalized window removed event")
        }

        let normalizedFloatingGeometry = EventNormalizer.normalize(
            event: .floatingGeometryUpdated(
                token: token,
                workspaceId: workspaceId,
                referenceMonitorId: nil,
                frame: CGRect(x: 120, y: 160, width: 400, height: 260),
                restoreToFloating: true,
                source: .command
            ),
            existingEntry: entry,
            monitors: [fallbackMonitor, otherMonitor]
        )
        if case let .floatingGeometryUpdated(_, _, referenceMonitorId, _, _, _) = normalizedFloatingGeometry {
            #expect(referenceMonitorId == otherMonitor.id)
        } else {
            Issue.record("Expected normalized floating geometry event")
        }

        let normalizedTopology = EventNormalizer.normalize(
            event: .topologyChanged(
                displays: [
                    DisplayFingerprint(monitor: otherMonitor),
                    DisplayFingerprint(monitor: fallbackMonitor),
                    DisplayFingerprint(monitor: otherMonitor),
                ],
                source: .service
            ),
            existingEntry: nil,
            monitors: [fallbackMonitor, otherMonitor]
        )
        if case let .topologyChanged(displays, _) = normalizedTopology {
            #expect(displays == [DisplayFingerprint(monitor: fallbackMonitor), DisplayFingerprint(monitor: otherMonitor)])
        } else {
            Issue.record("Expected normalized topology event")
        }

        let normalizedLease = EventNormalizer.normalize(
            event: .focusLeaseChanged(
                lease: FocusPolicyLease(
                    owner: .nativeMenu,
                    reason: "  menu_anywhere \n",
                    suppressesFocusFollowsMouse: true,
                    expiresAt: nil
                ),
                source: .focusPolicy
            ),
            existingEntry: nil,
            monitors: [fallbackMonitor]
        )
        if case let .focusLeaseChanged(lease, _) = normalizedLease {
            #expect(lease?.reason == "menu_anywhere")
        } else {
            Issue.record("Expected normalized focus lease event")
        }
    }

    @Test func restoreIntentPrefersDesiredObservedThenFloatingMonitorAndPreservesFloatingData() {
        let workspaceId = UUID()
        let primary = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
        let secondary = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
        let tertiary = makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(12),
            name: "Tertiary",
            x: 3840,
            y: 0
        )
        let token = WindowToken(pid: 9707, windowId: 9707)
        let floatingState = WindowModel.FloatingState(
            lastFrame: CGRect(x: 260, y: 190, width: 520, height: 340),
            normalizedOrigin: CGPoint(x: 0.22, y: 0.35),
            referenceMonitorId: tertiary.id,
            restoreToFloating: true
        )

        func makeEntry(
            desiredMonitorId: Monitor.ID?,
            observedMonitorId: Monitor.ID?
        ) -> WindowModel.Entry {
            WindowModel.Entry(
                handle: WindowHandle(id: token),
                axRef: makeLayoutPlanTestWindow(windowId: 9707),
                workspaceId: workspaceId,
                mode: .floating,
                observedState: ObservedWindowState(
                    frame: nil,
                    workspaceId: workspaceId,
                    monitorId: observedMonitorId,
                    isVisible: true,
                    isFocused: false,
                    hasAXReference: true,
                    isNativeFullscreen: false
                ),
                desiredState: DesiredWindowState(
                    workspaceId: workspaceId,
                    monitorId: desiredMonitorId,
                    disposition: .floating,
                    floatingFrame: CGRect(x: 300, y: 220, width: 540, height: 360),
                    rescueEligible: false
                ),
                managedReplacementMetadata: nil,
                floatingState: floatingState,
                manualLayoutOverride: nil,
                ruleEffects: .none,
                hiddenProportionalPosition: nil
            )
        }

        let desiredFirst = StateReducer.restoreIntent(
            for: makeEntry(desiredMonitorId: primary.id, observedMonitorId: secondary.id),
            monitors: [primary, secondary, tertiary]
        )
        #expect(desiredFirst.preferredMonitor == DisplayFingerprint(monitor: primary))
        #expect(desiredFirst.floatingFrame == CGRect(x: 300, y: 220, width: 540, height: 360))
        #expect(desiredFirst.normalizedFloatingOrigin == floatingState.normalizedOrigin)
        #expect(desiredFirst.restoreToFloating == true)
        #expect(desiredFirst.rescueEligible == true)

        let observedFallback = StateReducer.restoreIntent(
            for: makeEntry(desiredMonitorId: nil, observedMonitorId: secondary.id),
            monitors: [primary, secondary, tertiary]
        )
        #expect(observedFallback.preferredMonitor == DisplayFingerprint(monitor: secondary))

        let floatingFallback = StateReducer.restoreIntent(
            for: makeEntry(desiredMonitorId: nil, observedMonitorId: nil),
            monitors: [primary, secondary, tertiary]
        )
        #expect(floatingFallback.preferredMonitor == DisplayFingerprint(monitor: tertiary))
    }

    @Test func noteOnlyReducerEventsPreserveSwiftFacingNotes() {
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        let snapshot = makeReconcileKernelSnapshot(monitors: [monitor])

        let activeSpacePlan = StateReducer.reduce(
            event: .activeSpaceChanged(source: .service),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: [monitor]
        )
        #expect(activeSpacePlan.notes == ["active_space_changed"])

        let sleepPlan = StateReducer.reduce(
            event: .systemSleep(source: .service),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: [monitor]
        )
        #expect(sleepPlan.notes == ["system_sleep"])

        let wakePlan = StateReducer.reduce(
            event: .systemWake(source: .service),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: [monitor]
        )
        #expect(wakePlan.notes == ["system_wake"])
    }
}
