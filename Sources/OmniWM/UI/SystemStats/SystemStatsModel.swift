// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

@MainActor @Observable
final class SystemStatsModel {
    var snapshot: SystemStatsSnapshot?
}
