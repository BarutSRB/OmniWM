// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func append(_ value: Element) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private func awaitFrameBatchResults(
    from context: AppAXContext,
    frames: [(windowId: Int, frame: CGRect, currentFrameHint: CGRect?)]
) async -> [AXFrameApplyResult] {
    let requests = frames.enumerated().map { index, frame in
        AXFrameApplicationRequest(
            requestId: AXFrameRequestId(index + 1),
            pid: context.pid,
            windowId: frame.windowId,
            frame: frame.frame,
            currentFrameHint: frame.currentFrameHint
        )
    }
    return await withCheckedContinuation { continuation in
        context.setFramesBatch(requests) { results in
            continuation.resume(returning: results)
        }
    }
}

private func successfulWriteResult(frame: CGRect, currentFrameHint: CGRect?) -> AXFrameWriteResult {
    AXFrameWriteResult(
        targetFrame: frame,
        observedFrame: frame,
        writeOrder: AXWindowService.frameWriteOrder(currentFrame: currentFrameHint, targetFrame: frame),
        sizeError: .success,
        positionError: .success,
        failureReason: nil
    )
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}

@Suite(.serialized) struct AppAXContextTests {
    @Test @MainActor func getOrCreateSharesSingleInFlightCreationTaskPerPid() async throws {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        guard let targetApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }) else {
            Issue.record("Failed to locate a secondary running application for AppAXContext concurrency test")
            return
        }

        guard let expectedContext = await AppAXContext.makeForTests(processIdentifier: targetApp.processIdentifier) else {
            Issue.record("Failed to create AppAXContext test fixture")
            return
        }
        let app = expectedContext.nsApp

        let factoryCalls = LockedCounter()
        AppAXContext.contextFactoryForTests = { requestedApp in
            if requestedApp.processIdentifier == app.processIdentifier {
                _ = factoryCalls.increment()
                try await Task.sleep(for: .milliseconds(50))
                return expectedContext
            }

            return await AppAXContext.makeForTests(processIdentifier: requestedApp.processIdentifier)
        }

        defer {
            AppAXContext.contextFactoryForTests = nil
            expectedContext.destroy()
        }

        let contexts = try await withThrowingTaskGroup(of: AppAXContext?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await AppAXContext.getOrCreate(app)
                }
            }

            var contexts: [AppAXContext] = []
            for try await context in group {
                if let context {
                    contexts.append(context)
                }
            }
            return contexts
        }

        let distinctContextCount = Set(contexts.map(ObjectIdentifier.init)).count

        #expect(factoryCalls.snapshot() <= 1)
        #expect(contexts.count == 8)
        #expect(distinctContextCount == 1)
        if factoryCalls.snapshot() == 1 {
            #expect(contexts.allSatisfy { $0 === expectedContext })
        }
    }

    @Test @MainActor func cancelingOneWindowDoesNotAbortSiblingWriteInSameBatch() async throws {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        guard let context = await AppAXContext.makeForTests() else {
            Issue.record("Failed to create AppAXContext test fixture")
            return
        }
        defer {
            AXWindowService.setFrameResultProviderForTests = nil
            context.destroy()
        }

        let firstWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9201)
        let secondWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9202)
        try await context.installWindowsForTests([firstWindow, secondWindow])

        let writeTimeout: DispatchTimeInterval = .seconds(5)
        let startedFirstWrite = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let writtenWindowIds = LockedArray<Int>()

        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            if axRef.windowId == firstWindow.windowId {
                startedFirstWrite.signal()
                _ = releaseFirstWrite.wait(timeout: .now() + writeTimeout)
            }
            writtenWindowIds.append(axRef.windowId)
            return successfulWriteResult(frame: frame, currentFrameHint: currentFrameHint)
        }

        let resultsTask = Task { @MainActor in
            await awaitFrameBatchResults(
                from: context,
                frames: [
                    (windowId: firstWindow.windowId, frame: CGRect(x: 40, y: 40, width: 500, height: 320), currentFrameHint: nil),
                    (windowId: secondWindow.windowId, frame: CGRect(x: 560, y: 40, width: 500, height: 320), currentFrameHint: nil)
                ]
            )
        }

        let startWait = Task.detached {
            waitForSemaphore(startedFirstWrite, timeout: .now() + writeTimeout)
        }
        guard await startWait.value == .success else {
            Issue.record("Timed out waiting for the first AX write to begin")
            releaseFirstWrite.signal()
            _ = await resultsTask.value
            return
        }

        context.cancelFrameJob(for: firstWindow.windowId)
        releaseFirstWrite.signal()

        let results = await resultsTask.value
        let secondResult = results.first { $0.windowId == secondWindow.windowId }

        #expect(writtenWindowIds.snapshot().contains(secondWindow.windowId))
        #expect(secondResult?.writeResult.isVerifiedSuccess == true)
    }

    @Test @MainActor func cacheMissRefreshesAXWindowRefInsteadOfSkippingWrite() async {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        guard let context = await AppAXContext.makeForTests() else {
            Issue.record("Failed to create AppAXContext test fixture")
            return
        }
        defer {
            AXWindowService.axWindowRefProviderForTests = nil
            AXWindowService.setFrameResultProviderForTests = nil
            context.destroy()
        }

        let writtenWindowIds = LockedArray<Int>()
        let lookupWindowIds = LockedArray<UInt32>()
        let refreshedWindow = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 9301)

        AXWindowService.axWindowRefProviderForTests = { windowId, _ in
            lookupWindowIds.append(windowId)
            return windowId == UInt32(refreshedWindow.windowId) ? refreshedWindow : nil
        }
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            writtenWindowIds.append(axRef.windowId)
            return successfulWriteResult(frame: frame, currentFrameHint: currentFrameHint)
        }

        let results = await awaitFrameBatchResults(
            from: context,
            frames: [
                (windowId: refreshedWindow.windowId, frame: CGRect(x: 88, y: 96, width: 720, height: 480), currentFrameHint: nil)
            ]
        )

        #expect(lookupWindowIds.snapshot() == [UInt32(refreshedWindow.windowId)])
        #expect(writtenWindowIds.snapshot() == [refreshedWindow.windowId])
        #expect(results.first?.writeResult.isVerifiedSuccess == true)
    }
}
