// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension WorldStore {
    func isAppHidden(pid: pid_t) -> Bool {
        hiddenAppPIDs.contains(pid)
    }

    func scratchpadIndex(for token: WindowToken) -> ScratchpadIndex? {
        scratchpads.membersBySlot.first { $0.value.contains(token) }?.key
    }
}
