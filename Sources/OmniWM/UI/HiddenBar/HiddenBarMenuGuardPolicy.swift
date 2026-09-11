// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

enum HiddenBarMenuGuardPolicy {
    private nonisolated static let menuGuardRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2)
    ]
    private nonisolated static let maximumConsecutiveUnknownMenuStates = 3
    private nonisolated static let menuGuardWatchdogDuration: Duration = .seconds(60)

    nonisolated static func rehideRemaining(
        remaining: Duration,
        elapsed: Duration,
        previousMenuOpen: Bool?,
        menuOpen: Bool?
    ) -> Duration {
        guard previousMenuOpen == false, menuOpen == false else { return remaining }
        return max(.zero, remaining - max(.zero, elapsed))
    }

    nonisolated static func menuGuardRetryDelay(consecutiveDeferrals: Int) -> Duration {
        menuGuardRetryDelays[min(max(0, consecutiveDeferrals), menuGuardRetryDelays.count - 1)]
    }

    nonisolated static func shouldTerminateMenuGuardForUnknownState(consecutiveUnknownStates: Int) -> Bool {
        consecutiveUnknownStates >= maximumConsecutiveUnknownMenuStates
    }

    nonisolated static func menuGuardWatchdogExpired(elapsed: Duration) -> Bool {
        elapsed >= menuGuardWatchdogDuration
    }
}
