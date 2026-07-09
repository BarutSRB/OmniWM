// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct HiddenBarAppliedConfig: Equatable {
    let allowed: Set<String>
    let concealed: Set<String>
    let at: ContinuousClock.Instant
}

struct HiddenBarDesiredConfig: Equatable {
    let allowed: Set<String>
    let concealed: Set<String>
}

enum HiddenBarAntiFlap {
    static let defaultWindow: Duration = .seconds(3)

    static func shouldReactivate(
        desired: HiddenBarDesiredConfig,
        current: HiddenBarAppliedConfig?,
        previousConfig: HiddenBarAppliedConfig?,
        now: ContinuousClock.Instant
    ) -> Bool {
        let handleIsNil = current == nil
        let concealedChanged = desired.concealed != (current?.concealed ?? [])
        let newlyAppeared = !desired.allowed.subtracting(current?.allowed ?? []).isEmpty

        guard handleIsNil || concealedChanged || newlyAppeared else {
            return false
        }

        if !handleIsNil,
           let previousConfig,
           previousConfig.allowed == desired.allowed,
           previousConfig.concealed == desired.concealed,
           previousConfig.at.duration(to: now) < defaultWindow
        {
            return false
        }

        return true
    }
}
