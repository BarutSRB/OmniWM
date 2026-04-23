// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

private enum TestAwaitError: Error {
    case timedOut
}

private final class GatedRunLoopThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let completionSignal = DispatchSemaphore(value: 0)

    override func main() {
        let keepAlivePort = Port()
        RunLoop.current.add(keepAlivePort, forMode: .default)
        ready.signal()
        gate.wait()

        while !isCancelled {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }

        completionSignal.signal()
    }

    func startAndWait() {
        start()
        _ = ready.wait(timeout: .now() + 1)
    }

    func stopAndWait() {
        cancel()
        gate.signal()
        _ = completionSignal.wait(timeout: .now() + 2)
    }
}

private func awaitTaskValue<T: Sendable>(
    _ task: Task<T, Error>,
    timeout: Duration = .seconds(1)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestAwaitError.timedOut
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func makeRunInLoopTask(
    thread: GatedRunLoopThread,
    timeout: Duration
) -> Task<Int, Error> {
    Task { @Sendable [thread] in
        try await thread.runInLoop(timeout: timeout) { _ in
            1
        }
    }
}

@Suite struct ThreadRunLoopTests {
    @Test func pendingCancellationResumesContinuationInstalledLater() async {
        let state = RunLoopResumeState<Int>()
        let cancellationError = CancellationError()

        let stored = state.takeContinuation(orStore: .failure(cancellationError))
        #expect(stored == nil)

        do {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, any Error>) in
                if let pendingResult = state.install(cont) {
                    cont.resume(with: pendingResult)
                } else {
                    Issue.record("Expected pending cancellation to resume immediately after install")
                    cont.resume(returning: -1)
                }
            }
            Issue.record("Expected pending cancellation to throw")
        } catch is CancellationError {

        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func immediateCancellationResumesWhenTargetRunLoopNeverDrains() async {
        let thread = GatedRunLoopThread()
        thread.startAndWait()
        defer { thread.stopAndWait() }

        let task = makeRunInLoopTask(thread: thread, timeout: .seconds(5))

        task.cancel()

        do {
            _ = try await awaitTaskValue(task)
            Issue.record("Expected runInLoop cancellation to throw")
        } catch is CancellationError {

        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func timeoutResumesWhenTargetRunLoopNeverDrains() async {
        let thread = GatedRunLoopThread()
        thread.startAndWait()
        defer { thread.stopAndWait() }

        let task = makeRunInLoopTask(thread: thread, timeout: .milliseconds(50))

        do {
            _ = try await awaitTaskValue(task)
            Issue.record("Expected runInLoop timeout to throw")
        } catch is RunLoopTimeoutError {

        } catch {
            Issue.record("Expected RunLoopTimeoutError, got \(error)")
        }
    }
}
