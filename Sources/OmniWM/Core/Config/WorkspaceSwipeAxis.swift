// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

enum WorkspaceSwipeAxis: String, CaseIterable, Codable, Identifiable {
    case horizontal
    case vertical

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }
}
