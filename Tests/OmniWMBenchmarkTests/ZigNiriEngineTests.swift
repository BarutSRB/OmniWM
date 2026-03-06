import ApplicationServices
import Darwin
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
        XCTAssertEqual(view.columns.count, 2)

        let firstId = try XCTUnwrap(engine.nodeId(for: firstHandle))
        let secondId = try XCTUnwrap(engine.nodeId(for: secondHandle))
        XCTAssertNotNil(view.windowsById[firstId])
        XCTAssertNotNil(view.windowsById[secondId])
        XCTAssertTrue(view.columns.allSatisfy { $0.windowIds.count == 1 })
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

    func testBalanceSizesSignalsStructuralAnimation() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-balance-sizes-animation")
        let engine = ZigNiriEngine()
        let first = makeWindowHandle()
        let second = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second],
            in: workspace.id,
            selectedNodeId: nil
        )

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let firstColumnId = try XCTUnwrap(view.columns.first?.nodeId)
        XCTAssertTrue(
            engine.applyMutation(
                .setColumnWidth(columnId: firstColumnId, width: .proportion(0.2)),
                in: workspace.id
            ).applied
        )
        engine.cancelStructuralAnimation(in: workspace.id)

        let result = engine.applyMutation(.balanceSizes, in: workspace.id)
        XCTAssertTrue(result.applied)
        XCTAssertTrue(result.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))
    }

    func testTabDisplayWidthFullWidthAndFullscreenMutationsSignalStructuralAnimation() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-direct-mutation-animation")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows(
            [handle],
            in: workspace.id,
            selectedNodeId: nil
        )

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let columnId = try XCTUnwrap(view.columns.first?.nodeId)
        let windowId = try XCTUnwrap(engine.nodeId(for: handle))

        engine.cancelStructuralAnimation(in: workspace.id)
        let displayResult = engine.applyMutation(
            .setColumnDisplay(columnId: columnId, display: .tabbed),
            in: workspace.id
        )
        XCTAssertTrue(displayResult.applied)
        XCTAssertTrue(displayResult.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))

        engine.cancelStructuralAnimation(in: workspace.id)
        let widthResult = engine.applyMutation(
            .setColumnWidth(columnId: columnId, width: .proportion(0.55)),
            in: workspace.id
        )
        XCTAssertTrue(widthResult.applied)
        XCTAssertTrue(widthResult.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))

        engine.cancelStructuralAnimation(in: workspace.id)
        let fullWidthResult = engine.applyMutation(
            .toggleColumnFullWidth(columnId: columnId),
            in: workspace.id
        )
        XCTAssertTrue(fullWidthResult.applied)
        XCTAssertTrue(fullWidthResult.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))

        engine.cancelStructuralAnimation(in: workspace.id)
        let fullscreenResult = engine.applyMutation(
            .setWindowSizing(windowId: windowId, mode: .fullscreen),
            in: workspace.id
        )
        XCTAssertTrue(fullscreenResult.applied)
        XCTAssertTrue(fullscreenResult.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))
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

        let secondId = try XCTUnwrap(engine.nodeId(for: secondHandle))
        XCTAssertTrue(
            engine.applyMutation(
                .moveWindow(windowId: secondId, direction: .left, orientation: .horizontal),
                in: workspace.id
            ).applied
        )

        let initialView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let activeColumn = try XCTUnwrap(initialView.columns.first(where: { $0.windowIds.count >= 2 }))
        let windowIds = activeColumn.windowIds
        XCTAssertGreaterThanOrEqual(windowIds.count, 2)

        _ = engine.applyWorkspace(
            .setSelection(
                ZigNiriSelection(
                    selectedNodeId: windowIds[0],
                    focusedWindowId: windowIds[0]
                )
            ),
            in: workspace.id
        )

        let navResult = engine.applyNavigation(
            .focusWindow(index: 1),
            in: workspace.id
        )

        XCTAssertTrue(navResult.applied)
        let selectedNodeId = try XCTUnwrap(navResult.selection?.selectedNodeId)
        XCTAssertEqual(selectedNodeId, windowIds[1])
        let projectedView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertNotNil(projectedView.windowsById[selectedNodeId])
    }

    func testSyncWindowsBootstrapAddsIncomingWindowsAsNewColumnsByDefault() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-new-column-bootstrap")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 3)
        let handles = (0 ..< 6).map { _ in makeWindowHandle() }

        _ = engine.syncWindows(
            handles,
            in: workspace.id,
            selectedNodeId: nil
        )

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.columns.count, handles.count)
        XCTAssertTrue(view.columns.allSatisfy { $0.windowIds.count == 1 })
    }

    func testSyncWindowsIncrementalAddUsesNewColumnByDefault() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-new-column-incremental")
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
        let selectedColumnId = try XCTUnwrap(view.columns.last?.nodeId)
        XCTAssertEqual(view.columns.count, 2)
        XCTAssertTrue(view.columns.allSatisfy { $0.windowIds.count == 1 })

        _ = engine.syncWindows(
            [first, second, third],
            in: workspace.id,
            selectedNodeId: selectedColumnId
        )

        view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.columns.count, 3)
        XCTAssertTrue(view.columns.allSatisfy { $0.windowIds.count == 1 })

        _ = engine.syncWindows(
            [first, second, third, fourth],
            in: workspace.id,
            selectedNodeId: selectedColumnId
        )

        view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        XCTAssertEqual(view.columns.count, 4)
        XCTAssertTrue(view.columns.allSatisfy { $0.windowIds.count == 1 })
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
        engine.cancelStructuralAnimation(in: workspace.id)
        let firstId = try XCTUnwrap(engine.nodeId(for: first))
        _ = engine.applyWorkspace(
            .setSelection(
                ZigNiriSelection(
                    selectedNodeId: firstId,
                    focusedWindowId: firstId
                )
            ),
            in: workspace.id
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

        let leftHiddenCount = [first, second, third].filter { shifted.hiddenHandles[$0] == .left }.count
        let rightHiddenCount = [first, second, third].filter { shifted.hiddenHandles[$0] == .right }.count
        let visibleCount = [first, second, third].filter { shifted.hiddenHandles[$0] == nil }.count
        XCTAssertEqual(leftHiddenCount, 1)
        XCTAssertEqual(rightHiddenCount, 1)
        XCTAssertEqual(visibleCount, 1)
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

    func testFullscreenToggleProducesAnimatedIntermediateFrames() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-fullscreen-animation")
        let engine = ZigNiriEngine()
        let first = makeWindowHandle()
        let second = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second],
            in: workspace.id,
            selectedNodeId: nil
        )
        let firstId = try XCTUnwrap(engine.nodeId(for: first))

        let initial = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0
            )
        )
        let preFrame = try XCTUnwrap(initial.frames[first])

        let mutation = engine.applyMutation(
            .setWindowSizing(windowId: firstId, mode: .fullscreen),
            in: workspace.id
        )
        XCTAssertTrue(mutation.applied)
        XCTAssertTrue(mutation.structuralAnimationActive)
        let probeTime = CACurrentMediaTime()

        let animated = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0,
                animationTime: probeTime + 0.08
            )
        )
        let settled = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0,
                animationTime: probeTime + 0.35
            )
        )

        let animatedFrame = try XCTUnwrap(animated.frames[first])
        let settledFrame = try XCTUnwrap(settled.frames[first])
        XCTAssertNotEqual(preFrame, settledFrame)
        XCTAssertNotEqual(animatedFrame, settledFrame)
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

    func testInteractiveResizeMutatesRuntimeStateContinuouslyDuringDrag() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-interactive-resize-live")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows(
            [handle],
            in: workspace.id,
            selectedNodeId: nil
        )
        let windowId = try XCTUnwrap(engine.nodeId(for: handle))
        _ = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0
            )
        )

        XCTAssertTrue(
            engine.beginInteractiveResize(
                ZigNiriInteractiveResizeState(
                    windowId: windowId,
                    workspaceId: workspace.id,
                    edges: [.right],
                    startMouseLocation: CGPoint(x: 100, y: 100),
                    monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                    orientation: .horizontal,
                    gap: 8,
                    initialViewportOffset: 0
                )
            )
        )

        let updateOne = engine.updateInteractiveResize(mouseLocation: CGPoint(x: 60, y: 100))
        let updateTwo = engine.updateInteractiveResize(mouseLocation: CGPoint(x: 20, y: 100))

        XCTAssertTrue(updateOne.applied)
        XCTAssertTrue(updateTwo.applied)
        let widthOne = try XCTUnwrap(updateOne.resizeOutput?.columnWidth)
        let widthTwo = try XCTUnwrap(updateTwo.resizeOutput?.columnWidth)
        XCTAssertLessThan(widthTwo, widthOne)

        let view = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        guard case let .fixed(width)? = view.columns.first?.width else {
            XCTFail("Expected interactive resize to mutate column width to fixed size")
            return
        }
        XCTAssertEqual(width, widthTwo, accuracy: 0.001)

        _ = engine.endInteractiveResize(commit: true)
    }

    func testMoveMutationProducesAnimatedIntermediateFrames() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-structural-animation-move")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 2)
        let first = makeWindowHandle()
        let second = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second],
            in: workspace.id,
            selectedNodeId: nil
        )
        let firstId = try XCTUnwrap(engine.nodeId(for: first))

        let initial = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0
            )
        )
        let preFrame = try XCTUnwrap(initial.frames[first])

        let mutation = engine.applyMutation(
            .moveWindow(windowId: firstId, direction: .right, orientation: .horizontal),
            in: workspace.id
        )
        XCTAssertTrue(mutation.applied)
        XCTAssertTrue(mutation.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))
        let probeTime = CACurrentMediaTime()

        let animated = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0,
                animationTime: probeTime + 0.08
            )
        )
        let settled = engine.calculateLayout(
            ZigNiriLayoutRequest(
                workspaceId: workspace.id,
                monitorFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                screenFrame: nil,
                gaps: ZigNiriGaps(horizontal: 8, vertical: 8),
                scale: 2,
                workingArea: nil,
                orientation: .horizontal,
                viewportOffset: 0,
                animationTime: probeTime + 0.35
            )
        )

        let animatedFrame = try XCTUnwrap(animated.frames[first])
        let settledFrame = try XCTUnwrap(settled.frames[first])
        XCTAssertNotEqual(preFrame, settledFrame)
        XCTAssertNotEqual(animatedFrame, settledFrame)
    }

    func testConsumeAndExpelMutationsSignalStructuralAnimation() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-structural-animation-consume-expel")
        let engine = ZigNiriEngine(maxWindowsPerColumn: 3)
        let first = makeWindowHandle()
        let second = makeWindowHandle()
        let third = makeWindowHandle()

        _ = engine.syncWindows(
            [first, second, third],
            in: workspace.id,
            selectedNodeId: nil
        )
        let secondId = try XCTUnwrap(engine.nodeId(for: second))

        var consumeResult: ZigNiriMutationResult?
        for direction in [Direction.left, .right] {
            let result = engine.applyMutation(
                .consumeWindow(windowId: secondId, direction: direction),
                in: workspace.id
            )
            if result.applied {
                consumeResult = result
                break
            }
        }
        let resolvedConsume = try XCTUnwrap(consumeResult)
        XCTAssertTrue(resolvedConsume.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))

        let expelSourceId = try XCTUnwrap(engine.nodeId(for: second))
        let postConsumeView = try XCTUnwrap(engine.workspaceView(for: workspace.id))
        let expelSourceColumnId = try XCTUnwrap(postConsumeView.windowsById[expelSourceId]?.columnId)
        _ = engine.applyMutation(
            .setColumnDisplay(columnId: expelSourceColumnId, display: .tabbed),
            in: workspace.id
        )

        var expelResult: ZigNiriMutationResult?
        for direction in [Direction.left, .right] {
            let result = engine.applyMutation(
                .expelWindow(windowId: expelSourceId, direction: direction),
                in: workspace.id
            )
            if result.applied {
                expelResult = result
                break
            }
        }
        let resolvedExpel = try XCTUnwrap(expelResult)
        XCTAssertTrue(resolvedExpel.structuralAnimationActive)
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id))
    }

    func testWorkspaceSwitchStartsStructuralAnimationState() throws {
        let workspace = WorkspaceDescriptor(name: "zig-niri-workspace-switch-animation")
        let engine = ZigNiriEngine()
        let handle = makeWindowHandle()

        _ = engine.syncWindows(
            [handle],
            in: workspace.id,
            selectedNodeId: nil
        )

        XCTAssertTrue(engine.startWorkspaceSwitchAnimation(in: workspace.id))
        let probeTime = CACurrentMediaTime()
        XCTAssertTrue(engine.hasActiveStructuralAnimation(in: workspace.id, at: probeTime + 0.05))
        XCTAssertFalse(engine.hasActiveStructuralAnimation(in: workspace.id, at: probeTime + 0.35))
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
