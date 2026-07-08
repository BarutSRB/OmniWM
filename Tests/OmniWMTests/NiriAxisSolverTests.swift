// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriAxisSolverTests: XCTestCase {
    private func auto(weight: CGFloat = 1, min: CGFloat = 1, max: CGFloat = 0) -> NiriAxisSolver.Input {
        NiriAxisSolver.Input(
            weight: weight,
            minConstraint: min,
            maxConstraint: max,
            hasMaxConstraint: max > 0,
            isConstraintFixed: false,
            hasFixedValue: false,
            fixedValue: nil
        )
    }

    private func fixed(value: CGFloat, min: CGFloat = 1) -> NiriAxisSolver.Input {
        NiriAxisSolver.Input(
            weight: 1,
            minConstraint: min,
            maxConstraint: 0,
            hasMaxConstraint: false,
            isConstraintFixed: false,
            hasFixedValue: true,
            fixedValue: value
        )
    }

    func testFeasibleMinsArePinnedExactly() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 600), auto(min: 100)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 600, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 400, accuracy: 0.001)
    }

    func testInfeasibleEqualMinsScaleProportionally() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 800), auto(min: 800)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 500, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 500, accuracy: 0.001)
        XCTAssertTrue(outputs.allSatisfy(\.wasConstrained))
    }

    func testInfeasibleUnequalMinsPreserveRatioWithoutCollapse() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 900), auto(min: 300)],
            availableSpace: 800,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 600, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 200, accuracy: 0.001)
    }

    func testInfeasibleIgnoresFixedValues() {
        let outputs = NiriAxisSolver.solve(
            windows: [fixed(value: 900, min: 100), auto(min: 700)],
            availableSpace: 600,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 75, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 525, accuracy: 0.001)
    }

    func testFeasibleFixedSurplusScalingKeepsEveryFixedTileAboveItsMin() {
        let outputs = NiriAxisSolver.solve(
            windows: [fixed(value: 900, min: 100), fixed(value: 300, min: 290)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertGreaterThanOrEqual(outputs[0].value, 100)
        XCTAssertGreaterThanOrEqual(outputs[1].value, 290)
        XCTAssertEqual(outputs[0].value + outputs[1].value, 1000, accuracy: 0.01)
    }

    func testDegenerateSpaceKeepsOnePixelBackstop() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 500), auto(min: 500)],
            availableSpace: 0,
            gapSize: 0
        )
        XCTAssertTrue(outputs.allSatisfy { $0.value >= 1 })
    }

    func testTabbedOversizedMinOverflows() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 2000), auto(min: 100)],
            availableSpace: 1000,
            gapSize: 0,
            isTabbed: true
        )
        XCTAssertEqual(outputs[0].value, 2000, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 2000, accuracy: 0.001)
    }
}
