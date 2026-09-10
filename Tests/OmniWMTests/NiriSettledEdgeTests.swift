// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriSettledEdgeTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let area: WorkingAreaContext
        let orientation: Monitor.Orientation
        let state: ViewportState
        let fringeIndex: Int
    }

    func testReportedEdgeStripsShrinkWithoutChangingPackedGeometry() throws {
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            for scale: CGFloat in [1, 2] {
                for origin: CGFloat in [0, -3440, 3440] {
                    for screenSpan: CGFloat in [3440, 1800] {
                        for border: CGFloat in [3.5, 0] {
                            for trailing in [false, true] {
                                let fixture = makeFixture(
                                    screenSpan: screenSpan,
                                    border: border,
                                    origin: origin,
                                    scale: scale,
                                    orientation: orientation,
                                    trailing: trailing
                                )
                                let moving = layout(fixture, isSettled: false)
                                let columns = fixture.engine.columns(in: fixture.workspaceId)
                                let canonicalFrames = columns.map(\.frame)
                                let widths = columns.map(\.cachedWidth)
                                let heights = columns.map(\.cachedHeight)
                                let settled = layout(fixture, isSettled: true)
                                let fringe = fixture.tokens[fixture.fringeIndex]
                                let before = try XCTUnwrap(moving.frames[fringe])
                                let after = try XCTUnwrap(settled.frames[fringe])
                                let contact = nativeContact(
                                    after,
                                    screen: fixture.area.viewFrame,
                                    orientation: orientation
                                )
                                let context = "span=\(screenSpan) border=\(border) origin=\(origin) scale=\(scale) orientation=\(orientation) trailing=\(trailing)"

                                XCTAssertGreaterThan(
                                    nativeContact(before, screen: fixture.area.viewFrame, orientation: orientation),
                                    2,
                                    context
                                )
                                XCTAssertGreaterThanOrEqual(contact, 1, context)
                                XCTAssertLessThanOrEqual(contact, 2, context)
                                XCTAssertEqual(before.size, after.size, context)
                                XCTAssertEqual(moving.hiddenHandles, settled.hiddenHandles, context)
                                for token in fixture.tokens where token != fringe {
                                    XCTAssertEqual(moving.frames[token], settled.frames[token], context)
                                }
                                XCTAssertEqual(columns.map(\.frame), canonicalFrames, context)
                                XCTAssertEqual(columns.map(\.cachedWidth), widths, context)
                                XCTAssertEqual(columns.map(\.cachedHeight), heights, context)
                                XCTAssertEqual(layout(fixture, isSettled: true).frames, settled.frames, context)
                            }
                        }
                    }
                }
            }
        }
    }

    func testLiveAndDestinationSamplingPreserveUnsettledReveal() throws {
        let fixture = makeFixture()
        let moving = layout(fixture, isSettled: false)
        let sampled = layout(
            fixture,
            isSettled: false,
            settledVisibilityOffset: fixture.state.viewOffset + 1708.5
        )
        let token = fixture.tokens[fixture.fringeIndex]

        XCTAssertEqual(sampled.frames[token], moving.frames[token])
        XCTAssertNil(sampled.hiddenHandles[token])
        XCTAssertGreaterThan(try XCTUnwrap(sampled.frames[token]).maxX, 2)
    }

    func testSettledDiffUsesOnlyVerifiedNativeSizesForMinimumEdge() throws {
        let fixture = makeFixture()
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.niriLayoutHandler
        let token = fixture.tokens[fixture.fringeIndex]
        let frame = try XCTUnwrap(layout(fixture, isSettled: true).frames[token])
        let monitor = LayoutMonitorSnapshot(
            monitorId: .init(displayId: 991),
            displayId: 991,
            frame: fixture.area.viewFrame,
            visibleFrame: fixture.area.viewFrame,
            workingFrame: fixture.area.workingFrame,
            fullscreenLayoutFrame: fixture.area.viewFrame,
            scale: 2,
            orientation: .horizontal
        )
        func change(
            frame: CGRect,
            state: ViewportState? = fixture.state
        ) throws -> LayoutFrameChange {
            try XCTUnwrap(handler.layoutDiff(
                windows: [.init(token: token, constraints: .unconstrained, hiddenState: nil, layoutReason: .standard)],
                frames: [token: frame],
                hiddenHandles: [:],
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                canRestoreHiddenWorkspaceWindows: true,
                reassertHidden: true,
                settledContext: state.map { (monitor, $0) }
            ).frameChanges.first)
        }

        XCTAssertEqual(try change(frame: frame).frame, frame)
        XCTAssertEqual(try change(frame: frame).components, .all)
        for nativeWidth in [frame.width.rounded(.down), frame.width.rounded(.up)] {
            let native = CGRect(x: 100, y: frame.minY, width: nativeWidth, height: frame.height.rounded(.up))
            controller.axManager.confirmFrameWrite(for: token.windowId, frame: native)
            let settled = try change(frame: frame)
            XCTAssertEqual(settled.frame.maxX, fixture.area.viewFrame.minX + 1)
            XCTAssertEqual(settled.frame.size, native.size)
            XCTAssertEqual(settled.frame.maxY, frame.maxY)
            XCTAssertEqual(settled.components, .position)
            XCTAssertEqual(try change(frame: frame, state: nil).frame, frame)
            let partialFrame = frame.offsetBy(dx: 20, dy: 0)
            XCTAssertEqual(try change(frame: partialFrame).frame, partialFrame)
            var selected = fixture.state
            selected.selectedNodeId = fixture.engine.findNode(for: token, in: fixture.workspaceId)?.id
            XCTAssertEqual(try change(frame: frame, state: selected).frame, frame)
            var active = fixture.state
            active.activeColumnIndex = fixture.fringeIndex
            XCTAssertEqual(try change(frame: frame, state: active).frame, frame)
        }
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame.insetBy(dx: -1, dy: 0))
        XCTAssertEqual(try change(frame: frame).frame, frame)
        XCTAssertEqual(try change(frame: frame).components, .all)
        XCTAssertEqual(try XCTUnwrap(layout(fixture, isSettled: true).frames[token]), frame)
    }

    func testSelectedFringeAndMeaningfullyPartialColumnsStayUnchanged() throws {
        let fixture = makeFixture()
        var selectedState = fixture.state
        selectedState.selectedNodeId = try XCTUnwrap(
            fixture.engine.findNode(for: fixture.tokens[fixture.fringeIndex], in: fixture.workspaceId)
        ).id
        selectedState.viewOffset += CGFloat(fixture.state.activeColumnIndex - fixture.fringeIndex) * 1708.5
        XCTAssertEqual(
            layout(fixture, isSettled: true, state: selectedState).frames,
            layout(fixture, isSettled: false, state: selectedState).frames
        )

        var partialState = fixture.state
        partialState.viewOffset -= 32
        XCTAssertEqual(
            layout(fixture, isSettled: true, state: partialState).frames,
            layout(fixture, isSettled: false, state: partialState).frames
        )
    }

    private func makeFixture(
        screenSpan: CGFloat = 3440,
        border: CGFloat = 3.5,
        origin: CGFloat = 0,
        scale: CGFloat = 2,
        orientation: Monitor.Orientation = .horizontal,
        trailing: Bool = true
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let columnCount = screenSpan == 3440 ? 3 : 2
        let columnSpan: CGFloat = screenSpan == 3440 ? 1692.5 : 1761
        var tokens: [WindowToken] = []
        for index in 0 ..< columnCount {
            let token = WindowToken(pid: 1, windowId: index + 1)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            tokens.append(token)
        }
        for column in engine.columns(in: workspaceId) {
            switch orientation {
            case .horizontal: column.cachedWidth = columnSpan
            case .vertical: column.cachedHeight = columnSpan
            }
        }
        let screen = switch orientation {
        case .horizontal: CGRect(x: origin, y: 0, width: screenSpan, height: 1440)
        case .vertical: CGRect(x: 0, y: origin, width: 1440, height: screenSpan)
        }
        let working = screen.insetBy(dx: border, dy: border)
        var state = ViewportState()
        state.activeColumnIndex = trailing ? columnCount - 1 : 0
        state.viewOffset = trailing ? -(screenSpan - 2 * border - 16 - columnSpan) : -16
        state.selectedNodeId = engine.findNode(for: tokens[state.activeColumnIndex], in: workspaceId)?.id
        return Fixture(
            engine: engine,
            workspaceId: workspaceId,
            tokens: tokens,
            area: WorkingAreaContext(
                workingFrame: working,
                fullscreenLayoutFrame: screen,
                viewFrame: screen,
                scale: scale
            ),
            orientation: orientation,
            state: state,
            fringeIndex: trailing ? 0 : columnCount - 1
        )
    }

    private func layout(
        _ fixture: Fixture,
        isSettled: Bool,
        state: ViewportState? = nil,
        settledVisibilityOffset: CGFloat? = nil
    ) -> LayoutResult {
        fixture.engine.calculateLayoutWithVisibility(
            state: state ?? fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: fixture.area.workingFrame,
            screenFrame: fixture.area.viewFrame,
            gaps: (horizontal: 16, vertical: 16),
            workingArea: fixture.area,
            orientation: fixture.orientation,
            settledVisibilityOffset: settledVisibilityOffset,
            isSettled: isSettled
        )
    }

    private func nativeContact(_ frame: CGRect, screen: CGRect, orientation: Monitor.Orientation) -> CGFloat {
        switch orientation {
        case .horizontal:
            let minimum = frame.minX.rounded(.down)
            let maximum = minimum + frame.width.rounded(.down)
            return min(maximum, screen.maxX) - max(minimum, screen.minX)
        case .vertical:
            let maximum = screen.maxY - (screen.maxY - frame.maxY).rounded(.down)
            let minimum = maximum - frame.height.rounded(.down)
            return min(maximum, screen.maxY) - max(minimum, screen.minY)
        }
    }
}
