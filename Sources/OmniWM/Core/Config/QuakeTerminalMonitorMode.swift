// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

enum QuakeTerminalMonitorMode: String, CaseIterable, Codable {
    case mouseCursor
    case focusedWindow
    case mainMonitor

    var displayName: String {
        switch self {
        case .mouseCursor: "Mouse Cursor's Monitor"
        case .focusedWindow: "Focused Window's Monitor"
        case .mainMonitor: "Main Monitor"
        }
    }
}
