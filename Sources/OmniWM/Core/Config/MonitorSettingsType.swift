import Foundation

protocol MonitorSettingsType: Codable, Identifiable, Equatable {
    var monitorName: String { get }
}

enum MonitorSettingsStore {
    static func load<T: MonitorSettingsType>(from defaults: UserDefaults, key: String) -> [T] {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode([T].self, from: data)
        else {
            return []
        }
        return settings
    }

    static func save<T: MonitorSettingsType>(_ settings: [T], to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    static func get<T: MonitorSettingsType>(for monitorName: String, in settings: [T]) -> T? {
        settings.first { $0.monitorName == monitorName }
    }

    static func update<T: MonitorSettingsType>(_ item: T, in settings: inout [T]) {
        if let index = settings.firstIndex(where: { $0.monitorName == item.monitorName }) {
            settings[index] = item
        } else {
            settings.append(item)
        }
    }

    static func remove<T: MonitorSettingsType>(for monitorName: String, from settings: inout [T]) {
        settings.removeAll { $0.monitorName == monitorName }
    }
}
