// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarPanelGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func monitor(
        frame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 875),
        hasNotch: Bool = false,
        notchRange: ClosedRange<CGFloat>? = nil
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: visibleFrame,
            hasNotch: hasNotch,
            notchRange: notchRange,
            name: "Test"
        )
    }

    private func resolved(
        position: WorkspaceBarPosition = .belowMenuBar,
        notchMode: WorkspaceBarNotchMode = .off,
        height: Double = 24,
        xOffset: Double = 0,
        yOffset: Double = 0
    ) -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: true,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            reserveLayoutSpace: false,
            notchMode: notchMode,
            notchActiveZoneWidth: 300,
            systemStatsButton: false,
            position: position,
            windowLevel: .status,
            height: height,
            backgroundOpacity: 0.5,
            xOffset: xOffset,
            yOffset: yOffset,
            accentColor: nil,
            textColor: nil
        )
    }

    func testCentersUnderAnchor() {
        let frame = HiddenBarPanelController.panelFrame(
            anchor: CGPoint(x: 720, y: 900),
            size: CGSize(width: 200, height: 60),
            screenVisibleFrame: screen
        )
        XCTAssertEqual(frame.midX, 720, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 896, accuracy: 0.5)
    }

    func testClampsRightEdge() {
        let frame = HiddenBarPanelController.panelFrame(
            anchor: CGPoint(x: 1435, y: 900),
            size: CGSize(width: 200, height: 60),
            screenVisibleFrame: screen
        )
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 8 + 0.5)
    }

    func testClampsLeftEdge() {
        let frame = HiddenBarPanelController.panelFrame(
            anchor: CGPoint(x: 5, y: 900),
            size: CGSize(width: 200, height: 60),
            screenVisibleFrame: screen
        )
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + 8 - 0.5)
    }

    func testNarrowScreenPinsToMinX() {
        let narrow = CGRect(x: 100, y: 0, width: 150, height: 900)
        let frame = HiddenBarPanelController.panelFrame(
            anchor: CGPoint(x: 175, y: 900),
            size: CGSize(width: 200, height: 60),
            screenVisibleFrame: narrow
        )
        XCTAssertEqual(frame.minX, narrow.minX + 8, accuracy: 0.5)
    }

    func testAnchorBelowMenuBarHangsUnderIsland() {
        let anchor = HiddenBarPanelController.panelAnchor(
            monitor: monitor(),
            resolved: resolved(position: .belowMenuBar),
            barVisible: true
        )
        XCTAssertEqual(anchor, CGPoint(x: 720, y: 851))
    }

    func testAnchorOverlappingMenuBarHangsBelowBand() {
        let anchor = HiddenBarPanelController.panelAnchor(
            monitor: monitor(),
            resolved: resolved(position: .overlappingMenuBar),
            barVisible: true
        )
        XCTAssertEqual(anchor, CGPoint(x: 720, y: 875))
    }

    func testAnchorAppliesOffsets() {
        let anchor = HiddenBarPanelController.panelAnchor(
            monitor: monitor(),
            resolved: resolved(position: .belowMenuBar, xOffset: 10, yOffset: -5),
            barVisible: true
        )
        XCTAssertEqual(anchor, CGPoint(x: 730, y: 846))
    }

    func testAnchorFallsBackBelowMenuBarWhenBarHidden() {
        let anchor = HiddenBarPanelController.panelAnchor(
            monitor: monitor(),
            resolved: resolved(position: .overlappingMenuBar, xOffset: 50, yOffset: 50),
            barVisible: false
        )
        XCTAssertEqual(anchor, CGPoint(x: 720, y: 875))
    }

    func testAnchorNotchMoveBelowMenuBarDropsByBarHeight() {
        let anchor = HiddenBarPanelController.panelAnchor(
            monitor: monitor(hasNotch: true, notchRange: 650 ... 790),
            resolved: resolved(position: .overlappingMenuBar, notchMode: .moveBelowMenuBar),
            barVisible: true
        )
        XCTAssertEqual(anchor, CGPoint(x: 720, y: 851))
    }

    func testAnchorSplitModeKeepsSameOriginY() {
        let anchor = HiddenBarPanelController.panelAnchor(
            monitor: monitor(hasNotch: true, notchRange: 650 ... 790),
            resolved: resolved(position: .overlappingMenuBar, notchMode: .splitActiveLeft),
            barVisible: true
        )
        XCTAssertEqual(anchor, CGPoint(x: 720, y: 875))
    }

    func testBarSizeEmptyIsCompact() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [],
            rowHeight: 24,
            maxContentWidth: 600,
            spacing: 8,
            padding: 8
        )
        XCTAssertEqual(size, CGSize(width: 140, height: 40))
    }

    func testBarSizeSingleRowWhenItemsFit() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [30, 30, 30],
            rowHeight: 24,
            maxContentWidth: 600,
            spacing: 8,
            padding: 8
        )
        XCTAssertEqual(size, CGSize(width: 30 * 3 + 8 * 2 + 16, height: 24 + 16))
    }

    func testBarSizeWrapsWhenExceedingMaxWidth() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [30, 30, 30],
            rowHeight: 24,
            maxContentWidth: 70,
            spacing: 8,
            padding: 8
        )
        XCTAssertEqual(size.height, 24 * 2 + 8 + 16)
        XCTAssertEqual(size.width, 30 + 8 + 30 + 16)
    }

    func testRowRangesGreedyBoundaries() {
        let ranges = HiddenBarPanelController.rowRanges(
            itemWidths: [30, 30, 30],
            maxContentWidth: 70,
            spacing: 8
        )
        XCTAssertEqual(ranges, [0 ..< 2, 2 ..< 3])
    }

    func testRowRangesOversizeItemGetsOwnRow() {
        let ranges = HiddenBarPanelController.rowRanges(
            itemWidths: [200, 30],
            maxContentWidth: 100,
            spacing: 8
        )
        XCTAssertEqual(ranges, [0 ..< 1, 1 ..< 2])
    }

    func testGlyphDisplayWidthScalesDownTallGlyphs() {
        let width = HiddenBarPanelController.glyphDisplayWidth(
            for: CGSize(width: 40, height: 40),
            rowHeight: 24
        )
        XCTAssertEqual(width, 24)
    }

    func testGlyphDisplayWidthGuaranteesMinimumTarget() {
        let width = HiddenBarPanelController.glyphDisplayWidth(
            for: CGSize(width: 16, height: 16),
            rowHeight: 24
        )
        XCTAssertEqual(width, 24)
    }
}
