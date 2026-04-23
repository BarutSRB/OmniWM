// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeRestorePlannerTestMonitor(
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

private func makeRestorePlannerWindowSnapshot(
    token: WindowToken,
    workspaceId: WorkspaceDescriptor.ID,
    mode: TrackedWindowMode = .floating
) -> ReconcileWindowSnapshot {
    ReconcileWindowSnapshot(
        token: token,
        workspaceId: workspaceId,
        mode: mode,
        lifecyclePhase: mode == .floating ? .floating : .tiled,
        observedState: .initial(workspaceId: workspaceId, monitorId: nil),
        desiredState: .initial(
            workspaceId: workspaceId,
            monitorId: nil,
            disposition: mode
        ),
        restoreIntent: nil,
        replacementCorrelation: nil
    )
}

private func makeRestorePlannerSnapshot(
    focusedToken: WindowToken? = nil,
    interactionMonitorId: Monitor.ID? = nil,
    previousInteractionMonitorId: Monitor.ID? = nil,
    windows: [ReconcileWindowSnapshot] = []
) -> ReconcileSnapshot {
    ReconcileSnapshot(
        topologyProfile: TopologyProfile(monitors: []),
        focusSession: FocusSessionSnapshot(
            focusedToken: focusedToken,
            pendingManagedFocus: .empty,
            focusLease: nil,
            isNonManagedFocusActive: false,
            isAppFullscreenActive: false,
            interactionMonitorId: interactionMonitorId,
            previousInteractionMonitorId: previousInteractionMonitorId
        ),
        windows: windows
    )
}

private func makeRestorePlannerPersistedEntry(
    metadata: ManagedReplacementMetadata,
    workspaceName: String,
    preferredMonitor: DisplayFingerprint? = nil,
    floatingFrame: CGRect? = nil,
    normalizedFloatingOrigin: CGPoint? = nil,
    restoreToFloating: Bool = true
) -> PersistedWindowRestoreEntry {
    PersistedWindowRestoreEntry(
        key: PersistedWindowRestoreKey(metadata: metadata)!,
        restoreIntent: PersistedRestoreIntent(
            workspaceName: workspaceName,
            topologyProfile: TopologyProfile(monitors: []),
            preferredMonitor: preferredMonitor,
            floatingFrame: floatingFrame,
            normalizedFloatingOrigin: normalizedFloatingOrigin,
            restoreToFloating: restoreToFloating,
            rescueEligible: true
        )
    )
}

@Suite struct RestorePlannerTests {
    @Test func eventPlanningPreservesRefreshRoutingMatrix() {
        let planner = RestorePlanner()
        let monitor = makeRestorePlannerTestMonitor(
            displayId: 10,
            name: "Main",
            x: 0,
            y: 0
        )
        let snapshot = makeRestorePlannerSnapshot()

        let topologyPlan = planner.planEvent(
            .init(
                event: .topologyChanged(
                    displays: [DisplayFingerprint(monitor: monitor)],
                    source: .service
                ),
                snapshot: snapshot,
                monitors: [monitor]
            )
        )
        let activeSpacePlan = planner.planEvent(
            .init(
                event: .activeSpaceChanged(source: .service),
                snapshot: snapshot,
                monitors: [monitor]
            )
        )
        let wakePlan = planner.planEvent(
            .init(
                event: .systemWake(source: .service),
                snapshot: snapshot,
                monitors: [monitor]
            )
        )
        let sleepPlan = planner.planEvent(
            .init(
                event: .systemSleep(source: .service),
                snapshot: snapshot,
                monitors: [monitor]
            )
        )
        let removedPlan = planner.planEvent(
            .init(
                event: .windowRemoved(
                    token: WindowToken(pid: 91, windowId: 902),
                    workspaceId: nil,
                    source: .service
                ),
                snapshot: snapshot,
                monitors: [monitor]
            )
        )

        #expect(topologyPlan.refreshRestoreIntents == true)
        #expect(topologyPlan.notes == ["restore_refresh=topology"])
        #expect(activeSpacePlan.refreshRestoreIntents == true)
        #expect(activeSpacePlan.notes == ["restore_refresh=active_space"])
        #expect(wakePlan.refreshRestoreIntents == true)
        #expect(wakePlan.notes == ["restore_refresh=system_wake"])
        #expect(sleepPlan.refreshRestoreIntents == false)
        #expect(sleepPlan.notes == ["restore_refresh=system_sleep"])
        #expect(removedPlan.refreshRestoreIntents == false)
        #expect(removedPlan.notes.isEmpty)
    }

