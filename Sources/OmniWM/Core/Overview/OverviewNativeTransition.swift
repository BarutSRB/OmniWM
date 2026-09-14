// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import QuartzCore

struct OverviewNativeTransition {
    let generation: UInt64
    let startTime: CFTimeInterval
    let from: Double
    let target: Double
    let initialVelocity: Double
    let duration: CFTimeInterval

    private static let stiffness = 800.0
    private static let frequency = sqrt(stiffness)

    private var normalizedVelocity: Double {
        target == from ? 0 : initialVelocity / (target - from)
    }

    init(
        generation: UInt64,
        startTime: CFTimeInterval,
        from: Double,
        to: Double,
        initialVelocity: Double = 0
    ) {
        self.generation = generation
        self.startTime = startTime
        self.from = from
        target = to
        self.initialVelocity = initialVelocity
        let spring = Self.makeSpring(initialVelocity: to == from ? 0 : initialVelocity / (to - from))
        duration = to == from ? 0 : spring.settlingDuration
    }

    func value(at time: CFTimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else { return target }
        let displacement = from - target
        let coefficient = Self.frequency * displacement + initialVelocity
        return target + exp(-Self.frequency * elapsed) * (displacement + coefficient * elapsed)
    }

    func velocity(at time: CFTimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else { return 0 }
        let displacement = from - target
        let coefficient = Self.frequency * displacement + initialVelocity
        return exp(-Self.frequency * elapsed) * (
            initialVelocity - Self.frequency * coefficient * elapsed
        )
    }

    func makeAnimation(keyPath: String) -> CASpringAnimation {
        let animation = Self.makeSpring(initialVelocity: normalizedVelocity)
        animation.keyPath = keyPath
        animation.beginTime = startTime
        animation.duration = duration
        return animation
    }

    private static func makeSpring(initialVelocity: Double) -> CASpringAnimation {
        let animation = CASpringAnimation()
        animation.mass = 1
        animation.stiffness = stiffness
        animation.damping = 2 * frequency
        animation.initialVelocity = initialVelocity
        return animation
    }
}
