// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

enum OverviewRenderStyle {
    enum Colors {
        static let windowBackground = CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1.0)
        static let windowDimmed = CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.7)
        static let infoBackground = CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.9)
        static let closeButtonBackground = CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9)
        static let closeButtonHover = CGColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
        static let closeButtonX = CGColor(gray: 1.0, alpha: 1.0)
        static let searchBarBackground = CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 0.95)
        static let searchBarBorder = CGColor(red: 0.25, green: 0.25, blue: 0.3, alpha: 1.0)
        static let textWhite = CGColor(gray: 1.0, alpha: 1.0)
        static let textGray = CGColor(gray: 0.7, alpha: 1.0)
        static let textDimmed = CGColor(gray: 0.4, alpha: 1.0)
        static let workspaceLabelActive = CGColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1.0)
        static let workspaceLabelInactive = CGColor(gray: 0.6, alpha: 1.0)
        static let dropTarget = CGColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0)
        static let columnBackground = CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 0.6)
        static let columnBorder = CGColor(red: 0.25, green: 0.25, blue: 0.3, alpha: 1.0)
        static let columnDivider = CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 0.8)
        static let textWhiteNS = NSColor(cgColor: textWhite)!
        static let textGrayNS = NSColor(cgColor: textGray)!
        static let textDimmedNS = NSColor(cgColor: textDimmed)!
        static let workspaceLabelActiveNS = NSColor(cgColor: workspaceLabelActive)!
        static let workspaceLabelInactiveNS = NSColor(cgColor: workspaceLabelInactive)!
    }

    enum Metrics {
        static let windowCornerRadius: CGFloat = 8
        static let windowBorderWidth: CGFloat = 2
        static let selectedBorderWidth: CGFloat = 3
        static let closeButtonSize: CGFloat = 20
        static let closeButtonPadding: CGFloat = 6
        static let thumbnailInset: CGFloat = 1
        static let searchBarCornerRadius: CGFloat = 10
        static let searchBarBorderWidth: CGFloat = 1.5
        static let iconSize: CGFloat = 24
        static let groupBadgeHeight: CGFloat = 22
        static let groupBadgePadding: CGFloat = 8
        static let dropLineHeight: CGFloat = 4
        static let dropOutlineWidth: CGFloat = 3
        static let dropLineWidth: CGFloat = 4
        static let columnCornerRadius: CGFloat = 10
        static let dividerHeight: CGFloat = 2
        static let titleWidthBucket: CGFloat = 4
    }
}
