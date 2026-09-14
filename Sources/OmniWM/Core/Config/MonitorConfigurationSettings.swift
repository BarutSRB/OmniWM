// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class MonitorConfigurationSettings {
    private nonisolated static let defaults = SettingsExport.Routing.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var routingMode = MonitorConfigurationSettings.defaults.mode {
        didSet { onChange?() }
    }

    var arrangements = MonitorConfigurationSettings.defaults.arrangements {
        didSet { onChange?() }
    }

    var orientationOverrides: [MonitorOrientationSettings] = [] {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Routing {
        SettingsExport.Routing(
            mode: routingMode,
            arrangements: arrangements
        )
    }

    func orientationSettings(for monitor: Monitor) -> MonitorOrientationSettings? {
        MonitorSettingsStore.get(for: monitor, in: orientationOverrides)
    }

    func effectiveOrientation(for monitor: Monitor) -> Monitor.Orientation {
        if let override = orientationSettings(for: monitor),
           let orientation = override.orientation
        {
            return orientation
        }
        return monitor.autoOrientation
    }

    func updateOrientationSettings(_ settings: MonitorOrientationSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &orientationOverrides)
    }

    func removeOrientationSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &orientationOverrides)
    }

    func storeRoutingLayout(_ layout: [MonitorRoutingSettings], for monitors: [Monitor]) {
        MonitorRouting.store(layout, for: monitors, in: &arrangements)
    }
}
