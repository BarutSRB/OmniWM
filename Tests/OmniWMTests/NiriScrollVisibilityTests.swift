// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriScrollVisibilityTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let area: WorkingAreaContext
    }

    private func makeFiveColumnFixture() -> Fixture {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        var tokens: [WindowToken] = []
        for index in 0 ..< 5 {
            let token = WindowToken(pid: 1, windowId: index + 1)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            tokens.append(token)
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 1000
        }
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let area = WorkingAreaContext(
            workingFrame: frame,
            fullscreenLayoutFrame: frame,
            viewFrame: frame,
            scale: 1
        )
        return Fixture(engine: engine, workspaceId: workspaceId, tokens: tokens, area: area)
    }

    private func hiddenHandles(
        _ fixture: Fixture,
        viewOffsetOverride: CGFloat?,
        settledVisibilityOffset: CGFloat?
    ) -> [WindowToken: HideSide] {
        fixture.engine.calculateLayoutWithVisibility(
            state: ViewportState(),
            workspaceId: fixture.workspaceId,
            monitorFrame: fixture.area.workingFrame,
            screenFrame: fixture.area.viewFrame,
            gaps: (horizontal: 0, vertical: 0),
            scale: 1,
            workingArea: fixture.area,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset
        ).hiddenHandles
    }

    func testLiveVisibleColumnStaysVisibleMidTransit() {
        let fixture = makeFiveColumnFixture()

        let handles = hiddenHandles(
            fixture,
            viewOffsetOverride: 2000,
            settledVisibilityOffset: 4000
        )

        XCTAssertNil(handles[fixture.tokens[2]])
        XCTAssertNil(handles[fixture.tokens[4]])
        XCTAssertEqual(handles[fixture.tokens[0]], .left)
        XCTAssertEqual(handles[fixture.tokens[1]], .left)
        XCTAssertEqual(handles[fixture.tokens[3]], .left)
    }

    func testNoSettledOffsetKeepsLiveVisibilityForGestures() {
        let fixture = makeFiveColumnFixture()

        let handles = hiddenHandles(
            fixture,
            viewOffsetOverride: 2000,
            settledVisibilityOffset: nil
        )

        XCTAssertNil(handles[fixture.tokens[2]])
        XCTAssertEqual(handles[fixture.tokens[0]], .left)
        XCTAssertEqual(handles[fixture.tokens[4]], .right)
    }

    func testLayoutDiffReassertsHideOnSettlePass() {
        let handler = NiriLayoutHandler(controller: nil)
        let engine = NiriLayoutEngine()
        let token = WindowToken(pid: 1, windowId: 1)
        let window = LayoutWindowSnapshot(
            token: token,
            constraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            layoutConstraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            hiddenState: HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            layoutReason: .standard
        )

        let steady = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false
        )
        XCTAssertTrue(steady.visibilityChanges.isEmpty)

        let settle = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: true
        )
        XCTAssertEqual(settle.visibilityChanges.count, 1)
        guard case let .hide(hiddenToken, side) = settle.visibilityChanges[0] else {
            return XCTFail("expected hide re-assertion on settle pass")
        }
        XCTAssertEqual(hiddenToken, token)
        XCTAssertEqual(side, .left)
    }

    func testLayoutDiffReemitsHideForPendingPark() {
        let handler = NiriLayoutHandler(controller: nil)
        let engine = NiriLayoutEngine()
        let token = WindowToken(pid: 1, windowId: 1)
        let window = LayoutWindowSnapshot(
            token: token,
            constraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            layoutConstraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            hiddenState: HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            layoutReason: .standard
        )

        let pending = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false,
            pendingParkWindowIds: [token.windowId]
        )
        XCTAssertEqual(pending.visibilityChanges.count, 1)
        guard case let .hide(pendingToken, pendingSide) = pending.visibilityChanges[0] else {
            return XCTFail("expected hide re-emission for pending park")
        }
        XCTAssertEqual(pendingToken, token)
        XCTAssertEqual(pendingSide, .left)

        let confirmed = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false,
            pendingParkWindowIds: [999]
        )
        XCTAssertTrue(confirmed.visibilityChanges.isEmpty)
    }
}
