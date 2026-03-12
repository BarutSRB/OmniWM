import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@Suite struct LayoutRefreshControllerTests {
    @Test @MainActor func hiddenEdgeRevealUsesOnePointZeroForNonZoomApps() {
        #expect(LayoutRefreshController.hiddenEdgeReveal(isZoomApp: false) == 1.0)
    }

    @Test @MainActor func hiddenEdgeRevealUsesZeroForZoom() {
        #expect(LayoutRefreshController.hiddenEdgeReveal(isZoomApp: true) == 0)
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

    @Test @MainActor func executeLayoutPlanPreservesHiddenStateOnHideAndClearsItOnShow() {
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

        var hideDiff = WorkspaceLayoutDiff()
        hideDiff.visibilityChanges = [.hide(token, side: .right)]
        hideDiff.borderMode = .none

        controller.layoutRefreshController.executeLayoutPlan(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
                diff: hideDiff
            )
        )

        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)

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
            pid: getpid()
        ) else {
            Issue.record("Expected a live-frame hide origin for transient hide test")
            return
        }

        #expect(origin.y == frame.origin.y)
        #expect(origin.x < monitor.visibleFrame.minX)
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

    @Test @MainActor func hideWindowWithoutResolvedGeometryDoesNotMarkWindowHidden() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for unavailable hide test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 606)
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
}
