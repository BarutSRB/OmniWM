// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class MenuAnywhereFetcher {
    private let menuExtractor = MenuExtractor()

    func fetchMenuItemsSync(for pid: pid_t) -> [MenuItemModel] {
        guard let menuBar = menuExtractor.getMenuBar(for: pid) else {
            return []
        }
        return menuExtractor.flattenMenuItems(from: menuBar, appName: nil, excludeAppleMenu: true)
    }
}
