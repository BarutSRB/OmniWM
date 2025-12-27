import Foundation

enum EasingCurve {
    case linear
    case easeOutCubic
    case easeOutExpo

    func apply(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        switch self {
        case .linear:
            return clamped
        case .easeOutCubic:
            let inv = 1 - clamped
            return 1 - inv * inv * inv
        case .easeOutExpo:
            return clamped >= 1 ? 1 : 1 - pow(2, -10 * clamped)
        }
    }
}

final class ViewAnimation {
    let from: Double
    let to: Double
    let duration: TimeInterval
    let curve: EasingCurve
    let startTime: TimeInterval
    private let initialVelocity: Double

    init(
        from: Double,
        to: Double,
        duration: TimeInterval = 0.3,
        curve: EasingCurve = .easeOutCubic,
        startTime: TimeInterval,
        initialVelocity: Double = 0
    ) {
        self.from = from
        self.to = to
        self.duration = duration
        self.curve = curve
        self.startTime = startTime
        self.initialVelocity = initialVelocity
    }

    func value(at time: TimeInterval) -> Double {
        let elapsed = time - startTime
        guard elapsed >= 0 else { return from }
        guard elapsed < duration else { return to }

        let t = elapsed / duration
        let eased = curve.apply(t)

        let baseValue = from + (to - from) * eased

        if abs(initialVelocity) > 0.001 {
            let velocityInfluence = initialVelocity * duration * (1 - t) * (1 - t) * 0.1
            return baseValue + velocityInfluence
        }

        return baseValue
    }

    func isComplete(at time: TimeInterval) -> Bool {
        time - startTime >= duration
    }

    var targetValue: Double { to }
}

final class DecelerationAnimation {
    private static let decelerationRate: Double = 0.997

    let from: Double
    let initialVelocity: Double
    let startTime: TimeInterval

    private let coeff: Double
    private let projectedEnd: Double

    init(from: Double, initialVelocity: Double, startTime: TimeInterval) {
        self.from = from
        self.initialVelocity = initialVelocity
        self.startTime = startTime
        self.coeff = 1000.0 * log(Self.decelerationRate)
        self.projectedEnd = from - initialVelocity / coeff
    }

    func value(at time: TimeInterval) -> Double {
        let elapsed = time - startTime
        guard elapsed >= 0 else { return from }

        let decayFactor = pow(Self.decelerationRate, 1000.0 * elapsed)
        return from + (decayFactor - 1) / coeff * initialVelocity
    }

    func velocityAt(_ time: TimeInterval) -> Double {
        let elapsed = time - startTime
        guard elapsed >= 0 else { return initialVelocity }

        return initialVelocity * pow(Self.decelerationRate, 1000.0 * elapsed)
    }

    func isComplete(at time: TimeInterval, threshold: Double = 0.001) -> Bool {
        abs(velocityAt(time)) < threshold && abs(value(at: time) - projectedEnd) < 0.01
    }

    var targetValue: Double { projectedEnd }
}
