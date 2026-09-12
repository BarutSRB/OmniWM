// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct FullRescanAppTargetSelection {
    let discoveryEvidence: FullRescanDiscoveryEvidence
    let preservingPIDsByWindowId: [Int: pid_t]
    let persistentEvidencePIDs: Set<pid_t>
    let includedPIDs: Set<pid_t>?
    var includedWindowIdsByPID: [pid_t: Set<Int>] = [:]
    let allowsEvidenceFreeOneShot: Bool
}
