// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func layoutRefreshControllerTestWriteResult(
    targetFrame: CGRect,
    currentFrameHint: CGRect?,
    observedFrame: CGRect?,
    failureReason: AXFrameWriteFailureReason?
) -> AXFrameWriteResult {
    AXFrameWriteResult(
        targetFrame: targetFrame,
        observedFrame: observedFrame,
        writeOrder: AXWindowService.frameWriteOrder(
            currentFrame: currentFrameHint,
            targetFrame: targetFrame
        ),
        sizeError: .success,
        positionError: .success,
        failureReason: failureReason
    )
}

private func makeUnavailableLayoutPlanTestWindow(windowId: Int) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateApplication(pid_t.max), windowId: windowId)
}

@Suite(.serialized) struct LayoutRefreshControllerTests {
    @Test @MainActor func hiddenEdgeRevealUsesOnePointZeroForNonZoomApps() {
        #expect(LayoutRefreshController.hiddenEdgeReveal(isZoomApp: false) == 1.0)
    }

    @Test @MainActor func hiddenEdgeRevealUsesZeroForZoom() {
        #expect(LayoutRefreshController.hiddenEdgeReveal(isZoomApp: true) == 0)
    }

    @Test @MainActor func buildMonitorSnapshotUsesConfiguredWorkspaceBarInsetInOverlappingMode() {
        let monitor = Monitor(
            id: Monitor.ID(displayId: 91),
            displayId: 91,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 772),
            hasNotch: false,
            name: "Reserved"
        )
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        controller.settings.workspaceBarPosition = .overlappingMenuBar
        controller.settings.workspaceBarHeight = 24
        controller.settings.workspaceBarReserveLayoutSpace = true

