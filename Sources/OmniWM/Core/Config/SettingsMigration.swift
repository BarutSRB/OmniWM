import Foundation

enum StartupDecision: Equatable {
    case boot
    case requireReset(storedEpoch: Int?)
}

enum SettingsMigration {
    static let currentSettingsEpoch = 2

    private static let epochKey = "settings.settingsEpoch"
    private static let patchesKey = "appliedSettingsPatches"
    private static let ownedSettingsPrefix = "settings."

    enum MigrationError: LocalizedError {
        case invalidImportFile
        case unsupportedEpoch(expected: Int, found: Int?)
        case backupEncodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImportFile:
                return "The settings file is not valid JSON."
            case let .unsupportedEpoch(expected, found):
                if let found {
                    return "This settings file uses schema epoch \(found), but OmniWM expects epoch \(expected)."
                }
                return "This settings file is missing a schema epoch. OmniWM expects epoch \(expected)."
            case .backupEncodingFailed:
                return "OmniWM could not encode the backup snapshot."
            }
        }
    }

    static func startupDecision(defaults: UserDefaults = .standard) -> StartupDecision {
        let storedEpoch = storedEpoch(defaults: defaults)
        if let storedEpoch {
            return storedEpoch == currentSettingsEpoch ? .boot : .requireReset(storedEpoch: storedEpoch)
        }

        return hasOwnedSettings(defaults: defaults) ? .requireReset(storedEpoch: nil) : .boot
    }

    static func persistCurrentEpoch(defaults: UserDefaults = .standard) {
        defaults.set(currentSettingsEpoch, forKey: epochKey)
    }

    static func exportRawBackup(defaults: UserDefaults = .standard) throws -> URL {
        let snapshot = ownedSettingsSnapshot(defaults: defaults)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: snapshot,
            format: .xml,
            options: 0
        )

        let epochLabel = storedEpoch(defaults: defaults).map(String.init) ?? "missing"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let backupURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omniwm")
            .appendingPathComponent("settings-backup-epoch-\(epochLabel)-\(timestamp).plist")

        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plistData.write(to: backupURL)
        return backupURL
    }

    static func resetOwnedSettings(defaults: UserDefaults = .standard) {
        let ownedKeys = Set(ownedSettingsSnapshot(defaults: defaults).keys)
        for key in ownedKeys {
            defaults.removeObject(forKey: key)
        }
        persistCurrentEpoch(defaults: defaults)
    }

    static func validateImportEpoch(from rawData: Data) throws {
        let foundEpoch = try importEpoch(from: rawData)
        guard foundEpoch == currentSettingsEpoch else {
            throw MigrationError.unsupportedEpoch(expected: currentSettingsEpoch, found: foundEpoch)
        }
    }

    static func ownedSettingsSnapshot(defaults: UserDefaults = .standard) -> [String: Any] {
        defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(ownedSettingsPrefix) || key == patchesKey
        }
    }

    static func storedEpoch(defaults: UserDefaults = .standard) -> Int? {
        if defaults.object(forKey: epochKey) == nil {
            return nil
        }
        return defaults.integer(forKey: epochKey)
    }

    private static func hasOwnedSettings(defaults: UserDefaults) -> Bool {
        !ownedSettingsSnapshot(defaults: defaults).isEmpty
    }

    private static func importEpoch(from rawData: Data) throws -> Int? {
        guard let json = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw MigrationError.invalidImportFile
        }

        if let number = json["version"] as? NSNumber {
            return number.intValue
        }
        if json["version"] == nil {
            return nil
        }
        throw MigrationError.invalidImportFile
    }
}
