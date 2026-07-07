// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

final class DecelerationAnimation {
    static let decelerationRate = 0.997
    static let decayRate = 1000.0 * log(decelerationRate)

    private(set) var from: Double
    private let initialVelocity: Double
    private let startTime: TimeInterval
    private let velocityEpsilon: Double

    private var restingValue: Double = 0
    private var decelerationEnd: TimeInterval = 0

    init(
        from: Double,
        velocity: Double,
        startTime: TimeInterval,
        velocityEpsilon: Double = 1.0
    ) {
        self.from = from
        initialVelocity = velocity
        self.startTime = startTime
        self.velocityEpsilon = velocityEpsilon
        recompute()
    }

    var restingOffset: Double {
        restingValue
    }

    func value(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        if elapsed >= decelerationEnd { return restingValue }
        return from + initialVelocity * (exp(Self.decayRate * elapsed) - 1) / Self.decayRate
    }

    func velocity(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        if elapsed >= decelerationEnd { return 0 }
        return initialVelocity * exp(Self.decayRate * elapsed)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        time - startTime >= decelerationEnd
    }

    func offsetBy(_ delta: Double) {
        from += delta
        recompute()
    }

    private func recompute() {
        restingValue = from - initialVelocity / Self.decayRate
        decelerationEnd = abs(initialVelocity) <= velocityEpsilon
            ? 0
            : log(velocityEpsilon / abs(initialVelocity)) / Self.decayRate
    }
}
