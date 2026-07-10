// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

class NiriInteractionTestCase: XCTestCase {
    let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func addWindow(
        _ engine: NiriLayoutEngine,
        pid: pid_t,
        windowId: Int = 1,
        to workspaceId: WorkspaceDescriptor.ID,
        after node: NiriNode? = nil
    ) -> NiriWindow {
        engine.addWindow(
            token: WindowToken(pid: pid, windowId: windowId),
            to: workspaceId,
            afterSelection: node?.id
        )
    }

    func beginMove(
        _ engine: NiriLayoutEngine,
        window: NiriWindow,
        handle: WindowHandle? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        var state = ViewportState()
        let frames = layout(engine, in: workspaceId, state: state)
        return engine.interactiveMoveBegin(
            windowId: window.id,
            windowHandle: handle ?? window.handle,
            startLocation: frames[window.token]?.center ?? .zero,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: 0
        )
    }

    func beginResize(
        _ engine: NiriLayoutEngine,
        window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        let frame = layout(engine, in: workspaceId)[window.token] ?? .zero
        return engine.interactiveResizeBegin(
            windowId: window.id,
            edges: .right,
            startLocation: CGPoint(x: frame.maxX, y: frame.midY),
            in: workspaceId
        )
    }

    func layout(
        _ engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState = ViewportState()
    ) -> [WindowToken: CGRect] {
        engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 0, vertical: 0)
        )
    }

    func removeWindows(
        _ tokens: Set<WindowToken>,
        from engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriLayoutEngine.NiriRemovalResult {
        var state = ViewportState()
        return engine.removeWindows(
            tokens,
            in: workspaceId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 0,
            selectedNodeId: nil,
            removedNodeIds: []
        )
    }

    func windowOrder(
        _ engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> [WindowToken] {
        engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
    }
}

final class NiriInteractionOwnershipTests: NiriInteractionTestCase {
    func testInteractiveMoveUpdateAndEndRemainOwnedByStartingWorkspace() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_001, to: workspaceA)
        let target = addWindow(engine, pid: 1_001, windowId: 2, to: workspaceA, after: source)
        let foreignSource = addWindow(engine, pid: 1_002, to: workspaceB)
        _ = addWindow(engine, pid: 1_002, windowId: 2, to: workspaceB, after: foreignSource)
        var stateA = ViewportState()
        let framesA = layout(engine, in: workspaceA, state: stateA)
        _ = layout(engine, in: workspaceB)
        let sourceFrame = try XCTUnwrap(framesA[source.token])
        let targetFrame = try XCTUnwrap(framesA[target.token])
        let orderBefore = windowOrder(engine, in: workspaceA)
        let foreignOrderBefore = windowOrder(engine, in: workspaceB)

        XCTAssertTrue(
            engine.interactiveMoveBegin(
                windowId: source.id,
                windowHandle: source.handle,
                startLocation: sourceFrame.center,
                in: workspaceA,
                motion: .disabled,
                state: &stateA,
                workingFrame: workingFrame,
                gaps: 0
            )
        )
        let hoverTarget = try XCTUnwrap(
            engine.interactiveMoveUpdate(currentLocation: targetFrame.center)
        )
        guard case let .window(nodeId, _, insertPosition) = hoverTarget else {
            return XCTFail("Expected a window hover target")
        }
        XCTAssertEqual(nodeId, target.id)
        XCTAssertEqual(insertPosition, .swap)
        XCTAssertTrue(
            engine.interactiveMoveEnd(
                at: targetFrame.center,
                motion: .disabled,
                state: &stateA,
                workingFrame: workingFrame,
                gaps: 0
            )
        )
        XCTAssertNotEqual(windowOrder(engine, in: workspaceA), orderBefore)
        XCTAssertEqual(windowOrder(engine, in: workspaceB), foreignOrderBefore)
        XCTAssertNil(engine.interactiveMove)
    }

    func testInteractiveResizeUpdateAndEndRemainOwnedByStartingWorkspace() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_003, to: workspaceA)
        _ = addWindow(engine, pid: 1_004, to: workspaceB)
        var stateA = ViewportState()
        let framesA = layout(engine, in: workspaceA, state: stateA)
        _ = layout(engine, in: workspaceB)
        let sourceFrame = try XCTUnwrap(framesA[source.token])
        let sourceWidthBefore = try XCTUnwrap(engine.columns(in: workspaceA).first?.cachedWidth)
        let foreignWidthBefore = try XCTUnwrap(engine.columns(in: workspaceB).first?.cachedWidth)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: source.id,
                edges: .right,
                startLocation: CGPoint(x: sourceFrame.maxX, y: sourceFrame.midY),
                in: workspaceA
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: sourceFrame.maxX + 100, y: sourceFrame.midY),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0)
            )
        )
        engine.interactiveResizeEnd(
            motion: .disabled,
            state: &stateA,
            workingFrame: workingFrame,
            gaps: 0
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(engine.columns(in: workspaceA).first?.cachedWidth),
            sourceWidthBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(engine.columns(in: workspaceB).first?.cachedWidth),
            foreignWidthBefore
        )
        XCTAssertNil(engine.interactiveResize)
    }
}

