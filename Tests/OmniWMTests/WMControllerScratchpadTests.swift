import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@MainActor
private func setScratchpadTestFrame(
    on controller: WMController,
    token: WindowToken,
    frame: CGRect
) {
    controller.axManager.applyFramesParallel([(token.pid, token.windowId, frame)])
}

@Suite struct WMControllerScratchpadTests {
    @Test @MainActor func assignFocusedWindowToScratchpadHidesTiledWindowAndRejectsSecondAssignment() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad assignment test")
            return
        }

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 700)
        let secondToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 701)
        let firstFrame = CGRect(x: 140, y: 120, width: 760, height: 520)
        let secondFrame = CGRect(x: 980, y: 120, width: 760, height: 520)
        setScratchpadTestFrame(on: controller, token: firstToken, frame: firstFrame)
        setScratchpadTestFrame(on: controller, token: secondToken, frame: secondFrame)

        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()

        #expect(controller.workspaceManager.scratchpadToken() == firstToken)
        #expect(controller.workspaceManager.windowMode(for: firstToken) == .floating)
        #expect(controller.workspaceManager.hiddenState(for: firstToken)?.isScratchpad == true)
        #expect(controller.workspaceManager.floatingState(for: firstToken)?.lastFrame == firstFrame)
        #expect(controller.workspaceManager.pendingFocusedToken == secondToken)

        _ = controller.workspaceManager.setManagedFocus(secondToken, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()

        #expect(controller.workspaceManager.scratchpadToken() == firstToken)
        #expect(controller.workspaceManager.hiddenState(for: secondToken) == nil)
        #expect(controller.workspaceManager.windowMode(for: secondToken) == .tiling)
    }

    @Test @MainActor func toggleScratchpadWindowRestoresAndRecapturesFloatingFrame() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad toggle test")
            return
        }

        let windowId = 71_010
        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        let initialFrame = CGRect(x: 180, y: 140, width: 700, height: 460)
        setScratchpadTestFrame(on: controller, token: token, frame: initialFrame)

        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()
        controller.toggleScratchpadWindow()

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: windowId) == initialFrame)
        #expect(controller.workspaceManager.pendingFocusedToken == token)

        let movedFrame = initialFrame.offsetBy(dx: 120, dy: 90)
        setScratchpadTestFrame(on: controller, token: token, frame: movedFrame)

        controller.toggleScratchpadWindow()
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.workspaceManager.floatingState(for: token)?.lastFrame == movedFrame)

        controller.toggleScratchpadWindow()
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: windowId) == movedFrame)
    }

    @Test @MainActor func assignFocusedWindowToScratchpadClearsVisibleScratchpadSlotWhenRepeated() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad unassign test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 720)
        setScratchpadTestFrame(
            on: controller,
            token: token,
            frame: CGRect(x: 220, y: 180, width: 620, height: 420)
        )

        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()
        controller.toggleScratchpadWindow()
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        controller.assignFocusedWindowToScratchpad()

        #expect(controller.workspaceManager.scratchpadToken() == nil)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.workspaceManager.windowMode(for: token) == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: token) == .forceTile)
    }

    @Test @MainActor func assignFocusedWindowToScratchpadUnassignsVisibleFloatingWindowBackToTiling() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for floating scratchpad unassign test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 725),
            pid: 725,
            windowId: 725,
            to: workspaceId,
            mode: .floating
        )
        let frame = CGRect(x: 260, y: 190, width: 540, height: 360)
        setScratchpadTestFrame(on: controller, token: token, frame: frame)

        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)
        controller.assignFocusedWindowToScratchpad()
        controller.toggleScratchpadWindow()
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId, onMonitor: monitor.id)

        controller.assignFocusedWindowToScratchpad()

        #expect(controller.workspaceManager.scratchpadToken() == nil)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.workspaceManager.windowMode(for: token) == .tiling)
        #expect(controller.workspaceManager.manualLayoutOverride(for: token) == .forceTile)
    }

    @Test @MainActor func toggleScratchpadWindowSummonsToCurrentWorkspaceAndMonitor() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 730
        )
        let initialFrame = CGRect(x: 180, y: 140, width: 640, height: 420)
        setScratchpadTestFrame(on: controller, token: token, frame: initialFrame)

        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        controller.assignFocusedWindowToScratchpad()
        _ = controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id)

        guard let expectedFrame = controller.workspaceManager.resolvedFloatingFrame(
            for: token,
            preferredMonitor: fixture.secondaryMonitor
        ) else {
            Issue.record("Missing resolved floating frame for summoned scratchpad window")
            return
        }

        controller.toggleScratchpadWindow()

        #expect(controller.workspaceManager.workspace(for: token) == fixture.secondaryWorkspaceId)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: 730) == expectedFrame)
        #expect(controller.workspaceManager.pendingFocusedToken == token)
    }
}
