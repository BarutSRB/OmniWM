import Foundation

final class RunLoopJob: Sendable {
    nonisolated(unsafe) private var _isCancelled: Int32 = 0

    var isCancelled: Bool { _isCancelled == 1 }

    func cancel() {
        while !isCancelled {
            OSAtomicCompareAndSwapInt(0, 1, &_isCancelled)
        }
    }

    static let cancelled: RunLoopJob = {
        let job = RunLoopJob()
        job.cancel()
        return job
    }()

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}
