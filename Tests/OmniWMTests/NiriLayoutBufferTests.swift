// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriLayoutBufferTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let area: WorkingAreaContext
        let tokens: Set<WindowToken>
    }

    func testPooledResultsMatchFreshResultsAndSurviveLaterPasses() throws {
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            let fixture = makeFixture(orientation: orientation)
            let expected = fresh(fixture)
            let retained = pooled(fixture)
            XCTAssertFalse(retained.frames.isEmpty)
            XCTAssertFalse(retained.hiddenHandles.isEmpty)
            XCTAssertEqual(retained.frames, expected.frames)
            XCTAssertEqual(retained.hiddenHandles, expected.hiddenHandles)
            let excluded: Set<WindowToken> = [try XCTUnwrap(fixture.tokens.min { $0.windowId < $1.windowId })]

            let changed = pooled(fixture, offset: 1000, excluding: excluded)
            let changedExpected = fresh(fixture, offset: 1000, excluding: excluded)
            XCTAssertEqual(changed.frames, changedExpected.frames)
            XCTAssertEqual(changed.hiddenHandles, changedExpected.hiddenHandles)
            XCTAssertEqual(changed.frames.count, retained.frames.count - 1)
            XCTAssertEqual(retained.frames, expected.frames)
            XCTAssertEqual(retained.hiddenHandles, expected.hiddenHandles)

            let empty = pooled(fixture, excluding: fixture.tokens)
            XCTAssertTrue(empty.frames.isEmpty)
            XCTAssertTrue(empty.hiddenHandles.isEmpty)
            XCTAssertEqual(retained.frames, expected.frames)
            XCTAssertEqual(retained.hiddenHandles, expected.hiddenHandles)
            XCTAssertEqual(changed.frames, changedExpected.frames)
            XCTAssertEqual(changed.hiddenHandles, changedExpected.hiddenHandles)
        }
    }

    func testPooledBuffersKeepCapacityAcrossEmptyAndRefilledLayouts() {
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            let fixture = makeFixture(orientation: orientation)
            let filled = pooled(fixture)
            XCTAssertFalse(filled.frames.isEmpty)
            XCTAssertFalse(filled.hiddenHandles.isEmpty)

            let empty = pooled(fixture, excluding: fixture.tokens)
            XCTAssertTrue(empty.frames.isEmpty)
            XCTAssertTrue(empty.hiddenHandles.isEmpty)
            XCTAssertGreaterThanOrEqual(empty.frames.capacity, filled.frames.capacity)
            XCTAssertGreaterThanOrEqual(empty.hiddenHandles.capacity, filled.hiddenHandles.capacity)

            let refilled = pooled(fixture)
            XCTAssertEqual(refilled.frames, filled.frames)
            XCTAssertEqual(refilled.hiddenHandles, filled.hiddenHandles)
            XCTAssertGreaterThanOrEqual(refilled.frames.capacity, filled.frames.capacity)
            XCTAssertGreaterThanOrEqual(refilled.hiddenHandles.capacity, filled.hiddenHandles.capacity)
        }
    }

    private func makeFixture(orientation: Monitor.Orientation) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = WorkspaceDescriptor.ID()
        var tokens: Set<WindowToken> = []
        for index in 0 ..< 6 {
            let token = WindowToken(pid: 730, windowId: index + 1)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            tokens.insert(token)
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 1000
            column.cachedHeight = 1000
        }
        let frame = orientation == .horizontal
            ? CGRect(x: -1000, y: -800, width: 1000, height: 800)
            : CGRect(x: -800, y: -1000, width: 800, height: 1000)
        let monitor = Monitor(
            id: .init(displayId: 991),
            displayId: 991,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Layout Buffer Test"
        )
        _ = engine.ensureMonitor(for: monitor.id, monitor: monitor, orientation: orientation)
        let area = WorkingAreaContext(workingFrame: frame, viewFrame: frame, scale: 2)
        return Fixture(engine: engine, workspaceId: workspaceId, monitor: monitor, area: area, tokens: tokens)
    }

    private func fresh(
        _ fixture: Fixture,
        offset: CGFloat = 0,
        excluding tokens: Set<WindowToken> = []
    ) -> LayoutResult {
        fixture.engine.calculateCombinedLayoutWithVisibility(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: LayoutGaps(horizontal: 0, vertical: 0),
            state: ViewportState(),
            workingArea: fixture.area,
            animationTime: 100,
            viewOffsetOverride: offset,
            excludedTokens: tokens
        )
    }

    private func pooled(
        _ fixture: Fixture,
        offset: CGFloat = 0,
        excluding tokens: Set<WindowToken> = []
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: LayoutGaps(horizontal: 0, vertical: 0),
            state: ViewportState(),
            workingArea: fixture.area,
            animationTime: 100,
            viewOffsetOverride: offset,
            excludedTokens: tokens
        )
    }
}
