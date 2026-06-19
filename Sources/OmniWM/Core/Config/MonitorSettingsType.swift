// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

protocol MonitorSettingsType: Codable, Identifiable, Equatable {
    var monitorName: String { get set }
    var monitorDisplayId: CGDirectDisplayID? { get set }
}

enum MonitorSettingsStore {
    static func get<T: MonitorSettingsType>(for monitor: Monitor, in settings: [T]) -> T? {
        if let exact = settings.first(where: { $0.monitorDisplayId == monitor.displayId }) {
            return exact
        }
        return settings.first {
            $0.monitorDisplayId == nil && $0.monitorName == monitor.name
        }
    }

    static func get<T: MonitorSettingsType>(for monitorName: String, in settings: [T]) -> T? {
        settings.first { $0.monitorDisplayId == nil && $0.monitorName == monitorName } ??
            settings.first { $0.monitorName == monitorName }
    }

    static func update<T: MonitorSettingsType>(_ item: T, in settings: inout [T]) {
        if let displayId = item.monitorDisplayId,
           let index = settings.firstIndex(where: { $0.monitorDisplayId == displayId })
        {
            settings[index] = item
            return
        }

        if let index = settings.firstIndex(where: {
            $0.monitorDisplayId == nil && item.monitorDisplayId == nil && $0.monitorName == item.monitorName
        }) {
            settings[index] = item
            return
        }

        if item.monitorDisplayId != nil,
           let index = settings
           .firstIndex(where: { $0.monitorDisplayId == nil && $0.monitorName == item.monitorName })
        {
            settings[index] = item
            return
        }

        settings.append(item)
    }

    static func remove<T: MonitorSettingsType>(for monitor: Monitor, from settings: inout [T]) {
        settings.removeAll { item in
            if let itemDisplayId = item.monitorDisplayId {
                return itemDisplayId == monitor.displayId
            }
            return item.monitorName == monitor.name
        }
    }

    static func remove<T: MonitorSettingsType>(for monitorName: String, from settings: inout [T]) {
        settings.removeAll { $0.monitorName == monitorName }
    }
}
