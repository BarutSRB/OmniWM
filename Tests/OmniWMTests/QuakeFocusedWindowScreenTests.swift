// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class QuakeFocusedWindowScreenTests: XCTestCase {
    func testFirstEligibleWindowWinsAfterCoordinateConversion() {
        let monitors = [
            monitor(displayId: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            monitor(displayId: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        ]
        let first = CGRect(x: 1200, y: 100, width: 400, height: 300)
        let windowList = [
            window(bounds: ["X": 1200, "Y": 100, "Width": 400, "Height": 300]),
            window(bounds: ["X": 100, "Y": 100, "Width": 400, "Height": 300])
        ]
        var converted: [CGRect] = []

        let result = QuakeFocusedWindowScreen.displayId(
            monitors: monitors,
            windowList: windowList,
            ownPID: 7,
            toAppKitRect: { rect in
                converted.append(rect)
                return rect.offsetBy(dx: -1000, dy: 0)
            }
        )

        XCTAssertEqual(result, 1)
        XCTAssertEqual(converted, [first])
    }

    func testInvalidEntriesSkipConversionAndNativeNumericValuesRemainAccepted() {
        let monitors = [monitor(displayId: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))]
        let bounds: [String: Any] = ["X": Float(12.5), "Y": NSNumber(value: 25.25), "Width": 200, "Height": 300.5]
        let windowList = [
            [:],
            window(pid: "42", bounds: bounds),
            window(layer: NSNumber(value: 0.25), bounds: bounds),
            window(bounds: "invalid"),
            window(bounds: ["X": "12.5", "Y": 0, "Width": 200, "Height": 300]),
            window(bounds: ["X": Double.nan, "Y": 0, "Width": 200, "Height": 300]),
            window(bounds: ["X": 0, "Y": 0, "Width": Double.infinity, "Height": 300]),
            window(bounds: ["X": 0, "Y": 0, "Width": 50, "Height": 300]),
            window(bounds: ["X": 0, "Y": 0, "Width": 200, "Height": 100_001]),
            window(pid: Int32(42), layer: Int64(0), bounds: bounds)
        ]
        var converted: [CGRect] = []

        let result = QuakeFocusedWindowScreen.displayId(
            monitors: monitors,
            windowList: windowList,
            ownPID: 7,
            toAppKitRect: { rect in
                converted.append(rect)
                return rect
            }
        )

        XCTAssertEqual(result, 1)
        XCTAssertEqual(converted, [CGRect(x: 12.5, y: 25.25, width: 200, height: 300.5)])
    }

    private func monitor(displayId: CGDirectDisplayID, frame: CGRect) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "test-\(displayId)"
        )
    }

    private func window(pid: Any = Int32(42), layer: Any = Int(0), bounds: Any) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: bounds
        ]
    }
}
