// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SkyLightWindowTitleTests: XCTestCase {
    func testSuccessfulTitlesBypassFallback() {
        let copy: SkyLightSurfaceFunctions.CopyWindowPropertyFunc = { connectionID, windowId, key, value in
            guard connectionID == 7, key as String == "kCGSWindowTitle" else { return .failure }
            switch windowId {
            case 1:
                value.pointee = "Ordinary title" as CFString
            case 2:
                value.pointee = "OmniWM — 日本語 🪟 café" as CFString
            case 3:
                value.pointee = "" as CFString
            default:
                return .failure
            }
            return .success
        }

        for (windowId, expected) in [(UInt32(1), "Ordinary title"), (2, "OmniWM — 日本語 🪟 café"), (3, "")] {
            var fallbackCalls = 0
            let title = SkyLight.windowTitle(windowId, connectionID: 7, copyProperty: copy) {
                fallbackCalls += 1
                return "Fallback"
            }
            XCTAssertEqual(title, expected)
            XCTAssertEqual(fallbackCalls, 0)
        }
    }

    func testUnavailableConnectionDoesNotCallProperty() {
        let copy: SkyLightSurfaceFunctions.CopyWindowPropertyFunc = { _, _, _, _ in
            XCTFail("An unavailable connection must not query a property")
            return .failure
        }
        var fallbackCalls = 0
        let title = SkyLight.windowTitle(42, connectionID: 0, copyProperty: copy) {
            fallbackCalls += 1
            return "Fallback"
        }
        XCTAssertEqual(title, "Fallback")
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testMissingSymbolUsesFallback() {
        for expected in ["Fallback", "", nil] as [String?] {
            var fallbackCalls = 0
            let title = SkyLight.windowTitle(42, connectionID: 7, copyProperty: nil) {
                fallbackCalls += 1
                return expected
            }
            XCTAssertEqual(title, expected)
            XCTAssertEqual(fallbackCalls, 1)
        }
    }

    func testUnusableResultsUseFallback() {
        let copies: [SkyLightSurfaceFunctions.CopyWindowPropertyFunc] = [
            { _, _, _, _ in .failure },
            { _, _, _, value in
                value.pointee = "Discard failed result" as CFString
                return .failure
            },
            { _, _, _, _ in .success },
            { _, _, _, value in
                value.pointee = kCFNull
                return .success
            },
            { _, _, _, value in
                value.pointee = kCFBooleanTrue
                return .success
            },
            { _, _, _, value in
                value.pointee = ["Unexpected collection"] as CFArray
                return .success
            }
        ]
        for copy in copies {
            var fallbackCalls = 0
            let title = SkyLight.windowTitle(42, connectionID: 7, copyProperty: copy) {
                fallbackCalls += 1
                return "Fallback"
            }
            XCTAssertEqual(title, "Fallback")
            XCTAssertEqual(fallbackCalls, 1)
        }
    }
}
