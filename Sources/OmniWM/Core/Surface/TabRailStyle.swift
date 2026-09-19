// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum TabRailStyle: Equatable {
    case compact
    case appIcons

    static let iconSize: CGFloat = 20
    static let iconRowHeight: CGFloat = 28

    init(appIcons: Bool) {
        self = appIcons ? .appIcons : .compact
    }

    var reservedWidth: CGFloat {
        switch self {
        case .compact: TabRailMetrics.totalWidth
        case .appIcons: 28
        }
    }

    var hitWidth: CGFloat {
        max(reservedWidth, TabRailMetrics.hitWidth)
    }

    func fittedHeight(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        switch self {
        case .compact:
            TabRailLayout.fittedHeight(tabCount: tabCount, availableHeight: availableHeight)
        case .appIcons:
            min(max(0, availableHeight), CGFloat(max(0, tabCount)) * Self.iconRowHeight)
        }
    }
}
