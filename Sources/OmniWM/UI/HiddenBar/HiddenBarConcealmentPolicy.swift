// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

enum HiddenBarConcealmentPolicy {
    nonisolated static func wantsRefresh(
        enabled: Bool,
        available: Bool,
        hiddenBundleIDs: Set<String>
    ) -> Bool {
        enabled && available && !hiddenBundleIDs.isEmpty
    }

    nonisolated static func effectiveHiddenBundleIDs(
        configured: Set<String>,
        temporarilyRevealed: Set<String>,
        pendingCapture: Set<String> = []
    ) -> Set<String> {
        configured.subtracting(temporarilyRevealed).subtracting(pendingCapture)
    }
}
