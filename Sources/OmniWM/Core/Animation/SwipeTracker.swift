// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct SwipeEvent {
    let delta: Double
    let timestamp: TimeInterval
}

final class SwipeTracker {
    private static let historyLimit: TimeInterval = 0.080

    private var history: [SwipeEvent] = []
    private(set) var position: Double = 0

    func reset() {
        history.removeAll(keepingCapacity: true)
        position = 0
    }

    func push(delta: Double, timestamp: TimeInterval) {
        if let last = history.last, timestamp < last.timestamp {
            return
        }

        position += delta
        history.append(SwipeEvent(delta: delta, timestamp: timestamp))
        trimHistory(currentTime: timestamp)
    }

    func velocity() -> Double {
        guard let first = history.first, let last = history.last else { return 0 }

        let totalTime = last.timestamp - first.timestamp

        guard totalTime != 0 else { return 0 }

        let totalDelta = history.reduce(0.0) { $0 + $1.delta }
        return totalDelta / totalTime
    }

    private func trimHistory(currentTime: TimeInterval) {
        let cutoff = currentTime - Self.historyLimit
        history.removeAll { $0.timestamp <= cutoff }
    }
}
