// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class OverviewSettingsTOMLTests: XCTestCase {
    func testDefaultsMatchOverviewContract() {
        let defaults = SettingsExport.defaults()

        XCTAssertEqual(defaults.overview.zoom, 1.0)
        XCTAssertEqual(defaults.overview.backdrop, color(0.05, 0.05, 0.08, 1.0))
        XCTAssertEqual(defaults.overview.windowBorders.normal, color(0.3, 0.3, 0.35, 0.5))
        XCTAssertEqual(defaults.overview.windowBorders.hovered, color(0.4, 0.6, 1.0, 1.0))
        XCTAssertEqual(defaults.overview.windowBorders.selected, color(0.3, 0.8, 0.4, 1.0))
    }

    func testRoundTripsCanonicalOverviewTables() throws {
        var export = SettingsExport.defaults()
        export.overview.zoom = 1.25
        export.overview.backdrop = color(0.1, 0.2, 0.3, 0.4)
        export.overview.windowBorders.normal = color(0.2, 0.3, 0.4, 0.5)
        export.overview.windowBorders.hovered = color(0.3, 0.4, 0.5, 0.6)
        export.overview.windowBorders.selected = color(0.4, 0.5, 0.6, 0.7)

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[overview]"))
        XCTAssertTrue(toml.contains("[overview.backdrop]"))
        XCTAssertTrue(toml.contains("[overview.windowBorders.normal]"))
        XCTAssertTrue(toml.contains("[overview.windowBorders.hovered]"))
        XCTAssertTrue(toml.contains("[overview.windowBorders.selected]"))
        XCTAssertEqual(decoded.overview.zoom, export.overview.zoom)
        XCTAssertEqual(decoded.overview.backdrop, export.overview.backdrop)
        XCTAssertEqual(decoded.overview.windowBorders.normal, export.overview.windowBorders.normal)
        XCTAssertEqual(decoded.overview.windowBorders.hovered, export.overview.windowBorders.hovered)
        XCTAssertEqual(decoded.overview.windowBorders.selected, export.overview.windowBorders.selected)
    }

    func testMalformedOverviewTypesRejectDecode() throws {
        let defaults = String(
            decoding: try SettingsTOMLCodec.encode(SettingsExport.defaults()),
            as: UTF8.self
        )
        let malformed = [
            replacingValue(in: defaults, table: "overview", key: "zoom", with: "\"large\""),
            replacingValue(in: defaults, table: "overview.backdrop", key: "red", with: "\"dark\""),
            replacingValue(
                in: defaults,
                table: "overview.windowBorders.selected",
                key: "alpha",
                with: "true"
            )
        ]

        for toml in malformed {
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(toml.utf8)))
        }
    }

    @MainActor
    func testApplyExportClampsZoomAndColorComponents() {
        let defaults = SettingsExport.defaults()
        var export = defaults
        export.overview.zoom = .nan
        export.overview.backdrop = color(-1, 2, .nan, .infinity)
        export.overview.windowBorders.normal = color(.infinity, -.infinity, 0.25, 0.75)
        export.overview.windowBorders.hovered = color(1.5, -0.5, .nan, 0.4)
        export.overview.windowBorders.selected = color(0.2, .nan, 2, -1)

        let settings = makeSettingsStore()
        settings.applyExport(export)

        XCTAssertEqual(settings.overview.zoom, defaults.overview.zoom)
        XCTAssertEqual(settings.overview.backdropColor, color(0, 1, defaults.overview.backdrop.blue, 1))
        XCTAssertEqual(
            settings.overview.normalBorderColor,
            color(
                defaults.overview.windowBorders.normal.red,
                defaults.overview.windowBorders.normal.green,
                0.25,
                0.75
            )
        )
        XCTAssertEqual(
            settings.overview.hoveredBorderColor,
            color(1, 0, defaults.overview.windowBorders.hovered.blue, 0.4)
        )
        XCTAssertEqual(
            settings.overview.selectedBorderColor,
            color(0.2, defaults.overview.windowBorders.selected.green, 1, 0)
        )
    }

    @MainActor
    func testApplyExportClampsFiniteZoomBoundsAndExportsNormalizedValues() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()

        export.overview.zoom = 0.25
        settings.applyExport(export)
        XCTAssertEqual(settings.overview.zoom, 0.5)

        export.overview.zoom = 2
        settings.applyExport(export)
        XCTAssertEqual(settings.overview.zoom, 1.5)
        XCTAssertEqual(settings.toExport().overview.zoom, 1.5)
    }

    @MainActor
    func testAutosavePersistsEveryOverviewSetting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewAutosaveTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: false,
            deferSaves: false
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )

        settings.overview.zoom = 1.25
        settings.overview.backdropColor = color(0.1, 0.2, 0.3, 0.4)
        settings.overview.normalBorderColor = color(0.2, 0.3, 0.4, 0.5)
        settings.overview.hoveredBorderColor = color(0.3, 0.4, 0.5, 0.6)
        settings.overview.selectedBorderColor = color(0.4, 0.5, 0.6, 0.7)

        let persisted = try SettingsTOMLCodec.decode(Data(contentsOf: persistence.fileURL))
        XCTAssertEqual(persisted.overview.zoom, settings.overview.zoom)
        XCTAssertEqual(persisted.overview.backdrop, settings.overview.backdropColor)
        XCTAssertEqual(persisted.overview.windowBorders.normal, settings.overview.normalBorderColor)
        XCTAssertEqual(persisted.overview.windowBorders.hovered, settings.overview.hoveredBorderColor)
        XCTAssertEqual(persisted.overview.windowBorders.selected, settings.overview.selectedBorderColor)
    }

    private func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> SettingsColor {
        SettingsColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func replacingValue(
        in toml: String,
        table: String,
        key: String,
        with replacement: String
    ) -> String {
        transform(toml) { currentTable, line in
            guard currentTable == table, line.hasPrefix("\(key) = ") else { return line }
            return "\(key) = \(replacement)"
        }
    }

    private func removingValue(in toml: String, table: String, key: String) -> String {
        transform(toml) { currentTable, line in
            guard currentTable == table, line.hasPrefix("\(key) = ") else { return line }
            return nil
        }
    }

    private func removingTable(_ table: String, from toml: String) -> String {
        var currentTable = ""
        return toml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { substring -> String? in
                let line = String(substring)
                if line.hasPrefix("["), line.hasSuffix("]") {
                    currentTable = String(line.dropFirst().dropLast())
                }
                return currentTable == table ? nil : line
            }
            .joined(separator: "\n")
    }

    private func removingOverviewTables(from toml: String) -> String {
        var currentTable = ""
        return toml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { substring -> String? in
                let line = String(substring)
                if line.hasPrefix("["), line.hasSuffix("]") {
                    currentTable = String(line.dropFirst().dropLast())
                }
                return currentTable == "overview" || currentTable.hasPrefix("overview.") ? nil : line
            }
            .joined(separator: "\n")
    }

    private func transform(
        _ toml: String,
        _ operation: (_ table: String, _ line: String) -> String?
    ) -> String {
        var currentTable = ""
        return toml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { substring -> String? in
                let line = String(substring)
                if line.hasPrefix("["), line.hasSuffix("]") {
                    currentTable = String(line.dropFirst().dropLast())
                }
                return operation(currentTable, line)
            }
            .joined(separator: "\n")
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewSettingsTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
