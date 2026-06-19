// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import QuartzCore

final class AnimationClock {
    private var currentTime: TimeInterval
    private var lastSeenTime: TimeInterval

    init(time: TimeInterval = CACurrentMediaTime()) {
        currentTime = time
        lastSeenTime = time
    }

    func now() -> TimeInterval {
        let time = CACurrentMediaTime()
        guard lastSeenTime != time else { return currentTime }

        let delta = time - lastSeenTime
        currentTime += delta
        lastSeenTime = time
        return currentTime
    }
}
