// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

protocol MonitorSettingsType: Codable, Identifiable, Equatable {
    var monitorName: String { get set }
    var monitorDisplayId: CGDirectDisplayID? { get set }
}

enum MonitorSettingsStore {
    static func get<T: MonitorSettingsType>(for monitor: Monitor, in settings: [T]) -> T? {
        settings.first(where: { $0.monitorDisplayId == monitor.displayId })
    }

    static func get<T: MonitorSettingsType>(for monitorName: String, in settings: [T]) -> T? {
        settings.first { $0.monitorDisplayId == nil && $0.monitorName == monitorName } ??
            settings.first { $0.monitorName == monitorName }
    }

    static func update<T: MonitorSettingsType>(_ item: T, in settings: inout [T]) {
        if let displayId = item.monitorDisplayId,
           let index = settings.firstIndex(where: { $0.monitorDisplayId == displayId }) {
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
           let index = settings.firstIndex(where: { $0.monitorDisplayId == nil && $0.monitorName == item.monitorName }) {
            settings[index] = item
            return
        }

        settings.append(item)
    }

    static func rebound<T: MonitorSettingsType>(_ settings: [T], to monitors: [Monitor]) -> [T] {
        let exactDisplayIds = Set<CGDirectDisplayID>(
            settings.compactMap { item in
                guard let displayId = item.monitorDisplayId,
                      monitors.contains(where: { $0.displayId == displayId })
                else {
                    return nil
                }
                return displayId
            }
        )

        var reboundSettings: [T] = []
        reboundSettings.reserveCapacity(settings.count)

        for item in settings {
            var rebound = item

            if let exact = monitors.first(where: { $0.displayId == item.monitorDisplayId }) {
                rebound.monitorDisplayId = exact.displayId
                rebound.monitorName = exact.name
                update(rebound, in: &reboundSettings)
                continue
            }

            let nameMatches = monitors.filter { $0.name.caseInsensitiveCompare(item.monitorName) == .orderedSame }
            guard nameMatches.count == 1 else {
                update(rebound, in: &reboundSettings)
                continue
            }

            if exactDisplayIds.contains(nameMatches[0].displayId) {
                continue
            }

            rebound.monitorDisplayId = nameMatches[0].displayId
            rebound.monitorName = nameMatches[0].name
            update(rebound, in: &reboundSettings)
        }

        return reboundSettings
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
