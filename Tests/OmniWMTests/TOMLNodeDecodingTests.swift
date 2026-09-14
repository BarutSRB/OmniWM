// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class TOMLNodeDecodingTests: XCTestCase {
    func testScalarKindsRetainTheirTOMLTypes() throws {
        let source = Data("""
        enabled = true
        disabled = false
        integer = 1
        minimum = -9223372036854775808
        maximum = 9223372036854775807
        float = 1.0
        empty = ""
        string = "2026-06-15T12:30:00"
        """.utf8)
        let expected: [String: TOMLNode] = [
            "enabled": .boolean(true),
            "disabled": .boolean(false),
            "integer": .integer(1),
            "minimum": .integer(.min),
            "maximum": .integer(.max),
            "float": .float(1),
            "empty": .string(""),
            "string": .string("2026-06-15T12:30:00")
        ]

        let decoded = try TOMLDecoder().decode([String: TOMLNode].self, from: source)

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(try TOMLDecoder().decode([String: TOMLNode].self, from: TOMLEncoder().encode(decoded)), expected)
    }

    func testTemporalKindsRemainDistinct() throws {
        let source = Data("""
        localDateTime = 2026-06-15T12:30:00.123456789
        localDate = 2026-06-15
        localTime = 12:30:00.123456789
        offsetDateTime = 1970-01-01T01:00:00+01:00
        """.utf8)
        let expected: [String: TOMLNode] = [
            "localDateTime": .localDateTime(LocalDateTime(
                year: 2026, month: 6, day: 15, hour: 12, minute: 30, second: 0, nanosecond: 123_456_789
            )),
            "localDate": .localDate(LocalDate(year: 2026, month: 6, day: 15)),
            "localTime": .localTime(LocalTime(hour: 12, minute: 30, second: 0, nanosecond: 123_456_789)),
            "offsetDateTime": .offsetDateTime(Date(timeIntervalSince1970: 0))
        ]

        let decoded = try TOMLDecoder().decode([String: TOMLNode].self, from: source)

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(try TOMLDecoder().decode([String: TOMLNode].self, from: TOMLEncoder().encode(decoded)), expected)
    }

    func testNestedContainersDecodeRecursivelyWithoutChangingScalarKinds() throws {
        let source = Data("""
        nested = [[true, 1, 1.0, "1"], []]
        [table]
        child = { date = 2026-06-15, empty = {} }
        """.utf8)
        let expected: [String: TOMLNode] = [
            "nested": .array([
                .array([.boolean(true), .integer(1), .float(1), .string("1")]),
                .array([])
            ]),
            "table": .table([
                "child": .table([
                    "date": .localDate(LocalDate(year: 2026, month: 6, day: 15)),
                    "empty": .table([:])
                ])
            ])
        ]

        let decoded = try TOMLDecoder().decode([String: TOMLNode].self, from: source)

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(try TOMLDecoder().decode([String: TOMLNode].self, from: TOMLEncoder().encode(decoded)), expected)
    }
}
