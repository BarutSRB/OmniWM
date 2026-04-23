// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import SwiftUI

struct SpringConfig {
    let response: Double?
    let dampingFraction: Double?
    let blendDuration: Double
    let duration: Double
    let bounce: Double
    let epsilon: Double
    let velocityEpsilon: Double

    init(duration: Double = 0.2, bounce: Double = 0.0, epsilon: Double = 0.5, velocityEpsilon: Double = 10.0) {
        response = nil
        dampingFraction = nil
        blendDuration = 0.0
        self.duration = max(0.1, duration)
        self.bounce = min(max(bounce, -1.0), 1.0)
        self.epsilon = max(0, epsilon)
        self.velocityEpsilon = max(0, velocityEpsilon)
    }

    init(
        response: Double,
        dampingFraction: Double,
        blendDuration: Double = 0.0,
        epsilon: Double = 0.5,
        velocityEpsilon: Double = 10.0
    ) {
        self.response = max(0, response)
        self.dampingFraction = min(max(dampingFraction, 0), 1)
        self.blendDuration = max(0, blendDuration)
        duration = max(0.1, response)
        bounce = 0.0
        self.epsilon = max(0, epsilon)
        self.velocityEpsilon = max(0, velocityEpsilon)
    }

    static let snappy = SpringConfig(
        response: 0.22,
        dampingFraction: 0.95,
        blendDuration: 0.0,
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )
    static let dwindle = SpringConfig(
        response: 0.26,
        dampingFraction: 1.0,
        blendDuration: 0.0,
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )
    static let reducedMotion = SpringConfig(
        response: 0.18,
        dampingFraction: 0.98,
        blendDuration: 0.0,
        epsilon: 0.4,
        velocityEpsilon: 6.0
    )

    static let `default` = SpringConfig.snappy

    func resolvedForReduceMotion(_ reduceMotion: Bool) -> SpringConfig {
        guard reduceMotion else { return self }
        return SpringConfig.reducedMotion
    }

    var appleSpring: Spring {
        if let response, let dampingFraction {
            return Spring(
                response: response,
                dampingRatio: dampingFraction
            )
        }
        return Spring(duration: duration, bounce: bounce)
    }
}

final class SpringAnimation {
    private(set) var from: Double
    private(set) var target: Double
    private let initialVelocity: Double
    private let startTime: TimeInterval
    let config: SpringConfig
    private let displayRefreshRate: Double

    private let spring: Spring
    private var displacement: Double

    init(
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        startTime: TimeInterval,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0
    ) {
        self.from = from
        target = to
        self.startTime = startTime
        self.displayRefreshRate = displayRefreshRate
        self.initialVelocity = initialVelocity

        let resolvedConfig = config.resolvedForReduceMotion(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        self.config = resolvedConfig

        spring = resolvedConfig.appleSpring
        displacement = to - from
    }

    func value(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)

        let springValue = spring.value(
            target: displacement,
            initialVelocity: initialVelocity,
            time: elapsed
        )

        return from + springValue
    }

    func isComplete(at time: TimeInterval) -> Bool {
        let position = value(at: time)
        let currentVelocity = velocity(at: time)

        let refreshScale = 60.0 / displayRefreshRate
        let scaledEpsilon = config.epsilon * refreshScale
        let scaledVelocityEpsilon = config.velocityEpsilon * refreshScale

        let positionSettled = abs(position - target) < scaledEpsilon
        let velocitySettled = abs(currentVelocity) < scaledVelocityEpsilon

        return positionSettled && velocitySettled
    }

    func velocity(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)

        return spring.velocity(
            target: displacement,
            initialVelocity: initialVelocity,
            time: elapsed
        )
    }

    func offsetBy(_ delta: Double) {
        from += delta
        target += delta
    }
}
