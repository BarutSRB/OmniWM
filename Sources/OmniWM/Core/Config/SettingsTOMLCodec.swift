import Foundation
import TOML

// Only file in OmniWM that imports TOML — keep this boundary so swift-toml stays swappable.
enum SettingsTOMLCodec {
    static func encode(_ export: SettingsExport) throws -> Data {
        let canonical = CanonicalTOMLConfig(export: export)
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(canonical)
    }

    static func decode(_ data: Data) throws -> SettingsExport {
        do {
            let canonical = try TOMLDecoder().decode(CanonicalTOMLConfig.self, from: data)
            return canonical.toSettingsExport()
        } catch DecodingError.keyNotFound(_, _) {
            return try TOMLDecoder().decode(LenientSettingsTOMLConfig.self, from: data).export
        }
    }
}
