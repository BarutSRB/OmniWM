// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

final class AXUIElementConversionTests: XCTestCase {
    func testMissingValueIsRejected() {
        XCTAssertNil(AXUIElement.from(nil))
    }

    func testNonElementCoreFoundationTypesAreRejected() throws {
        var point = CGPoint(x: 10, y: 20)
        let pointValue = try XCTUnwrap(AXValueCreate(.cgPoint, &point))

        XCTAssertNil(AXUIElement.from("AXButton" as CFString))
        XCTAssertNil(AXUIElement.from(kCFBooleanTrue))
        XCTAssertNil(AXUIElement.from(kCFNull))
        XCTAssertNil(AXUIElement.from(pointValue))
    }

    func testElementReferenceIdentityIsPreserved() throws {
        let element = AXUIElementCreateApplication(91_580)
        let converted = try XCTUnwrap(AXUIElement.from(element))

        XCTAssertTrue(converted === element)
    }

    func testConvertedElementSurvivesInputScope() throws {
        let converted = try XCTUnwrap(autoreleasepool {
            AXUIElement.from(AXUIElementCreateApplication(91_581))
        })
        var processIdentifier: pid_t = 0

        XCTAssertEqual(AXUIElementGetPid(converted, &processIdentifier), .success)
        XCTAssertEqual(processIdentifier, 91_581)
    }
}