        let snapshot = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)

        #expect(snapshot.visibleFrame == monitor.visibleFrame)
        #expect(snapshot.workingFrame == CGRect(x: 0, y: 0, width: 1000, height: 748))
    }

    @Test @MainActor func backingScaleLookupUsesScreenCacheAfterFirstResolution() {
        let monitor = makeLayoutPlanPrimaryTestMonitor()
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        ScreenLookupCache.shared.resetForTests()
        defer {
            ScreenLookupCache.shared.resetForTests()
        }

        _ = controller.layoutRefreshController.backingScale(for: monitor)
        _ = controller.layoutRefreshController.backingScale(for: monitor)

    }

    @Test @MainActor func executeLayoutPlanAppliesFrameDiffAndFocusedBorder() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout executor test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 101)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 120, y: 80, width: 900, height: 640)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)
        diff.borderMode = .direct

        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: workspaceId,
                rememberedFocusToken: token
            ),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(controller.axManager.lastAppliedFrame(for: 101) == frame)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 101)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == token)
    }

    @Test @MainActor func executeLayoutPlanSkipsFrameApplicationWhenAnimationOwnsFrames() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for animation-owned frame skip test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 119)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 180, y: 120, width: 840, height: 560)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)
        diff.borderMode = .direct

        var plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: workspaceId,
                rememberedFocusToken: token
            ),
            diff: diff
        )
        plan.skipFrameApplicationForAnimation = true

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == frame)
        #expect(controller.workspaceManager.preferredFocusToken(in: workspaceId) == token)
    }

    @Test @MainActor func windowCloseAnimationCachesDisplayLinkReverseLookup() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for display-link reverse lookup test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 120)
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry for display-link reverse lookup test")
            return
        }

        AXWindowService.fastFrameProviderForTests = { axRef in
            guard axRef.windowId == token.windowId else { return nil }
            return CGRect(x: 200, y: 140, width: 720, height: 480)
        }
        defer { AXWindowService.fastFrameProviderForTests = nil }

        controller.layoutRefreshController.startWindowCloseAnimation(entry: entry, monitor: monitor)

        guard let link = controller.layoutRefreshController.layoutState.displayLinksByDisplay[monitor.displayId] else {
            Issue.record("Expected close animation to create a display link")
            return
        }

        #expect(controller.layoutRefreshController.layoutState.displayIdByLink[ObjectIdentifier(link)] == monitor.displayId)

        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: monitor.displayId,
            migrateAnimations: false
        )

        #expect(controller.layoutRefreshController.layoutState.displayLinksByDisplay[monitor.displayId] == nil)
        #expect(controller.layoutRefreshController.layoutState.displayIdByLink[ObjectIdentifier(link)] == nil)
    }

    @Test @MainActor func displayLinkSchedulingIsIdempotentAcrossAnimationEntryPoints() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for display-link scheduling test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 121)
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing managed entry for display-link scheduling test")
            return
        }

        var scheduledDisplayIds: [CGDirectDisplayID] = []
        controller.layoutRefreshController.displayLinkScheduleHookForTests = { displayId in
            scheduledDisplayIds.append(displayId)
        }
        AXWindowService.fastFrameProviderForTests = { _ in
            CGRect(x: 210, y: 150, width: 730, height: 490)
        }
        defer {
            controller.layoutRefreshController.displayLinkScheduleHookForTests = nil
            AXWindowService.fastFrameProviderForTests = nil
        }

        controller.layoutRefreshController.startWindowCloseAnimation(entry: entry, monitor: monitor)
        controller.layoutRefreshController.startDwindleAnimation(for: workspaceId, monitor: monitor)
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)

        #expect(scheduledDisplayIds == [monitor.displayId])
        #expect(
            controller.layoutRefreshController.layoutState.scheduledDisplayLinkDisplayIds == [monitor.displayId]
        )

        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: monitor.displayId,
            migrateAnimations: false
        )

        #expect(
            controller.layoutRefreshController.layoutState.scheduledDisplayLinkDisplayIds.isEmpty
        )
    }

    @Test @MainActor func executeLayoutPlanDoesNotPersistRestoreSnapshotOnVerificationMismatch() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for restore snapshot persistence test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 102)
        let frame = CGRect(x: 140, y: 92, width: 880, height: 612)
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: nil,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token) == nil)
    }

    @Test @MainActor func managedRestoreMaterialStateHintPersistsWorkspaceMoveWithoutFrameApply() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let sourceWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let targetWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace fixture for managed restore material-state test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: sourceWorkspaceId, windowId: 108)
        let frame = CGRect(x: 160, y: 108, width: 860, height: 600)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.example.material-state",
                workspaceId: sourceWorkspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Material State Window",
                windowLevel: 0,
                parentWindowId: nil,
                frame: frame
            ),
            for: token
        )
        controller.recordManagedRestoreGeometry(for: token, frame: frame)

        controller.workspaceManager.setWorkspace(for: token, to: targetWorkspaceId)

        var plan = WorkspaceLayoutPlan(
            workspaceId: targetWorkspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: targetWorkspaceId),
            diff: WorkspaceLayoutDiff()
        )
        plan.managedRestoreMaterialStateChanges = [
            ManagedRestoreMaterialStateChange(
                token: token,
                reason: .workspaceMoved
            )
        ]

        controller.layoutRefreshController.executeLayoutPlan(plan)

        let snapshot = controller.workspaceManager.managedRestoreSnapshot(for: token)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(snapshot?.workspaceId == targetWorkspaceId)
        #expect(snapshot?.replacementMetadata?.workspaceId == targetWorkspaceId)
    }

    @Test @MainActor func managedRestoreMaterialStateHintUsesCanonicalNiriFrameDuringScrollAnimation() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace fixture for Niri material-state frame regression test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 109)
        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        guard let windowNode = controller.niriEngine?.findNode(for: token) as? NiriWindow,
              let settledFrame = windowNode.frame
        else {
            Issue.record("Expected a Niri window node with a canonical frame")
            return
        }

        controller.recordManagedRestoreGeometry(for: token, frame: settledFrame)

        let tweenFrame = settledFrame.offsetBy(dx: 72, dy: 48)
        windowNode.savedHeight = .fixed(333)
        windowNode.renderedFrame = tweenFrame
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .spring(
                SpringAnimation(
                    from: 0,
                    to: 120,
                    startTime: 0,
                    config: .snappy
                )
            )
        }
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)

        var plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: WorkspaceLayoutDiff()
        )
        plan.managedRestoreMaterialStateChanges = [
            ManagedRestoreMaterialStateChange(
                token: token,
                reason: .niriStateChanged
            )
        ]

        controller.layoutRefreshController.executeLayoutPlan(plan)

        let snapshot = controller.workspaceManager.managedRestoreSnapshot(for: token)
        #expect(snapshot?.frame == settledFrame)
        #expect(snapshot?.frame != tweenFrame)
        #expect(snapshot?.niriState?.windowSizing.savedHeight == .fixed(333))
    }

    @Test @MainActor func activateNodeRelayoutPersistsManagedRestoreSnapshotWithoutFrameConfirmation() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace fixture for Niri activate-node restore regression test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 130)
        let secondToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 131)
        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        guard let engine = controller.niriEngine,
              let firstNode = engine.findNode(for: firstToken),
              let secondNode = engine.findNode(for: secondToken)
        else {
            Issue.record("Expected Niri nodes before activate-node restore regression test")
            return
        }

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: firstNode.id,
            focusedToken: firstToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.axManager.suppressFrameWrites([(secondToken.pid, secondToken.windowId)])
        _ = controller.workspaceManager.clearManagedRestoreSnapshot(for: secondToken)
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: .skipped(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        failureReason: .cancelled
                    )
                )
            }
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            controller.niriLayoutHandler.activateNode(
                secondNode,
                in: workspaceId,
                state: &state,
                options: .init(
                    activateWindow: false,
                    ensureVisible: false,
                    updateTimestamp: false,
                    axFocus: false,
                    startAnimation: false
                )
            )
        }
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let snapshot = controller.workspaceManager.managedRestoreSnapshot(for: secondToken)
        #expect(controller.axManager.lastAppliedFrame(for: secondToken.windowId) == nil)
        #expect(snapshot?.token == secondToken)
        #expect(snapshot?.niriState?.nodeId == secondNode.id)
    }

    @Test @MainActor func midAnimationFullscreenEntryDoesNotPersistTweenFrame() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for mid-animation fullscreen regression test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 110)
        let targetFrame = CGRect(x: 120, y: 80, width: 900, height: 640)
        let tweenFrame = CGRect(x: 188, y: 112, width: 832, height: 588)

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])
        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == targetFrame)

        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: token)

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: tweenFrame, forceApply: false)]

        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: diff
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == targetFrame)
    }

    @Test @MainActor func nativeFullscreenRestoreStatePersistsUntilLayoutPlanCommit() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for native fullscreen restore commit test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 111)
        let frozenFrame = CGRect(x: 120, y: 80, width: 900, height: 640)
        let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: frozenFrame,
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
        _ = controller.workspaceManager.beginNativeFullscreenRestore(for: token)

        guard let restoringRecord = controller.workspaceManager.nativeFullscreenRecord(for: token) else {
            Issue.record("Missing restoring native fullscreen record before layout plan commit")
            return
        }
        if case .restoring = restoringRecord.transition {} else {
            Issue.record("Expected native fullscreen record to remain restoring before layout commit")
        }
        #expect(controller.workspaceManager.layoutReason(for: token) == .standard)
        #expect(controller.workspaceManager.hasPendingNativeFullscreenTransition)
        #expect(controller.workspaceManager.isAppFullscreenActive)

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frozenFrame, forceApply: false)]

        var plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: diff
        )
        plan.nativeFullscreenRestoreFinalizeTokens = [token]

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token) == nil)
        #expect(controller.workspaceManager.hasPendingNativeFullscreenTransition == false)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
    }

    @Test @MainActor func nativeFullscreenRestoreLayoutPlanForceAppliesFirstRestoreFrame() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for native fullscreen force-apply test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 112)
        let frozenFrame = CGRect(x: 120, y: 80, width: 900, height: 640)
        var submittedRequests: [AXFrameApplicationRequest] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            submittedRequests.append(contentsOf: requests)
            return requests.map { request in
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

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, frozenFrame)])
        submittedRequests.removeAll()

        let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: frozenFrame,
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
        _ = controller.workspaceManager.beginNativeFullscreenRestore(for: token)

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frozenFrame, forceApply: true)]

        var plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: diff
        )
        plan.nativeFullscreenRestoreFinalizeTokens = [token]

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(submittedRequests.count == 1)
        #expect(submittedRequests.first?.windowId == 112)
        #expect(submittedRequests.first?.frame == frozenFrame)
        #expect(controller.axManager.lastAppliedFrame(for: 112) == frozenFrame)
    }

    @Test @MainActor func nativeFullscreenRestoreAppliesFrameDespiteSkipFrameApplicationForAnimation() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for skip-animation-gate restore test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 113)
        let frozenFrame = CGRect(x: 200, y: 140, width: 860, height: 600)
        var submittedRequests: [AXFrameApplicationRequest] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            submittedRequests.append(contentsOf: requests)
            return requests.map { request in
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

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, frozenFrame)])
        submittedRequests.removeAll()

        let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: frozenFrame,
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
        _ = controller.workspaceManager.beginNativeFullscreenRestore(for: token)

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frozenFrame, forceApply: true)]

        var plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: diff
        )
        plan.nativeFullscreenRestoreFinalizeTokens = [token]
        plan.skipFrameApplicationForAnimation = true

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(submittedRequests.count == 1)
        #expect(submittedRequests.first?.windowId == 113)
        #expect(submittedRequests.first?.frame == frozenFrame)
        #expect(controller.axManager.lastAppliedFrame(for: 113) == frozenFrame)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token) == nil)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
    }

    @Test @MainActor func executeLayoutPlanPreservesHiddenStateOnHideAndClearsItOnShow() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout visibility test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 202)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: CGPoint(x: 0.4, y: 0.3),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )
        let visibleFrame = CGRect(x: 240, y: monitor.visibleFrame.minY + 80, width: 640, height: 420)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, visibleFrame)])
        var framesByWindowId = [token.windowId: visibleFrame]
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        AXWindowService.fastFrameProviderForTests = { axRef in framesByWindowId[axRef.windowId] }
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            framesByWindowId[axRef.windowId] = frame
            return layoutRefreshControllerTestWriteResult(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                observedFrame: frame,
                failureReason: nil
            )
        }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            AXWindowService.setFrameResultProviderForTests = nil
            axHooksLease.release()
        }

        var hideDiff = WorkspaceLayoutDiff()
        let hiddenFrame = CGRect(
            x: monitor.visibleFrame.maxX + 24,
            y: monitor.visibleFrame.minY + 80,
            width: 640,
            height: 420
        )
        hideDiff.visibilityChanges = [
            .hide(
                LayoutHideRequest(
                    token: token,
                    side: .right,
                    hiddenFrame: hiddenFrame
                )
            )
        ]
        hideDiff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: hideDiff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == false)
        #expect(controller.workspaceManager.hiddenState(for: token)?.offscreenSide == .right)
        #expect(controller.layoutRefreshController.lastAppliedHideOrigin(for: token) == hiddenFrame.origin)

        var showDiff = WorkspaceLayoutDiff()
        showDiff.visibilityChanges = [.show(token)]
        showDiff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: showDiff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.layoutRefreshController.lastAppliedHideOrigin(for: token) == nil)
    }

    @Test @MainActor func coordinatedBorderUpdateUsesObservedGhosttyFrameWhenItDiffersFromLayoutFrame() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Ghostty border frame test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 205)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)
        controller.appInfoCache.storeInfoForTests(pid: token.pid, bundleId: "com.mitchellh.ghostty")

        let layoutFrame = CGRect(x: 120, y: 80, width: 900, height: 640)
        let observedFrame = CGRect(x: 120, y: 56, width: 900, height: 664)
        controller.borderCoordinator.observedFrameProviderForTests = { axRef in
            axRef.windowId == 205 ? observedFrame : nil
        }
        defer {
            controller.borderCoordinator.observedFrameProviderForTests = nil
        }

        var diff = WorkspaceLayoutDiff()
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: layoutFrame)
        diff.borderMode = .coordinated

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 205)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == observedFrame)
    }

    @Test @MainActor func directBorderUpdateUsesObservedGhosttyFrameWhenItDiffersFromLayoutFrame() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for direct Ghostty border frame test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 206)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)
        controller.appInfoCache.storeInfoForTests(pid: token.pid, bundleId: "com.mitchellh.ghostty")

        let layoutFrame = CGRect(x: 240, y: 96, width: 840, height: 600)
        let observedFrame = CGRect(x: 240, y: 72, width: 840, height: 624)
        controller.borderCoordinator.observedFrameProviderForTests = { axRef in
            axRef.windowId == 206 ? observedFrame : nil
        }
        defer {
            controller.borderCoordinator.observedFrameProviderForTests = nil
        }

        var diff = WorkspaceLayoutDiff()
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: layoutFrame)
        diff.borderMode = .direct

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 206)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == observedFrame)
    }

    @Test @MainActor func directGhosttyBorderUpdateFallsBackToPreferredFrameBeforeCachedFrameWhenObservedReadMisses() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Ghostty border fallback test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 207)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)
        controller.appInfoCache.storeInfoForTests(pid: token.pid, bundleId: "com.mitchellh.ghostty")

        let staleCachedFrame = CGRect(x: 96, y: 72, width: 720, height: 480)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, staleCachedFrame)])
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == staleCachedFrame)

        controller.axManager.frameApplyOverrideForTests = nil
        controller.borderCoordinator.observedFrameProviderForTests = { _ in nil }
        defer {
            controller.borderCoordinator.observedFrameProviderForTests = nil
        }

        let freshPreferredFrame = CGRect(x: 132, y: 88, width: 840, height: 560)
        let rendered = controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: token),
            preferredFrame: freshPreferredFrame,
            policy: .direct
        )

        #expect(rendered)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 207)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == freshPreferredFrame)
    }

    @Test @MainActor func managedResizeFailureKeepsConfirmedFrameAndObservedBorder() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for failed resize border test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 207)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let originalFrame = CGRect(x: 96, y: 72, width: 840, height: 540)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, originalFrame)])
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == originalFrame)

        controller.borderCoordinator.observedFrameProviderForTests = { axRef in
            axRef.windowId == token.windowId ? originalFrame : nil
        }
        defer {
            controller.borderCoordinator.observedFrameProviderForTests = nil
        }

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
                        observedFrame: originalFrame,
                        writeOrder: AXWindowService.frameWriteOrder(
                            currentFrame: request.currentFrameHint,
                            targetFrame: request.frame
                        ),
                        sizeError: .success,
                        positionError: .success,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }

        let failedTarget = CGRect(x: 96, y: 72, width: 1040, height: 700)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: failedTarget, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: failedTarget)
        diff.borderMode = .coordinated

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == originalFrame)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == token.windowId)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == originalFrame)
    }

    @Test @MainActor func liveFrameHideOriginPreservesWindowYForTransientHide() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first else {
            Issue.record("Missing monitor for transient hide-origin test")
            return
        }

        let frame = CGRect(x: 240, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: monitor,
            side: .left,
            pid: getpid(),
            reason: .layoutTransient
        ) else {
            Issue.record("Expected a live-frame hide origin for transient hide test")
            return
        }

        #expect(origin.y == frame.origin.y)
        #expect(origin.x < monitor.visibleFrame.minX)
    }

    @Test @MainActor func liveFrameHideOriginPreservesWindowYForWorkspaceHideOnVerticalOverride() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.secondaryMonitor.name,
                monitorDisplayId: fixture.secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        let frame = CGRect(x: 2160, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: fixture.secondaryMonitor,
            side: .left,
            pid: getpid(),
            reason: .workspaceInactive
        ) else {
            Issue.record("Expected a live-frame hide origin for workspace hide test")
            return
        }

        #expect(origin.y == frame.origin.y)
        #expect(
            origin.x < fixture.secondaryMonitor.visibleFrame.minX
                || origin.x > fixture.secondaryMonitor.visibleFrame.maxX - 1.0
        )
    }

    @Test @MainActor func liveFrameHideOriginPreservesWindowYForScratchpadHideOnVerticalOverride() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.secondaryMonitor.name,
                monitorDisplayId: fixture.secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        let frame = CGRect(x: 2160, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: fixture.secondaryMonitor,
            side: .right,
            pid: getpid(),
            reason: .scratchpad
        ) else {
            Issue.record("Expected a live-frame hide origin for scratchpad hide test")
            return
        }

        #expect(origin.y == frame.origin.y)
        #expect(origin.x > fixture.secondaryMonitor.visibleFrame.maxX - 1.0)
    }

    @Test @MainActor func liveFrameHideOriginUsesVerticalAxisForTransientHideOnVerticalOverride() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.secondaryMonitor.name,
                monitorDisplayId: fixture.secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        let frame = CGRect(x: 2160, y: 180, width: 800, height: 600)
        guard let origin = controller.layoutRefreshController.liveFrameHideOrigin(
            for: frame,
            monitor: fixture.secondaryMonitor,
            side: .left,
            pid: getpid(),
            reason: .layoutTransient
        ) else {
            Issue.record("Expected a live-frame hide origin for vertical transient hide test")
            return
        }

        #expect(origin.x == frame.origin.x)
        #expect(origin.y < fixture.secondaryMonitor.visibleFrame.minY)
    }

    @Test @MainActor func hideInactiveWorkspacesMarksSecondaryWorkspaceWindowHiddenOnVerticalOverride() async {
        let primaryMonitor = makeLayoutPlanTestMonitor(
            displayId: 100,
            name: "Primary"
        )
        let secondaryMonitor = makeLayoutPlanTestMonitor(
            displayId: 200,
            name: "Secondary",
            x: 1920
        )
        let controller = makeLayoutPlanTestController(
            monitors: [primaryMonitor, secondaryMonitor],
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary),
                WorkspaceConfiguration(name: "3", monitorAssignment: .secondary)
            ]
        )
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: secondaryMonitor.name,
                monitorDisplayId: secondaryMonitor.displayId,
                orientation: .vertical
            )
        )

        guard let visibleWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let hiddenWorkspaceId = controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        else {
            Issue.record("Missing secondary workspaces for inactive hide test")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(visibleWorkspaceId, on: secondaryMonitor.id))

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: hiddenWorkspaceId, windowId: 608)
        let visibleFrame = CGRect(x: 2160, y: 180, width: 800, height: 600)
        controller.axManager.applyFramesParallel(
            [(pid: token.pid, windowId: token.windowId, frame: visibleFrame)]
        )
        var framesByWindowId = [token.windowId: visibleFrame]
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        AXWindowService.fastFrameProviderForTests = { axRef in framesByWindowId[axRef.windowId] }
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            framesByWindowId[axRef.windowId] = frame
            return layoutRefreshControllerTestWriteResult(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                observedFrame: frame,
                failureReason: nil
            )
        }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            AXWindowService.setFrameResultProviderForTests = nil
            axHooksLease.release()
        }

        controller.layoutRefreshController.hideInactiveWorkspacesSync()

        #expect(controller.axManager.inactiveWorkspaceWindowIds.contains(token.windowId))
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }

    @Test @MainActor func executeLayoutPlanRestoresInactiveWindowFromFrameDiffWithoutShow() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for frame-only restore test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 250)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)

        let frame = CGRect(x: 160, y: 110, width: 820, height: 540)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: WindowModel.HiddenState(
                    proportionalPosition: CGPoint(x: 0.5, y: 0.5),
                    referenceMonitorId: monitor.id,
                    workspaceInactive: true
                )
            )
        ]
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 250) == frame)
    }

    @Test @MainActor func executeLayoutPlanHidesBorderWhenFocusedFrameIsMissing() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for border executor test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 303)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.visibilityChanges = [.show(token)]
        primingDiff.focusedFrame = LayoutFocusedFrame(
            token: token,
            frame: CGRect(x: 20, y: 20, width: 400, height: 300)
        )
        primingDiff.borderMode = .direct

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 303)

        var hideBorderDiff = WorkspaceLayoutDiff()
        hideBorderDiff.borderMode = .coordinated

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: hideBorderDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)
    }

    @Test @MainActor func directBorderUpdateRespectsPreservedNonManagedFocus() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for direct border gating test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 304)
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let frame = CGRect(x: 24, y: 24, width: 420, height: 320)
        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame)
        primingDiff.borderMode = .direct

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 304)

        _ = controller.workspaceManager.enterNonManagedFocus(
            appFullscreen: false,
            preserveFocusedToken: true
        )
        controller.borderManager.hideBorder()
        #expect(controller.workspaceManager.focusedToken == token)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)

        var diff = WorkspaceLayoutDiff()
        diff.focusedFrame = LayoutFocusedFrame(token: token, frame: frame.offsetBy(dx: 12, dy: 8))
        diff.borderMode = .direct

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)
    }

    @Test @MainActor func activateWindowPlanReappliesBorderAfterFirstDirectUpdateMisses() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for post-layout border reapply test")
            return
        }

        controller.setBordersEnabled(true)

        let oldToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 307)
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 308)
        _ = controller.workspaceManager.setManagedFocus(oldToken, in: workspaceId, onMonitor: monitor.id)

        let oldFrame = CGRect(x: 28, y: 28, width: 420, height: 320)
        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.focusedFrame = LayoutFocusedFrame(token: oldToken, frame: oldFrame)
        primingDiff.borderMode = .coordinated

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 307)

        controller.borderCoordinator.suppressNextManagedBorderUpdateForTests = { token, mode in
            token == newToken && mode == .direct
        }

        let newFrame = CGRect(x: 520, y: 32, width: 420, height: 320)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: newToken, frame: newFrame, forceApply: false)]
        diff.focusedFrame = LayoutFocusedFrame(token: newToken, frame: newFrame)
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff,
                animationDirectives: [.activateWindow(token: newToken)]
            )
        )

        #expect(controller.workspaceManager.pendingFocusedToken == newToken)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 307)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == oldFrame)
    }

    @Test @MainActor func staleBorderUpdatesDoNotReplaceExistingFocusedBorder() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for stale border gating test")
            return
        }

        let focusedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 305)
        let staleToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 306)
        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: monitor.id)
        controller.setBordersEnabled(true)

        let focusedFrame = CGRect(x: 32, y: 32, width: 420, height: 320)
        var primingDiff = WorkspaceLayoutDiff()
        primingDiff.focusedFrame = LayoutFocusedFrame(token: focusedToken, frame: focusedFrame)
        primingDiff.borderMode = .coordinated

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: primingDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 305)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == focusedFrame)

        let staleFrame = focusedFrame.offsetBy(dx: 80, dy: 24)
        var directDiff = WorkspaceLayoutDiff()
        directDiff.focusedFrame = LayoutFocusedFrame(token: staleToken, frame: staleFrame)
        directDiff.borderMode = .direct

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: directDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 305)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == focusedFrame)

        var coordinatedDiff = WorkspaceLayoutDiff()
        coordinatedDiff.focusedFrame = LayoutFocusedFrame(token: staleToken, frame: staleFrame.offsetBy(dx: 20, dy: 12))
        coordinatedDiff.borderMode = .coordinated

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: coordinatedDiff
            )
        )

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 305)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == focusedFrame)
    }

    @Test @MainActor func executeLayoutPlanDoesNotRestoreInactiveWorkspaceForNonActivePlan() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let inactiveWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let activeWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for inactive restore regression test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: inactiveWorkspaceId, windowId: 404)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        _ = controller.workspaceManager.setActiveWorkspace(activeWorkspaceId, on: monitor.id)

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [
            LayoutFrameChange(
                token: token,
                frame: CGRect(x: 220, y: 120, width: 760, height: 520),
                forceApply: false
            )
        ]
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: inactiveWorkspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: inactiveWorkspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }

    @Test @MainActor func executeLayoutPlanRestoresSecondaryWorkspaceWindowOnVisibleMonitor() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 505
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: fixture.secondaryMonitor
        )

        let frame = CGRect(x: 2040, y: 140, width: 760, height: 520)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: WindowModel.HiddenState(
                    proportionalPosition: CGPoint(x: 0.4, y: 0.4),
                    referenceMonitorId: fixture.secondaryMonitor.id,
                    workspaceInactive: true
                )
            )
        ]
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: fixture.secondaryWorkspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.secondaryMonitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: fixture.secondaryWorkspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 505) == frame)
    }

    @Test @MainActor func unhideWorkspaceRestoresFloatingWindowFromOwnedFloatingState() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for floating restore test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 560),
            pid: 560,
            windowId: 560,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 180, y: 140, width: 520, height: 360)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.3, y: 0.25),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.9, y: 0.9),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )

        controller.layoutRefreshController.unhideWorkspace(workspaceId, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 560) == floatingFrame)
    }

    @Test @MainActor func unhideWorkspaceLeavesScratchpadWindowHidden() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for scratchpad unhide test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 580),
            pid: 580,
            windowId: 580,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 220, y: 180, width: 500, height: 340),
                normalizedOrigin: CGPoint(x: 0.25, y: 0.2),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.8, y: 0.75),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )

        controller.layoutRefreshController.unhideWorkspace(workspaceId, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.axManager.lastAppliedFrame(for: 580) == nil)
    }

    @Test @MainActor func restoreScratchpadWindowUsesOwnedFloatingState() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for scratchpad restore test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 581),
            pid: 581,
            windowId: 581,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 260, y: 160, width: 540, height: 360)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.3, y: 0.25),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.85, y: 0.8),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for scratchpad restore test")
            return
        }

        controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 581) == floatingFrame)
    }

    @Test @MainActor func restoreScratchpadWindowKeepsHiddenStateUntilAsyncRevealCompletes() async throws {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for async scratchpad reveal test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 582),
            pid: getpid(),
            windowId: 582,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 300, y: 180, width: 560, height: 380)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.35, y: 0.3),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.82, y: 0.76),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )

        guard let entry = controller.workspaceManager.entry(for: token),
              let context = await AppAXContext.makeForTests(processIdentifier: token.pid)
        else {
            Issue.record("Failed to create AX test context for async scratchpad reveal test")
            return
        }

        controller.axManager.frameApplyOverrideForTests = nil
        AppAXContext.contexts[token.pid] = context
        try await context.installWindowsForTests([entry.axRef])

        let startedWrite = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            if axRef.windowId == token.windowId {
                startedWrite.signal()
                _ = releaseWrite.wait(timeout: .now() + 1)
            }
            return layoutRefreshControllerTestWriteResult(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                observedFrame: frame,
                failureReason: nil
            )
        }
        defer {
            AXWindowService.setFrameResultProviderForTests = nil
            context.destroy()
        }

        controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

        let sawWriteStart = await Task.detached {
            waitForSemaphoreForTests(startedWrite, timeout: .now() + 1) == .success
        }.value

        #expect(sawWriteStart)
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId))

        releaseWrite.signal()

        let completedReveal = await waitForConditionForTests {
            controller.workspaceManager.hiddenState(for: token) == nil
                && controller.axManager.hasPendingFrameWrite(for: token.windowId) == false
        }

        #expect(completedReveal)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame)
    }

    @Test @MainActor func windowCloseAnimationUsesExactSnappyConfigAndSettlesToExpectedFrame() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for window close animation test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 593)
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for window close animation test")
            return
        }

        let initialFrame = CGRect(x: 220, y: 160, width: 760, height: 520)
        var appliedFrames: [CGRect] = []

        AXWindowService.fastFrameProviderForTests = { _ in initialFrame }
        AXWindowService.setFrameResultProviderForTests = { _, frame, currentFrameHint in
            appliedFrames.append(frame)
            return layoutRefreshControllerTestWriteResult(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                observedFrame: frame,
                failureReason: nil
            )
        }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            AXWindowService.setFrameResultProviderForTests = nil
        }

        controller.layoutRefreshController.startWindowCloseAnimation(entry: entry, monitor: monitor)

        let animation = controller.layoutRefreshController.layoutState
            .closingAnimationsByDisplay[monitor.displayId]?[entry.windowId]
        guard let animation else {
            Issue.record("Expected closing animation to be registered")
            return
        }
        let expectedFinalFrame = initialFrame.offsetBy(
            dx: animation.displacement.x,
            dy: animation.displacement.y
        )

        #expect(animation.animation.config.response == SpringConfig.snappy.response)
        #expect(animation.animation.config.dampingFraction == SpringConfig.snappy.dampingFraction)
        #expect(animation.animation.config.epsilon == SpringConfig.snappy.epsilon)
        #expect(animation.animation.config.velocityEpsilon == SpringConfig.snappy.velocityEpsilon)

        controller.layoutRefreshController.settleAllAnimationsForTests()

        #expect(appliedFrames.last == expectedFinalFrame)
        #expect(
            controller.layoutRefreshController.layoutState.closingAnimationsByDisplay[monitor.displayId] == nil
        )
    }

    @Test @MainActor func restoreScratchpadWindowWithoutRestoreGeometryKeepsHiddenStateAndSkipsSuccessAction() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        AXWindowService.fastFrameProviderForTests = { _ in nil }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for scratchpad no-geometry test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeUnavailableLayoutPlanTestWindow(windowId: 587),
            pid: 587,
            windowId: 587,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.6, y: 0.6),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for scratchpad no-geometry test")
            return
        }

        var successCount = 0
        controller.layoutRefreshController.restoreScratchpadWindow(
            entry,
            monitor: monitor,
            onSuccess: { successCount += 1 }
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        #expect(successCount == 0)
    }

    @Test @MainActor func restoreScratchpadWindowVerificationMismatchCompletesAfterDelayedVerification() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for delayed verification mismatch test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 588),
            pid: 588,
            windowId: 588,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 260, y: 160, width: 620, height: 420)
        var observedFrame = CGRect(x: -1400, y: 160, width: 620, height: 420)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.3, y: 0.24),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.82, y: 0.7),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )
        AXWindowService.fastFrameProviderForTests = { _ in observedFrame }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: observedFrame,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for delayed verification mismatch test")
            return
        }

        controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)
        observedFrame = floatingFrame

        let completedReveal = await waitForConditionForTests(timeoutNanoseconds: 10_000_000_000) {
            controller.workspaceManager.hiddenState(for: token) == nil
                && controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame
        }

        #expect(completedReveal)
        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == floatingFrame)
    }

    @Test @MainActor func restoreScratchpadWindowReadbackFailureCompletesAfterDelayedVerification() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for delayed readback-failure test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 589),
            pid: 589,
            windowId: 589,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 280, y: 180, width: 580, height: 380)
        var observedFrame = CGRect(x: -1500, y: 180, width: 580, height: 380)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.32, y: 0.26),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.84, y: 0.72),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )
        AXWindowService.fastFrameProviderForTests = { _ in observedFrame }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: nil,
                        failureReason: .readbackFailed
                    )
                )
            }
        }

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for delayed readback-failure test")
            return
        }

        controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)
        observedFrame = floatingFrame

        let completedReveal = await waitForConditionForTests(timeoutNanoseconds: 10_000_000_000) {
            controller.workspaceManager.hiddenState(for: token) == nil
                && controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame
        }

        #expect(completedReveal)
        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == floatingFrame)
    }

    @Test @MainActor func restoreScratchpadWindowFailurePreservesHiddenStateAndRetryCanSucceed() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for scratchpad failure retry test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 583),
            pid: 583,
            windowId: 583,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 320, y: 190, width: 520, height: 350)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.33, y: 0.28),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.8, y: 0.7),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )

        var shouldFail = true
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: shouldFail ? request.currentFrameHint : request.frame,
                        failureReason: shouldFail ? .suppressed : nil
                    )
                )
            }
        }

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for scratchpad failure retry test")
            return
        }

        controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)

        shouldFail = false
        controller.layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == floatingFrame)
    }

    @Test @MainActor func unhideWindowFailureDoesNotRestoreWorkspaceHiddenState() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for workspace unhide failure test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 584),
            pid: 584,
            windowId: 584,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 180, y: 120, width: 500, height: 320)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.25, y: 0.2),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.78, y: 0.74),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .suppressed
                    )
                )
            }
        }

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for workspace unhide failure test")
            return
        }

        controller.layoutRefreshController.unhideWindow(entry, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .suppressed)
    }

    @Test @MainActor func executeLayoutPlanShowWithCachedVisibleFrameClearsHiddenStateWithoutRevealTransaction() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for cached reveal frame test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 590)
        let frame = CGRect(x: 220, y: 140, width: 760, height: 520)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, frame)])
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)

        var attemptCount = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += requests.count
            return requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }

        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges = [.show(token)]
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(attemptCount == 0)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == frame)
    }

    @Test @MainActor func pendingRevealTransactionSurvivesManagedRekeyDuringDelayedVerification() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for reveal rekey test")
            return
        }

        let originalToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 591),
            pid: 591,
            windowId: 591,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 300, y: 170, width: 560, height: 360)
        var observedFrame = CGRect(x: -1300, y: 170, width: 560, height: 360)
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: floatingFrame,
                normalizedOrigin: CGPoint(x: 0.34, y: 0.24),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: originalToken
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.83, y: 0.71),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: originalToken
        )
        AXWindowService.fastFrameProviderForTests = { _ in observedFrame }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: observedFrame,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }

        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing entry for reveal rekey test")
            return
        }

        controller.layoutRefreshController.restoreScratchpadWindow(originalEntry, monitor: monitor)

        let newToken = WindowToken(pid: originalToken.pid, windowId: 592)
        let newAXRef = makeLayoutPlanTestWindow(windowId: newToken.windowId)
        guard let newEntry = controller.workspaceManager.rekeyWindow(
            from: originalToken,
            to: newToken,
            newAXRef: newAXRef
        ) else {
            Issue.record("Failed to rekey window during reveal rekey test")
            return
        }

        controller.axManager.rekeyWindowState(
            pid: newToken.pid,
            oldWindowId: originalToken.windowId,
            newWindow: newAXRef
        )
        controller.layoutRefreshController.rekeyPendingRevealTransaction(
            from: originalToken,
            to: newToken,
            entry: newEntry
        )

        observedFrame = floatingFrame

        let completedReveal = await waitForConditionForTests {
            controller.workspaceManager.hiddenState(for: newToken) == nil
                && controller.axManager.lastAppliedFrame(for: newToken.windowId) == floatingFrame
        }

        #expect(completedReveal)
    }

    @Test @MainActor func executeLayoutPlanRestoreFrameFailureDoesNotRehideWorkspaceInactiveWindow() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for layout restore failure test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 585)
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        let frame = CGRect(x: 200, y: 120, width: 760, height: 520)
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: layoutRefreshControllerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .suppressed
                    )
                )
            }
        }

        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [LayoutFrameChange(token: token, frame: frame, forceApply: false)]
        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: WindowModel.HiddenState(
                    proportionalPosition: CGPoint(x: 0.5, y: 0.5),
                    referenceMonitorId: monitor.id,
                    workspaceInactive: true
                )
            )
        ]
        diff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: diff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .suppressed)
    }

    @Test @MainActor func unhideWindowPositionPlanRevealClearsHiddenStateSynchronously() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for position-plan unhide test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 586)
        let hiddenFrame = CGRect(x: -1400, y: 200, width: 720, height: 460)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, hiddenFrame)])
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.2, y: 0.25),
                referenceMonitorId: monitor.id,
                workspaceInactive: true
            ),
            for: token
        )

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for position-plan unhide test")
            return
        }

        controller.layoutRefreshController.unhideWindow(entry, monitor: monitor)

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId) == false)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == nil)
    }

    @Test @MainActor func workspaceInactiveHideUsesManagedRestoreSnapshotFrameHintOrFailsClosedWhenMoveCannotBeVerified() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        AXWindowService.fastFrameProviderForTests = { _ in nil }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }
        guard let monitor = controller.workspaceManager.monitors.first,
              let inactiveWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing monitor or workspace for workspace-inactive frame-hint test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeUnavailableLayoutPlanTestWindow(windowId: 607),
            pid: 607,
            windowId: 607,
            to: inactiveWorkspaceId,
            mode: .tiling
        )
        let hintFrame = CGRect(x: 140, y: 160, width: 720, height: 460)
        _ = controller.workspaceManager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: token,
                workspaceId: inactiveWorkspaceId,
                frame: hintFrame,
                topologyProfile: controller.workspaceManager.topologyProfile,
                niriState: nil,
                replacementMetadata: nil
            ),
            for: token
        )

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for workspace-inactive frame-hint test")
            return
        }

        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )

        if controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true {
            #expect(controller.layoutRefreshController.lastAppliedHideOrigin(for: token) != nil)
        } else {
            #expect(controller.workspaceManager.hiddenState(for: token) == nil)
            #expect(controller.layoutRefreshController.lastAppliedHideOrigin(for: token) == nil)
            #expect(controller.layoutRefreshController.workspaceInactiveHideRetryCount(for: token.windowId) == 0)
        }
    }

    @Test @MainActor func workspaceInactiveHideTreatsLastAppliedFrameAsHintAndFailsClosedWhenMoveCannotBeVerified() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        AXWindowService.fastFrameProviderForTests = { _ in nil }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }
        guard let monitor = controller.workspaceManager.monitors.first,
              let inactiveWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing monitor or workspace for cached-frame workspace hide test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeUnavailableLayoutPlanTestWindow(windowId: 611),
            pid: 611,
            windowId: 611,
            to: inactiveWorkspaceId,
            mode: .tiling
        )
        let staleCachedFrame = CGRect(x: 260, y: 200, width: 720, height: 460)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, staleCachedFrame)])

        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for cached-frame workspace hide test")
            return
        }

        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.layoutRefreshController.lastAppliedHideOrigin(for: token) == nil)
        #expect(controller.layoutRefreshController.workspaceInactiveHideRetryCount(for: token.windowId) == 0)
        #expect(!controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))
    }

    @Test @MainActor func workspaceInactiveHideRetriesOnceThenAwaitsFreshFrame() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        AXWindowService.fastFrameProviderForTests = { _ in nil }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for workspace-inactive retry test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeUnavailableLayoutPlanTestWindow(windowId: 608),
            pid: 608,
            windowId: 608,
            to: workspaceId,
            mode: .tiling
        )
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for workspace-inactive retry test")
            return
        }

        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.layoutRefreshController.workspaceInactiveHideRetryCount(for: token.windowId) == 0)
        #expect(!controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))

        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )

        #expect(controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))

        controller.layoutRefreshController.handleFreshFrameEvent(for: token)

        #expect(controller.layoutRefreshController.workspaceInactiveHideRetryCount(for: token.windowId) == nil)
        #expect(!controller.layoutRefreshController.isAwaitingFreshFrameAfterWorkspaceHideFailure(for: token.windowId))
    }

    @Test @MainActor func hiddenOriginClearsOnWorkspaceAndScratchpadRevealPaths() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let inactiveWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        else {
            Issue.record("Missing monitor or workspace for hidden-origin clearing test")
            return
        }

        let workspaceToken = addLayoutPlanTestWindow(on: controller, workspaceId: inactiveWorkspaceId, windowId: 609)
        let scratchpadToken = addLayoutPlanTestWindow(on: controller, workspaceId: activeWorkspaceId, windowId: 610)

        let workspaceVisibleFrame = CGRect(x: 180, y: 180, width: 640, height: 420)
        let scratchpadVisibleFrame = CGRect(x: 320, y: 220, width: 680, height: 440)
        var framesByWindowId = [
            workspaceToken.windowId: workspaceVisibleFrame,
            scratchpadToken.windowId: scratchpadVisibleFrame
        ]
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        AXWindowService.fastFrameProviderForTests = { axRef in framesByWindowId[axRef.windowId] }
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            framesByWindowId[axRef.windowId] = frame
            return layoutRefreshControllerTestWriteResult(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                observedFrame: frame,
                failureReason: nil
            )
        }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            AXWindowService.setFrameResultProviderForTests = nil
            axHooksLease.release()
        }

        guard let workspaceEntry = controller.workspaceManager.entry(for: workspaceToken),
              let scratchpadEntry = controller.workspaceManager.entry(for: scratchpadToken)
        else {
            Issue.record("Missing entries for hidden-origin clearing test")
            return
        }

        controller.layoutRefreshController.hideWindow(
            workspaceEntry,
            monitor: monitor,
            side: .right,
            reason: .workspaceInactive
        )
        controller.layoutRefreshController.hideWindow(
            scratchpadEntry,
            monitor: monitor,
            side: .left,
            reason: .scratchpad
        )

        #expect(controller.layoutRefreshController.lastAppliedHideOrigin(for: workspaceToken) != nil)
        #expect(controller.layoutRefreshController.lastAppliedHideOrigin(for: scratchpadToken) != nil)

        framesByWindowId[workspaceToken.windowId] = CGRect(x: -1400, y: 180, width: 640, height: 420)
        framesByWindowId[scratchpadToken.windowId] = CGRect(x: -1500, y: 220, width: 680, height: 440)

        controller.layoutRefreshController.unhideWindow(workspaceEntry, monitor: monitor)
        controller.layoutRefreshController.restoreScratchpadWindow(scratchpadEntry, monitor: monitor)

        let clearedHiddenOrigins = await waitForConditionForTests {
            controller.layoutRefreshController.lastAppliedHideOrigin(for: workspaceToken) == nil
                && controller.layoutRefreshController.lastAppliedHideOrigin(for: scratchpadToken) == nil
        }

        #expect(clearedHiddenOrigins)
    }

    @Test @MainActor func failedBatchHideDoesNotFinalizeNativeFullscreenRestoreForUnverifiedToken() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for native fullscreen finalize gating test")
            return
        }

        let successToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 616)
        let failureToken = controller.workspaceManager.addWindow(
            makeUnavailableLayoutPlanTestWindow(windowId: 617),
            pid: 617,
            windowId: 617,
            to: workspaceId,
            mode: .tiling
        )
        let successVisibleFrame = CGRect(x: 160, y: 140, width: 640, height: 420)
        let failureVisibleFrame = CGRect(x: 840, y: 140, width: 640, height: 420)
        var framesByWindowId = [
            successToken.windowId: successVisibleFrame,
            failureToken.windowId: failureVisibleFrame
        ]
        let failingWindowIds: Set<Int> = [failureToken.windowId]
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        AXWindowService.fastFrameProviderForTests = { axRef in framesByWindowId[axRef.windowId] }
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            if failingWindowIds.contains(axRef.windowId) {
                return layoutRefreshControllerTestWriteResult(
                    targetFrame: frame,
                    currentFrameHint: currentFrameHint,
                    observedFrame: framesByWindowId[axRef.windowId],
                    failureReason: .verificationMismatch
                )
            }

            framesByWindowId[axRef.windowId] = frame
            return layoutRefreshControllerTestWriteResult(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                observedFrame: frame,
                failureReason: nil
            )
        }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            AXWindowService.setFrameResultProviderForTests = nil
            axHooksLease.release()
        }

        for (token, frame) in [(successToken, successVisibleFrame), (failureToken, failureVisibleFrame)] {
            let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
                frame: frame,
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
            _ = controller.workspaceManager.beginNativeFullscreenRestore(for: token)
        }

        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges = [
            .hide(
                LayoutHideRequest(
                    token: successToken,
                    side: .right,
                    hiddenFrame: CGRect(x: monitor.visibleFrame.maxX + 24, y: 140, width: 640, height: 420)
                )
            ),
            .hide(
                LayoutHideRequest(
                    token: failureToken,
                    side: .right,
                    hiddenFrame: CGRect(x: monitor.visibleFrame.maxX + 48, y: 140, width: 640, height: 420)
                )
            )
        ]
        diff.borderMode = .none

        var plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: diff
        )
        plan.nativeFullscreenRestoreFinalizeTokens = [successToken, failureToken]

        controller.layoutRefreshController.executeLayoutPlan(plan)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.nativeFullscreenRestoreContext(for: successToken) == nil)
        #expect(controller.workspaceManager.nativeFullscreenRestoreContext(for: failureToken) != nil)
    }

    @Test @MainActor func alreadyHiddenBatchHideStillFinalizesNativeFullscreenRestore() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for already-hidden native fullscreen finalize test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 618)
        let hiddenFrame = CGRect(x: monitor.visibleFrame.maxX + 24, y: 160, width: 640, height: 420)
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        AXWindowService.fastFrameProviderForTests = { _ in hiddenFrame }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
            axHooksLease.release()
        }

        let restoreSnapshot = WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot(
            frame: hiddenFrame,
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
        _ = controller.workspaceManager.beginNativeFullscreenRestore(for: token)

        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges = [
            .hide(
                LayoutHideRequest(
                    token: token,
                    side: .right,
                    hiddenFrame: hiddenFrame
                )
            )
        ]
        diff.borderMode = .none

        var plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: diff
        )
        plan.nativeFullscreenRestoreFinalizeTokens = [token]

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(controller.workspaceManager.nativeFullscreenRestoreContext(for: token) == nil)
    }

    @Test @MainActor func hideWindowWithoutResolvedGeometryDoesNotMarkWindowHidden() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let controller = makeLayoutPlanTestController()
        AXWindowService.fastFrameProviderForTests = { _ in nil }
        defer {
            AXWindowService.fastFrameProviderForTests = nil
        }
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for unavailable hide test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeUnavailableLayoutPlanTestWindow(windowId: 606),
            pid: 606,
            windowId: 606,
            to: workspaceId,
            mode: .tiling
        )
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing entry for unavailable hide test")
            return
        }

        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: .workspaceInactive
        )

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
    }

    @Test @MainActor func immediateRelayoutDefersFrameApplicationToScrollAnimationTick() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for scroll-animation handoff test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 620)
        var applyRequestCounts: [Int] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            applyRequestCounts.append(requests.count)
            return requests.map { request in
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

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .spring(
                SpringAnimation(
                    from: 0,
                    to: 120,
                    startTime: 0,
                    config: .snappy
                )
            )
        }
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)

        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(applyRequestCounts.isEmpty)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == workspaceId)

        controller.niriLayoutHandler.tickScrollAnimation(targetTime: 1, displayId: monitor.displayId)

        #expect(applyRequestCounts.count == 1)
        #expect(applyRequestCounts[0] > 0)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) != nil)
    }
}
