import Foundation

struct SwipeEvent {
    let delta: Double
    let timestamp: TimeInterval
}

final class SwipeTracker {
    private static let historyLimit: TimeInterval = 0.150
    private static let decelerationRate: Double = 0.997

    private var history: [SwipeEvent] = []
    private(set) var position: Double = 0

    func push(delta: Double, timestamp: TimeInterval) {
        position += delta
        history.append(SwipeEvent(delta: delta, timestamp: timestamp))
        trimHistory(currentTime: timestamp)
    }

    func velocity() -> Double {
        guard history.count >= 2 else { return 0 }

        let firstTime = history.first!.timestamp
        let lastTime = history.last!.timestamp
        let totalTime = lastTime - firstTime

        guard totalTime > 0.001 else { return 0 }

        let totalDelta = history.reduce(0.0) { $0 + $1.delta }
        return totalDelta / totalTime
    }

    func projectedEndPosition() -> Double {
        let v = velocity()
        guard abs(v) > 0.001 else { return position }

        let coeff = 1000.0 * log(Self.decelerationRate)
        return position - v / coeff
    }

    func reset() {
        history.removeAll()
        position = 0
    }

    private func trimHistory(currentTime: TimeInterval) {
        let cutoff = currentTime - Self.historyLimit
        history.removeAll { $0.timestamp < cutoff }
    }
}
