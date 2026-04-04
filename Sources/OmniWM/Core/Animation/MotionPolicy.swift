import Observation

struct MotionSnapshot: Equatable, Sendable {
    let animationsEnabled: Bool

    static let enabled = MotionSnapshot(animationsEnabled: true)
    static let disabled = MotionSnapshot(animationsEnabled: false)
}

@MainActor @Observable
final class MotionPolicy {
    var animationsEnabled: Bool

    init(animationsEnabled: Bool = true) {
        self.animationsEnabled = animationsEnabled
    }

    func snapshot() -> MotionSnapshot {
        MotionSnapshot(animationsEnabled: animationsEnabled)
    }
}
