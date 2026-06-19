// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum CommandPaletteMode: String, CaseIterable, Codable {
    case windows
    case menu
    case clipboard

    var displayName: String {
        switch self {
        case .windows: "Windows"
        case .menu: "Menu"
        case .clipboard: "Clipboard"
        }
    }
}
