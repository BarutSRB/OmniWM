// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private enum ScratchpadFocusOperationEvent: Equatable {
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
}

private final class ScratchpadFocusRecorder {
    var events: [ScratchpadFocusOperationEvent] = []
}

private func scratchpadTestWriteResult(
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

@MainActor
private func makeScratchpadFocusOperations(
    recorder: ScratchpadFocusRecorder
) -> WindowFocusOperations {
    WindowFocusOperations(
        activateApp: { pid in
            recorder.events.append(.activate(pid))
        },
        focusSpecificWindow: { pid, windowId, _ in
            recorder.events.append(.focus(pid, windowId))
        },
        raiseWindow: { _ in
            recorder.events.append(.raise)
        }
    )
}

@MainActor
private func setScratchpadTestFrame(
    on controller: WMController,
    token: WindowToken,
    frame: CGRect
) {
    controller.axManager.applyFramesParallel([(token.pid, token.windowId, frame)])
}

@Suite(.serialized) struct WMControllerScratchpadTests {
    @Test @MainActor func assignFocusedWindowToScratchpadScopesImmediateRelayoutToOriginWorkspace() async {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 7_032
        )
        setScratchpadTestFrame(
            on: controller,
            token: token,
            frame: CGRect(x: 180, y: 160, width: 620, height: 420)
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        var enqueuedRefreshes: [ScheduledRefresh] = []
        controller.layoutRefreshController.debugHooks.onRefreshEnqueued = { refresh in
            enqueuedRefreshes.append(refresh)
        }
        controller.layoutRefreshController.debugHooks.onRelayout = { _, _ in
            true
        }

        controller.assignFocusedWindowToScratchpad()
        await waitForLayoutPlanRefreshWork(on: controller)

        guard let refresh = enqueuedRefreshes.last(where: { $0.reason == .layoutCommand }) else {
            Issue.record("Missing scoped scratchpad relayout")
            return
        }

        #expect(refresh.kind == .immediateRelayout)
        #expect(refresh.affectedWorkspaceIds == [fixture.primaryWorkspaceId])
    }

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

    @Test @MainActor func toggleScratchpadWindowFrontsWindowOnlyAfterAsyncRevealSucceeds() async throws {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let recorder = ScratchpadFocusRecorder()
        let fixture = makeTwoMonitorLayoutPlanTestController(
            primaryMonitor: makeLayoutPlanPrimaryTestMonitor(name: "Primary"),
            secondaryMonitor: makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920),
            windowFocusOperations: makeScratchpadFocusOperations(recorder: recorder)
        )
        let controller = fixture.controller

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 731
        )
        let initialFrame = CGRect(x: 220, y: 160, width: 620, height: 400)
        setScratchpadTestFrame(on: controller, token: token, frame: initialFrame)

        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        controller.assignFocusedWindowToScratchpad()
        await waitForLayoutPlanRefreshWork(on: controller)
        _ = controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id)

        guard let expectedFrame = controller.workspaceManager.resolvedFloatingFrame(
            for: token,
            preferredMonitor: fixture.secondaryMonitor
        )
        else {
            Issue.record("Missing scratchpad entry or expected frame for async focus test")
            return
        }

        guard let entry = controller.workspaceManager.entry(for: token),
              let context = try await installAsynchronousFrameApplyContextForLayoutPlanTests(
                  on: controller,
                  entry: entry
              )
        else {
            Issue.record("Failed to create AX test context for async scratchpad focus test")
            return
        }

        let writeTimeout: DispatchTimeInterval = .seconds(10)
        let startedWrite = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            if axRef.windowId == token.windowId {
                startedWrite.signal()
                _ = releaseWrite.wait(timeout: .now() + writeTimeout)
            }

            return scratchpadTestWriteResult(
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

        controller.toggleScratchpadWindow()

        let sawWriteStart = await Task.detached {
            waitForSemaphoreForTests(startedWrite, timeout: .now() + writeTimeout) == .success
        }.value
        #expect(sawWriteStart)

        let observedPendingReveal = await waitForConditionForTests(
            timeoutNanoseconds: 10_000_000_000
        ) {
            controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true
                && controller.axManager.hasPendingFrameWrite(for: token.windowId)
        }

        #expect(observedPendingReveal)
        #expect(recorder.events.isEmpty)
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.axManager.hasPendingFrameWrite(for: token.windowId))

        releaseWrite.signal()

        let observedFronting = await waitForConditionForTests(
            timeoutNanoseconds: 10_000_000_000
        ) {
            recorder.events.count == 3
        }

        #expect(observedFronting)
        #expect(
            recorder.events == [
                .activate(token.pid),
                .focus(token.pid, UInt32(token.windowId)),
                .raise
            ]
        )
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == expectedFrame)
    }

    @Test @MainActor func toggleScratchpadWindowFailedHiddenRevealKeepsScratchpadStateAndSkipsFocus() {
        let recorder = ScratchpadFocusRecorder()
        let controller = makeLayoutPlanTestController(
            windowFocusOperations: makeScratchpadFocusOperations(recorder: recorder)
        )
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for scratchpad failure focus test")
            return
        }

        let visibleToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 733)
        _ = controller.workspaceManager.setManagedFocus(visibleToken, in: workspaceId, onMonitor: monitor.id)

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 734),
            pid: 734,
            windowId: 734,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 240, y: 170, width: 600, height: 390),
                normalizedOrigin: CGPoint(x: 0.3, y: 0.22),
                referenceMonitorId: monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        controller.workspaceManager.setHiddenState(
            .init(
                proportionalPosition: CGPoint(x: 0.84, y: 0.74),
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )
        #expect(controller.workspaceManager.setScratchpadToken(token))

        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: scratchpadTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .suppressed
                    )
                )
            }
        }

        controller.toggleScratchpadWindow()

        #expect(controller.workspaceManager.scratchpadToken() == token)
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)
        #expect(controller.workspaceManager.focusedToken == visibleToken)
        #expect(controller.workspaceManager.pendingFocusedToken != token)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(recorder.events.isEmpty)
    }
}
