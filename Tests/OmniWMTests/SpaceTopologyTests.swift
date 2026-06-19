// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class SpaceTopologyTests: XCTestCase {
    private func twoDisplayTopology() -> SpaceTopology {
        SpaceTopology(
            displays: [
                SpaceTopology.DisplaySpaces(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: 1),
                SpaceTopology.DisplaySpaces(displayIdentifier: "secondary", spaceIds: [3, 4], currentSpaceId: 3)
            ],
            activeSpaceId: 1,
            fullscreenSpaceIds: [4],
            windowSpace: [:]
        )
    }

    func testIsCurrentSpaceMatchesEachDisplay() {
        let topology = twoDisplayTopology()
        XCTAssertTrue(topology.isCurrentSpace(1))
        XCTAssertTrue(topology.isCurrentSpace(3))
        XCTAssertFalse(topology.isCurrentSpace(2))
        XCTAssertFalse(topology.isCurrentSpace(4))
        XCTAssertFalse(topology.isCurrentSpace(999))
    }

    func testIsWindowOnKnownInactiveSpace() {
        var topology = twoDisplayTopology()
        topology.windowSpace = [10: 2, 11: 3, 12: 999]
        XCTAssertTrue(topology.isWindowOnKnownInactiveSpace(10))
        XCTAssertFalse(topology.isWindowOnKnownInactiveSpace(11))
        XCTAssertFalse(topology.isWindowOnKnownInactiveSpace(12))
        XCTAssertFalse(topology.isWindowOnKnownInactiveSpace(13))
    }

    func testSelectWindowSpacePrefersCurrentNonFullscreen() {
        let topology = twoDisplayTopology()
        XCTAssertEqual(topology.selectWindowSpace(from: [4, 2, 3]), 3)
    }

    func testSelectWindowSpaceFallsBackToKnownNonFullscreen() {
        let topology = twoDisplayTopology()
        XCTAssertEqual(topology.selectWindowSpace(from: [4, 2]), 2)
    }

    func testSelectWindowSpaceFallsBackToCurrentFullscreen() {
        let topology = SpaceTopology(
            displays: [
                SpaceTopology.DisplaySpaces(displayIdentifier: "d", spaceIds: [5], currentSpaceId: 5)
            ],
            activeSpaceId: 5,
            fullscreenSpaceIds: [5],
            windowSpace: [:]
        )
        XCTAssertEqual(topology.selectWindowSpace(from: [5]), 5)
    }

    func testSelectWindowSpaceFallsBackToFirstNonzero() {
        let topology = twoDisplayTopology()
        XCTAssertEqual(topology.selectWindowSpace(from: [0, 777, 888]), 777)
    }

    func testSelectWindowSpaceReturnsNilForEmptyOrZero() {
        let topology = twoDisplayTopology()
        XCTAssertNil(topology.selectWindowSpace(from: []))
        XCTAssertNil(topology.selectWindowSpace(from: [0]))
    }
}