    @Test func eventPlanningNormalizesInteractionMonitorToSortedFallbackAndClearsInvalidPrevious() {
        let planner = RestorePlanner()
        let left = makeRestorePlannerTestMonitor(
            displayId: 10,
            name: "Left",
            x: 0,
            y: 0
        )
        let right = makeRestorePlannerTestMonitor(
            displayId: 20,
            name: "Right",
            x: 1920,
            y: 0
        )
        let snapshot = makeRestorePlannerSnapshot(
            interactionMonitorId: Monitor.ID(displayId: 999),
            previousInteractionMonitorId: Monitor.ID(displayId: 998)
        )

        let plan = planner.planEvent(
            .init(
                event: .systemSleep(source: .service),
                snapshot: snapshot,
                monitors: [right, left]
            )
        )

        #expect(plan.interactionMonitorId == left.id)
        #expect(plan.previousInteractionMonitorId == nil)
    }

    @Test func persistedHydrationRequiresExactlyOneUnconsumedMatchAndResolvableWorkspace() {
        let planner = RestorePlanner()
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.editor",
            workspaceId: workspaceId,
            mode: .tiling,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Doc",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let matching = makeRestorePlannerPersistedEntry(
            metadata: metadata,
            workspaceName: "2"
        )
        let nonMatching = makeRestorePlannerPersistedEntry(
            metadata: ManagedReplacementMetadata(
                bundleId: "com.example.editor",
                workspaceId: workspaceId,
                mode: .tiling,
                role: "AXWindow",
                subrole: "AXStandardWindow",
                title: "Other",
                windowLevel: 0,
                parentWindowId: nil,
                frame: nil
            ),
            workspaceName: "2"
        )

        let noMatch = planner.planPersistedHydration(
            .init(
                metadata: metadata,
                catalog: .init(entries: [nonMatching]),
                consumedKeys: [],
                monitors: [],
                workspaceIdForName: { _ in workspaceId }
            )
        )
        let ambiguous = planner.planPersistedHydration(
            .init(
                metadata: metadata,
                catalog: .init(entries: [matching, matching]),
                consumedKeys: [],
                monitors: [],
                workspaceIdForName: { _ in workspaceId }
            )
        )
        let missingWorkspace = planner.planPersistedHydration(
            .init(
                metadata: metadata,
                catalog: .init(entries: [matching]),
                consumedKeys: [],
                monitors: [],
                workspaceIdForName: { _ in nil }
            )
        )
        let consumed = planner.planPersistedHydration(
            .init(
                metadata: metadata,
                catalog: .init(entries: [matching]),
                consumedKeys: [matching.key],
                monitors: [],
                workspaceIdForName: { _ in workspaceId }
            )
        )

