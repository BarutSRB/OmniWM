// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class SettingsColorCodecTests: XCTestCase {
    func testCanonicalColorsKeepRGBAObjectsAndTablePaths() throws {
        var export = SettingsExport.defaults()
        export.borders.color.red = 0.1
        export.borders.color.green = 0.2
        export.borders.color.blue = 0.3
        export.borders.color.alpha = 0.4
        export.overview.backdrop = SettingsColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5)
        export.overview.windowBorders.normal = SettingsColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.6)
        export.overview.windowBorders.hovered = SettingsColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 0.7)
        export.overview.windowBorders.selected = SettingsColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 0.8)
        export.workspaceBar.accentColor = SettingsColor(red: 0.6, green: 0.7, blue: 0.8, alpha: 0.9)
        export.workspaceBar.textColor = SettingsColor(red: 0.7, green: 0.8, blue: 0.9, alpha: 1.0)
        let expected = [
            "borders.color": ["red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 0.4],
            "overview.backdrop": ["red": 0.2, "green": 0.3, "blue": 0.4, "alpha": 0.5],
            "overview.windowBorders.normal": ["red": 0.3, "green": 0.4, "blue": 0.5, "alpha": 0.6],
            "overview.windowBorders.hovered": ["red": 0.4, "green": 0.5, "blue": 0.6, "alpha": 0.7],
            "overview.windowBorders.selected": ["red": 0.5, "green": 0.6, "blue": 0.7, "alpha": 0.8],
            "workspaceBar.accentColor": ["red": 0.6, "green": 0.7, "blue": 0.8, "alpha": 0.9],
            "workspaceBar.textColor": ["red": 0.7, "green": 0.8, "blue": 0.9, "alpha": 1.0]
        ]
        let canonical = CanonicalTOMLConfig(export: export)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(canonical))
        let tomlData = try SettingsTOMLCodec.encode(export)
        let toml = try TOMLDecoder().decode([String: TOMLNode].self, from: tomlData)

        for (path, components) in expected {
            var jsonValue = json
            var tomlValue = TOMLNode.table(toml)
            for key in path.split(separator: ".").map(String.init) {
                jsonValue = try XCTUnwrap((jsonValue as? [String: Any])?[key], path)
                guard case let .table(table) = tomlValue else {
                    return XCTFail("Expected TOML table at \(path)")
                }
                tomlValue = try XCTUnwrap(table[key], path)
            }
            XCTAssertEqual(jsonValue as? [String: Double], components, path)
            XCTAssertEqual(tomlValue, .table(components.mapValues(TOMLNode.float)), path)
        }
        XCTAssertEqual(CanonicalTOMLConfig(export: try SettingsTOMLCodec.decode(tomlData)), canonical)
    }

    func testUnsetWorkspaceColorsRemainOmittedAndDecodeAsNil() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.accentColor = nil
        export.workspaceBar.textColor = nil
        let canonical = CanonicalTOMLConfig(export: export)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(canonical)) as? [String: Any]
        )
        let workspaceBar = try XCTUnwrap(json["workspaceBar"] as? [String: Any])
        XCTAssertNil(workspaceBar["accentColor"])
        XCTAssertNil(workspaceBar["textColor"])

        let tomlData = try SettingsTOMLCodec.encode(export)
        let toml = try TOMLDecoder().decode([String: TOMLNode].self, from: tomlData)
        guard case let .table(workspaceBarTable) = try XCTUnwrap(toml["workspaceBar"]) else {
            return XCTFail("Expected workspaceBar TOML table")
        }
        XCTAssertNil(workspaceBarTable["accentColor"])
        XCTAssertNil(workspaceBarTable["textColor"])
        let decoded = try SettingsTOMLCodec.decode(tomlData)
        XCTAssertNil(decoded.workspaceBar.accentColor)
        XCTAssertNil(decoded.workspaceBar.textColor)
    }
}
