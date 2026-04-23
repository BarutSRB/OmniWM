// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TOML

enum SettingsTOMLCodec {
    static func encode(_ export: SettingsExport) throws -> Data {
        let canonical = CanonicalTOMLConfig(export: export)
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(canonical)
    }

    static func decode(_ data: Data) throws -> SettingsExport {
        let canonical = try TOMLDecoder().decode(CanonicalTOMLConfig.self, from: data)
        return canonical.toSettingsExport()
    }
}