        #expect(noMatch == nil)
        #expect(ambiguous == nil)
        #expect(missingWorkspace == nil)
        #expect(consumed == nil)
    }

    @Test func persistedHydrationUsesExactFingerprintAndPreservesMetadataModeWhenRestoreToFloatingIsDisabled() {
        let planner = RestorePlanner()
        let monitor = makeRestorePlannerTestMonitor(
            displayId: 60,
            name: "Studio",
            x: 0,
            y: 0,
            width: 1600,
            height: 900
        )
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.editor",
            workspaceId: workspaceId,
            mode: .tiling,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Exact",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let entry = makeRestorePlannerPersistedEntry(
            metadata: metadata,
            workspaceName: "2",
            preferredMonitor: DisplayFingerprint(monitor: monitor),
            floatingFrame: CGRect(x: 120, y: 140, width: 480, height: 320),
            normalizedFloatingOrigin: CGPoint(x: 0.2, y: 0.3),
            restoreToFloating: false
        )

        let plan = planner.planPersistedHydration(
            .init(
                metadata: metadata,
                catalog: .init(entries: [entry]),
                consumedKeys: [],
                monitors: [monitor],
                workspaceIdForName: { _ in workspaceId }
            )
        )

        #expect(plan?.workspaceId == workspaceId)
        #expect(plan?.preferredMonitorId == monitor.id)
        #expect(plan?.targetMode == .tiling)
        #expect(plan?.floatingFrame == nil)
        #expect(plan?.consumedKey == entry.key)
    }

    @Test func persistedHydrationPrefersExactDisplayIdAndAppliesNormalizedOriginWhenPreferredMonitorChanged() {
        let planner = RestorePlanner()
        let exactDisplayId = makeRestorePlannerTestMonitor(
            displayId: 70,
            name: "Other",
            x: 5000,
            y: 0,
            width: 1200,
            height: 800
        )
        let betterFallback = makeRestorePlannerTestMonitor(
            displayId: 71,
            name: "Studio",
            x: 0,
            y: 0,
            width: 1600,
            height: 900
        )
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.editor",
            workspaceId: workspaceId,
            mode: .tiling,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Display Id Wins",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let preferredFingerprint = DisplayFingerprint(
            monitor: makeRestorePlannerTestMonitor(
                displayId: 70,
                name: "Studio",
                x: 0,
                y: 0,
                width: 1600,
                height: 900
            )
        )
        let entry = makeRestorePlannerPersistedEntry(
            metadata: metadata,
            workspaceName: "2",
            preferredMonitor: preferredFingerprint,
            floatingFrame: CGRect(x: 1400, y: 780, width: 300, height: 200),
            normalizedFloatingOrigin: CGPoint(x: 1, y: 1),
            restoreToFloating: true
        )

        let plan = planner.planPersistedHydration(
            .init(
                metadata: metadata,
                catalog: .init(entries: [entry]),
                consumedKeys: [],
                monitors: [betterFallback, exactDisplayId],
                workspaceIdForName: { _ in workspaceId }
            )
        )

        #expect(plan?.preferredMonitorId == exactDisplayId.id)
        #expect(plan?.targetMode == .floating)
        #expect(plan?.floatingFrame == CGRect(x: 5900, y: 600, width: 300, height: 200))
    }

    @Test func persistedHydrationFallbackScoringPrefersNamePenaltyBeforeGeometry() {
        let planner = RestorePlanner()
        let betterName = makeRestorePlannerTestMonitor(
            displayId: 81,
            name: "Studio Display",
            x: 300,
            y: 0,
            width: 1600,
            height: 900
        )
        let betterGeometry = makeRestorePlannerTestMonitor(
            displayId: 82,
            name: "Other",
            x: 0,
            y: 0,
            width: 1600,
            height: 900
        )
        let workspaceId = WorkspaceDescriptor.ID()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.editor",
            workspaceId: workspaceId,
            mode: .tiling,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Fallback",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let preferredFingerprint = DisplayFingerprint(
            monitor: makeRestorePlannerTestMonitor(
                displayId: 80,
                name: "Studio Display",
                x: 0,
                y: 0,
                width: 1600,
                height: 900
            )
        )
        let entry = makeRestorePlannerPersistedEntry(
            metadata: metadata,
            workspaceName: "2",
            preferredMonitor: preferredFingerprint
        )

        let plan = planner.planPersistedHydration(
            .init(
                metadata: metadata,
                catalog: .init(entries: [entry]),
                consumedKeys: [],
                monitors: [betterGeometry, betterName],
                workspaceIdForName: { _ in workspaceId }
            )
        )

        #expect(plan?.preferredMonitorId == betterName.id)
    }

    @Test func floatingRescueSkipsHiddenAndApproximatelyEqualCandidatesButRescuesMissingOrMovedFrames() {
        let planner = RestorePlanner()
        let monitor = makeRestorePlannerTestMonitor(
            displayId: 90,
            name: "Main",
            x: 0,
            y: 0
        )
        let workspaceId = WorkspaceDescriptor.ID()

        let plan = planner.planFloatingRescue([
            .init(
                token: WindowToken(pid: 1, windowId: 1),
                pid: 1,
                windowId: 1,
                workspaceId: workspaceId,
                targetMonitor: monitor,
                currentFrame: nil,
                floatingFrame: CGRect(x: 100, y: 100, width: 300, height: 200),
                normalizedOrigin: nil,
                referenceMonitorId: nil,
                isScratchpadHidden: false,
                isWorkspaceInactiveHidden: false
            ),
            .init(
                token: WindowToken(pid: 2, windowId: 2),
                pid: 2,
                windowId: 2,
                workspaceId: workspaceId,
                targetMonitor: monitor,
                currentFrame: CGRect(x: 100.4, y: 100.5, width: 299.4, height: 200.2),
                floatingFrame: CGRect(x: 100, y: 100, width: 300, height: 200),
                normalizedOrigin: nil,
                referenceMonitorId: nil,
                isScratchpadHidden: false,
                isWorkspaceInactiveHidden: false
            ),
            .init(
                token: WindowToken(pid: 3, windowId: 3),
                pid: 3,
                windowId: 3,
                workspaceId: workspaceId,
                targetMonitor: monitor,
                currentFrame: CGRect(x: 0, y: 0, width: 300, height: 200),
                floatingFrame: CGRect(x: 500, y: 300, width: 300, height: 200),
                normalizedOrigin: nil,
                referenceMonitorId: nil,
                isScratchpadHidden: false,
                isWorkspaceInactiveHidden: false
            ),
            .init(
                token: WindowToken(pid: 4, windowId: 4),
                pid: 4,
                windowId: 4,
                workspaceId: workspaceId,
                targetMonitor: monitor,
                currentFrame: nil,
                floatingFrame: CGRect(x: 200, y: 160, width: 300, height: 200),
                normalizedOrigin: nil,
                referenceMonitorId: nil,
                isScratchpadHidden: true,
                isWorkspaceInactiveHidden: false
            ),
        ])

        #expect(plan.rescuedCount == 2)
        #expect(plan.operations.map(\.windowId) == [1, 3])
    }

    @Test func floatingRescueOrdersRescuesDeterministicallyByStableWindowIdentity() {
        let planner = RestorePlanner()
        let monitor = makeRestorePlannerTestMonitor(
            displayId: 91,
            name: "Main",
            x: 0,
            y: 0
        )
        let laterWorkspace = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlierWorkspace = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let plan = planner.planFloatingRescue([
            .init(
                token: WindowToken(pid: 4, windowId: 400),
                pid: 4,
                windowId: 400,
                workspaceId: laterWorkspace,
                targetMonitor: monitor,
                currentFrame: CGRect(x: 0, y: 0, width: 300, height: 200),
                floatingFrame: CGRect(x: 500, y: 300, width: 300, height: 200),
                normalizedOrigin: nil,
                referenceMonitorId: nil,
                isScratchpadHidden: false,
                isWorkspaceInactiveHidden: false
            ),
            .init(
                token: WindowToken(pid: 1, windowId: 100),
                pid: 1,
                windowId: 100,
                workspaceId: earlierWorkspace,
                targetMonitor: monitor,
                currentFrame: CGRect(x: 0, y: 0, width: 300, height: 200),
                floatingFrame: CGRect(x: 450, y: 260, width: 300, height: 200),
                normalizedOrigin: nil,
                referenceMonitorId: nil,
                isScratchpadHidden: false,
                isWorkspaceInactiveHidden: false
            ),
        ])

        #expect(plan.operations.map(\.windowId) == [100, 400])
    }
}
