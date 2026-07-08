// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriColumnMinWidthTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let gaps: CGFloat = 12

    private func makeSingleWindowEngine() -> (NiriLayoutEngine, WorkspaceDescriptor.ID, WindowToken, NiriContainer) {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let column = engine.columns(in: workspaceId)[0]
        return (engine, workspaceId, token, column)
    }

    private func minConstraints(width: CGFloat = 1, height: CGFloat = 1) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: CGSize(width: width, height: height),
            maxSize: .zero,
            isFixed: false
        )
    }

    func testBalanceSizesRespectsMinWidth() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800))

        XCTAssertTrue(
            engine.balanceSizes(
                in: workspaceId,
                motion: .disabled,
                workingAreaWidth: workingFrame.width,
                gaps: gaps
            )
        )
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testSetColumnWidthBelowMinSettlesAtMin() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800))
        var state = ViewportState()

        engine.setColumnWidth(
            column,
            change: .setFixed(200),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testOversizedMinWidthIsKeptBeyondWorkArea() {
        let (engine, _, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 2000))

        column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)

        XCTAssertEqual(column.cachedWidth, 2000, accuracy: 0.001)
    }

    func testToggleFullWidthRestoreRespectsMin() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800))
        var state = ViewportState()

        engine.toggleFullWidth(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
        XCTAssertGreaterThanOrEqual(column.cachedWidth, 800)

        engine.toggleFullWidth(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testConstraintArrivalRetargetsActiveAnimationWithoutSnapping() {
        let (engine, _, token, column) = makeSingleWindowEngine()
        column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        let widthBeforeConstraint = column.cachedWidth

        column.animateWidthTo(
            newWidth: 400,
            clock: nil,
            config: .niriWindowMovement,
            displayRefreshRate: 60,
            animated: true
        )
        XCTAssertEqual(column.targetWidth, 400)

        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800))

        XCTAssertEqual(column.targetWidth, 800)
        XCTAssertEqual(column.cachedWidth, widthBeforeConstraint, accuracy: 0.001)

        _ = column.tickWidthAnimation(at: CACurrentMediaTime() + 30)
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testConstraintArrivalWithoutAnimationReclampsImmediately() {
        let (engine, _, token, column) = makeSingleWindowEngine()
        column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        XCTAssertLessThan(column.cachedWidth, 800)

        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800))

        XCTAssertNil(column.targetWidth)
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testTickFloorPreventsUndershootBelowMinClampedTarget() {
        var rawMinAcrossVelocities = CGFloat.greatestFiniteMagnitude
        for initialVelocity in [-8000.0, 8000.0] {
            let spring = SpringAnimation(
                from: 950,
                to: 800,
                initialVelocity: initialVelocity,
                startTime: 0,
                config: .niriWindowMovement,
                displayRefreshRate: 60
            )
            let (_, _, _, column) = makeSingleWindowEngine()
            column.cachedWidth = 950
            column.widthAnimation = spring
            column.targetWidth = 800

            var flooredMin = CGFloat.greatestFiniteMagnitude
            for tick in stride(from: 0.0, through: 1.0, by: 0.002) {
                rawMinAcrossVelocities = min(rawMinAcrossVelocities, CGFloat(spring.value(at: tick)))
                if column.widthAnimation != nil {
                    _ = column.tickWidthAnimation(at: tick)
                    flooredMin = min(flooredMin, column.cachedWidth)
                }
            }

            XCTAssertGreaterThanOrEqual(flooredMin, 800)
        }
        XCTAssertLessThan(rawMinAcrossVelocities, 800)
    }

    func testCachedHeightReclampedOnConstraintArrival() {
        let (engine, _, token, column) = makeSingleWindowEngine()
        column.cachedHeight = 300

        engine.updateWindowConstraints(for: token, constraints: minConstraints(height: 700))

        XCTAssertEqual(column.cachedHeight, 700, accuracy: 0.001)
    }
}
