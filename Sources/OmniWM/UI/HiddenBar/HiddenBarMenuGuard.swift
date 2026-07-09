// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum HiddenBarMenuGuard {
    static func isMenuOpen(
        windows: [(layer: Int, ownerPID: pid_t, title: String?)],
        menuOwnerPIDs: Set<pid_t>
    ) -> Bool {
        guard !menuOwnerPIDs.isEmpty else { return false }
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let menuLevels: Set<Int> = [popUpLevel, popUpLevel - 1]
        return windows.contains { window in
            menuLevels.contains(window.layer)
                && (window.title?.isEmpty ?? true)
                && menuOwnerPIDs.contains(window.ownerPID)
        }
    }

    static func isAnyMenuOpen(menuOwnerPIDs: Set<pid_t>) -> Bool? {
        guard !menuOwnerPIDs.isEmpty else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let windows = list.compactMap { info -> (layer: Int, ownerPID: pid_t, title: String?)? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            return (layer, pid, info[kCGWindowName as String] as? String)
        }
        return isMenuOpen(windows: windows, menuOwnerPIDs: menuOwnerPIDs)
    }
}
