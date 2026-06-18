import Foundation
@testable import OmniWM
import XCTest

final class SettingsTOMLCodecTests: XCTestCase {
    func testPreservingEncodeKeepsUnknownKeysInsideKnownTables() throws {
        let previous = try defaultsWithReplacements(
            ("[general]\n", "[general]\nfutureSetting = \"keep-me\"\n"),
            ("[niri]\n", "[niri]\nfutureNiriSetting = true\n")
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gapSize = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("futureSetting = \"keep-me\""))
        XCTAssertTrue(rewritten.contains("futureNiriSetting = true"))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeKeepsUnknownExtensionTables() throws {
        let previous = try defaultsWithSuffix(
            """

            [future]
            topValue = "top"

            [future.nested]
            flag = true
            """
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gapSize = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("[future]"))
        XCTAssertTrue(rewritten.contains("topValue = \"top\""))
        XCTAssertTrue(rewritten.contains("[future.nested]"))
        XCTAssertTrue(rewritten.contains("flag = true"))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeKeepsUnknownDateTimeTypes() throws {
        let previous = try defaultsWithSuffix(
            """

            [futureTimeTypes]
            futureDate = 2026-06-15
            futureLocalDateTime = 2026-06-15T12:30:00
            futureOffset = 2026-06-15T12:30:00-04:00
            futureTime = 12:30:00
            """
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gapSize = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("futureDate = 2026-06-15"))
        XCTAssertTrue(rewritten.contains("futureLocalDateTime = 2026-06-15T12:30:00"))
        XCTAssertTrue(rewritten.contains("futureTime = 12:30:00"))

        let actualValue = try XCTUnwrap(tomlValue(for: "futureOffset", in: rewritten))
        let actual = try XCTUnwrap(parseOffsetDateTime(actualValue))
        let expected = try XCTUnwrap(parseOffsetDateTime("2026-06-15T12:30:00-04:00"))
        XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPreservingEncodeDoesNotResurrectClearedKnownOptionals() throws {
        let previous = try SettingsTOMLCodec.encode(.defaults())

        var export = try SettingsTOMLCodec.decode(previous)
        export.mouseWarpAxis = nil
        export.quakeTerminalOpacity = nil

        let rewrittenData = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous)
        let rewritten = String(decoding: rewrittenData, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(rewrittenData)

        XCTAssertFalse(rewritten.contains("axis = \"horizontal\""))
        XCTAssertFalse(rewritten.contains("opacity = 1.0"))
        XCTAssertNil(decoded.mouseWarpAxis)
        XCTAssertNil(decoded.quakeTerminalOpacity)
    }

    @MainActor
    func testSavePathPreservesUnknownKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = try defaultsWithReplacements(
            ("[general]\n", "[general]\nfutureSetting = \"keep-me\"\n")
        )
        let fileURL = directory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        try previous.write(to: fileURL, options: .atomic)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        var export = persistence.load()
        export.gapSize = 24

        try persistence.saveImmediately(export)

        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("futureSetting = \"keep-me\""))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeKeepsCanonicalBytesWhenNoUnknownKeysExist() throws {
        let export = SettingsExport.defaults()
        let canonicalData = try SettingsTOMLCodec.encode(export)

        let rewritten = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: canonicalData)

        XCTAssertEqual(rewritten, canonicalData)
    }

    func testTrackpadScrollStyleRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().trackpadScrollStyle, TrackpadScrollStyle.snap.rawValue)

        var export = SettingsExport.defaults()
        export.trackpadScrollStyle = TrackpadScrollStyle.momentum.rawValue
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("trackpadScrollStyle = \"momentum\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).trackpadScrollStyle, TrackpadScrollStyle.momentum.rawValue)
    }

    func testTrackpadScrollStyleRecoversToSnapWhenMissing() throws {
        let withoutKey = try defaultsWithReplacements(
            ("trackpadScrollStyle = \"snap\"\n", "")
        )
        XCTAssertEqual(try SettingsTOMLCodec.decode(withoutKey).trackpadScrollStyle, TrackpadScrollStyle.snap.rawValue)
    }

    func testUnsupportedSystemHyperTriggerRecoversToNone() throws {
        let unsupportedKey = try defaultsWithReplacements(
            ("systemHyperTrigger = \"None\"\n", "systemHyperTrigger = \"A\"\n")
        )
        XCTAssertTrue(String(decoding: unsupportedKey, as: UTF8.self).contains("systemHyperTrigger = \"A\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(unsupportedKey).systemHyperTrigger, .none)

        let unsupportedMouse = try defaultsWithReplacements(
            ("systemHyperTrigger = \"None\"\n", "systemHyperTrigger = \"MouseButton2\"\n")
        )
        XCTAssertTrue(String(decoding: unsupportedMouse, as: UTF8.self).contains("systemHyperTrigger = \"MouseButton2\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(unsupportedMouse).systemHyperTrigger, .none)
    }

    private func defaultsWithReplacements(_ replacements: (String, String)...) throws -> Data {
        var toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        for (target, replacement) in replacements {
            toml = toml.replacingOccurrences(of: target, with: replacement)
        }
        return Data(toml.utf8)
    }

    private func defaultsWithSuffix(_ suffix: String) throws -> Data {
        var toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        toml += suffix
        toml += "\n"
        return Data(toml.utf8)
    }

    private func tomlValue(for key: String, in toml: String) -> String? {
        let prefix = "\(key) = "
        return toml
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func parseOffsetDateTime(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]

        return fractional.date(from: value) ?? wholeSeconds.date(from: value)
    }
}
