import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private func axManagerTestWriteResult(
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

@Suite(.serialized) struct AXManagerTests {
    @Test func observedTargetFrameConfirmsApplyResultDespiteAttributeWriteFailure() {
        let targetFrame = CGRect(x: 120, y: 90, width: 640, height: 420)
        let result = AXFrameApplyResult(
            pid: 910,
            windowId: 910,
            targetFrame: targetFrame,
            currentFrameHint: nil,
            writeResult: axManagerTestWriteResult(
                targetFrame: targetFrame,
                currentFrameHint: nil,
                observedFrame: targetFrame,
                failureReason: .sizeWriteFailed(.attributeUnsupported)
            )
        )

        #expect(result.confirmedFrame == targetFrame)
    }

    @Test @MainActor func failedWriteRetriesOnceAndPromotesConfirmedFrameAfterSuccess() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager retry test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 910)
        let targetFrame = CGRect(x: 140, y: 88, width: 960, height: 620)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let writeResult = if attemptCount == 1 {
                    axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: .cacheMiss
                    )
                } else {
                    axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                }

                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: writeResult
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }

        #expect(attemptCount == 2)
        #expect(observedTerminalResult)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.confirmedFrame == targetFrame)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
    }

    @Test @MainActor func terminalObserverFiresOnceAfterRetriesExhaustOnFailure() async {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager terminal failure test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 911)
        let targetFrame = CGRect(x: 200, y: 120, width: 840, height: 540)

        var attemptCount = 0
        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                let failureReason: AXFrameWriteFailureReason = if attemptCount == 1 {
                    .cacheMiss
                } else {
                    .verificationMismatch
                }
                return AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.currentFrameHint,
                        failureReason: failureReason
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        let observedTerminalResult = await waitForConditionForTests {
            observerResults.count == 1
        }

        #expect(observedTerminalResult)
        #expect(attemptCount == 2)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.writeResult.failureReason == .verificationMismatch)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == nil)
        #expect(controller.axManager.recentFrameWriteFailure(for: token.windowId) == .verificationMismatch)
    }

    @Test @MainActor func terminalObserverCompletesImmediatelyWhenTargetFrameAlreadyCached() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager cached-frame observer test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 912)
        let targetFrame = CGRect(x: 160, y: 96, width: 900, height: 580)

        var attemptCount = 0
        controller.axManager.frameApplyOverrideForTests = { requests in
            attemptCount += 1
            return requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: axManagerTestWriteResult(
                        targetFrame: request.frame,
                        currentFrameHint: request.currentFrameHint,
                        observedFrame: request.frame,
                        failureReason: nil
                    )
                )
            }
        }

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        var observerResults: [AXFrameApplyResult] = []
        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        #expect(attemptCount == 1)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.confirmedFrame == targetFrame)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
    }

    @Test @MainActor func laterTrackedWriteDoesNotConsumeSupersededObserver() async throws {
        try await withAXFrameProviderIsolationForTests {
            let controller = makeLayoutPlanTestController()
            guard let monitor = controller.workspaceManager.monitors.first,
                  let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            else {
                Issue.record("Missing monitor or active workspace for AXManager observer scoping test")
                return
            }

            let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 913)
            guard let entry = controller.workspaceManager.entry(for: token),
                  let context = await AppAXContext.makeForTests(processIdentifier: token.pid)
            else {
                Issue.record("Failed to create AX test context for AXManager observer scoping test")
                return
            }

            controller.axManager.frameApplyOverrideForTests = nil
            AppAXContext.contexts[token.pid] = context
            try await context.installWindowsForTests([entry.axRef])

            let firstFrame = CGRect(x: 180, y: 100, width: 880, height: 560)
            let secondFrame = CGRect(x: 260, y: 140, width: 760, height: 500)
            let startedFirstWrite = DispatchSemaphore(value: 0)
            let releaseFirstWrite = DispatchSemaphore(value: 0)
            let startedSecondWrite = DispatchSemaphore(value: 0)
            let releaseSecondWrite = DispatchSemaphore(value: 0)

            AXWindowService.setFrameResultProviderForTests = { _, frame, currentFrameHint in
                if frame == firstFrame {
                    startedFirstWrite.signal()
                    _ = releaseFirstWrite.wait(timeout: .now() + 1)
                } else if frame == secondFrame {
                    startedSecondWrite.signal()
                    _ = releaseSecondWrite.wait(timeout: .now() + 1)
                }

                return axManagerTestWriteResult(
                    targetFrame: frame,
                    currentFrameHint: currentFrameHint,
                    observedFrame: frame,
                    failureReason: nil
                )
            }
            defer {
                AXWindowService.setFrameResultProviderForTests = nil
                AppAXContext.contexts.removeValue(forKey: token.pid)
                context.destroy()
            }

            var firstObserverResults: [AXFrameApplyResult] = []
            var secondObserverResults: [AXFrameApplyResult] = []

            controller.axManager.applyFramesParallel(
                [(token.pid, token.windowId, firstFrame)],
                terminalObserver: { firstObserverResults.append($0) }
            )

            let sawFirstStart = await Task.detached {
                waitForSemaphoreForTests(startedFirstWrite, timeout: .now() + 1) == .success
            }.value
            #expect(sawFirstStart)

            controller.axManager.applyFramesParallel(
                [(token.pid, token.windowId, secondFrame)],
                terminalObserver: { secondObserverResults.append($0) }
            )

            releaseFirstWrite.signal()

            let sawSecondStart = await Task.detached {
                waitForSemaphoreForTests(startedSecondWrite, timeout: .now() + 1) == .success
            }.value
            #expect(sawSecondStart)

            releaseSecondWrite.signal()

            let observedSecondTerminalResult = await waitForConditionForTests {
                secondObserverResults.count == 1
            }

            #expect(observedSecondTerminalResult)
            #expect(firstObserverResults.isEmpty)
            #expect(secondObserverResults.count == 1)
            #expect(secondObserverResults.first?.targetFrame == secondFrame)
            #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == secondFrame)
        }
    }
}
