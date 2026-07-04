// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class GhosttySurfaceSizingTests: XCTestCase {
    func testNormalizeScalesPointSizeByBackingScale() {
        let metrics = GhosttySurfaceCellMetrics(cellWidthPx: 8, cellHeightPx: 16)
        let oneX = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 800, height: 400),
            backingScale: 1,
            cellMetrics: metrics
        )
        let twoX = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 800, height: 400),
            backingScale: 2,
            cellMetrics: metrics
        )
        XCTAssertEqual(oneX, GhosttySurfacePixelSize(widthPx: 800, heightPx: 400))
        XCTAssertEqual(twoX, GhosttySurfacePixelSize(widthPx: 1600, heightPx: 800))
        XCTAssertNotEqual(oneX, twoX)
    }

    func testNormalizeChangesWithPointHeight() {
        let metrics = GhosttySurfaceCellMetrics(cellWidthPx: 8, cellHeightPx: 16)
        let external = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 1720, height: 656),
            backingScale: 2,
            cellMetrics: metrics
        )
        let builtIn = GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 756, height: 491),
            backingScale: 2,
            cellMetrics: metrics
        )
        XCTAssertNotNil(external)
        XCTAssertNotNil(builtIn)
        XCTAssertNotEqual(external, builtIn)
    }

    func testNormalizeRejectsNonPositiveInputs() {
        let metrics = GhosttySurfaceCellMetrics(cellWidthPx: 8, cellHeightPx: 16)
        XCTAssertNil(GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 0, height: 400),
            backingScale: 2,
            cellMetrics: metrics
        ))
        XCTAssertNil(GhosttySurfacePixelSizeNormalizer.normalize(
            pointSize: CGSize(width: 800, height: 400),
            backingScale: 0,
            cellMetrics: metrics
        ))
    }

    func testConfiguredFrameSizeDiffersPerVisibleFrame() {
        let external = QuakeTerminalGeometryPolicy.configuredFrameSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
            widthPercent: 50,
            heightPercent: 50
        )
        let builtIn = QuakeTerminalGeometryPolicy.configuredFrameSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            widthPercent: 50,
            heightPercent: 50
        )
        XCTAssertEqual(external, CGSize(width: 1720, height: 720))
        XCTAssertEqual(builtIn, CGSize(width: 756, height: 491))
        XCTAssertNotEqual(external, builtIn)
    }

    func testConfiguredFrameSizeClampsPercent() {
        let clamped = QuakeTerminalGeometryPolicy.configuredFrameSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            widthPercent: 0,
            heightPercent: 200
        )
        XCTAssertEqual(clamped, CGSize(width: 100, height: 1000))
    }

    @MainActor
    func testFocusedWindowDisplayIdPicksMonitorContainingWindowCenter() {
        let monitors = [
            makeMonitor(displayId: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            makeMonitor(displayId: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        ]
        let windowList: [[String: Any]] = [
            makeWindow(pid: 42, layer: 0, x: 1200, y: 100, width: 400, height: 300)
        ]
        let result = QuakeTerminalController.focusedWindowDisplayId(
            monitors: monitors,
            windowList: windowList,
            ownPID: 7,
            toAppKitRect: { $0 }
        )
        XCTAssertEqual(result, 2)
    }

    @MainActor
    func testFocusedWindowDisplayIdSkipsOwnPIDTinyAndNonZeroLayer() {
        let monitors = [makeMonitor(displayId: 1, frame: CGRect(x: 0, y: 0, width: 2000, height: 2000))]
        let windowList: [[String: Any]] = [
            makeWindow(pid: 7, layer: 0, x: 100, y: 100, width: 400, height: 300),
            makeWindow(pid: 42, layer: 5, x: 100, y: 100, width: 400, height: 300),
            makeWindow(pid: 42, layer: 0, x: 100, y: 100, width: 40, height: 40),
            makeWindow(pid: 99, layer: 0, x: 500, y: 500, width: 200, height: 200)
        ]
        let result = QuakeTerminalController.focusedWindowDisplayId(
            monitors: monitors,
            windowList: windowList,
            ownPID: 7,
            toAppKitRect: { $0 }
        )
        XCTAssertEqual(result, 1)
    }

    private func makeMonitor(displayId: CGDirectDisplayID, frame: CGRect) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "test-\(displayId)"
        )
    }

    private func makeWindow(
        pid: Int,
        layer: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height] as [String: Any]
        ]
    }
}
