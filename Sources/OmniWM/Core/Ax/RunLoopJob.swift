// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Synchronization

final class RunLoopJob: Sendable {
    private let _cancelled = Atomic<Bool>(false)
    nonisolated(unsafe) weak var action: RunLoopAction?

    var isCancelled: Bool { _cancelled.load(ordering: .acquiring) }

    func cancel() {
        let (exchanged, _) = _cancelled.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        if exchanged {
            action?.clearAction()
            action = nil
        }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}
