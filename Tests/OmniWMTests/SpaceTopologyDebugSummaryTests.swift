// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SpaceTopologyDebugSummaryTests: XCTestCase {
    func testDebugSummaryFormatsDisplaysAndWindowMemberships() {
        let topology = SpaceTopology(
            displays: [
                SpaceTopology.DisplaySpaces(displayIdentifier: "DisplayA", spaceIds: [1, 2], currentSpaceId: 1),
                SpaceTopology.DisplaySpaces(displayIdentifier: "DisplayB", spaceIds: [3], currentSpaceId: 3)
            ],
            activeSpaceId: 1,
            fullscreenSpaceIds: [2],
            windowSpace: [200: 3, 100: 1]
        )

        let text = topology.debugSummary
        XCTAssertTrue(text.contains("active=1 populated=true fullscreen=[2]"))
        XCTAssertTrue(text.contains("display=DisplayA current=1 spaces=[1,2]"))
        XCTAssertTrue(text.contains("display=DisplayB current=3 spaces=[3]"))

        let windowLines = text.split(separator: "\n").filter { $0.hasPrefix("window=") }
        XCTAssertEqual(windowLines, ["window=100 space=1", "window=200 space=3"])
    }

    func testDebugSummaryReportsNoneWhenEmpty() {
        XCTAssertEqual(SpaceTopology().debugSummary, "none")
    }
}
