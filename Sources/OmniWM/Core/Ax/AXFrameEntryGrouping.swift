// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum AXFrameEntryGrouping {
    static func unique(_ entries: [(pid: pid_t, windowId: Int)]) -> [(pid: pid_t, windowId: Int)] {
        var uniqueEntries: [(pid: pid_t, windowId: Int)] = []
        uniqueEntries.reserveCapacity(entries.count)
        var seen: Set<WindowToken> = []
        for entry in entries {
            let token = WindowToken(pid: entry.pid, windowId: entry.windowId)
            guard seen.insert(token).inserted else { continue }
            uniqueEntries.append(entry)
        }
        return uniqueEntries
    }
}
