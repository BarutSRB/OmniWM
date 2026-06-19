// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct MonitorOrientationSettings: MonitorSettingsType {
    var id: String {
        monitorDisplayId.map(String.init) ?? monitorName
    }

    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID? = nil
    var orientation: Monitor.Orientation?
}
