import Foundation

struct SpringConfig {
    var stiffness: Double
    var dampingRatio: Double
    var epsilon: Double

    init(stiffness: Double = 800, dampingRatio: Double = 1.0, epsilon: Double = 0.0001) {
        self.stiffness = max(0, stiffness)
        self.dampingRatio = max(0, dampingRatio)
        self.epsilon = max(0, epsilon)
    }

    static let snappy = SpringConfig(stiffness: 800, dampingRatio: 1.0)
    static let smooth = SpringConfig(stiffness: 400, dampingRatio: 1.0)
    static let bouncy = SpringConfig(stiffness: 600, dampingRatio: 0.7)
}

final class SpringAnimation {
    private let from: Double
    let target: Double
    private let initialVelocity: Double
    private let startTime: TimeInterval
    let config: SpringConfig

    private let beta: Double
    private let omega0: Double

    init(
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        startTime: TimeInterval,
        config: SpringConfig = .snappy
    ) {
        self.from = from
        self.target = to
        self.initialVelocity = initialVelocity
        self.startTime = startTime
        self.config = config

        let mass = 1.0
        let damping = 2.0 * config.dampingRatio * sqrt(config.stiffness * mass)
        self.beta = damping / (2.0 * mass)
        self.omega0 = sqrt(config.stiffness / mass)
    }

    func value(at time: TimeInterval) -> Double {
        let t = max(0, time - startTime)
        return oscillate(t: t)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        let t = max(0, time - startTime)
        let position = oscillate(t: t)
        return abs(position - target) < config.epsilon
    }

    func duration() -> TimeInterval {
        let delta = 0.001

        if abs(beta) <= .ulpOfOne || beta < 0 {
            return .infinity
        }

        if abs(target - from) <= .ulpOfOne {
            return 0
        }

        var x0 = -log(config.epsilon) / beta

        let epsilonForComparison = Double(Float.ulpOfOne)
        if abs(beta - omega0) <= epsilonForComparison || beta < omega0 {
            return x0
        }

        var y0 = oscillate(t: x0)
        var m = (oscillate(t: x0 + delta) - y0) / delta

        var x1 = (target - y0 + m * x0) / m
        var y1 = oscillate(t: x1)

        var i = 0
        while abs(target - y1) > config.epsilon {
            if i > 1000 {
                return 0
            }

            x0 = x1
            y0 = y1

            m = (oscillate(t: x0 + delta) - y0) / delta

            x1 = (target - y0 + m * x0) / m
            y1 = oscillate(t: x1)

            if !y1.isFinite {
                return x0
            }

            i += 1
        }

        return x1
    }

    func clampedDuration() -> TimeInterval? {
        if abs(beta) <= .ulpOfOne || beta < 0 {
            return .infinity
        }

        if abs(target - from) <= .ulpOfOne {
            return 0
        }

        var i: UInt16 = 1
        var y = oscillate(t: Double(i) / 1000.0)

        while (target - from > .ulpOfOne && target - y > config.epsilon) ||
              (from - target > .ulpOfOne && y - target > config.epsilon) {
            if i > 3000 {
                return nil
            }

            i += 1
            y = oscillate(t: Double(i) / 1000.0)
        }

        return Double(i) / 1000.0
    }

    private func oscillate(t: Double) -> Double {
        let x0 = from - target
        let v0 = initialVelocity

        let envelope = exp(-beta * t)

        let epsilonForComparison = Double(Float.ulpOfOne)

        if abs(beta - omega0) <= epsilonForComparison {
            return target + envelope * (x0 + (beta * x0 + v0) * t)
        } else if beta < omega0 {
            let omega1 = sqrt(omega0 * omega0 - beta * beta)
            return target + envelope * (
                x0 * cos(omega1 * t) +
                ((beta * x0 + v0) / omega1) * sin(omega1 * t)
            )
        } else {
            let omega2 = sqrt(beta * beta - omega0 * omega0)
            return target + envelope * (
                x0 * cosh(omega2 * t) +
                ((beta * x0 + v0) / omega2) * sinh(omega2 * t)
            )
        }
    }

}
