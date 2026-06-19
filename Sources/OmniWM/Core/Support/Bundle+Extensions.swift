// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension Bundle {
    var appVersion: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var releaseVersion: ReleaseVersion? {
        appVersion.flatMap(ReleaseVersion.init)
    }
}
