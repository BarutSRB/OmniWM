// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum HiddenBarAllowlistResolver {
    static let allowedSystemItemIdentifiers: [Int] = Array(0 ... 8)

    static let systemHostBundleIDs = HiddenBarSettingsPolicy.protectedSystemHostBundleIDs

    static func resolve(
        hiddenBundleIDs: Set<String>,
        runningBundleIDs: Set<String>,
        protectedBundleIDs: Set<String>
    ) -> (allowed: Set<String>, concealed: Set<String>) {
        let concealed = hiddenBundleIDs
            .subtracting(protectedBundleIDs)
            .subtracting(systemHostBundleIDs)
        let allowed = runningBundleIDs
            .subtracting(concealed)
            .union(protectedBundleIDs)
            .union(systemHostBundleIDs)
        return (allowed, concealed)
    }
}
