// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

final class AXSnapshotValueFormatterTests: XCTestCase {
    func testScalarTypesKeepTheirDiagnosticRepresentation() throws {
        let truth = try XCTUnwrap(kCFBooleanTrue)
        let falsehood = try XCTUnwrap(kCFBooleanFalse)

        XCTAssertEqual(describe(truth), "true")
        XCTAssertEqual(describe(falsehood), "false")
        XCTAssertEqual(describe(NSNumber(value: 42)), "42")
        XCTAssertEqual(describe("true" as CFString), "true")
        XCTAssertEqual(describe("window 🪟" as CFString), "window 🪟")
    }

    func testAXGeometryAndElementIdentityRemainDistinct() throws {
        var point = CGPoint(x: 1.5, y: -2)
        var size = CGSize(width: 80, height: 45.5)
        let pointValue = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let sizeValue = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        let element = AXUIElementCreateApplication(91_040)

        XCTAssertEqual(describe(pointValue), "point(x=1.5,y=-2.0)")
        XCTAssertEqual(describe(sizeValue), "size(w=80.0,h=45.5)")
        XCTAssertEqual(describe(element), "AXUIElement(reference=\(CFHash(element)))")
    }

    func testArrayLimitKeepsOrderAndReportsOnlyOmittedElements() {
        let values = (0 ... 65).map { NSNumber(value: $0) } as CFArray
        let retained = (0 ... 63).map(String.init).joined(separator: ", ")

        XCTAssertEqual(describe(values), "[\(retained), truncated=2]")
        XCTAssertEqual(describe([] as CFArray), "[]")
    }

    func testStringLimitPreservesCompleteUTF8Characters() {
        let value = String(repeating: "🪟", count: 1_025) as CFString

        XCTAssertEqual(describe(value), String(repeating: "🪟", count: 1_024))
    }

    private func describe(_ value: CFTypeRef) -> String {
        AXSnapshotValueFormatter.describe(value, arrayLimit: RuntimeTraceLimits.axArrayElements)
    }
}
