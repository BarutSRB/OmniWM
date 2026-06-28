// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class ResolvedLayoutConstraintsTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 2560, height: 1410)

    private func constraints(minHeight: CGFloat, minWidth: CGFloat = 100) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: CGSize(width: minWidth, height: minHeight),
            maxSize: .zero,
            isFixed: false
        )
    }

    private func hidden(_ reason: HiddenReason) -> HiddenState {
        HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: reason)
    }

    private func resolve(
        _ constraints: WindowSizeConstraints,
        layoutReason: LayoutReason = .standard,
        hiddenState: HiddenState? = nil,
        workingFrame: CGRect? = nil
    ) -> WindowSizeConstraints {
        LayoutRefreshController.resolvedLayoutConstraints(
            for: constraints,
            layoutReason: layoutReason,
            hiddenState: hiddenState,
            workingFrame: workingFrame ?? self.workingFrame
        )
    }

    func testVisibleFittingMinIsKept() {
        let result = resolve(constraints(minHeight: 600))
        XCTAssertEqual(result.minSize.height, 600)
    }

    func testVisibleOversizedMinIsRelaxed() {
        let result = resolve(constraints(minHeight: 2000))
        XCTAssertEqual(result.minSize.height, 1)
        XCTAssertEqual(result.minSize.width, 1)
    }

    func testLayoutTransientFittingMinIsKept() {
        let result = resolve(constraints(minHeight: 600), hiddenState: hidden(.layoutTransient(.left)))
        XCTAssertEqual(result.minSize.height, 600)
    }

    func testLayoutTransientOversizedMinIsRelaxed() {
        let result = resolve(constraints(minHeight: 2000), hiddenState: hidden(.layoutTransient(.right)))
        XCTAssertEqual(result.minSize.height, 1)
    }

    func testWorkspaceInactiveMinIsRelaxed() {
        let result = resolve(constraints(minHeight: 600), hiddenState: hidden(.workspaceInactive))
        XCTAssertEqual(result.minSize.height, 1)
    }

    func testScratchpadMinIsRelaxed() {
        let result = resolve(constraints(minHeight: 600), hiddenState: hidden(.scratchpad))
        XCTAssertEqual(result.minSize.height, 1)
    }

    func testNativeFullscreenKeepsConstraints() {
        let result = resolve(constraints(minHeight: 600), layoutReason: .nativeFullscreen)
        XCTAssertEqual(result.minSize.height, 600)
    }

    func testFixedConstraintsAreKept() {
        let fixed = WindowSizeConstraints.fixed(size: CGSize(width: 800, height: 600))
        let result = resolve(fixed)
        XCTAssertTrue(result.isFixed)
        XCTAssertEqual(result.minSize.height, 600)
        XCTAssertEqual(result.minSize.width, 800)
    }

    func testNilWorkingFrameRelaxes() {
        let result = LayoutRefreshController.resolvedLayoutConstraints(
            for: constraints(minHeight: 600),
            layoutReason: .standard,
            hiddenState: nil,
            workingFrame: nil
        )
        XCTAssertEqual(result.minSize.height, 1)
    }

    func testToleranceBoundary() {
        let kept = resolve(constraints(minHeight: workingFrame.height + 0.5))
        XCTAssertEqual(kept.minSize.height, workingFrame.height + 0.5)

        let relaxed = resolve(constraints(minHeight: workingFrame.height + 0.6))
        XCTAssertEqual(relaxed.minSize.height, 1)
    }
}
