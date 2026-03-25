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

    @Test @MainActor func hideInactiveWorkspacesMarksSecondaryWorkspaceWindowHiddenOnVerticalOverride() {
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
        controller.axManager.applyFramesParallel(
            [(pid: token.pid, windowId: token.windowId, frame: CGRect(x: 2160, y: 180, width: 800, height: 600))]
        )

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
