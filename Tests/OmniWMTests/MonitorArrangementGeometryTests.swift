// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class MonitorArrangementGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 1e-6

    func testEmptyInputReturnsEmpty() {
        let rects = MonitorArrangementGeometry.canvasRects(
            forFramesYUp: [],
            in: CGSize(width: 200, height: 120),
            padding: 8
        )
        XCTAssertTrue(rects.isEmpty)
    }

    func testSideBySidePreservesAspectAndUniformScale() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1280, height: 1024)
        ]
        let rects = MonitorArrangementGeometry.canvasRects(
            forFramesYUp: frames,
            in: CGSize(width: 400, height: 240),
            padding: 10
        )

        XCTAssertEqual(rects.count, frames.count)
        assertAspectAndUniformScale(frames: frames, rects: rects)
    }

    func testStackedPreservesAspectAndUniformScale() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1600, height: 900),
            CGRect(x: 0, y: 900, width: 1600, height: 1200)
        ]
        let rects = MonitorArrangementGeometry.canvasRects(
            forFramesYUp: frames,
            in: CGSize(width: 320, height: 480),
            padding: 6
        )

        XCTAssertEqual(rects.count, frames.count)
        assertAspectAndUniformScale(frames: frames, rects: rects)
    }

    func testHigherYUpMonitorAppearsAtTop() {
        let lower = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let upper = CGRect(x: 0, y: 600, width: 1000, height: 600)
        let rects = MonitorArrangementGeometry.canvasRects(
            forFramesYUp: [lower, upper],
            in: CGSize(width: 300, height: 400),
            padding: 5
        )

        XCTAssertLessThan(rects[1].minY, rects[0].minY)
    }

    func testRectsStayWithinCanvasAndAreCentered() {
        let canvas = CGSize(width: 500, height: 300)
        let padding: CGFloat = 12
        let frames = [
            CGRect(x: -1440, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 0, width: 1920, height: 1080)
        ]
        let rects = MonitorArrangementGeometry.canvasRects(
            forFramesYUp: frames,
            in: canvas,
            padding: padding
        )

        let unionMinX = rects.map(\.minX).min() ?? 0
        let unionMaxX = rects.map(\.maxX).max() ?? 0
        let unionMinY = rects.map(\.minY).min() ?? 0
        let unionMaxY = rects.map(\.maxY).max() ?? 0

        XCTAssertGreaterThanOrEqual(unionMinX, padding - accuracy)
        XCTAssertLessThanOrEqual(unionMaxX, canvas.width - padding + accuracy)
        XCTAssertGreaterThanOrEqual(unionMinY, padding - accuracy)
        XCTAssertLessThanOrEqual(unionMaxY, canvas.height - padding + accuracy)

        let leftGap = unionMinX
        let rightGap = canvas.width - unionMaxX
        let topGap = unionMinY
        let bottomGap = canvas.height - unionMaxY
        XCTAssertEqual(leftGap, rightGap, accuracy: 1e-4)
        XCTAssertEqual(topGap, bottomGap, accuracy: 1e-4)
    }

    func testYFlipRoundTripThroughNegativeAndPositiveOrigins() {
        let canvas = CGSize(width: 360, height: 240)
        let padding: CGFloat = 14
        let frames = [
            CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            CGRect(x: 0, y: 300, width: 1280, height: 800)
        ]
        let rects = MonitorArrangementGeometry.canvasRects(
            forFramesYUp: frames,
            in: canvas,
            padding: padding
        )

        for index in frames.indices {
            let logicalCenter = CGPoint(x: frames[index].midX, y: frames[index].midY)
            let canvasCenter = CGPoint(x: rects[index].midX, y: rects[index].midY)
            let restored = MonitorArrangementGeometry.logicalPointYUp(
                forCanvasPoint: canvasCenter,
                framesYUp: frames,
                in: canvas,
                padding: padding
            )
            XCTAssertEqual(restored.x, logicalCenter.x, accuracy: accuracy)
            XCTAssertEqual(restored.y, logicalCenter.y, accuracy: accuracy)
        }
    }

    private func assertAspectAndUniformScale(frames: [CGRect], rects: [CGRect]) {
        for index in frames.indices {
            let frame = frames[index]
            let rect = rects[index]
            let inputRatio = frame.width / frame.height
            let outputRatio = rect.width / rect.height
            XCTAssertEqual(outputRatio, inputRatio, accuracy: 1e-4)

            let scaleX = rect.width / frame.width
            let scaleY = rect.height / frame.height
            XCTAssertEqual(scaleX, scaleY, accuracy: 1e-4)
        }
    }
}
