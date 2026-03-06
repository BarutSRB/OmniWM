import ApplicationServices
import XCTest

@testable import OmniWM

@MainActor
final class ZigNiriContractTests: XCTestCase {
    func testSyncWindowsMaintainsStableNodeIdsAndPrunesRemovedHandles() throws {
        let workspace = WorkspaceDescriptor(name: "phase5-contract-sync")
        let engine = ZigNiriEngine()
        let firstHandle = makeWindowHandle()
        let secondHandle = makeWindowHandle()

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspace.id,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )

        let firstNodeId = try XCTUnwrap(engine.nodeId(for: firstHandle))
        let secondNodeId = try XCTUnwrap(engine.nodeId(for: secondHandle))

        let removed = engine.syncWindows(
            [firstHandle],
            in: workspace.id,
            selectedNodeId: firstNodeId,
            focusedHandle: firstHandle
        )

        XCTAssertEqual(removed.count, 1)
        XCTAssertTrue(removed.contains(secondHandle))
        XCTAssertEqual(engine.nodeId(for: firstHandle), firstNodeId)
        XCTAssertNil(engine.nodeId(for: secondHandle))
        XCTAssertNil(engine.windowHandle(for: secondNodeId))

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertNotNil(view.windowsById[firstNodeId])
        XCTAssertNil(view.windowsById[secondNodeId])
        XCTAssertEqual(view.selection?.focusedWindowId, firstNodeId)
    }

    func testWorkspaceEnsureAndClearProvideStableEmptyProjection() throws {
        let workspace = WorkspaceDescriptor(name: "phase5-contract-clear")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        let firstEnsure = engine.applyWorkspace(.ensureWorkspace, in: workspace.id)
        let secondEnsure = engine.applyWorkspace(.ensureWorkspace, in: workspace.id)
        XCTAssertTrue(firstEnsure.applied)
        XCTAssertFalse(secondEnsure.applied)

        _ = engine.syncWindows([handle], in: workspace.id, selectedNodeId: nil, focusedHandle: handle)
        let windowId = try XCTUnwrap(engine.nodeId(for: handle))

        let clearResult = engine.applyWorkspace(.clearWorkspace, in: workspace.id)
        XCTAssertTrue(clearResult.applied)
        XCTAssertNil(engine.windowHandle(for: windowId))

        let clearedView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertTrue(clearedView.windowsById.isEmpty)
        XCTAssertEqual(clearedView.columns.count, 1)
        XCTAssertEqual(clearedView.columns.first?.windowIds.count, 0)
    }

    func testMutationAndNavigationContractsUpdateSelectionAndFocus() throws {
        let workspace = WorkspaceDescriptor(name: "phase5-contract-mutation-navigation")
        let engine = ZigNiriEngine()
        let firstHandle = makeWindowHandle()
        let secondHandle = makeWindowHandle()

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspace.id,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        let secondNodeId = try XCTUnwrap(engine.nodeId(for: secondHandle))
        XCTAssertTrue(
            engine.applyMutation(
                .moveWindow(windowId: secondNodeId, direction: .left, orientation: .horizontal),
                in: workspace.id
            ).applied
        )

        let initialView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let columnId = try XCTUnwrap(initialView.columns.first?.nodeId)

        let displayResult = engine.applyMutation(
            .setColumnDisplay(columnId: columnId, display: .tabbed),
            in: workspace.id
        )
        XCTAssertTrue(displayResult.applied)

        let navResult = engine.applyNavigation(.focusWindow(index: 1), in: workspace.id)
        XCTAssertTrue(navResult.applied)
        XCTAssertNotNil(navResult.targetNodeId)

        let projectedView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(projectedView.columns.first?.display, .tabbed)
        let selectedNodeId = try XCTUnwrap(projectedView.selection?.selectedNodeId)
        let focusedNodeId = try XCTUnwrap(projectedView.selection?.focusedWindowId)
        XCTAssertNotNil(projectedView.windowsById[selectedNodeId])
        XCTAssertNotNil(projectedView.windowsById[focusedNodeId])
        XCTAssertEqual(projectedView.windowsById[focusedNodeId]?.isFocused, true)
    }

    func testWorkspaceMoveWindowProjectsSourceAndTargetWorkspaces() throws {
        let sourceWorkspace = WorkspaceDescriptor(name: "phase5-contract-workspace-source")
        let targetWorkspace = WorkspaceDescriptor(name: "phase5-contract-workspace-target")
        let engine = ZigNiriEngine()
        let keepHandle = makeWindowHandle()
        let moveHandle = makeWindowHandle()

        _ = engine.syncWindows(
            [keepHandle, moveHandle],
            in: sourceWorkspace.id,
            selectedNodeId: nil,
            focusedHandle: moveHandle
        )
        let moveNodeId = try XCTUnwrap(engine.nodeId(for: moveHandle))

        let moveResult = engine.applyWorkspace(
            .moveWindow(windowId: moveNodeId, targetWorkspaceId: targetWorkspace.id),
            in: sourceWorkspace.id
        )

        XCTAssertTrue(moveResult.applied)
        XCTAssertEqual(moveResult.workspaceId, targetWorkspace.id)
        XCTAssertTrue(engine.windowHandle(for: moveNodeId) === moveHandle)

        let targetView = try XCTUnwrap(engine.workspaceView(for: targetWorkspace.id))
        XCTAssertNotNil(targetView.windowsById[moveNodeId])

        let staleSourceView = try XCTUnwrap(engine.workspaceView(for: sourceWorkspace.id))
        XCTAssertNotNil(staleSourceView.windowsById[moveNodeId])

        _ = engine.applyWorkspace(.setSelection(nil), in: sourceWorkspace.id)
        let sourceView = try XCTUnwrap(engine.workspaceView(for: sourceWorkspace.id))
        XCTAssertNil(sourceView.windowsById[moveNodeId])
    }

    func testInteractiveMoveAndResizeContractsResetStateBetweenSessions() throws {
        let workspace = WorkspaceDescriptor(name: "phase5-contract-interactive")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows([handle], in: workspace.id, selectedNodeId: nil, focusedHandle: handle)
        let windowId = try XCTUnwrap(engine.nodeId(for: handle))

        XCTAssertTrue(
            engine.beginInteractiveMove(
                ZigNiriInteractiveMoveState(
                    windowId: windowId,
                    workspaceId: workspace.id,
                    startMouseLocation: CGPoint(x: 40, y: 40),
                    monitorFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                    currentHoverTarget: nil
                )
            )
        )
        XCTAssertFalse(
            engine.beginInteractiveMove(
                ZigNiriInteractiveMoveState(
                    windowId: windowId,
                    workspaceId: workspace.id,
                    startMouseLocation: CGPoint(x: 40, y: 40),
                    monitorFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                    currentHoverTarget: nil
                )
            )
        )

        let hoverTarget = engine.updateInteractiveMove(mouseLocation: CGPoint(x: -10, y: 40))
        switch hoverTarget {
        case let .workspaceEdge(side):
            XCTAssertEqual(side, .left)
        default:
            XCTFail("Expected workspace edge hover target while cursor is outside monitor bounds")
        }

        let moveResult = engine.endInteractiveMove(commit: true)
        XCTAssertTrue(moveResult.applied)
        XCTAssertEqual(moveResult.affectedNodeIds, [windowId])

        XCTAssertTrue(
            engine.beginInteractiveResize(
                ZigNiriInteractiveResizeState(
                    windowId: windowId,
                    workspaceId: workspace.id,
                    edges: [.right],
                    startMouseLocation: CGPoint(x: 10, y: 10),
                    monitorFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                    orientation: .horizontal,
                    gap: 8,
                    initialViewportOffset: 0
                )
            )
        )
        XCTAssertFalse(
            engine.beginInteractiveResize(
                ZigNiriInteractiveResizeState(
                    windowId: windowId,
                    workspaceId: workspace.id,
                    edges: [.right],
                    startMouseLocation: CGPoint(x: 10, y: 10),
                    monitorFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                    orientation: .horizontal,
                    gap: 8,
                    initialViewportOffset: 0
                )
            )
        )

        let resizeNoop = engine.updateInteractiveResize(mouseLocation: CGPoint(x: 10, y: 10))
        XCTAssertFalse(resizeNoop.applied)

        let resizeUpdate = engine.updateInteractiveResize(mouseLocation: CGPoint(x: 30, y: 10))
        XCTAssertTrue(resizeUpdate.applied)
        XCTAssertTrue(resizeUpdate.affectedNodeIds.contains(windowId))

        let resizeEnd = engine.endInteractiveResize(commit: true)
        XCTAssertTrue(resizeEnd.applied)
        XCTAssertEqual(resizeEnd.affectedNodeIds, [windowId])

        XCTAssertTrue(
            engine.beginInteractiveResize(
                ZigNiriInteractiveResizeState(
                    windowId: windowId,
                    workspaceId: workspace.id,
                    edges: [.left],
                    startMouseLocation: CGPoint(x: 12, y: 12),
                    monitorFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                    orientation: .horizontal,
                    gap: 8,
                    initialViewportOffset: 0
                )
            )
        )
    }

    private func makeWindowHandle() -> WindowHandle {
        let pid = getpid()
        return WindowHandle(
            id: UUID(),
            pid: pid,
            axElement: AXUIElementCreateApplication(pid)
        )
    }
}
