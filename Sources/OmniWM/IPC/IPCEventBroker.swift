// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OmniWMIPC

struct IPCEventStreamRegistration: Sendable {
    let channel: IPCSubscriptionChannel
    let id: UUID
    let stream: AsyncStream<IPCEventEnvelope>
}

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

    func registerStream(for channel: IPCSubscriptionChannel) -> IPCEventStreamRegistration {
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
        return IPCEventStreamRegistration(channel: channel, id: id, stream: stream)
    }

    func stream(for channel: IPCSubscriptionChannel) -> AsyncStream<IPCEventEnvelope> {
        registerStream(for: channel).stream
    }

    func publish(_ event: IPCEventEnvelope) {
        guard let currentContinuations = continuations[event.channel]?.values else { return }
        for continuation in currentContinuations {
            continuation.yield(event)
        }
    }

    func removeStream(id: UUID, from channel: IPCSubscriptionChannel) {
        removeContinuation(id: id, from: channel)
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
        guard continuations[channel]?.removeValue(forKey: id) != nil else { return }
        demandTracker.decrement(channel)
        if continuations[channel]?.isEmpty == true {
            continuations.removeValue(forKey: channel)
        }
    }
}
