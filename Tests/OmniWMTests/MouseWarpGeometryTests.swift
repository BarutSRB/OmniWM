// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseWarpGeometryTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func testRightEdgeCrossingMapsToRightDirectionAndLeftEntry() {
        let crossing = MouseWarpGeometry.crossing(location: CGPoint(x: 999, y: 700), frame: frame, margin: 2)
        XCTAssertEqual(crossing?.direction, .right)
        XCTAssertEqual(crossing?.entryEdge, .left)
        XCTAssertEqual(crossing?.ratio ?? -1, 0.3, accuracy: 0.0001)
    }

    func testLeftEdgeCrossingMapsToLeftDirectionAndRightEntry() {
        let crossing = MouseWarpGeometry.crossing(location: CGPoint(x: 1, y: 250), frame: frame, margin: 2)
        XCTAssertEqual(crossing?.direction, .left)
        XCTAssertEqual(crossing?.entryEdge, .right)
    }

    func testTopAndBottomEdgesMapToUpAndDown() {
        let top = MouseWarpGeometry.crossing(location: CGPoint(x: 400, y: 999), frame: frame, margin: 2)
        XCTAssertEqual(top?.direction, .up)
        XCTAssertEqual(top?.entryEdge, .bottom)

        let bottom = MouseWarpGeometry.crossing(location: CGPoint(x: 400, y: 1), frame: frame, margin: 2)
        XCTAssertEqual(bottom?.direction, .down)
        XCTAssertEqual(bottom?.entryEdge, .top)
    }

    func testInteriorLocationDoesNotCross() {
        XCTAssertNil(MouseWarpGeometry.crossing(location: CGPoint(x: 500, y: 500), frame: frame, margin: 2))
    }

    func testProportionalPlacementPreservedOnSideBySideNeighbor() {
        let crossing = MouseWarpGeometry.crossing(location: CGPoint(x: 999, y: 700), frame: frame, margin: 2)
        let target = CGRect(x: 5000, y: 0, width: 1000, height: 1000)
        let destination = MouseWarpGeometry.destinationPoint(
            on: target,
            entryEdge: crossing?.entryEdge ?? .left,
            ratio: crossing?.ratio ?? 0,
            margin: 2
        )
        XCTAssertEqual(destination.x, 5003, accuracy: 0.5)
        XCTAssertEqual(destination.y, 700, accuracy: 0.5)
    }

    func testProportionalPlacementPreservedWhenNeighborIsPhysicallyBelow() {
        let target = CGRect(x: 0, y: -1000, width: 1000, height: 1000)
        let destination = MouseWarpGeometry.destinationPoint(on: target, entryEdge: .left, ratio: 0.3, margin: 2)
        XCTAssertEqual(destination.x, 3, accuracy: 0.5)
        XCTAssertEqual(destination.y, -300, accuracy: 0.5)
    }
}
