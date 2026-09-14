// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class FrameSizeGeometryTests: XCTestCase {
    func testFrameToleranceIncludesBoundaryOnBothDimensions() {
        let size = CGSize(width: 100, height: 200)
        XCTAssertTrue(size.isWithinFrameTolerance(of: CGSize(width: 101, height: 199)))
        XCTAssertTrue(size.isWithinFrameTolerance(of: CGSize(width: 99, height: 201)))
        XCTAssertFalse(size.isWithinFrameTolerance(of: CGSize(width: CGFloat(101).nextUp, height: 200)))
        XCTAssertFalse(size.isWithinFrameTolerance(of: CGSize(width: 100, height: CGFloat(201).nextUp)))
    }

    func testFrameToleranceRejectsNonfiniteDifferences() {
        let size = CGSize(width: 100, height: 200)
        for invalid in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertFalse(size.isWithinFrameTolerance(of: CGSize(width: invalid, height: 200)))
            XCTAssertFalse(size.isWithinFrameTolerance(of: CGSize(width: 100, height: invalid)))
            XCTAssertFalse(CGSize(width: invalid, height: 200).isWithinFrameTolerance(of: size))
            XCTAssertFalse(CGSize(width: 100, height: invalid).isWithinFrameTolerance(of: size))
        }
    }

    func testFinitePositiveDimensionsRejectInvalidAndEmptySizes() {
        XCTAssertTrue(CGSize(width: CGFloat.leastNonzeroMagnitude, height: 1).hasFinitePositiveDimensions())
        for invalid in [CGFloat.zero, -1, .nan, .infinity, -.infinity] {
            XCTAssertFalse(CGSize(width: invalid, height: 1).hasFinitePositiveDimensions())
            XCTAssertFalse(CGSize(width: 1, height: invalid).hasFinitePositiveDimensions())
        }
    }
}
