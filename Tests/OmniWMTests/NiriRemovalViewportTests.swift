// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

/// Regression tests for issue #498: closing a column must not leave the viewport
/// straddling space the remaining columns no longer occupy.
@MainActor
final class NiriRemovalViewportTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let workingFrame: CGRect
        let gap: CGFloat
        var state: ViewportState
    }

    private func makeFixture(
        widths: [CGFloat],
        gap: CGFloat,
        span: CGFloat
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        var tokens: [WindowToken] = []
        for index in 0 ..< widths.count {
            let token = WindowToken(pid: 1, windowId: index + 1)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            tokens.append(token)
        }
        let columns = engine.columns(in: workspaceId)
        for (column, width) in zip(columns, widths) {
            column.cachedWidth = width
        }

        var state = ViewportState()
        let lastIdx = columns.count - 1
        state.activeColumnIndex = lastIdx
        state.selectedNodeId = columns[lastIdx].windowNodes.first?.id
        let lastColX = state.columnX(at: lastIdx, columns: columns, gap: gap)
        state.viewOffset = (lastColX + widths[lastIdx] - span) - lastColX

        return Fixture(
            engine: engine,
            workspaceId: workspaceId,
            tokens: tokens,
            workingFrame: CGRect(x: 0, y: 0, width: span, height: 800),
            gap: gap,
            state: state
        )
    }

    private func removeToken(at index: Int, from fixture: inout Fixture) {
        _ = fixture.engine.removeWindows(
            [fixture.tokens[index]],
            in: fixture.workspaceId,
            state: &fixture.state,
            motion: .disabled,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            selectedNodeId: fixture.state.selectedNodeId,
            removedNodeIds: []
        )
    }

    private func assertViewportSane(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        XCTAssertFalse(columns.isEmpty, "expected surviving columns", file: file, line: line)

        let gap = fixture.gap
        let span = fixture.workingFrame.width
        let activePos = fixture.state.columnX(
            at: fixture.state.activeColumnIndex,
            columns: columns,
            gap: gap
        )
        let viewStart = activePos + fixture.state.viewOffset
        let total = fixture.state.totalWidth(columns: columns, gap: gap)
        let contentEdge = total - span + gap

        XCTAssertGreaterThanOrEqual(
            viewStart,
            min(-gap, contentEdge) - 1,
            "viewport shows void left of the remaining columns",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            viewStart,
            max(-gap, contentEdge) + 1,
            "viewport shows void right of the remaining columns",
            file: file,
            line: line
        )

        guard let selectedId = fixture.state.selectedNodeId,
              let node = fixture.engine.findNode(by: selectedId, in: fixture.workspaceId),
              let column = fixture.engine.column(of: node),
              let columnIdx = fixture.engine.columnIndex(of: column, in: fixture.workspaceId)
        else {
            return XCTFail("no valid selection after removal", file: file, line: line)
        }
        let selX = fixture.state.columnX(at: columnIdx, columns: columns, gap: gap)
        XCTAssertGreaterThanOrEqual(selX, viewStart - 1, "focused column cut on the left", file: file, line: line)
        XCTAssertLessThanOrEqual(
            selX + columns[columnIdx].cachedWidth,
            viewStart + span + 1,
            "focused column cut on the right",
            file: file,
            line: line
        )
    }

    /// Issue #498: focus-follows-mouse refocuses the neighbor before the AX destroy
    /// event arrives, so the removal lands right of the already-active column and
    /// previously skipped every viewport recalculation.
    func testCloseRightmostAfterFocusMovedToNeighbor() {
        var fixture = makeFixture(widths: [700, 700, 700], gap: 8, span: 1440)

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let neighbor = columns[1].windowNodes[0]
        fixture.state.selectedNodeId = neighbor.id
        fixture.engine.ensureSelectionVisible(
            node: neighbor,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap
        )

        removeToken(at: fixture.tokens.count - 1, from: &fixture)

        assertViewportSane(fixture)

        let remaining = fixture.engine.columns(in: fixture.workspaceId)
        let activePos = fixture.state.columnX(
            at: fixture.state.activeColumnIndex,
            columns: remaining,
            gap: fixture.gap
        )
        let viewStart = activePos + fixture.state.viewOffset
        for (idx, column) in remaining.enumerated() {
            let x = fixture.state.columnX(at: idx, columns: remaining, gap: fixture.gap)
            XCTAssertGreaterThanOrEqual(
                x,
                viewStart - fixture.gap - 1,
                "column \(idx) pushed off-screen left even though everything fits"
            )
            XCTAssertLessThanOrEqual(
                x + column.cachedWidth,
                viewStart + fixture.workingFrame.width + fixture.gap + 1,
                "column \(idx) pushed off-screen right even though everything fits"
            )
        }
    }

    func testCloseRightmostFocusedColumn() {
        var fixture = makeFixture(widths: [500, 500, 500], gap: 8, span: 1000)
        removeToken(at: fixture.tokens.count - 1, from: &fixture)
        assertViewportSane(fixture)
    }

    func testCloseRightmostWithStaleRestoreOffset() {
        var fixture = makeFixture(widths: [500, 500, 500], gap: 0, span: 1000)
        fixture.state.activatePrevColumnOnRemoval = 300
        removeToken(at: fixture.tokens.count - 1, from: &fixture)
        assertViewportSane(fixture)
    }

    /// Removing a column left of the active one rebases the offset to keep the view origin
    /// stationary, but the strip is now shorter: viewing the far right end must not leave
    /// the viewport hanging past the remaining content.
    func testCloseLeftmostWhileViewingFarRight() {
        var fixture = makeFixture(widths: [500, 500, 500], gap: 0, span: 1000)
        removeToken(at: 0, from: &fixture)
        assertViewportSane(fixture)
    }
}
