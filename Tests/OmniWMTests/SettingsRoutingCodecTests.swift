// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsRoutingCodecTests: XCTestCase {
    func testRoutingSettingsRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.routing.mode = .custom
        export.mouseWarp.enabled = false
        export.routing.arrangements = [MonitorArrangement(monitors: [
            MonitorRoutingSettings(monitorName: "Studio Display", monitorDisplayId: 7, gridColumn: 1, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Built-in", monitorDisplayId: 2, gridColumn: 0, gridRow: 0)
        ]), MonitorArrangement(monitors: [
            MonitorRoutingSettings(monitorName: "Work Display", monitorDisplayId: 9, gridColumn: 0, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Built-in", monitorDisplayId: 2, gridColumn: 0, gridRow: 1)
        ])]

        let encoded = try SettingsTOMLCodec.encode(export)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("[[routing.arrangements.monitors]]"))
        XCTAssertFalse(text.contains("monitorRoutingOverrides"))
        let mode = try XCTUnwrap(text.range(of: "mode = \"custom\""))
        let arrangements = try XCTUnwrap(text.range(of: "[[routing.arrangements]]"))
        XCTAssertLessThan(mode.lowerBound, arrangements.lowerBound)

        let decoded = try SettingsTOMLCodec.decode(encoded)

        XCTAssertEqual(decoded.routing.mode, .custom)
        XCTAssertFalse(decoded.mouseWarp.enabled)
        XCTAssertEqual(decoded.routing.arrangements, export.routing.arrangements)
    }

    func testRoutingDefaults() throws {
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(.defaults()))

        XCTAssertEqual(decoded.routing.mode, .macOS)
        XCTAssertTrue(decoded.mouseWarp.enabled)
        XCTAssertTrue(decoded.routing.arrangements.isEmpty)
        XCTAssertTrue(String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
            .contains("arrangements = []"))
    }
}
