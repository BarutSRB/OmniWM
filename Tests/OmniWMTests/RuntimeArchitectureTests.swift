import ApplicationServices
@testable import OmniWM
import XCTest

final class RuntimeArchitectureTests: XCTestCase {
    func testHyprlandDwindleBezierStartsAndEndsAtBounds() {
        let config = CubicConfig.hyprlandDwindle
        let startTime = 4.0
        let animation = CubicAnimation(
            from: 0.0,
            to: 1.0,
            startTime: startTime,
            config: config
        )

        XCTAssertEqual(animation.value(at: startTime), 0.0, accuracy: 0.000001)
        XCTAssertEqual(animation.value(at: startTime + config.duration), 1.0, accuracy: 0.000001)
        XCTAssertTrue(animation.isComplete(at: startTime + config.duration))
    }

    func testHyprlandDwindleBezierIsMonotonicAndSnappy() {
        let config = CubicConfig.hyprlandDwindle
        let startTime = 9.0
        let animation = CubicAnimation(
            from: 0.0,
            to: 1.0,
            startTime: startTime,
            config: config
        )
        var previous = -Double.infinity

        for step in 0 ... 40 {
            let time = startTime + config.duration * Double(step) / 40.0
            let value = animation.value(at: time)
            XCTAssertGreaterThanOrEqual(value + 0.000001, previous)
            previous = value
        }

        let quarterValue = animation.value(at: startTime + config.duration * 0.25)
        XCTAssertGreaterThan(quarterValue, 0.65)
        XCTAssertLessThan(quarterValue, 1.0)
    }

    func testDwindleRectAnimationRetargetsFromPresentedFrame() throws {
        let config = CubicConfig.hyprlandDwindle
        let node = DwindleNode(kind: .leaf(handle: WindowToken(pid: 10, windowId: 20), fullscreen: false))
        let firstStart = CGRect(x: 10, y: 20, width: 320, height: 180)
        let firstTarget = CGRect(x: 200, y: 80, width: 480, height: 240)
        let secondTarget = CGRect(x: 60, y: 140, width: 360, height: 420)
        let retargetTime = config.duration * 0.35

        node.cachedFrame = firstTarget
        node.animateFrom(
            oldFrame: firstStart,
            newFrame: firstTarget,
            startTime: 0,
            config: config,
            animated: true
        )

        let visibleFrame = try XCTUnwrap(node.presentedFrame(at: retargetTime))
        node.cachedFrame = secondTarget
        node.animateFrom(
            oldFrame: visibleFrame,
            newFrame: secondTarget,
            startTime: retargetTime,
            config: config,
            animated: true
        )

        Self.assertFrame(
            try XCTUnwrap(node.presentedFrame(at: retargetTime)),
            equals: visibleFrame
        )
    }

    func testDwindleRectAnimationUsesSingleProgressForFrameComponents() throws {
        let config = CubicConfig.hyprlandDwindle
        let node = DwindleNode(kind: .leaf(handle: WindowToken(pid: 11, windowId: 21), fullscreen: false))
        let startFrame = CGRect(x: 20, y: 40, width: 300, height: 200)
        let targetFrame = CGRect(x: 220, y: 160, width: 500, height: 440)
        let sampleTime = config.duration * 0.5
        let progress = CGFloat(CubicAnimation(
            from: 0.0,
            to: 1.0,
            startTime: 0,
            config: config
        ).value(at: sampleTime))

        node.cachedFrame = targetFrame
        node.animateFrom(
            oldFrame: startFrame,
            newFrame: targetFrame,
            startTime: 0,
            config: config,
            animated: true
        )

        let expectedFrame = CGRect(
            x: startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * progress,
            y: startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * progress,
            width: startFrame.width + (targetFrame.width - startFrame.width) * progress,
            height: startFrame.height + (targetFrame.height - startFrame.height) * progress
        )
        Self.assertFrame(
            try XCTUnwrap(node.presentedFrame(at: sampleTime)),
            equals: expectedFrame
        )

        node.tickAnimations(at: config.duration)
        XCTAssertFalse(node.hasActiveAnimations(at: config.duration))
        Self.assertFrame(
            try XCTUnwrap(node.presentedFrame(at: config.duration)),
            equals: targetFrame
        )
    }

    func testRuntimeRevisionDomainsRejectOnlyRelevantChanges() {
        let baseline = RuntimeRevision(
            runtime: 1,
            workspace: 10,
            layout: 20,
            focus: 30,
            fullscreen: 40
        )
        let focusChanged = RuntimeRevision(
            runtime: 2,
            workspace: 10,
            layout: 20,
            focus: 31,
            fullscreen: 40
        )
        let layoutChanged = RuntimeRevision(
            runtime: 3,
            workspace: 10,
            layout: 21,
            focus: 30,
            fullscreen: 40
        )
        let fullscreenChanged = RuntimeRevision(
            runtime: 4,
            workspace: 10,
            layout: 20,
            focus: 30,
            fullscreen: 41
        )

        XCTAssertTrue(baseline.matches(focusChanged, domains: .layoutCommit))
        XCTAssertFalse(baseline.matches(focusChanged, domains: .focusCommit))
        XCTAssertFalse(baseline.matches(layoutChanged, domains: .layoutCommit))
        XCTAssertFalse(baseline.matches(fullscreenChanged, domains: .layoutCommit))
    }

