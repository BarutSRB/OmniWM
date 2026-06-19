// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

enum ScrollModifierKey: String, CaseIterable, Codable {
    case optionShift
    case controlShift

    var displayName: String {
        switch self {
        case .optionShift: "Option+Shift (⌥⇧)"
        case .controlShift: "Control+Shift (⌃⇧)"
        }
    }
}