final class NiriInteractionLifecycleTests: NiriInteractionTestCase {
    func testMoveAndResizeBeginsAreMutuallyExclusive() {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 1_023, to: workspace)

        XCTAssertTrue(beginMove(engine, window: window, in: workspace))
        XCTAssertFalse(beginResize(engine, window: window, in: workspace))

        engine.interactiveMoveCancel()

        XCTAssertTrue(beginResize(engine, window: window, in: workspace))
        XCTAssertFalse(beginMove(engine, window: window, in: workspace))
    }

    func testWorkspaceRemovalClearsMoveAndPermitsMoveInAnotherWorkspace() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_005, to: workspaceA)
        let next = addWindow(engine, pid: 1_006, to: workspaceB)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceA))
        XCTAssertFalse(beginMove(engine, window: next, in: workspaceB))

        engine.removeWorkspaceState(workspaceA)

        XCTAssertNil(engine.interactiveMove)
        XCTAssertTrue(beginMove(engine, window: next, in: workspaceB))
    }

    func testWorkspaceRemovalClearsResizeAndPermitsResizeInAnotherWorkspace() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_007, to: workspaceA)
        let next = addWindow(engine, pid: 1_008, to: workspaceB)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceA))
        XCTAssertFalse(beginResize(engine, window: next, in: workspaceB))

        engine.removeWorkspaceState(workspaceA)

        XCTAssertNil(engine.interactiveResize)
        XCTAssertTrue(beginResize(engine, window: next, in: workspaceB))
    }

    func testSimpleRemovalClearsOnlyMatchingMoveAndResizeSessions() {
        let moveEngine = NiriLayoutEngine()
        let moveWorkspaceA = WorkspaceDescriptor.ID()
        let moveWorkspaceB = WorkspaceDescriptor.ID()
        let moveSource = addWindow(moveEngine, pid: 1_009, to: moveWorkspaceA)
        let unrelatedMoveWindow = addWindow(moveEngine, pid: 1_010, to: moveWorkspaceB)
        XCTAssertTrue(beginMove(moveEngine, window: moveSource, in: moveWorkspaceA))
        moveEngine.removeWindow(token: unrelatedMoveWindow.token, in: moveWorkspaceB)
        XCTAssertNotNil(moveEngine.interactiveMove)
        moveEngine.removeWindow(token: moveSource.token, in: moveWorkspaceA)
        XCTAssertNil(moveEngine.interactiveMove)

        let resizeEngine = NiriLayoutEngine()
        let resizeWorkspaceA = WorkspaceDescriptor.ID()
        let resizeWorkspaceB = WorkspaceDescriptor.ID()
        let resizeSource = addWindow(resizeEngine, pid: 1_011, to: resizeWorkspaceA)
        let unrelatedResizeWindow = addWindow(resizeEngine, pid: 1_012, to: resizeWorkspaceB)
        XCTAssertTrue(beginResize(resizeEngine, window: resizeSource, in: resizeWorkspaceA))
        resizeEngine.removeWindow(token: unrelatedResizeWindow.token, in: resizeWorkspaceB)
        XCTAssertNotNil(resizeEngine.interactiveResize)
        resizeEngine.removeWindow(token: resizeSource.token, in: resizeWorkspaceA)
        XCTAssertNil(resizeEngine.interactiveResize)
    }

    func testBatchRemovalClearsMatchingMoveAndResizeSessions() {
        let moveEngine = NiriLayoutEngine()
        let moveWorkspace = WorkspaceDescriptor.ID()
        let moveSource = addWindow(moveEngine, pid: 1_013, to: moveWorkspace)
        _ = addWindow(moveEngine, pid: 1_013, windowId: 2, to: moveWorkspace, after: moveSource)
        XCTAssertTrue(beginMove(moveEngine, window: moveSource, in: moveWorkspace))
        _ = removeWindows([moveSource.token], from: moveEngine, in: moveWorkspace)
        XCTAssertNil(moveEngine.interactiveMove)

        let resizeEngine = NiriLayoutEngine()
        let resizeWorkspace = WorkspaceDescriptor.ID()
        let resizeSource = addWindow(resizeEngine, pid: 1_014, to: resizeWorkspace)
        _ = addWindow(resizeEngine, pid: 1_014, windowId: 2, to: resizeWorkspace, after: resizeSource)
        XCTAssertTrue(beginResize(resizeEngine, window: resizeSource, in: resizeWorkspace))
        _ = removeWindows([resizeSource.token], from: resizeEngine, in: resizeWorkspace)
        XCTAssertNil(resizeEngine.interactiveResize)
    }

    func testWindowTransferClearsMatchingMoveSession() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_015, to: workspaceA)
        _ = addWindow(engine, pid: 1_015, windowId: 2, to: workspaceA, after: source)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveWindowToWorkspace(
                source,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )
        XCTAssertNil(engine.interactiveMove)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceB))
    }

    func testWindowTransferClearsMatchingResizeSession() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_016, to: workspaceA)
        _ = addWindow(engine, pid: 1_016, windowId: 2, to: workspaceA, after: source)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveWindowToWorkspace(
                source,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )
        XCTAssertNil(engine.interactiveResize)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceB))
    }

    func testColumnTransferClearsMatchingMoveSession() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_017, to: workspaceA)
        let column = try XCTUnwrap(engine.columns(in: workspaceA).first)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveColumnToWorkspace(
                column,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )
        XCTAssertNil(engine.interactiveMove)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceB))
    }

    func testColumnTransferClearsMatchingResizeSession() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_018, to: workspaceA)
        let column = try XCTUnwrap(engine.columns(in: workspaceA).first)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveColumnToWorkspace(
                column,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )
        XCTAssertNil(engine.interactiveResize)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceB))
    }

    func testSuccessfulRestoreCancelsMoveAndResizeButNoOpRestorePreservesThem() {
        let firstToken = WindowToken(pid: 1_020, windowId: 1)
        let secondToken = WindowToken(pid: 1_020, windowId: 2)
        let donor = NiriLayoutEngine()
        let donorWorkspace = WorkspaceDescriptor.ID()
        let donorFirst = donor.addWindow(token: firstToken, to: donorWorkspace, afterSelection: nil)
        _ = donor.addWindow(token: secondToken, to: donorWorkspace, afterSelection: donorFirst.id)
        let placements = donor.persistedPlacements(in: donorWorkspace)

        let moveEngine = NiriLayoutEngine()
        let moveWorkspace = WorkspaceDescriptor.ID()
        let moveWindow = moveEngine.addWindow(token: firstToken, to: moveWorkspace, afterSelection: nil)
        XCTAssertTrue(beginMove(moveEngine, window: moveWindow, in: moveWorkspace))
        XCTAssertFalse(moveEngine.restoreInitialPlacements(placements, matching: [firstToken], in: moveWorkspace))
        XCTAssertNotNil(moveEngine.interactiveMove)
        XCTAssertTrue(
            moveEngine.restoreInitialPlacements(placements, matching: [firstToken, secondToken], in: moveWorkspace)
        )
        XCTAssertNil(moveEngine.interactiveMove)

        let resizeEngine = NiriLayoutEngine()
        let resizeWorkspace = WorkspaceDescriptor.ID()
        let resizeWindow = resizeEngine.addWindow(token: firstToken, to: resizeWorkspace, afterSelection: nil)
        XCTAssertTrue(beginResize(resizeEngine, window: resizeWindow, in: resizeWorkspace))
        XCTAssertFalse(resizeEngine.restoreInitialPlacements(placements, matching: [firstToken], in: resizeWorkspace))
        XCTAssertNotNil(resizeEngine.interactiveResize)
        XCTAssertTrue(
            resizeEngine.restoreInitialPlacements(
                placements,
                matching: [firstToken, secondToken],
                in: resizeWorkspace
            )
        )
        XCTAssertNil(resizeEngine.interactiveResize)
    }

    func testRekeyKeepsInteractiveMoveHandleCurrent() throws {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 1_019, windowId: 1)
        let newToken = WindowToken(pid: 1_019, windowId: 101)
        let source = engine.addWindow(token: oldToken, to: workspace, afterSelection: nil)
        let target = addWindow(engine, pid: 1_019, windowId: 2, to: workspace, after: source)
        let moveHandle = source.handle
        XCTAssertTrue(beginMove(engine, window: source, handle: moveHandle, in: workspace))

        XCTAssertTrue(engine.rekeyWindow(from: oldToken, to: newToken, in: workspace))

        XCTAssertEqual(source.token, newToken)
        XCTAssertEqual(moveHandle.token, newToken)
        XCTAssertEqual(engine.interactiveMove?.windowHandle.token, newToken)
        let targetFrame = try XCTUnwrap(layout(engine, in: workspace)[target.token])
        XCTAssertNotNil(engine.interactiveMoveUpdate(currentLocation: targetFrame.center))
    }
}
