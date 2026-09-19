// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import QuartzCore

struct OverviewNativeTransition {
    static let response = 0.25
    private static let rubberBandCoefficient = 0.55
    private static let rubberBandDimension = 0.30
    private static let flickVelocity = 0.5
    private static let inertia = 0.15
    private static let responseCompression = 0.25

    let generation: UInt64
    let startTime: CFTimeInterval
    let from: Double
    let target: Double
    let initialVelocity: Double
    let response: Double
    let duration: CFTimeInterval
    private let frequency: Double

    var chromeExitResponse: Double? {
        target == 0 ? response / 2 : nil
    }

    private var normalizedVelocity: Double {
        target == from ? 0 : initialVelocity / (target - from)
    }

    init(
        generation: UInt64,
        startTime: CFTimeInterval,
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        response: Double = Self.response
    ) {
        self.generation = generation
        self.startTime = startTime
        self.from = from
        target = to
        self.initialVelocity = initialVelocity
        self.response = response
        frequency = 2 * .pi / response
        let normalizedVelocity = to == from ? 0 : initialVelocity / (to - from)
        duration = to == from
            ? 0
            : Self.makeSpring(initialVelocity: normalizedVelocity, frequency: frequency).settlingDuration
    }

    func value(at time: CFTimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else { return target }
        let displacement = from - target
        let coefficient = frequency * displacement + initialVelocity
        return target + exp(-frequency * elapsed) * (displacement + coefficient * elapsed)
    }

    func velocity(at time: CFTimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else { return 0 }
        let displacement = from - target
        let coefficient = frequency * displacement + initialVelocity
        return exp(-frequency * elapsed) * (
            initialVelocity - frequency * coefficient * elapsed
        )
    }

    func makeAnimation(keyPath: String, response: Double? = nil) -> CASpringAnimation {
        let animation = Self.makeSpring(
            initialVelocity: normalizedVelocity,
            frequency: response.map { 2 * .pi / $0 } ?? frequency
        )
        animation.keyPath = keyPath
        animation.beginTime = startTime
        animation.duration = response == nil ? duration : animation.settlingDuration
        return animation
    }

    static func rubberBand(_ raw: Double) -> Double {
        if raw < 0 { return -resist(-raw) }
        if raw > 1 { return 1 + resist(raw - 1) }
        return raw
    }

    static func rubberBandInverse(_ progress: Double) -> Double {
        if progress < 0 { return -unresist(-progress) }
        if progress > 1 { return 1 + unresist(progress - 1) }
        return progress
    }

    static func releaseTarget(progress: Double, velocity: Double) -> Double {
        if progress > 1 { return 1 }
        if progress < 0 { return 0 }
        if velocity >= flickVelocity { return 1 }
        if velocity <= -flickVelocity { return 0 }
        return progress + velocity * inertia >= 0.5 ? 1 : 0
    }

    static func compressedResponse(forReleaseVelocity velocity: Double) -> Double {
        response * (1 - responseCompression * tanh(abs(velocity) / flickVelocity))
    }

    private static func resist(_ excess: Double) -> Double {
        excess * rubberBandDimension * rubberBandCoefficient
            / (rubberBandDimension + rubberBandCoefficient * excess)
    }

    private static func unresist(_ stretch: Double) -> Double {
        let bounded = min(stretch, rubberBandDimension - 1e-9)
        return bounded * rubberBandDimension / (rubberBandCoefficient * (rubberBandDimension - bounded))
    }

    private static func makeSpring(initialVelocity: Double, frequency: Double) -> CASpringAnimation {
        let animation = CASpringAnimation()
        animation.mass = 1
        animation.stiffness = frequency * frequency
        animation.damping = 2 * frequency
        animation.initialVelocity = initialVelocity
        return animation
    }
}
