// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

struct MotionSnapshot: Equatable, Sendable {
    let animationsEnabled: Bool

    static let enabled = MotionSnapshot(animationsEnabled: true)
    static let disabled = MotionSnapshot(animationsEnabled: false)
}

@MainActor @Observable
final class MotionPolicy {
    var userAnimationsEnabled: Bool
    var systemReducesMotion = false

    var animationsEnabled: Bool {
        get { userAnimationsEnabled && !systemReducesMotion }
        set { userAnimationsEnabled = newValue }
    }

    init(animationsEnabled: Bool = true) {
        userAnimationsEnabled = animationsEnabled
    }

    func snapshot() -> MotionSnapshot {
        MotionSnapshot(animationsEnabled: animationsEnabled)
    }
}