    func testManagedFocusRequestCarriesRequestId() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let plan = Planner().plan(
            event: .managedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: 7,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: Self.snapshot(),
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.token, token)
        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.workspaceId, workspaceId)
        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.requestId, 7)
        XCTAssertTrue(plan.mutatesRuntimeState)
    }

    func testManagedFocusCancelRejectsMismatchedRequestId() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: 7
            )
        )

        let mismatchedPlan = Planner().plan(
            event: .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                requestId: 8,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )
        let matchingPlan = Planner().plan(
            event: .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                requestId: 7,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )

        XCTAssertFalse(mismatchedPlan.mutatesRuntimeState)
        XCTAssertEqual(matchingPlan.focusSession?.pendingManagedFocus, .empty)
    }

    func testManagedFocusConfirmRequiresMatchingRequest() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let monitorId = Monitor.ID(displayId: 2)
        let previousMonitorId = Monitor.ID(displayId: 1)
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceId,
                monitorId: previousMonitorId,
                requestId: 7
            ),
            interactionMonitorId: previousMonitorId
        )

        let mismatch = Planner().plan(
            event: .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                appFullscreen: false,
                requestId: 8,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )
        let match = Planner().plan(
            event: .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                appFullscreen: false,
                requestId: 7,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )

        XCTAssertFalse(mismatch.mutatesRuntimeState)
        XCTAssertEqual(match.focusSession?.focusedToken, token)
        XCTAssertEqual(match.focusSession?.pendingManagedFocus, .empty)
        XCTAssertEqual(match.focusSession?.interactionMonitorId, monitorId)
        XCTAssertEqual(match.focusSession?.previousInteractionMonitorId, previousMonitorId)
    }

    func testManagedReplacementFocusTransactionRekeysAnchorAndProtectedTokens() {
        let workspaceId = WorkspaceDescriptor.ID()
        let key = ManagedReplacementFocusKey(pid: 77821, workspaceId: workspaceId)
        let oldToken = WindowToken(pid: 77821, windowId: 4245)
        let tempToken = WindowToken(pid: 77821, windowId: 4707)
        let restoredToken = WindowToken(pid: 77821, windowId: 4245)
        var transaction = ManagedReplacementFocusTransaction(
            key: key,
            anchorToken: oldToken,
            protectedToken: tempToken
        )

        transaction.rekey(from: oldToken, to: tempToken)
        XCTAssertEqual(transaction.anchorToken, tempToken)
        XCTAssertTrue(transaction.protects(tempToken))
        XCTAssertFalse(transaction.protects(oldToken))

        transaction.rekey(from: tempToken, to: restoredToken)
        XCTAssertEqual(transaction.anchorToken, restoredToken)
        XCTAssertTrue(transaction.protects(restoredToken))
        XCTAssertFalse(transaction.protects(tempToken))
    }

    func testManagedReplacementFocusTransactionSuppressesOnlyUnprotectedSameWorkspaceTokens() {
        let workspaceId = WorkspaceDescriptor.ID()
        let otherWorkspaceId = WorkspaceDescriptor.ID()
        let key = ManagedReplacementFocusKey(pid: 77821, workspaceId: workspaceId)
        let anchorToken = WindowToken(pid: 77821, windowId: 4245)
        let tempToken = WindowToken(pid: 77821, windowId: 4707)
        let unrelatedSameWorkspaceToken = WindowToken(pid: 77821, windowId: 3164)
        let otherPidToken = WindowToken(pid: 91438, windowId: 3164)
        let transaction = ManagedReplacementFocusTransaction(
            key: key,
            anchorToken: anchorToken,
            protectedToken: tempToken
        )

        XCTAssertFalse(transaction.suppressesUnrelatedActivation(token: anchorToken, workspaceId: workspaceId))
        XCTAssertFalse(transaction.suppressesUnrelatedActivation(token: tempToken, workspaceId: workspaceId))
        XCTAssertTrue(transaction.suppressesUnrelatedActivation(
            token: unrelatedSameWorkspaceToken,
            workspaceId: workspaceId
        ))
        XCTAssertFalse(transaction.suppressesUnrelatedActivation(token: otherPidToken, workspaceId: workspaceId))
        XCTAssertFalse(transaction.suppressesUnrelatedActivation(
            token: unrelatedSameWorkspaceToken,
            workspaceId: otherWorkspaceId
        ))
    }

    @MainActor
    func testRejectedManagedFocusConfirmDoesNotBumpRuntimeRevisionThroughRestoreIntentRefresh() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_101),
            pid: getpid(),
            windowId: 9_101,
            to: workspaceId
        )

        _ = manager.beginManagedFocusRequest(token, in: workspaceId, requestId: 7)
        let before = manager.runtimeRevision(for: workspaceId)
        let txn = manager.recordReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                appFullscreen: false,
                requestId: 8,
                source: .workspaceManager
            )
        )

        XCTAssertFalse(txn.plan.mutatesRuntimeState)
        XCTAssertEqual(manager.runtimeRevision(for: workspaceId), before)
    }

    func testPendingManagedFocusWithoutRequestIdIsInvariantViolation() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: nil
            )
        )

        let codes = Set(InvariantChecks.validate(snapshot: snapshot).map(\.code))

        XCTAssertTrue(codes.contains("pending_focus_token_missing"))
        XCTAssertTrue(codes.contains("pending_focus_without_request"))
    }

    func testFocusInvariantTableCoversCorruptSnapshots() {
        let token = WindowToken(pid: 100, windowId: 42)
        let workspaceId = WorkspaceDescriptor.ID()
        let otherWorkspaceId = WorkspaceDescriptor.ID()

        let duplicateCodes = Self.invariantCodes(
            windows: [
                Self.window(token: token, workspaceId: workspaceId),
                Self.window(token: token, workspaceId: workspaceId)
            ]
        )
        XCTAssertTrue(duplicateCodes.contains("duplicate_window_token"))

        let destroyedFocusedCodes = Self.invariantCodes(
            focusedToken: token,
            windows: [
                Self.window(token: token, workspaceId: workspaceId, lifecyclePhase: .destroyed)
            ]
        )
        XCTAssertTrue(destroyedFocusedCodes.contains("focused_token_destroyed"))

        let requestShapeCodes = Self.invariantCodes(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: nil,
                workspaceId: nil,
                monitorId: nil,
                requestId: 7
            )
        )
        XCTAssertTrue(requestShapeCodes.contains("pending_focus_request_without_token"))
        XCTAssertTrue(requestShapeCodes.contains("pending_focus_request_without_workspace"))

        let mismatchCodes = Self.invariantCodes(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: otherWorkspaceId,
                monitorId: nil,
                requestId: 7
            ),
            windows: [
                Self.window(token: token, workspaceId: workspaceId)
            ]
        )
        XCTAssertTrue(mismatchCodes.contains("pending_focus_workspace_mismatch"))
    }

    @MainActor
    func testWorkspaceManagerDoesNotBumpRevisionForNoOpRuntimeSetters() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_001),
            pid: getpid(),
            windowId: 9_001,
            to: workspaceId,
            mode: .floating
        )

        let hiddenState = WindowModel.HiddenState(
            proportionalPosition: CGPoint(x: 0.25, y: 0.5),
            referenceMonitorId: nil,
            reason: .workspaceInactive
        )
        manager.setHiddenState(hiddenState, for: token)
        let afterHiddenState = manager.runtimeRevision(for: workspaceId)
        manager.setHiddenState(hiddenState, for: token)
        XCTAssertEqual(manager.runtimeRevision(for: workspaceId), afterHiddenState)

        let floatingState = WindowModel.FloatingState(
            lastFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            normalizedOrigin: CGPoint(x: 0.1, y: 0.2),
            referenceMonitorId: nil,
            restoreToFloating: true
        )
        manager.setFloatingState(floatingState, for: token)
        let afterFloatingState = manager.runtimeRevision(for: workspaceId)
        manager.setFloatingState(floatingState, for: token)
        XCTAssertEqual(manager.runtimeRevision(for: workspaceId), afterFloatingState)

        let constraints = WindowSizeConstraints.fixed(size: CGSize(width: 320, height: 240))
        let beforeConstraints = manager.runtimeRevision(for: workspaceId)
        manager.setCachedConstraints(constraints, for: token)
        XCTAssertEqual(manager.runtimeRevision(for: workspaceId), beforeConstraints)
        let afterConstraints = manager.runtimeRevision(for: workspaceId)
        manager.setCachedConstraints(constraints, for: token)
        XCTAssertEqual(manager.runtimeRevision(for: workspaceId), afterConstraints)
    }

    @MainActor
    func testWorkspaceManagerDoesNotGlobalInvalidateForMissingTokens() throws {
        let manager = Self.workspaceManager()
        let missingToken = WindowToken(pid: getpid(), windowId: 987_654)
        let before = manager.runtimeEpoch(for: .layoutCommit)

        manager.setFloatingState(
            WindowModel.FloatingState(
                lastFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
                normalizedOrigin: CGPoint(x: 0.1, y: 0.2),
                referenceMonitorId: nil,
                restoreToFloating: true
            ),
            for: missingToken
        )
        manager.setManualLayoutOverride(.forceFloat, for: missingToken)
        manager.setCachedConstraints(.fixed(size: CGSize(width: 320, height: 240)), for: missingToken)
        manager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: missingToken
        )
        XCTAssertFalse(manager.setScratchpadToken(missingToken))

        XCTAssertEqual(manager.runtimeEpoch(for: .layoutCommit), before)
    }

    @MainActor
    func testApplySessionPatchRejectsStaleLayoutRevision() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_101),
            pid: getpid(),
            windowId: 9_101,
            to: workspaceId
        )
        let staleRevision = manager.runtimeRevision(for: workspaceId)
        manager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: token
        )
        var viewportState = ViewportState()
        viewportState.activeColumnIndex = 4

        let changed = manager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: viewportState,
                runtimeRevision: staleRevision
            )
        )

        XCTAssertFalse(changed)
        XCTAssertNotEqual(manager.niriViewportState(for: workspaceId).activeColumnIndex, 4)
    }

    @MainActor
    func testApplySessionPatchAppliesViewportButRejectsStaleRememberedFocus() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let firstToken = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_201),
            pid: getpid(),
            windowId: 9_201,
            to: workspaceId
        )
        let secondToken = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_202),
            pid: getpid(),
            windowId: 9_202,
            to: workspaceId
        )
        let staleFocusRevision = manager.runtimeRevision(for: workspaceId)
        _ = manager.beginManagedFocusRequest(firstToken, in: workspaceId, requestId: 7)
        var viewportState = ViewportState()
        viewportState.activeColumnIndex = 3

        let changed = manager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: viewportState,
                rememberedFocusToken: secondToken,
                runtimeRevision: staleFocusRevision
            )
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(manager.niriViewportState(for: workspaceId).activeColumnIndex, 3)
        XCTAssertEqual(manager.lastFocusedToken(in: workspaceId), firstToken)
    }

    func testPostLayoutActionRefreshesAcceptedRevisionsAndHonorsDomains() {
        let workspaceId = WorkspaceDescriptor.ID()
        let otherWorkspaceId = WorkspaceDescriptor.ID()
        let before = RuntimeRevision(
            runtime: 1,
            workspace: 10,
            layout: 20,
            focus: 30,
            fullscreen: 40
        )
        let after = RuntimeRevision(
            runtime: 2,
            workspace: 11,
            layout: 21,
            focus: 30,
            fullscreen: 40
        )
        let beforeFocusChanged = RuntimeRevision(
            runtime: 3,
            workspace: 10,
            layout: 20,
            focus: 31,
            fullscreen: 40
        )
        let afterFocusChanged = RuntimeRevision(
            runtime: 5,
            workspace: 11,
            layout: 21,
            focus: 31,
            fullscreen: 40
        )
        let unrelated = RuntimeRevision(
            runtime: 4,
            workspace: 100,
            layout: 200,
            focus: 300,
            fullscreen: 400
        )
        let action = RefreshPostLayoutAction(
            workspaceRevisions: [
                workspaceId: before,
                otherWorkspaceId: unrelated
            ],
            domains: .layoutCommit
        ) {}

        let refreshed = action.refreshingAcceptedRevisions(
            [
                workspaceId: AcceptedRuntimeRevision(
                    before: beforeFocusChanged,
                    after: afterFocusChanged,
                    domains: .layoutCommit
                )
            ]
        )
        let notRefreshed = action.refreshingAcceptedRevisions(
            [
                workspaceId: AcceptedRuntimeRevision(
                    before: after,
                    after: before,
                    domains: .layoutCommit
                )
            ]
        )
        let focusAction = RefreshPostLayoutAction(
            workspaceRevisions: [workspaceId: before],
            domains: .focusCommit
        ) {}
        let staleFocusNotRebased = focusAction.refreshingAcceptedRevisions(
            [
                workspaceId: AcceptedRuntimeRevision(
                    before: before,
                    after: afterFocusChanged,
                    domains: .layoutCommit
                )
            ]
        )
        let acceptedFocusRebased = focusAction.refreshingAcceptedRevisions(
            [
                workspaceId: AcceptedRuntimeRevision(
                    before: before,
                    after: afterFocusChanged,
                    domains: .layoutCommit.union(.focusCommit)
                )
            ]
        )

        XCTAssertEqual(refreshed.workspaceRevisions[workspaceId], afterFocusChanged)
        XCTAssertEqual(refreshed.workspaceRevisions[otherWorkspaceId], unrelated)
        XCTAssertEqual(notRefreshed.workspaceRevisions[workspaceId], before)
        XCTAssertEqual(staleFocusNotRebased.workspaceRevisions[workspaceId], before)
        XCTAssertEqual(acceptedFocusRebased.workspaceRevisions[workspaceId], afterFocusChanged)
        XCTAssertTrue(action.hasWorkspace(in: [workspaceId]))
    }

    @MainActor
    func testLayoutPlanAcceptedRevisionIncludesAnimationDirectiveFocusMutation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_005), windowId: 765_105),
            pid: 765_005,
            windowId: 765_105,
            to: workspaceId
        )
        let revision = controller.workspaceManager.runtimeRevision(for: workspaceId)

        let accepted = try XCTUnwrap(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedRevision(
                WorkspaceLayoutPlan(
                    workspaceId: workspaceId,
                    monitor: Self.layoutMonitorSnapshot(monitor),
                    runtimeRevision: revision,
                    sessionPatch: WorkspaceSessionPatch(
                        workspaceId: workspaceId,
                        runtimeRevision: revision
                    ),
                    diff: WorkspaceLayoutDiff(),
                    animationDirectives: [.activateWindow(token: token)]
                )
            )
        )

        XCTAssertEqual(accepted.after, controller.workspaceManager.runtimeRevision(for: workspaceId))
        XCTAssertNotEqual(accepted.after.focus, revision.focus)
        XCTAssertTrue(accepted.domains.contains(.focus))
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
    }

    @MainActor
    func testLayoutCommandPostLayoutDefaultRejectsFocusRevisionChange() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_013), windowId: 765_113),
            pid: 765_013,
            windowId: 765_113,
            to: workspaceId
        )
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        var didRun = false
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId]
        ) {
            didRun = true
        }
        let action = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            .first)
        _ = controller.workspaceManager.rememberFocus(token, in: workspaceId)

        action.runIfCurrent(using: controller.workspaceManager)

        XCTAssertFalse(didRun)
    }

    @MainActor
    func testResetStateDropsOldCancelledRefreshCompletion() async throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [workspaceId]
        )
        let task = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefreshTask)

        controller.layoutRefreshController.resetState()
        await task.value

        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefreshTask)
    }

    @MainActor
    func testNativeFullscreenTransitionIdsFenceStaleExpiry() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_301),
            pid: getpid(),
            windowId: 9_301,
            to: workspaceId
        )

        XCTAssertTrue(manager.requestNativeFullscreenEnter(token, in: workspaceId))
        let enterTransitionId = try XCTUnwrap(manager.nativeFullscreenRecord(for: token)?.transitionId)
        let unavailableRecord = try XCTUnwrap(
            manager.markNativeFullscreenTemporarilyUnavailable(token, now: Date(timeIntervalSince1970: 1))
        )
        let unavailableTransitionId = unavailableRecord.transitionId
        let refreshedUnavailableRecord = try XCTUnwrap(
            manager.markNativeFullscreenTemporarilyUnavailable(token, now: Date(timeIntervalSince1970: 2))
        )

        XCTAssertNotEqual(unavailableTransitionId, enterTransitionId)
        XCTAssertEqual(refreshedUnavailableRecord.transitionId, unavailableTransitionId)
        XCTAssertTrue(manager.showsNativeFullscreenPlaceholder(for: token))

        XCTAssertTrue(manager.requestNativeFullscreenExit(token, initiatedByCommand: true))
        let exitTransitionId = try XCTUnwrap(manager.nativeFullscreenRecord(for: token)?.transitionId)

        XCTAssertNotEqual(exitTransitionId, unavailableTransitionId)
        XCTAssertNil(
            manager.expireStaleTemporarilyUnavailableNativeFullscreenRecord(
                originalToken: token,
                transitionId: unavailableTransitionId,
                now: Date(timeIntervalSince1970: 10),
                staleInterval: 0
            )
        )
    }

    @MainActor
    func testAXFrameLedgerIgnoresStaleResultsAfterNewerRequest() throws {
        let ledger = AXFrameApplicationLedger()
        let firstFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let secondFrame = CGRect(x: 40, y: 50, width: 360, height: 240)
        var firstResults: [AXFrameApplyResult] = []
        var secondResults: [AXFrameApplyResult] = []

        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: firstFrame,
            isRetry: false
        ) { result in
            firstResults.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)
        let secondDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: secondFrame,
            isRetry: false
        ) { result in
            secondResults.append(result)
        }
        let secondRequest = try XCTUnwrap(secondDecision.request)

        for delivery in secondDecision.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(firstResults.map(\.writeResult.failureReason), [.cancelled])

        let staleOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest)
        ])
        XCTAssertTrue(staleOutcome.deliveries.isEmpty)
        XCTAssertTrue(staleOutcome.retries.isEmpty)
        XCTAssertEqual(ledger.pendingFrameWrite(for: 10), secondFrame)

        let currentOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: secondRequest)
        ])
        XCTAssertEqual(currentOutcome.deliveries.count, 1)
        for delivery in currentOutcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(secondResults.map(\.requestId), [secondRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), secondFrame)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: 10))
    }

    @MainActor
    func testAXFrameLedgerRekeysPendingRequestBeforeCompletion() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        var results: [AXFrameApplyResult] = []
        let decision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false
        ) { result in
            results.append(result)
        }
        let request = try XCTUnwrap(decision.request)

        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        let outcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: request)
        ])
        XCTAssertEqual(outcome.deliveries.count, 1)
        for delivery in outcome.deliveries {
            delivery.deliver()
        }

        XCTAssertEqual(results.map(\.windowId), [20])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: 20))
    }

    @MainActor
    func testAXFrameLedgerRetriesRekeyCancelledOldIdCompletion() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        var results: [AXFrameApplyResult] = []
        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false
        ) { result in
            results.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)

        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        let cancelledOldCompletion = Self.frameResult(
            requestId: firstRequest.requestId,
            pid: firstRequest.pid,
            windowId: firstRequest.windowId,
            targetFrame: firstRequest.frame,
            currentFrameHint: firstRequest.currentFrameHint,
            failureReason: .cancelled
        )
        let cancelledOutcome = ledger.handleFrameApplyResults([cancelledOldCompletion])

        XCTAssertTrue(cancelledOutcome.deliveries.isEmpty)
        XCTAssertEqual(cancelledOutcome.retries, [
            AXFrameRetryRequest(pid: getpid(), windowId: 20, frame: frame)
        ])

        let retryDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 20,
            frame: frame,
            isRetry: true,
            terminalObserver: nil
        )
        let retryRequest = try XCTUnwrap(retryDecision.request)
        let retryOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: retryRequest)
        ])
        for delivery in retryOutcome.deliveries {
            delivery.deliver()
        }

        XCTAssertEqual(results.map(\.requestId), [retryRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
    }

    @MainActor
    func testAXFrameLedgerTransfersObserverToRetryRequest() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        var results: [AXFrameApplyResult] = []
        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false
        ) { result in
            results.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)

        let failedOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest, failureReason: .cacheMiss)
        ])
        XCTAssertTrue(failedOutcome.deliveries.isEmpty)
        XCTAssertEqual(failedOutcome.retries, [
            AXFrameRetryRequest(pid: getpid(), windowId: 10, frame: frame)
        ])

        let retryDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: true,
            terminalObserver: nil
        )
        let retryRequest = try XCTUnwrap(retryDecision.request)

        let staleOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest)
        ])
        XCTAssertTrue(staleOutcome.deliveries.isEmpty)

        let retryOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: retryRequest)
        ])
        XCTAssertEqual(retryOutcome.deliveries.count, 1)
        for delivery in retryOutcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(results.map(\.requestId), [retryRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), frame)
    }

    @MainActor
    func testAXFrameLedgerTransfersObserverToSameTargetNonRetryReplacement() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        var firstResults: [AXFrameApplyResult] = []
        var secondResults: [AXFrameApplyResult] = []
        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false
        ) { result in
            firstResults.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)

        let failedOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest, failureReason: .cacheMiss)
        ])
        XCTAssertEqual(failedOutcome.retries, [
            AXFrameRetryRequest(pid: getpid(), windowId: 10, frame: frame)
        ])

        let secondDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false
        ) { result in
            secondResults.append(result)
        }
        let secondRequest = try XCTUnwrap(secondDecision.request)

        let currentOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: secondRequest)
        ])
        XCTAssertEqual(currentOutcome.deliveries.count, 1)
        for delivery in currentOutcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(firstResults.map(\.requestId), [secondRequest.requestId])
        XCTAssertEqual(secondResults.map(\.requestId), [secondRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), frame)
    }

    @MainActor
    func testAXFrameLedgerOldIdCancelAndSuppressDoNotDestroyRekeyedState() throws {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let cancelLedger = AXFrameApplicationLedger()
        var cancelResults: [AXFrameApplyResult] = []
        let cancelDecision = cancelLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                cancelResults.append(result)
            }
        )
        let cancelRequest = try XCTUnwrap(cancelDecision.request)
        cancelLedger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        XCTAssertEqual(cancelLedger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(cancelLedger.cancelFrameJob(windowId: 10).isEmpty)
        XCTAssertEqual(cancelLedger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(cancelLedger.hasPendingFrameWrite(for: 20))
        XCTAssertTrue(cancelResults.isEmpty)
        XCTAssertEqual(
            cancelLedger.handleFrameApplyResults([
                Self.frameResult(for: cancelRequest, failureReason: .cancelled)
            ]).retries,
            [AXFrameRetryRequest(pid: getpid(), windowId: 20, frame: frame)]
        )

        let suppressLedger = AXFrameApplicationLedger()
        let suppressDecision = suppressLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 30,
            frame: frame,
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertNotNil(suppressDecision.request)
        suppressLedger.rekeyWindowState(oldWindowId: 30, newWindowId: 40)
        XCTAssertEqual(suppressLedger.resolvedWindowId(for: 30), 40)
        XCTAssertTrue(suppressLedger.suppressFrameWrite(windowId: 30).isEmpty)
        XCTAssertEqual(suppressLedger.resolvedWindowId(for: 30), 40)
        XCTAssertTrue(suppressLedger.hasPendingFrameWrite(for: 40))
    }

    @MainActor
    func testAXFrameLedgerLiveIdCancelSuppressAndRemoveClearRekeyedState() throws {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let cancelLedger = AXFrameApplicationLedger()
        var cancelResults: [AXFrameApplyResult] = []
        let cancelDecision = cancelLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                cancelResults.append(result)
            }
        )
        let cancelRequest = try XCTUnwrap(cancelDecision.request)
        cancelLedger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        for delivery in cancelLedger.cancelFrameJob(windowId: 20) {
            delivery.deliver()
        }
        XCTAssertEqual(cancelLedger.resolvedWindowId(for: 10), 10)
        XCTAssertEqual(cancelResults.map(\.writeResult.failureReason), [.cancelled])
        XCTAssertFalse(cancelLedger.hasPendingFrameWrite(for: 20))
        XCTAssertTrue(
            cancelLedger.handleFrameApplyResults([
                Self.frameResult(for: cancelRequest, failureReason: .cancelled)
            ]).deliveries.isEmpty
        )

        let suppressLedger = AXFrameApplicationLedger()
        let suppressDecision = suppressLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 30,
            frame: frame,
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertNotNil(suppressDecision.request)
        suppressLedger.rekeyWindowState(oldWindowId: 30, newWindowId: 40)
        _ = suppressLedger.suppressFrameWrite(windowId: 40)
        XCTAssertEqual(suppressLedger.resolvedWindowId(for: 30), 30)
        XCTAssertFalse(suppressLedger.hasPendingFrameWrite(for: 40))

        let removeLedger = AXFrameApplicationLedger()
        var removeResults: [AXFrameApplyResult] = []
        let removeDecision = removeLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 50,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                removeResults.append(result)
            }
        )
        let removeRequest = try XCTUnwrap(removeDecision.request)
        removeLedger.rekeyWindowState(oldWindowId: 50, newWindowId: 60)
        for delivery in removeLedger.removeWindowState(windowId: 60) {
            delivery.deliver()
        }
        XCTAssertEqual(removeLedger.resolvedWindowId(for: 50), 50)
        XCTAssertEqual(removeResults.map(\.writeResult.failureReason), [.cancelled])
        XCTAssertFalse(removeLedger.hasPendingFrameWrite(for: 60))
        XCTAssertTrue(
            removeLedger.handleFrameApplyResults([
                Self.frameResult(for: removeRequest)
            ]).deliveries.isEmpty
        )
    }

    @MainActor
    func testAXFrameLedgerOldWindowRemoveDoesNotRemoveRekeyedPendingState() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        var results: [AXFrameApplyResult] = []
        let decision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                results.append(result)
            }
        )
        let request = try XCTUnwrap(decision.request)

        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        XCTAssertEqual(ledger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(ledger.removeWindowState(windowId: 10).isEmpty)

        XCTAssertEqual(ledger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(ledger.hasPendingFrameWrite(for: 20))
        XCTAssertEqual(
            ledger.handleFrameApplyResults([
                Self.frameResult(for: request, failureReason: .cancelled)
            ]).retries,
            [AXFrameRetryRequest(pid: getpid(), windowId: 20, frame: frame)]
        )
    }

    @MainActor
    func testAXFrameLedgerClearsSettledRekeyAliasWhenNoPendingState() {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        ledger.confirmFrameWrite(for: 10, frame: frame)
        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
        XCTAssertEqual(ledger.resolvedWindowId(for: 10), 10)

        let updatedFrame = CGRect(x: 30, y: 40, width: 500, height: 300)
        ledger.confirmFrameWrite(for: 10, frame: updatedFrame)

        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), updatedFrame)
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
    }

    @MainActor
    func testLayoutRuntimeRevisionCancelsPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_001
        let windowId = 765_101
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [(pid, windowId, CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: token
        )

        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testFocusOnlyRevisionDoesNotCancelPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_002
        let windowId = 765_102
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [(pid, windowId, CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        _ = controller.workspaceManager.beginManagedFocusRequest(token, in: workspaceId, requestId: 7)
        XCTAssertTrue(terminalResults.isEmpty)

        controller.axManager.cancelPendingFrameJobs([(pid, windowId)])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testPureLayoutRevisionDoesNotCancelPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_008
        let windowId = 765_108
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [(pid, windowId, CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        XCTAssertTrue(terminalResults.isEmpty)

        controller.axManager.cancelPendingFrameJobs([(pid, windowId)])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testSuppressedLayoutRevisionDoesNotCancelPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_003
        let windowId = 765_103
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [(pid, windowId, CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(
                WindowModel.HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: nil,
                    reason: .workspaceInactive
                ),
                for: token
            )
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.axManager.cancelPendingFrameJobs([(pid, windowId)])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testPendingScratchpadRevealUsesLiveWorkspaceAfterReassignment() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let destinationWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let pid: pid_t = 765_004
        let windowId = 765_104
        let targetFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: sourceWorkspaceId,
            mode: .floating
        )
        let staleEntry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let hiddenState = WindowModel.HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        controller.reassignManagedWindow(token, to: destinationWorkspaceId)

        let transactionId = try XCTUnwrap(
            controller.layoutRefreshController.beginPendingRevealTransaction(
                for: staleEntry,
                hiddenState: hiddenState,
                targetFrame: targetFrame,
                monitor: controller.workspaceManager.monitor(for: destinationWorkspaceId) ?? Monitor.fallback()
            )
        )
        controller.workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        controller.axManager.confirmFrameWrite(for: windowId, frame: targetFrame)
        XCTAssertEqual(controller.axManager.lastAppliedFrame(for: windowId), targetFrame)
        controller.layoutRefreshController.completePendingRevealTransaction(
            with: Self.frameResult(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                targetFrame: targetFrame,
                currentFrameHint: nil
            ),
            transactionId: transactionId
        )

        XCTAssertEqual(controller.workspaceManager.hiddenState(for: token), hiddenState)
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: windowId))
    }

    @MainActor
    func testPendingScratchpadRevealSuccessActionRejectsStaleFocusRevision() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let pid: pid_t = 765_006
        let windowId = 765_106
        let targetFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let focusToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 765_206),
            pid: pid,
            windowId: 765_206,
            to: workspaceId
        )
        let hiddenState = WindowModel.HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        var didRun = false

        controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let transactionId = try XCTUnwrap(
            controller.layoutRefreshController.beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: targetFrame,
                monitor: monitor,
                onSuccess: {
                    didRun = true
                }
            )
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(focusToken, in: workspaceId, requestId: 99)

        controller.layoutRefreshController.completePendingRevealTransaction(
            with: Self.frameResult(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                targetFrame: targetFrame,
                currentFrameHint: nil
            ),
            transactionId: transactionId
        )

        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertFalse(didRun)
    }

    @MainActor
    func testPendingScratchpadRevealSuccessActionRebasesLocalHiddenMutation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let pid: pid_t = 765_007
        let windowId = 765_107
        let targetFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let hiddenState = WindowModel.HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        var didRun = false

        controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let transactionId = try XCTUnwrap(
            controller.layoutRefreshController.beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: targetFrame,
                monitor: monitor,
                onSuccess: {
                    didRun = true
                }
            )
        )

        controller.layoutRefreshController.completePendingRevealTransaction(
            with: Self.frameResult(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                targetFrame: targetFrame,
                currentFrameHint: nil
            ),
            transactionId: transactionId
        )

        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertTrue(didRun)
    }

    @MainActor
    func testNiriFocusNeighborAcrossColumnsFocusesSelectedWindowAfterViewportCommit() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_009), windowId: 765_109),
            pid: 765_009,
            windowId: 765_109,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_010), windowId: 765_110),
            pid: 765_010,
            windowId: 765_110,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(
            token: firstToken,
            to: workspaceId,
            afterSelection: nil
        )
        let secondNode = engine.addWindow(
            token: secondToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: firstNode.id,
            focusedToken: firstToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.niriLayoutHandler.focusNeighbor(direction: .right)
        for _ in 0 ..< 40 where focusedTokens.last != secondToken {
            if let refreshTask = controller.layoutRefreshController.layoutState.activeRefreshTask {
                await refreshTask.value
            } else {
                await Task.yield()
            }
        }

        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId, secondNode.id)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), secondToken)
        XCTAssertEqual(focusedTokens.last, secondToken)
    }

    @MainActor
    func testNiriPostLayoutFocusRejectsFocusRevisionChange() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let selectedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_011), windowId: 765_111),
            pid: 765_011,
            windowId: 765_111,
            to: workspaceId
        )
        let staleLastFocusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_012), windowId: 765_112),
            pid: 765_012,
            windowId: 765_112,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let selectedNode = engine.addWindow(
            token: selectedToken,
            to: workspaceId,
            afterSelection: nil
        )
        _ = engine.addWindow(
            token: staleLastFocusedToken,
            to: workspaceId,
            afterSelection: selectedNode.id,
            focusedToken: selectedToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: selectedNode.id,
            focusedToken: selectedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        controller.niriLayoutHandler.activateNode(
            selectedNode,
            in: workspaceId,
            state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil,
                runtimeRevision: controller.workspaceManager.runtimeRevision(for: workspaceId)
            )
        )
        controller.niriLayoutHandler.requestSelectedWindowFocusAfterLayout(in: workspaceId)
        let action = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            .first)
        _ = controller.workspaceManager.rememberFocus(staleLastFocusedToken, in: workspaceId)

        action.runIfCurrent(using: controller.workspaceManager)

        XCTAssertNil(focusedTokens.last)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), staleLastFocusedToken)
    }

    @MainActor
    func testNiriProtectedReplacementActivationPreservesViewportOffset() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_013), windowId: 765_113),
            pid: 765_013,
            windowId: 765_113,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_014), windowId: 765_114),
            pid: 765_014,
            windowId: 765_114,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(
            token: firstToken,
            to: workspaceId,
            afterSelection: nil
        )
        let secondNode = engine.addWindow(
            token: secondToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = firstNode.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(-16.0)

        controller.niriLayoutHandler.activateNode(
            secondNode,
            in: workspaceId,
            state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                preserveViewportAnchor: true,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )

        XCTAssertEqual(state.selectedNodeId, secondNode.id)
        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertEqual(state.viewOffsetPixels.current(), -16.0, accuracy: 0.001)
        XCTAssertFalse(state.viewOffsetPixels.isAnimating)
    }

    @MainActor
    func testNiriTabLocalAddAtLeftEdgePreservesViewportWithoutScroll() async throws {
        try await Self.assertNiriTabLocalAddPreservesViewport(.leftEdge)
    }

    @MainActor
    func testNiriTabLocalAddInMiddlePreservesViewportWithoutScroll() async throws {
        try await Self.assertNiriTabLocalAddPreservesViewport(.middle)
    }

    @MainActor
    func testNiriTabLocalAddAtRightEdgePreservesViewportWithoutScroll() async throws {
        try await Self.assertNiriTabLocalAddPreservesViewport(.rightEdge)
    }

    @MainActor
    func testNiriMixedTabLocalAndNewColumnOnlyAnimatesTrueColumnAddition() async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let existingTokens = Self.addNiriRuntimeWindows(
            count: 3,
            pidBase: 765_300,
            windowBase: 765_400,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        Self.seedNiriEngineColumns(
            tokens: existingTokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: 1
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let targetColumn = initialColumns[1]
        let selectedNode = try XCTUnwrap(targetColumn.windowNodes.first)
        let targetColumnX = state.columnX(at: 1, columns: initialColumns, gap: CGFloat(controller.workspaceManager.gaps))
        let viewOrigin = targetColumnX - (monitor.visibleFrame.width - columnWidth) / 2
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(viewOrigin - targetColumnX)
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                runtimeRevision: controller.workspaceManager.runtimeRevision(for: workspaceId)
            )
        )

        let newTabToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_303), windowId: 765_403),
            pid: 765_303,
            windowId: 765_403,
            to: workspaceId
        )
        let newColumnToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_304), windowId: 765_404),
            pid: 765_304,
            windowId: 765_404,
            to: workspaceId
        )
        var placements = Self.niriRestorePlacements(
            tokens: existingTokens,
            columnWidth: columnWidth,
            tabbedColumnIndex: 1,
            activeTabIndex: 1
        )
        placements[newTabToken] = Self.niriRestorePlacement(
            columnIndex: 1,
            tileIndex: 1,
            displayMode: .tabbed,
            activeTileIndex: 1,
            columnWidth: columnWidth
        )
        controller.workspaceManager.setNiriRestorePlacements(placements)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        let plan = try XCTUnwrap(plans.first)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState)
        let newTabNode = try XCTUnwrap(engine.findNode(for: newTabToken))
        let newColumnNode = try XCTUnwrap(engine.findNode(for: newColumnToken))
        let newTabColumn = try XCTUnwrap(engine.column(of: newTabNode))

        XCTAssertFalse(newTabNode.hasMoveAnimationsRunning)
        XCTAssertTrue(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        XCTAssertTrue(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newColumnToken))
        XCTAssertEqual(newTabColumn.activeWindow?.token, newTabToken)
        XCTAssertEqual(patchedState.selectedNodeId, newColumnNode.id)
    }

    @MainActor
    func testNiriLiveCreateInSelectedTabbedColumnCreatesNormalColumn() async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let existingTokens = Self.addNiriRuntimeWindows(
            count: 2,
            pidBase: 765_500,
            windowBase: 765_600,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        Self.seedNiriEngineColumns(
            tokens: existingTokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: 0
        )

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let selectedNode = try XCTUnwrap(initialColumns[0].windowNodes.first)
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                runtimeRevision: controller.workspaceManager.runtimeRevision(for: workspaceId)
            )
        )

        let newToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_502), windowId: 765_602),
            pid: 765_502,
            windowId: 765_602,
            to: workspaceId
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        let plan = try XCTUnwrap(plans.first)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState)
        let finalColumns = engine.columns(in: workspaceId)
        let newNode = try XCTUnwrap(engine.findNode(for: newToken))
        let newColumn = try XCTUnwrap(engine.column(of: newNode))

        XCTAssertEqual(finalColumns.count, initialColumns.count + 1)
        XCTAssertEqual(finalColumns[0].displayMode, .tabbed)
        XCTAssertEqual(finalColumns[0].windowNodes.map(\.token), [existingTokens[0]])
        XCTAssertEqual(newColumn.displayMode, .normal)
        XCTAssertEqual(newColumn.windowNodes.map(\.token), [newToken])
        XCTAssertTrue(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertTrue(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        XCTAssertEqual(patchedState.selectedNodeId, newNode.id)
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newToken))
    }

    @MainActor
    func testNiriVisibleSameAppCreateDoesNotRekeyOrAutoTab() async throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let frame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let existingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_510), windowId: 765_610),
            pid: 765_510,
            windowId: 765_610,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: 765_510,
                frame: frame
            )
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let existingNode = engine.addWindow(
            token: existingToken,
            to: workspaceId,
            afterSelection: nil
        )
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = existingNode.id
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                runtimeRevision: controller.workspaceManager.runtimeRevision(for: workspaceId)
            )
        )

        let newToken = WindowToken(pid: 765_510, windowId: 765_611)
        controller.axEventHandler.visibleWindowInfoProvider = {
            [
                Self.visibleWindowInfo(pid: existingToken.pid, windowId: existingToken.windowId, frame: frame),
                Self.visibleWindowInfo(pid: newToken.pid, windowId: newToken.windowId, frame: frame)
            ]
        }
        XCTAssertFalse(
            controller.axEventHandler.rekeyStructuralManagedReplacementIfNeeded(
                token: newToken,
                windowId: UInt32(newToken.windowId),
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(newToken.pid),
                    windowId: newToken.windowId
                ),
                bundleId: Self.nativeTabBundleId(pid: newToken.pid),
                mode: .tiling,
                facts: Self.nativeTabFacts(pid: newToken.pid, windowId: newToken.windowId, frame: frame)
            )
        )
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(newToken.pid), windowId: newToken.windowId),
            pid: newToken.pid,
            windowId: newToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: newToken.pid,
                frame: frame
            )
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        let plan = try XCTUnwrap(plans.first)
        let newNode = try XCTUnwrap(engine.findNode(for: newToken))
        let leaderColumn = try XCTUnwrap(engine.column(of: existingNode))
        let newColumn = try XCTUnwrap(engine.column(of: newNode))

        XCTAssertFalse(leaderColumn === newColumn)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 2)
        XCTAssertEqual(leaderColumn.displayMode, .normal)
        XCTAssertEqual(newColumn.displayMode, .normal)
        XCTAssertTrue(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newToken))
    }

    @MainActor
    func testNiriNativeMacOSTabRekeysInvisibleSiblingWithoutOmniWMTab() async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let nativeFrame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let leftToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_520), windowId: 765_620),
            pid: 765_520,
            windowId: 765_620,
            to: workspaceId
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_521), windowId: 765_621),
            pid: 765_521,
            windowId: 765_621,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: 765_521,
                frame: nativeFrame
            )
        )
        let rightToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_522), windowId: 765_622),
            pid: 765_522,
            windowId: 765_622,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        Self.seedNiriEngineColumns(
            tokens: [leftToken, oldToken, rightToken],
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: -1
        )

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let oldNode = try XCTUnwrap(engine.findNode(for: oldToken))
        let gap = CGFloat(controller.workspaceManager.gaps)
        let selectedColumnX = state.columnX(at: 1, columns: initialColumns, gap: gap)
        let viewOrigin = selectedColumnX - (monitor.visibleFrame.width - columnWidth) / 2
        state.selectedNodeId = oldNode.id
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(viewOrigin - selectedColumnX)
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                runtimeRevision: controller.workspaceManager.runtimeRevision(for: workspaceId)
            )
        )

        let newToken = WindowToken(pid: oldToken.pid, windowId: 765_623)
        controller.axEventHandler.visibleWindowInfoProvider = {
            [
                Self.visibleWindowInfo(pid: newToken.pid, windowId: newToken.windowId, frame: nativeFrame)
            ]
        }

        XCTAssertTrue(
            controller.axEventHandler.rekeyStructuralManagedReplacementIfNeeded(
                token: newToken,
                windowId: UInt32(newToken.windowId),
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(newToken.pid),
                    windowId: newToken.windowId
                ),
                bundleId: Self.nativeTabBundleId(pid: newToken.pid),
                mode: .tiling,
                facts: Self.nativeTabFacts(pid: newToken.pid, windowId: newToken.windowId, frame: nativeFrame)
            )
        )
        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: newToken))

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId],
            useScrollAnimationPath: true
        )
        let plan = try XCTUnwrap(plans.first)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState)
        let finalColumns = engine.columns(in: workspaceId)
        let newNode = try XCTUnwrap(engine.findNode(for: newToken))
        let patchedViewOrigin = patchedState.viewPosPixels(columns: finalColumns, gap: gap)

        XCTAssertNil(engine.findNode(for: oldToken))
        XCTAssertEqual(newNode.id, oldNode.id)
        XCTAssertEqual(finalColumns.count, initialColumns.count)
        XCTAssertEqual(finalColumns[1].displayMode, .normal)
        XCTAssertEqual(finalColumns[1].windowNodes.map(\.token), [newToken])
        XCTAssertFalse(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertFalse(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        XCTAssertFalse(engine.hasAnyWindowAnimationsRunning(in: workspaceId))
        XCTAssertFalse(patchedState.viewOffsetPixels.isAnimating)
        XCTAssertEqual(patchedViewOrigin, viewOrigin, accuracy: 0.001)
        XCTAssertEqual(patchedState.selectedNodeId, newNode.id)
    }

    @MainActor
    func testNiriFocusedRemovalPreferredRecoveryUsesLayoutRememberedToken() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let closingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_015), windowId: 765_115),
            pid: 765_015,
            windowId: 765_115,
            to: workspaceId
        )
        let selectedFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_016), windowId: 765_116),
            pid: 765_016,
            windowId: 765_116,
            to: workspaceId
        )
        let resolverFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_017), windowId: 765_117),
            pid: 765_017,
            windowId: 765_117,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let closingNode = engine.addWindow(
            token: closingToken,
            to: workspaceId,
            afterSelection: nil
        )
        let selectedFallbackNode = engine.addWindow(
            token: selectedFallbackToken,
            to: workspaceId,
            afterSelection: closingNode.id,
            focusedToken: closingToken
        )
        let resolverFallbackNode = engine.addWindow(
            token: resolverFallbackToken,
            to: workspaceId,
            afterSelection: selectedFallbackNode.id,
            focusedToken: closingToken
        )
        _ = controller.workspaceManager.setManagedFocus(
            closingToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode.id,
            focusedToken: nil,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.rememberFocus(resolverFallbackToken, in: workspaceId)

        controller.axEventHandler.handleRemoved(token: closingToken)
        await Self.waitForRemovalRefresh(controller, removedToken: closingToken)

        XCTAssertNil(controller.workspaceManager.entry(for: closingToken))
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId, resolverFallbackNode.id)
        XCTAssertEqual(focusedTokens.last, resolverFallbackToken)
    }

    @MainActor
    func testNiriManagedReplacementProtectedRemovalResolvesFocusFallbackDuringValidation() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.omniwm.tests.tabs",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "tab",
            windowLevel: 0,
            parentWindowId: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 420)
        )
        let closingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_018), windowId: 765_118),
            pid: 765_018,
            windowId: 765_118,
            to: workspaceId,
            managedReplacementMetadata: metadata
        )
        let selectedFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_019), windowId: 765_119),
            pid: 765_019,
            windowId: 765_119,
            to: workspaceId
        )
        let resolverFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_020), windowId: 765_120),
            pid: 765_020,
            windowId: 765_120,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let closingNode = engine.addWindow(
            token: closingToken,
            to: workspaceId,
            afterSelection: nil
        )
        let selectedFallbackNode = engine.addWindow(
            token: selectedFallbackToken,
            to: workspaceId,
            afterSelection: closingNode.id,
            focusedToken: closingToken
        )
        let resolverFallbackNode = engine.addWindow(
            token: resolverFallbackToken,
            to: workspaceId,
            afterSelection: selectedFallbackNode.id,
            focusedToken: closingToken
        )
        _ = controller.workspaceManager.setManagedFocus(
            closingToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode.id,
            focusedToken: nil,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.rememberFocus(resolverFallbackToken, in: workspaceId)

        controller.axEventHandler.handleRemoved(pid: closingToken.pid, winId: closingToken.windowId)
        await Self.waitForRemovalRefresh(controller, removedToken: closingToken)

        XCTAssertNil(controller.workspaceManager.entry(for: closingToken))
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId, resolverFallbackNode.id)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), resolverFallbackToken)
        XCTAssertEqual(focusedTokens.last, resolverFallbackToken)
    }

    private static func snapshot(
        focusedToken: WindowToken? = nil,
        pendingManagedFocus: PendingManagedFocusSnapshot = .empty,
        interactionMonitorId: Monitor.ID? = nil,
        previousInteractionMonitorId: Monitor.ID? = nil,
        windows: [ReconcileWindowSnapshot] = []
    ) -> ReconcileSnapshot {
        ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(
                focusedToken: focusedToken,
                pendingManagedFocus: pendingManagedFocus,
                focusLease: nil,
                isNonManagedFocusActive: false,
                isAppFullscreenActive: false,
                interactionMonitorId: interactionMonitorId,
                previousInteractionMonitorId: previousInteractionMonitorId
            ),
            windows: windows
        )
    }

    private static func invariantCodes(
        focusedToken: WindowToken? = nil,
        pendingManagedFocus: PendingManagedFocusSnapshot = .empty,
        windows: [ReconcileWindowSnapshot] = []
    ) -> Set<String> {
        Set(
            InvariantChecks.validate(
                snapshot: snapshot(
                    focusedToken: focusedToken,
                    pendingManagedFocus: pendingManagedFocus,
                    windows: windows
                )
            ).map(\.code)
        )
    }

    private static func window(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        lifecyclePhase: WindowLifecyclePhase = .tiled
    ) -> ReconcileWindowSnapshot {
        ReconcileWindowSnapshot(
            token: token,
            workspaceId: workspaceId,
            mode: .tiling,
            lifecyclePhase: lifecyclePhase,
            observedState: .initial(workspaceId: workspaceId, monitorId: nil),
            desiredState: .initial(workspaceId: workspaceId, monitorId: nil, disposition: .tiling),
            restoreIntent: nil,
            replacementCorrelation: nil
        )
    }

    private static func frameResult(
        for request: AXFrameApplicationRequest,
        failureReason: AXFrameWriteFailureReason? = nil
    ) -> AXFrameApplyResult {
        frameResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            failureReason: failureReason
        )
    }

    private static func frameResult(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        targetFrame: CGRect,
        currentFrameHint: CGRect?,
        failureReason: AXFrameWriteFailureReason? = nil
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: AXFrameWriteResult(
                targetFrame: targetFrame,
                observedFrame: failureReason == nil ? targetFrame : nil,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: failureReason
            )
        )
    }

    private static func layoutMonitorSnapshot(_ monitor: Monitor) -> LayoutMonitorSnapshot {
        LayoutMonitorSnapshot(
            monitorId: monitor.id,
            displayId: monitor.displayId,
            frame: monitor.frame,
            visibleFrame: monitor.visibleFrame,
            workingFrame: monitor.visibleFrame,
            scale: 1,
            orientation: monitor.autoOrientation
        )
    }

    @MainActor
    private static func waitForRemovalRefresh(
        _ controller: WMController,
        removedToken: WindowToken
    ) async {
        for _ in 0 ..< 80 {
            if let refreshTask = controller.layoutRefreshController.layoutState.activeRefreshTask {
                await refreshTask.value
                continue
            }
            if controller.workspaceManager.entry(for: removedToken) == nil,
               controller.layoutRefreshController.layoutState.pendingRefresh == nil
            {
                await Task.yield()
                if controller.layoutRefreshController.layoutState.activeRefreshTask == nil,
                   controller.layoutRefreshController.layoutState.pendingRefresh == nil
                {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum NiriTabLocalViewportPosition {
        case leftEdge
        case middle
        case rightEdge

        var targetColumnIndex: Int {
            switch self {
            case .leftEdge: 0
            case .middle: 2
            case .rightEdge: 4
            }
        }

        func viewOrigin(targetColumnX: CGFloat, columnWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
            switch self {
            case .leftEdge:
                targetColumnX
            case .middle:
                targetColumnX - (viewportWidth - columnWidth) / 2
            case .rightEdge:
                targetColumnX - (viewportWidth - columnWidth)
            }
        }
    }

    @MainActor
    private static func assertNiriTabLocalAddPreservesViewport(
        _ position: NiriTabLocalViewportPosition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller(file: file, line: line)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let existingTokens = Self.addNiriRuntimeWindows(
            count: 5,
            pidBase: 765_200,
            windowBase: 765_300,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine, file: file, line: line)
        Self.seedNiriEngineColumns(
            tokens: existingTokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: position.targetColumnIndex
        )

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId), file: file, line: line)
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let targetColumn = initialColumns[position.targetColumnIndex]
        let selectedNode = try XCTUnwrap(targetColumn.windowNodes.first, file: file, line: line)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let targetColumnX = state.columnX(at: position.targetColumnIndex, columns: initialColumns, gap: gap)
        let viewOrigin = position.viewOrigin(
            targetColumnX: targetColumnX,
            columnWidth: columnWidth,
            viewportWidth: monitor.visibleFrame.width
        )
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = position.targetColumnIndex
        state.viewOffsetPixels = .static(viewOrigin - targetColumnX)
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                runtimeRevision: controller.workspaceManager.runtimeRevision(for: workspaceId)
            )
        )

        let newTabToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_205), windowId: 765_305),
            pid: 765_205,
            windowId: 765_305,
            to: workspaceId
        )
        var placements = Self.niriRestorePlacements(
            tokens: existingTokens,
            columnWidth: columnWidth,
            tabbedColumnIndex: position.targetColumnIndex,
            activeTabIndex: 1
        )
        placements[newTabToken] = Self.niriRestorePlacement(
            columnIndex: position.targetColumnIndex,
            tileIndex: 1,
            displayMode: .tabbed,
            activeTileIndex: 1,
            columnWidth: columnWidth
        )
        controller.workspaceManager.setNiriRestorePlacements(placements)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        let plan = try XCTUnwrap(plans.first, file: file, line: line)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState, file: file, line: line)
        let finalColumns = engine.columns(in: workspaceId)
        let newTabNode = try XCTUnwrap(engine.findNode(for: newTabToken), file: file, line: line)
        let patchedViewOrigin = patchedState.viewPosPixels(columns: finalColumns, gap: gap)

        XCTAssertEqual(patchedViewOrigin, viewOrigin, accuracy: 0.001, file: file, line: line)
        XCTAssertFalse(patchedState.viewOffsetPixels.isAnimating, file: file, line: line)
        XCTAssertEqual(patchedState.selectedNodeId, newTabNode.id, file: file, line: line)
        XCTAssertEqual(finalColumns[position.targetColumnIndex].activeWindow?.token, newTabToken, file: file, line: line)
        XCTAssertFalse(engine.hasAnyColumnAnimationsRunning(in: workspaceId), file: file, line: line)
        XCTAssertFalse(engine.hasAnyWindowAnimationsRunning(in: workspaceId), file: file, line: line)
        XCTAssertFalse(plan.animationDirectives.containsStartNiriScroll(for: workspaceId), file: file, line: line)
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newTabToken), file: file, line: line)
    }

    @MainActor
    private static func addNiriRuntimeWindows(
        count: Int,
        pidBase: Int32,
        windowBase: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> [WindowToken] {
        (0 ..< count).map { index in
            let pid = pidBase + Int32(index)
            let windowId = windowBase + index
            return controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
        }
    }

    @MainActor
    private static func seedNiriEngineColumns(
        tokens: [WindowToken],
        workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        columnWidth: CGFloat,
        tabbedColumnIndex: Int
    ) {
        var previousNode: NiriWindow?
        for token in tokens {
            previousNode = engine.addWindow(
                token: token,
                to: workspaceId,
                afterSelection: previousNode?.id,
                focusedToken: previousNode?.token
            )
        }

        let columns = engine.columns(in: workspaceId)
        for (index, column) in columns.enumerated() {
            column.width = .fixed(columnWidth)
            column.cachedWidth = columnWidth
            column.displayMode = index == tabbedColumnIndex ? .tabbed : .normal
            column.setActiveTileIdx(0)
            engine.updateTabbedColumnVisibility(column: column)
        }
    }

    private static func niriRestorePlacements(
        tokens: [WindowToken],
        columnWidth: CGFloat,
        tabbedColumnIndex: Int,
        activeTabIndex: Int
    ) -> [WindowToken: PersistedNiriPlacement] {
        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            let isTabbedColumn = index == tabbedColumnIndex
            placements[token] = niriRestorePlacement(
                columnIndex: index,
                tileIndex: 0,
                displayMode: isTabbedColumn ? .tabbed : .normal,
                activeTileIndex: isTabbedColumn ? activeTabIndex : 0,
                columnWidth: columnWidth
            )
        }
        return placements
    }

    private static func niriRestorePlacement(
        columnIndex: Int,
        tileIndex: Int,
        displayMode: ColumnDisplay,
        activeTileIndex: Int,
        columnWidth: CGFloat
    ) -> PersistedNiriPlacement {
        PersistedNiriPlacement(
            columnIndex: columnIndex,
            tileIndex: tileIndex,
            column: PersistedNiriColumnState(
                displayMode: displayMode,
                activeTileIndex: activeTileIndex,
                width: .fixed(columnWidth),
                presetWidthIndex: nil,
                isFullWidth: false,
                savedWidth: nil,
                hasManualSingleWindowWidthOverride: false
            ),
            window: PersistedNiriWindowState(
                sizingMode: .normal,
                height: .auto(weight: 1),
                savedHeight: nil,
                windowWidth: .auto(weight: 1)
            )
        )
    }

    private static func managedReplacementMetadata(
        workspaceId: WorkspaceDescriptor.ID,
        pid: pid_t,
        frame: CGRect
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: nativeTabBundleId(pid: pid),
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "native-tab",
            windowLevel: 0,
            parentWindowId: nil,
            frame: frame
        )
    }

    private static func nativeTabBundleId(pid: pid_t) -> String {
        "com.omniwm.tests.native-tabs.\(pid)"
    }

    private static func nativeTabFacts(
        pid: pid_t,
        windowId: Int,
        frame: CGRect
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: "Native Tabs",
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "native-tab",
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: nativeTabBundleId(pid: pid),
                attributeFetchSucceeded: true
            ),
            sizeConstraints: nil,
            windowServer: visibleWindowInfo(pid: pid, windowId: windowId, frame: frame)
        )
    }

    private static func visibleWindowInfo(
        pid: pid_t,
        windowId: Int,
        frame: CGRect
    ) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(windowId),
            pid: pid,
            level: 0,
            frame: frame,
            tags: 1,
            attributes: 2,
            parentId: 0,
            title: nil
        )
    }

    private static func assertFrame(
        _ actual: CGRect,
        equals expected: CGRect,
        accuracy: CGFloat = 0.000001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    @MainActor
    private static func workspaceManager(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorkspaceManager {
        WorkspaceManager(settings: settingsStore(file: file, line: line))
    }

    @MainActor
    private static func controller(
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        ),
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WMController {
        WMController(
            settings: settingsStore(file: file, line: line),
            windowFocusOperations: windowFocusOperations
        )
    }

    @MainActor
    private static func settingsStore(
        file _: StaticString = #filePath,
        line _: UInt = #line
    ) -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return settings
    }
}

private extension Array where Element == AnimationDirective {
    func containsStartNiriScroll(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
        contains { directive in
            if case .startNiriScroll(let directiveWorkspaceId) = directive {
                return directiveWorkspaceId == workspaceId
            }
            return false
        }
    }

    func containsActivateWindow(_ token: WindowToken) -> Bool {
        contains { directive in
            if case .activateWindow(let directiveToken) = directive {
                return directiveToken == token
            }
            return false
        }
    }
}
