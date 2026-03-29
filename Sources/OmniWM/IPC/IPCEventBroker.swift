import Foundation
import OmniWMIPC

final class IPCEventDemandTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [IPCSubscriptionChannel: Int] = [:]

    func increment(_ channel: IPCSubscriptionChannel) {
        lock.lock()
        counts[channel, default: 0] += 1
        lock.unlock()
    }

    func decrement(_ channel: IPCSubscriptionChannel) {
        lock.lock()
        let nextValue = max(0, (counts[channel] ?? 0) - 1)
        if nextValue == 0 {
            counts.removeValue(forKey: channel)
        } else {
            counts[channel] = nextValue
        }
        lock.unlock()
    }

    func hasSubscribers(for channel: IPCSubscriptionChannel) -> Bool {
        lock.lock()
        let result = (counts[channel] ?? 0) > 0
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        counts.removeAll()
        lock.unlock()
    }
}

actor IPCEventBroker {
    private var continuations: [IPCSubscriptionChannel: [UUID: AsyncStream<IPCEventEnvelope>.Continuation]] = [:]
    private let demandTracker: IPCEventDemandTracker

    init(demandTracker: IPCEventDemandTracker = IPCEventDemandTracker()) {
        self.demandTracker = demandTracker
    }

    func stream(for channel: IPCSubscriptionChannel) -> AsyncStream<IPCEventEnvelope> {
        let id = UUID()
        var capturedContinuation: AsyncStream<IPCEventEnvelope>.Continuation?
        let stream = AsyncStream<IPCEventEnvelope>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(id: id, from: channel)
                }
            }
        }

        if let capturedContinuation {
            continuations[channel, default: [:]][id] = capturedContinuation
            demandTracker.increment(channel)
        }
        return stream
    }

    func publish(_ event: IPCEventEnvelope) {
        guard let currentContinuations = continuations[event.channel]?.values else { return }
        for continuation in currentContinuations {
            continuation.yield(event)
        }
    }

    func finishAll() {
        let currentContinuations = continuations.values.flatMap(\.values)
        continuations.removeAll()
        demandTracker.reset()
        for continuation in currentContinuations {
            continuation.finish()
        }
    }

    nonisolated func hasSubscribers(for channel: IPCSubscriptionChannel) -> Bool {
        demandTracker.hasSubscribers(for: channel)
    }

    private func removeContinuation(id: UUID, from channel: IPCSubscriptionChannel) {
        continuations[channel]?.removeValue(forKey: id)
        demandTracker.decrement(channel)
        if continuations[channel]?.isEmpty == true {
            continuations.removeValue(forKey: channel)
        }
    }
}
