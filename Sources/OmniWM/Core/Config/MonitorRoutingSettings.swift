// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum MonitorRoutingMode: String, Codable, CaseIterable {
    case macOS
    case custom
}

struct MonitorRoutingSettings: MonitorSettingsType {
    var id: String {
        monitorDisplayId.map(String.init) ?? monitorName
    }

    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID? = nil
    var gridColumn: Int
    var gridRow: Int
}
