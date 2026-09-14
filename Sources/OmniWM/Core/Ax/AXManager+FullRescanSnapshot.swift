// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    struct FullRescanEnumerationSnapshot {
        let windows: [FullRescanWindowCandidate]
        let successfullyEnumeratedPIDs: Set<pid_t>
        let failedPIDs: Set<pid_t>
        let authoritativeTargetPIDs: Set<pid_t>
        let exactWindowIds: Set<Int>?
        let identityAliasesByWindowId: [Int: FullRescanWindowIdentityAliases]
        let windowServerInfoByWindowId: [Int: WindowServerInfo]
    }
}
