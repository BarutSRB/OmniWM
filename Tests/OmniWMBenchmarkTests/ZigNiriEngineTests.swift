import ApplicationServices
import XCTest

@testable import OmniWM

@MainActor
final class ZigNiriEngineTests: XCTestCase {
    func testSyncWindowsProjectsRuntimeViewAndFocus() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-sync-runtime-view")
        let engine = ZigNiriEngine()
        let firstHandle = makeWindowHandle()
        let secondHandle = makeWindowHandle()

        let removed = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspace.id,
            selectedNodeId: nil,
            focusedHandle: secondHandle
        )

        XCTAssertTrue(removed.isEmpty)

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.windowsById.count, 2)
        XCTAssertEqual(view.columns.count, 1)

        let firstId = try XCTUnwrap(engine.nodeId(for: firstHandle))
        let secondId = try XCTUnwrap(engine.nodeId(for: secondHandle))
        XCTAssertNotNil(view.windowsById[firstId])
        XCTAssertNotNil(view.windowsById[secondId])
        XCTAssertEqual(view.selection?.focusedWindowId, secondId)
        XCTAssertEqual(view.windowsById[secondId]?.isFocused, true)
    }

    func testColumnDisplayAndWindowHeightMutationsProjectFromRuntime() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-runtime-mutations")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows(
            [handle],
            in: workspace.id,
            selectedNodeId: nil
        )

        let baselineView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let columnId = try XCTUnwrap(baselineView.columns.first?.nodeId)
        let windowId = try XCTUnwrap(engine.nodeId(for: handle))

        let displayResult = engine.applyMutation(
            .setColumnDisplay(columnId: columnId, display: .tabbed),
            in: workspace.id
        )
        XCTAssertTrue(displayResult.applied)

        let heightResult = engine.applyMutation(
            .setWindowHeight(windowId: windowId, height: .fixed(240)),
            in: workspace.id
        )
        XCTAssertTrue(heightResult.applied)

        let updatedView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(updatedView.columns.first?.display, .tabbed)

        guard case let .fixed(value)? = updatedView.windowsById[windowId]?.height else {
            XCTFail("Expected fixed height after runtime mutation projection")
            return
        }
        XCTAssertEqual(value, 240, accuracy: 0.001)
    }

    func testColumnWidthMutationUpdatesColumnWithoutChangingWindowHeight() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-column-width-mutation")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows(
            [handle],
            in: workspace.id,
            selectedNodeId: nil
        )

        let baselineView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let columnId = try XCTUnwrap(baselineView.columns.first?.nodeId)
        let windowId = try XCTUnwrap(engine.nodeId(for: handle))

        XCTAssertTrue(
            engine.applyMutation(
                .setWindowHeight(windowId: windowId, height: .fixed(320)),
                in: workspace.id
            ).applied
        )

        XCTAssertTrue(
            engine.applyMutation(
                .setColumnWidth(columnId: columnId, width: .proportion(0.5)),
                in: workspace.id
            ).applied
        )

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        guard case let .proportion(width)? = view.columns.first?.width else {
            XCTFail("Expected proportional width after mutation")
            return
        }
        XCTAssertEqual(width, 0.5, accuracy: 0.001)
        guard case let .fixed(height)? = view.windowsById[windowId]?.height else {
            XCTFail("Expected fixed window height to remain unchanged")
            return
        }
        XCTAssertEqual(height, 320, accuracy: 0.001)
    }

    func testToggleColumnFullWidthRestoresSavedWidthOnSecondToggle() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-column-full-width-toggle")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows(
            [handle],
            in: workspace.id,
            selectedNodeId: nil
        )

        var view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let columnId = try XCTUnwrap(view.columns.first?.nodeId)

        XCTAssertTrue(
            engine.applyMutation(
                .setColumnWidth(columnId: columnId, width: .proportion(0.66)),
                in: workspace.id
            ).applied
        )

        XCTAssertTrue(
            engine.applyMutation(
                .toggleColumnFullWidth(columnId: columnId),
                in: workspace.id
            ).applied
        )

        view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.columns.first?.isFullWidth, true)

        XCTAssertTrue(
            engine.applyMutation(
                .toggleColumnFullWidth(columnId: columnId),
                in: workspace.id
            ).applied
        )

        view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.columns.first?.isFullWidth, false)
        guard case let .proportion(width)? = view.columns.first?.width else {
            XCTFail("Expected proportional width to be restored")
            return
        }
        XCTAssertEqual(width, 0.66, accuracy: 0.001)
    }

    func testMoveWindowWorkspaceCommandLazilyResyncsSourceWorkspace() throws {
        let sourceWorkspace = WorkspaceDescriptor(name: "zig-niri-workspace-source")
        let targetWorkspace = WorkspaceDescriptor(name: "zig-niri-workspace-target")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows(
            [handle],
            in: sourceWorkspace.id,
            selectedNodeId: nil
        )
        let windowId = try XCTUnwrap(engine.nodeId(for: handle))

        let moveResult = engine.applyWorkspace(
            .moveWindow(windowId: windowId, targetWorkspaceId: targetWorkspace.id),
            in: sourceWorkspace.id
        )
        XCTAssertTrue(moveResult.applied)
        XCTAssertEqual(moveResult.workspaceId, targetWorkspace.id)

        let targetView = try XCTUnwrap(engine.workspaceView(for: targetWorkspace.id))
        XCTAssertNotNil(targetView.windowsById[windowId])
        XCTAssertTrue(engine.windowHandle(for: windowId) === handle)

        let staleSourceView = try XCTUnwrap(engine.workspaceView(for: sourceWorkspace.id))
        XCTAssertNotNil(staleSourceView.windowsById[windowId], "Source should remain stale until accessed again")

        _ = engine.applyWorkspace(.setSelection(nil), in: sourceWorkspace.id)
        let refreshedSourceView = try XCTUnwrap(engine.workspaceView(for: sourceWorkspace.id))
        XCTAssertNil(refreshedSourceView.windowsById[windowId], "Source should resync on the next source-workspace command")
    }

    func testNavigationFocusWindowUsesRuntimeSelectionAnchor() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-navigation-focus-window")
        let engine = ZigNiriEngine()
        let firstHandle = makeWindowHandle()
        let secondHandle = makeWindowHandle()

        _ = engine.syncWindows(
            [firstHandle, secondHandle],
            in: workspace.id,
            selectedNodeId: nil
        )

        let initialView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let windowIds = try XCTUnwrap(initialView.columns.first?.windowIds)
        XCTAssertGreaterThanOrEqual(windowIds.count, 2)

        _ = engine.applyWorkspace(
            .setSelection(
                ZigNiriSelection(
                    selectedNodeId: windowIds[1],
                    focusedWindowId: windowIds[1]
                )
            ),
            in: workspace.id
        )

        let navResult = engine.applyNavigation(
            .focusWindow(index: 1),
            in: workspace.id
        )

        XCTAssertTrue(navResult.applied)
        XCTAssertEqual(navResult.targetNodeId, windowIds[1])
        XCTAssertEqual(navResult.selection?.selectedNodeId, windowIds[1])
    }

    func testSyncWindowsBootstrapSplitsColumnsByMaxWindowsPerColumn() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-max-per-column-bootstrap")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 3)
        let handles = (0 ..< 6).map { _ in makeWindowHandle() }

        _ = engine.syncWindows(
            handles,
            in: workspace.id,
            selectedNodeId: nil
        )

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertGreaterThanOrEqual(view.columns.count, 2)
        XCTAssertTrue(view.columns.allSatisfy { $0.windowIds.count <= 3 })
    }

    func testSyncWindowsIncrementalAddFillsCurrentColumnThenCreatesNext() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-max-per-column-incremental")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 3)
        let first = makeWindowHandle()
        let second = makeWindowHandle()
        let third = makeWindowHandle()
        let fourth = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second],
            in: workspace.id,
            selectedNodeId: nil
        )

        var view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let selectedColumnId = try XCTUnwrap(view.columns.first?.nodeId)

        _ = engine.syncWindows(
            [first, second, third],
            in: workspace.id,
            selectedNodeId: selectedColumnId
        )

        view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.columns.count, 1)
        XCTAssertEqual(view.columns[0].windowIds.count, 3)

        _ = engine.syncWindows(
            [first, second, third, fourth],
            in: workspace.id,
            selectedNodeId: selectedColumnId
        )

        view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.columns.count, 2)
        XCTAssertEqual(view.columns[0].windowIds.count, 3)
        XCTAssertEqual(view.columns[1].windowIds.count, 1)
    }

    func testLayoutProjectionMarksOverflowColumnsAndPreservesOffscreenFrames() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-layout-overflow-hidden")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 1)
        let first = makeWindowHandle()
        let second = makeWindowHandle()
        let third = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second, third],
            in: workspace.id,
            selectedNodeId: nil
        )

        let layout = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0
            )
        )

        XCTAssertNil(layout.hiddenHandles[first])
        XCTAssertEqual(layout.hiddenHandles[second], .right)
        XCTAssertEqual(layout.hiddenHandles[third], .right)

        let firstX = try XCTUnwrap(layout.frames[first]?.origin.x)
        let secondX = try XCTUnwrap(layout.frames[second]?.origin.x)
        XCTAssertNotEqual(firstX, secondX)

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let secondId = try XCTUnwrap(engine.nodeId(for: second))
        XCTAssertNotNil(view.windowsById[secondId]?.frame)
    }

    func testViewportOffsetShiftsVisibleColumnsBySide() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-layout-viewport-offset")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 1)
        let first = makeWindowHandle()
        let second = makeWindowHandle()
        let third = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second, third],
            in: workspace.id,
            selectedNodeId: nil
        )

        let shifted = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 1000
            )
        )

        XCTAssertEqual(shifted.hiddenHandles[first], .left)
        XCTAssertNil(shifted.hiddenHandles[second])
        XCTAssertEqual(shifted.hiddenHandles[third], .right)
    }

    func testFullscreenToggleMaintainsSingleOwnerAndRestoresDemotedHeight() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-fullscreen-exclusive")
        let engine = ZigNiriEngine()
        let first = makeWindowHandle()
        let second = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second],
            in: workspace.id,
            selectedNodeId: nil
        )

        let firstId = try XCTUnwrap(engine.nodeId(for: first))
        let secondId = try XCTUnwrap(engine.nodeId(for: second))

        let setHeightResult = engine.applyMutation(
            .setWindowHeight(windowId: firstId, height: .fixed(240)),
            in: workspace.id
        )
        XCTAssertTrue(setHeightResult.applied)

        let fullscreenFirst = engine.applyMutation(
            .setWindowSizing(windowId: firstId, mode: .fullscreen),
            in: workspace.id
        )
        XCTAssertTrue(fullscreenFirst.applied)

        let fullscreenSecond = engine.applyMutation(
            .setWindowSizing(windowId: secondId, mode: .fullscreen),
            in: workspace.id
        )
        XCTAssertTrue(fullscreenSecond.applied)

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let fullscreenOwners = view.windowsById.values.filter { $0.sizingMode == .fullscreen }.map(\.nodeId)
        XCTAssertEqual(fullscreenOwners.count, 1)
        XCTAssertEqual(fullscreenOwners.first, secondId)
        XCTAssertEqual(view.windowsById[firstId]?.sizingMode, .normal)
        guard case let .fixed(value)? = view.windowsById[firstId]?.height else {
            XCTFail("Expected demoted fullscreen window to restore fixed height")
            return
        }
        XCTAssertEqual(value, 240, accuracy: 0.001)
    }

    func testColumnTargetMutationSelectionResolvesToConcreteWindowId() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-column-target-selection")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 1)
        let first = makeWindowHandle()
        let second = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second],
            in: workspace.id,
            selectedNodeId: nil
        )

        let baselineView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let firstColumnId = try XCTUnwrap(baselineView.columns.first?.nodeId)

        let result = engine.applyMutation(
            .moveColumn(columnId: firstColumnId, direction: .right),
            in: workspace.id
        )

        XCTAssertTrue(result.applied)
        let selectedNodeId = try XCTUnwrap(result.selection?.selectedNodeId)
        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertNotNil(view.windowsById[selectedNodeId], "Expected selection to resolve to a concrete window id")
    }

    func testSyncWindowsNoOpPreservesProjectionForValidRuntimeState() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-normalize-fast-path")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 3)
        let handles = (0 ..< 3).map { _ in makeWindowHandle() }

        _ = engine.syncWindows(
            handles,
            in: workspace.id,
            selectedNodeId: nil
        )
        let firstView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let firstColumns = firstView.columns.map(\.windowIds)

        let removed = engine.syncWindows(
            handles,
            in: workspace.id,
            selectedNodeId: nil
        )
        XCTAssertTrue(removed.isEmpty)

        let secondView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let secondColumns = secondView.columns.map(\.windowIds)
        XCTAssertEqual(firstColumns, secondColumns)
    }

    func testOverflowSplitNormalizationIsDeterministicAcrossResync() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-overflow-deterministic")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 2)
        let handles = (0 ..< 5).map { _ in makeWindowHandle() }

        _ = engine.syncWindows(
            handles,
            in: workspace.id,
            selectedNodeId: nil
        )
        let firstView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let firstColumnIds = firstView.columns.map(\.nodeId)
        let firstColumnWindows = firstView.columns.map(\.windowIds)

        _ = engine.syncWindows(
            handles,
            in: workspace.id,
            selectedNodeId: nil
        )
        let secondView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let secondColumnIds = secondView.columns.map(\.nodeId)
        let secondColumnWindows = secondView.columns.map(\.windowIds)

        XCTAssertEqual(firstColumnIds, secondColumnIds)
        XCTAssertEqual(firstColumnWindows, secondColumnWindows)
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
