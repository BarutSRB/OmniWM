// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct RunLoopTimeoutError: Error, Sendable {
    let timeout: Duration
}



final class RunLoopResumeState<T: Sendable>: @unchecked Sendable {
    private enum State {
        case empty
        case waiting(CheckedContinuation<T, any Error>)
        case pending(Result<T, any Error>)
        case resumed
    }

    private let lock = NSLock()
    private var state: State = .empty

    func install(_ continuation: CheckedContinuation<T, any Error>) -> Result<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .empty:
            state = .waiting(continuation)
            return nil
        case let .pending(result):
            state = .resumed
            return result
        case .waiting, .resumed:
            return nil
        }
    }

    func takeContinuation(orStore result: Result<T, any Error>) -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .empty:
            state = .pending(result)
            return nil
        case let .waiting(continuation):
            state = .resumed
            return continuation
        case .pending, .resumed:
            return nil
        }
    }
}

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob = RunLoopJob(),
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> Void
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body)
        job.action = action
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T: Sendable>(
        timeout: Duration = .seconds(2),
        _ body: @Sendable @escaping (RunLoopJob) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let job = RunLoopJob()
        let state = RunLoopResumeState<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let pendingResult = state.install(cont) {
                    cont.resume(with: pendingResult)
                    return
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }

                    job.cancel()
                    let timeoutError = RunLoopTimeoutError(timeout: timeout)
                    guard let continuation = state.takeContinuation(orStore: .failure(timeoutError)) else {
                        return
                    }
                    continuation.resume(throwing: timeoutError)
                }

                self.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
                    timeoutTask.cancel()

                    do {
                        try job.checkCancellation()
                        let value = try body(job)
                        guard let continuation = state.takeContinuation(orStore: .success(value)) else {
                            return
                        }
                        continuation.resume(returning: value)
                    } catch {
                        guard let continuation = state.takeContinuation(orStore: .failure(error)) else {
                            return
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            job.cancel()
            let cancellationError = CancellationError()
            guard let continuation = state.takeContinuation(orStore: .failure(cancellationError)) else {
                return
            }
            continuation.resume(throwing: cancellationError)
        }
    }
}

final class RunLoopAction: NSObject, Sendable {
    nonisolated(unsafe) private var _action: (@Sendable (RunLoopJob) -> Void)?
    let job: RunLoopJob
    private let autoCheckCancelled: Bool

    init(job: RunLoopJob, autoCheckCancelled: Bool, _ action: @escaping @Sendable (RunLoopJob) -> Void) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        _action = action
    }

    @objc func action() {
        guard let actionToRun = _action else { return }
        _action = nil
        job.action = nil
        if autoCheckCancelled, job.isCancelled { return }
        actionToRun(job)
    }

    func clearAction() {
        _action = nil
    }
}
