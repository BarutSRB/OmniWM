// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

enum TrackpadScrollStyle: String, CaseIterable, Codable, Identifiable {
    case snap
    case momentum

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .snap: "Snap to Columns"
        case .momentum: "Momentum"
        }
    }
}
