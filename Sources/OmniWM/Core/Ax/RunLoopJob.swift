// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Synchronization

final class RunLoopJob: Sendable {
    private struct State {
        var cancelled = false
        var scheduledBody: (@Sendable (RunLoopJob) -> Void)?
    }

    private let state = Mutex(State())

    var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            $0.scheduledBody = nil
        }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    func schedule(_ body: @escaping @Sendable (RunLoopJob) -> Void) {
        state.withLock { $0.scheduledBody = body }
    }

    func takeScheduledBody() -> (@Sendable (RunLoopJob) -> Void)? {
        state.withLock {
            let body = $0.scheduledBody
            $0.scheduledBody = nil
            return body
        }
    }
}
