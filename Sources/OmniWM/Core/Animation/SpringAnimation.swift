import Foundation

struct SpringConfig {
    var stiffness: Double = 1000
    var dampingRatio: Double = 1.0
    var epsilon: Double = 0.0001

    var damping: Double {
        2 * dampingRatio * sqrt(stiffness)
    }

    static let snappy = SpringConfig(stiffness: 1000, dampingRatio: 1.0)
    static let smooth = SpringConfig(stiffness: 400, dampingRatio: 1.0)
    static let bouncy = SpringConfig(stiffness: 600, dampingRatio: 0.7)
}

final class SpringAnimation {
    private(set) var current: Double
    private(set) var target: Double
    private(set) var velocity: Double
    private var lastTime: TimeInterval
    let config: SpringConfig

    init(
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        startTime: TimeInterval,
        config: SpringConfig = .snappy
    ) {
        self.current = from
        self.target = to
        self.velocity = initialVelocity
        self.lastTime = startTime
        self.config = config
    }

    func value(at time: TimeInterval) -> Double {
        step(to: time)
        return current
    }

    func isComplete(at time: TimeInterval) -> Bool {
        step(to: time)
        let displacement = abs(current - target)
        let speed = abs(velocity)
        return displacement < config.epsilon && speed < config.epsilon
    }

    var targetValue: Double { target }

    private func step(to time: TimeInterval) {
        var elapsed = time - lastTime
        guard elapsed > 0 else { return }

        lastTime = time

        let maxStep = 1.0 / 120.0
        while elapsed > 0 {
            let dt = min(elapsed, maxStep)
            integrate(dt: dt)
            elapsed -= dt
        }
    }

    private func integrate(dt: Double) {
        let displacement = current - target
        let springForce = -config.stiffness * displacement
        let dampingForce = -config.damping * velocity
        let acceleration = springForce + dampingForce

        velocity += acceleration * dt
        current += velocity * dt
    }

    func retarget(to newTarget: Double, at time: TimeInterval) {
        step(to: time)
        target = newTarget
    }
}
