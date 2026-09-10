// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum HiddenBarMenuGuard {
    struct WindowInfo {
        let layer: Int
        let ownerPID: pid_t
        let title: String?
    }

    static func isMenuOpen(
        windows: [WindowInfo],
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
        let windows = list.compactMap { info -> WindowInfo? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            return WindowInfo(layer: layer, ownerPID: pid, title: info[kCGWindowName as String] as? String)
        }
        return isMenuOpen(windows: windows, menuOwnerPIDs: menuOwnerPIDs)
    }
}
