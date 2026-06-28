// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class LaunchOverlayTests: XCTestCase {
    func testEmptyScreensCompletesSynchronously() {
        let controller = LaunchOverlayController()
        var completions = 0
        controller.play(screens: []) { completions += 1 }
        XCTAssertEqual(completions, 1)
    }

    func testWordmarkPathIsNonEmpty() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertFalse(OmniWMBrandMark.omniWordmarkPath(in: rect).isEmpty)
        XCTAssertGreaterThan(OmniWMBrandMark.omniWordmarkAspect, 0)
    }

    func testStatusItemImageIsUntinted() {
        let image = OmniWMBrandMark.statusItemImage(pointSize: 18)
        XCTAssertFalse(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testDwindleChoreographyTrackInvariants() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tracks = DwindleBuildChoreography(bounds: bounds, gap: 10).tracks
        XCTAssertEqual(tracks.count, 5)
        for track in tracks {
            let count = track.positions.count
            XCTAssertEqual(track.sizes.count, count)
            XCTAssertEqual(track.opacities.count, count)
            XCTAssertEqual(track.keyTimes.count, count)
            XCTAssertEqual(track.timings.count, count - 1)
            XCTAssertEqual(track.keyTimes, track.keyTimes.sorted())
            XCTAssertEqual(track.keyTimes.first ?? -1, 0, accuracy: 1e-9)
            XCTAssertEqual(track.keyTimes.last ?? -1, 1, accuracy: 1e-9)
            XCTAssertEqual(track.opacities.first ?? -1, 0, accuracy: 1e-9)
            XCTAssertEqual(track.opacities.last ?? -1, 1, accuracy: 1e-9)
        }
    }

    func testDwindleChoreographyStageTileEndsAsLeftHalf() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let gap = 10.0
        let track = DwindleBuildChoreography(bounds: bounds, gap: gap).tracks[0]
        let finalSize = try XCTUnwrap(track.sizes.last)
        XCTAssertEqual(finalSize.width, 0.5 * bounds.width - gap, accuracy: 0.001)
        XCTAssertEqual(finalSize.height, bounds.height - gap, accuracy: 0.001)
    }
}
