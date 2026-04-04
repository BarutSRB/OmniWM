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

@Suite @MainActor struct ReconcileStateTests {
    @Test func windowAdmissionSeedsReconcileSlicesAndTrace() throws {
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

        let trace = manager.reconcileTraceSnapshotForTests()
        #expect(trace.contains { record in
            if case let .windowAdmitted(recordedToken, recordedWorkspaceId, _, recordedMode, _) = record.event {
                return recordedToken == token
                    && recordedWorkspaceId == workspaceId
                    && recordedMode == .floating
            }
            return false
        })
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
        let hydrationTxn = try #require(manager.reconcileTraceSnapshotForTests().last)

        #expect(manager.windowMode(for: token) == .floating)
        #expect(restoredFrame == CGRect(x: 280, y: 180, width: 760, height: 520))
        #expect(manager.restoreIntent(for: token)?.rescueEligible == true)
        #expect(manager.consumedBootPersistedWindowRestoreKeysForTests().contains(catalog.entries[0].key))
        #expect(hydrationTxn.plan.persistedHydration?.consumedKey == catalog.entries[0].key)
        #expect(hydrationTxn.plan.persistedHydration?.targetMode == .floating)
        #expect(hydrationTxn.plan.notes.contains("persisted_hydration"))
        #expect(hydrationTxn.plan.restoreIntent?.rescueEligible == true)
        #expect(hydrationTxn.invariantViolations.isEmpty)
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

        let traceCountBeforeEnrichment = manager.reconcileTraceSnapshotForTests().count
        _ = manager.updateManagedReplacementTitle("Needs Title", for: token)
        let traces = manager.reconcileTraceSnapshotForTests()
        let enrichmentTxn = try #require(traces.last)

        #expect(manager.workspace(for: token) == workspace2)
        #expect(manager.windowMode(for: token) == .floating)
        #expect(manager.replacementCorrelation(for: token) == nil)
        #expect(manager.consumedBootPersistedWindowRestoreKeysForTests() == Set(catalog.entries.map(\.key)))
        #expect(traces.count == traceCountBeforeEnrichment + 1)
        if case let .managedReplacementMetadataChanged(recordedToken, recordedWorkspaceId, recordedMonitorId, source) = enrichmentTxn.event {
            #expect(recordedToken == token)
            #expect(recordedWorkspaceId == workspace1)
            #expect(recordedMonitorId == monitor.id)
            #expect(source == .workspaceManager)
        } else {
            Issue.record("Expected metadata enrichment to record a single managed replacement reconcile event")
        }
        #expect(enrichmentTxn.plan.persistedHydration?.workspaceId == workspace2)
        #expect(enrichmentTxn.plan.persistedHydration?.targetMode == .floating)
        #expect(enrichmentTxn.plan.notes.contains("persisted_hydration"))
        #expect(enrichmentTxn.invariantViolations.isEmpty)
        let enrichedWindow = try #require(enrichmentTxn.snapshot.windows.first { $0.token == token })
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

        let traceCountBeforeTopology = manager.reconcileTraceSnapshotForTests().count
        let newMonitor = makeLayoutPlanTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(9),
            name: "New Primary",
            x: 0,
            y: 0
        )
        manager.applyMonitorConfigurationChange([newMonitor])

        let traces = manager.reconcileTraceSnapshotForTests()
        let topologyTxn = try #require(traces.last)
        let reconciledWindow = try #require(topologyTxn.snapshot.windows.first { $0.token == token })

        #expect(traces.count == traceCountBeforeTopology + 1)
        if case let .topologyChanged(displays, source) = topologyTxn.event {
            #expect(displays == [DisplayFingerprint(monitor: newMonitor)])
            #expect(source == .workspaceManager)
        } else {
            Issue.record("Expected topology change to be recorded as a single reconcile transaction")
        }
        #expect(topologyTxn.plan.topologyTransition?.previousMonitors == [oldMonitor])
        #expect(topologyTxn.plan.topologyTransition?.newMonitors == [newMonitor])
        #expect(topologyTxn.plan.topologyTransition?.refreshRestoreIntents == true)
        #expect(topologyTxn.snapshot.topologyProfile == TopologyProfile(monitors: [newMonitor]))
        #expect(manager.observedState(for: token)?.monitorId == newMonitor.id)
        #expect(manager.desiredState(for: token)?.monitorId == newMonitor.id)
        #expect(reconciledWindow.observedState.monitorId == newMonitor.id)
        #expect(reconciledWindow.desiredState.monitorId == newMonitor.id)
        #expect(topologyTxn.invariantViolations.isEmpty)
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

        let traceCountBeforeTopology = manager.reconcileTraceSnapshotForTests().count
        manager.applyMonitorConfigurationChange([primary])

        let traces = manager.reconcileTraceSnapshotForTests()
        let topologyTxn = try #require(traces.last)

        #expect(traces.count == traceCountBeforeTopology + 1)
        #expect(topologyTxn.plan.topologyTransition?.visibleAssignments.count == 1)
        #expect(topologyTxn.plan.topologyTransition?.disconnectedVisibleWorkspaceCache.count == 1)
        #expect(topologyTxn.plan.topologyTransition?.newMonitors == [primary])
        #expect(topologyTxn.snapshot.topologyProfile == TopologyProfile(monitors: [primary]))
        #expect(topologyTxn.invariantViolations.isEmpty)
    }

    @Test func runtimeStoreRecordsNormalizedEventAndDumpHooks() throws {
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

        _ = manager.recordReconcileEvent(
            .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                mode: .tiling,
                source: .command
            )
        )

        let trace = try #require(manager.reconcileTraceSnapshotForTests().last)
        if case let .windowModeChanged(_, _, monitorId, _, _) = trace.normalizedEvent {
            #expect(monitorId == monitor.id)
        } else {
            Issue.record("Expected normalized window mode change event")
        }
        #expect(manager.reconcileSnapshotDump().contains("topology displays=1"))
        #expect(manager.reconcileTraceDump(limit: 1).contains("window_mode_changed"))
    }

    @Test func focusEventsPublishPendingFocusAndLeaseIntoSnapshotDump() throws {
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([makeLayoutPlanPrimaryTestMonitor()])

        let workspaceId = try #require(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            makeLayoutPlanTestWindow(windowId: 9501),
            pid: 9501,
            windowId: 9501,
            to: workspaceId
        )

        #expect(manager.beginManagedFocusRequest(token, in: workspaceId))
        _ = manager.recordReconcileEvent(
            .focusLeaseChanged(
                lease: FocusPolicyLease(
                    owner: .nativeMenu,
                    reason: "menu_anywhere",
                    suppressesFocusFollowsMouse: true,
                    expiresAt: nil
                ),
                source: .focusPolicy
            )
        )

        let dump = manager.reconcileSnapshotDump()
        #expect(dump.contains("pending-focus=\(String(describing: token))"))
        #expect(dump.contains("focus-lease=native_menu"))
    }
}
