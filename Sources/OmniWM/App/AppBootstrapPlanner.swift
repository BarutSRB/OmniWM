// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum AppBootstrapDecision: Equatable {
    case boot
}

enum AppBootstrapPlanner {
    static func decision() -> AppBootstrapDecision {
        .boot
    }
}
