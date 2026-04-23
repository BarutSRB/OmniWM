// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

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
    @Test func invalidTargetFrameIsRejectedLocally() {
        let window = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 999)
        let invalidFrame = CGRect(x: 100, y: 100, width: 0, height: 480)

        let result = AXWindowService.setFrame(window, frame: invalidFrame)

        #expect(result.failureReason == AXFrameWriteFailureReason.invalidTargetFrame)
        #expect(result.observedFrame == nil)
        #expect(result.targetFrame == invalidFrame)
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
        let originalOnFrameConfirmed = controller.axManager.onFrameConfirmed
        var confirmedFrames: [CGRect] = []
        var confirmResults: [FrameConfirmResult] = []
        controller.axManager.onFrameConfirmed = { pid, windowId, frame, result in
            confirmedFrames.append(frame)
            confirmResults.append(result)
            originalOnFrameConfirmed?(pid, windowId, frame, result)
        }

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
        confirmedFrames.removeAll()
        confirmResults.removeAll()
        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, targetFrame)],
            terminalObserver: { observerResults.append($0) }
        )

        #expect(attemptCount == 1)
        #expect(observerResults.count == 1)
        #expect(observerResults.first?.confirmedFrame == targetFrame)
        #expect(confirmedFrames == [targetFrame])
        #expect(confirmResults == [.cachedNoOp])
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
    }

    @Test @MainActor func verifiedNoOpFramePersistsOnceThroughOnFrameConfirmed() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager no-op persistence test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 914)
        let staleFrame = CGRect(x: 104, y: 72, width: 640, height: 420)
        let targetFrame = CGRect(x: 180, y: 90, width: 800, height: 520)

        controller.axManager.confirmFrameWrite(for: token.windowId, frame: targetFrame)
        _ = controller.workspaceManager.setManagedRestoreSnapshot(
            ManagedWindowRestoreSnapshot(
                token: token,
                workspaceId: workspaceId,
                frame: staleFrame,
                topologyProfile: controller.workspaceManager.topologyProfile,
                niriState: nil,
                replacementMetadata: nil
            ),
            for: token
        )

        let originalOnFrameConfirmed = controller.axManager.onFrameConfirmed
        var confirmedFrames: [CGRect] = []
        var confirmResults: [FrameConfirmResult] = []
        controller.axManager.onFrameConfirmed = { pid, windowId, frame, result in
            confirmedFrames.append(frame)
            confirmResults.append(result)
            originalOnFrameConfirmed?(pid, windowId, frame, result)
        }

        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        #expect(confirmedFrames == [targetFrame])
        #expect(confirmResults == [.cachedNoOp])
        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == targetFrame)
    }

    @Test @MainActor func cachedNoOpFrameConfirmShortCircuitsManagedRestoreSnapshotBuild() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager cached no-op short-circuit test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 915)
        let targetFrame = CGRect(x: 220, y: 110, width: 860, height: 540)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.example.cached-noop",
                workspaceId: workspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Cached No-Op",
                windowLevel: 8,
                parentWindowId: nil,
                frame: targetFrame
            ),
            for: token
        )
        controller.recordManagedRestoreGeometry(for: token, frame: targetFrame)
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: targetFrame)


        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])

        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == targetFrame)
    }

    @Test @MainActor func confirmedWriteFrameConfirmShortCircuitsManagedRestoreSnapshotBuild() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager confirmed-write short-circuit test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 916)
        let targetFrame = CGRect(x: 240, y: 128, width: 840, height: 520)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.example.confirmed-write",
                workspaceId: workspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Confirmed Write",
                windowLevel: 9,
                parentWindowId: nil,
                frame: targetFrame
            ),
            for: token
        )
        controller.recordManagedRestoreGeometry(for: token, frame: targetFrame)


        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
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

        #expect(controller.workspaceManager.managedRestoreSnapshot(for: token)?.frame == targetFrame)
    }

    @Test @MainActor func managedRestoreFastPathCacheClearsWhenWindowIsRemoved() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for fast-path cache removal test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 917)
        let targetFrame = CGRect(x: 260, y: 144, width: 820, height: 500)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.example.cache-remove",
                workspaceId: workspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Cache Remove",
                windowLevel: 10,
                parentWindowId: nil,
                frame: targetFrame
            ),
            for: token
        )
        controller.recordManagedRestoreGeometry(for: token, frame: targetFrame)

        #expect(controller.managedRestoreFastPathCacheWindowIdsForTests().contains(token.windowId))

        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)

        #expect(!controller.managedRestoreFastPathCacheWindowIdsForTests().contains(token.windowId))
    }

    @Test @MainActor func managedRestoreFastPathCacheInvalidatesOnWindowRekey() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for fast-path cache rekey test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 918)
        let targetFrame = CGRect(x: 280, y: 156, width: 800, height: 480)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.example.cache-rekey",
                workspaceId: workspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Cache Rekey",
                windowLevel: 11,
                parentWindowId: nil,
                frame: targetFrame
            ),
            for: token
        )
        controller.recordManagedRestoreGeometry(for: token, frame: targetFrame)

        #expect(controller.managedRestoreFastPathCacheWindowIdsForTests().contains(token.windowId))

        let rekeyedToken = WindowToken(pid: token.pid, windowId: 919)
        #expect(
            controller.workspaceManager.rekeyWindow(
                from: token,
                to: rekeyedToken,
                newAXRef: makeLayoutPlanTestWindow(windowId: rekeyedToken.windowId)
            ) != nil
        )

        let cacheWindowIdsAfterRekey = controller.managedRestoreFastPathCacheWindowIdsForTests()
        #expect(!cacheWindowIdsAfterRekey.contains(token.windowId))
        #expect(!cacheWindowIdsAfterRekey.contains(rekeyedToken.windowId))

        controller.recordManagedRestoreGeometry(for: rekeyedToken, frame: targetFrame)

        #expect(controller.managedRestoreFastPathCacheWindowIdsForTests().contains(rekeyedToken.windowId))
    }

    @Test @MainActor func testOverrideFlatteningOnlyRunsWhenOverrideIsInstalled() {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for AXManager override flattening test")
            return
        }

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 913)
        let targetFrame = CGRect(x: 180, y: 90, width: 800, height: 520)

        controller.axManager.frameApplyOverrideForTests = nil
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, targetFrame)])


        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
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

    }

    @Test @MainActor func laterTrackedWriteDoesNotConsumeSupersededObserver() async throws {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

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
        let writeTimeout: DispatchTimeInterval = .seconds(3)
        let startedFirstWrite = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let startedSecondWrite = DispatchSemaphore(value: 0)
        let releaseSecondWrite = DispatchSemaphore(value: 0)

        AXWindowService.setFrameResultProviderForTests = { _, frame, currentFrameHint in
            if frame == firstFrame {
                startedFirstWrite.signal()
                _ = releaseFirstWrite.wait(timeout: .now() + writeTimeout)
            } else if frame == secondFrame {
                startedSecondWrite.signal()
                _ = releaseSecondWrite.wait(timeout: .now() + writeTimeout)
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
            context.destroy()
        }

        var firstObserverResults: [AXFrameApplyResult] = []
        var secondObserverResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, firstFrame)],
            terminalObserver: { firstObserverResults.append($0) }
        )

        let sawFirstStart = await Task.detached {
            waitForSemaphoreForTests(startedFirstWrite, timeout: .now() + writeTimeout) == .success
        }.value
        #expect(sawFirstStart)

        controller.axManager.applyFramesParallel(
            [(token.pid, token.windowId, secondFrame)],
            terminalObserver: { secondObserverResults.append($0) }
        )

        releaseFirstWrite.signal()

        let sawSecondStart = await Task.detached {
            waitForSemaphoreForTests(startedSecondWrite, timeout: .now() + writeTimeout) == .success
        }.value
        #expect(sawSecondStart)

        releaseSecondWrite.signal()

        let observedSecondTerminalResult = await waitForConditionForTests(
            timeoutNanoseconds: 3_000_000_000
        ) {
            secondObserverResults.count == 1
                && controller.axManager.lastAppliedFrame(for: token.windowId) == secondFrame
        }

        #expect(observedSecondTerminalResult)
        #expect(firstObserverResults.isEmpty)
        #expect(secondObserverResults.count == 1)
        #expect(secondObserverResults.first?.targetFrame == secondFrame)
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == secondFrame)
    }
}
