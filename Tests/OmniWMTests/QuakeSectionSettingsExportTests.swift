// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class QuakeSectionSettingsExportTests: XCTestCase {
    func testOptionalQuakeFieldsStayAbsentWithoutCodecDefaults() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.opacity = nil
        export.quakeTerminal.backgroundBlurRadius = nil
        export.quakeTerminal.monitorMode = nil
        let data = try SettingsTOMLCodec.encode(export)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        let node = try XCTUnwrap(tree["quakeTerminal"])
        guard case let .table(quake) = node else { return XCTFail("Expected quakeTerminal table") }

        XCTAssertNil(quake["opacity"])
        XCTAssertNil(quake["backgroundBlurRadius"])
        XCTAssertNil(quake["monitorMode"])
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
    }

    func testNonoptionalQuakeFieldsRemainRequired() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let keys = [
            "enabled", "position", "widthPercent", "heightPercent", "animationDuration", "autoHide", "backgroundEffect"
        ]
        for key in keys {
            let incomplete = try removingQuakeField(key, from: source)
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(incomplete.utf8))) { error in
                guard case let DecodingError.keyNotFound(missingKey, context) = error else {
                    return XCTFail("Expected missing Quake field, got \(error)")
                }
                XCTAssertEqual(missingKey.stringValue, key)
                XCTAssertEqual(context.codingPath.map(\.stringValue), ["quakeTerminal"])
            }
        }
    }

    private func removingQuakeField(_ key: String, from source: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        let header = try XCTUnwrap(lines.firstIndex(of: "[quakeTerminal]"))
        let following = lines.indices.dropFirst(header + 1)
        let sectionEnd = following.first { lines[$0].hasPrefix("[") } ?? lines.endIndex
        let field = try XCTUnwrap(((header + 1) ..< sectionEnd).first {
            lines[$0].hasPrefix("\(key) = ")
        })
        lines.remove(at: field)
        return lines.joined(separator: "\n")
    }
}
