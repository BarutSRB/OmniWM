import ApplicationServices
import CZigLayout
import Foundation
import XCTest

@testable import OmniWM

@MainActor
final class NiriTxnIntegrationTests: XCTestCase {
    private func makeWindow() -> NiriWindow {
        let pid = getpid()
        let handle = WindowHandle(
            id: UUID(),
            pid: pid,
            axElement: AXUIElementCreateApplication(pid)
        )
        return NiriWindow(handle: handle)
    }

    private func makeSeededSingleWindowContext(
        workspaceName: String
    ) throws -> (
        engine: NiriLayoutEngine,
        workspace: WorkspaceDescriptor,
        context: NiriLayoutZigKernel.LayoutContext,
        column: NiriContainer,
        window: NiriWindow
    ) {
        let workspace = WorkspaceDescriptor(name: workspaceName)
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)
        let window = makeWindow()
        column.appendChild(window)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        return (engine: engine, workspace: workspace, context: context, column: column, window: window)
    }

    func testNavigationTxnUpdatesActiveTileAndExportsDelta() throws {
        let workspace = WorkspaceDescriptor(name: "txn-nav")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)

        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        column.appendChild(firstWindow)
        column.appendChild(secondWindow)
        column.setActiveTileIdx(0)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.NavigationRequest(
            op: .focusWindowBottom,
            sourceWindowId: firstWindow.id,
            sourceColumnId: column.id
        )

        let outcome = NiriStateZigKernel.applyNavigation(
            context: context,
            request: .init(request: request)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertNotNil(outcome.delta)
        XCTAssertEqual(outcome.targetWindowId, secondWindow.id)
        XCTAssertEqual(outcome.delta?.columns.first?.column.activeTileIdx, 1)
    }

    func testMutationTxnExportsTargetAndDeltaCounts() throws {
        let workspace = WorkspaceDescriptor(name: "txn-mutation")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspace.id)
        let firstColumn = try XCTUnwrap(root.columns.first)

        let leftWindow = makeWindow()
        let rightWindow = makeWindow()
        firstColumn.appendChild(leftWindow)

        let secondColumn = NiriContainer()
        root.appendChild(secondColumn)
        secondColumn.appendChild(rightWindow)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .moveWindowHorizontal,
            sourceWindowId: leftWindow.id,
            direction: .right,
            maxWindowsPerColumn: engine.maxWindowsPerColumn
        )

        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(request: request)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        XCTAssertNotNil(outcome.targetWindowId)
        XCTAssertGreaterThanOrEqual(outcome.delta?.columns.count ?? 0, 1)
        XCTAssertLessThanOrEqual(outcome.delta?.columns.count ?? 0, snapshot.columns.count)
        XCTAssertEqual(outcome.delta?.windows.count, snapshot.windows.count)
    }

    func testCreateColumnAndMoveTxnAppliesAndReindexesMovedWindow() throws {
        let workspace = WorkspaceDescriptor(name: "txn-create-column")
        let engine = NiriLayoutEngine(maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspace.id)
        let sourceColumn = try XCTUnwrap(root.columns.first)

        let movingWindow = makeWindow()
        let remainingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)
        sourceColumn.appendChild(remainingWindow)
        sourceColumn.setActiveTileIdx(0)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .createColumnAndMove,
            sourceWindowId: movingWindow.id,
            direction: .right,
            maxVisibleColumns: engine.maxVisibleColumns
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(
                request: request,
                createdColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        let delta = try XCTUnwrap(outcome.delta)

        let movedRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == movingWindow.id })
        let remainingRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == remainingWindow.id })
        XCTAssertEqual(movedRecord.columnOrderIndex, 1)
        XCTAssertEqual(remainingRecord.columnOrderIndex, 0)
    }

    func testSwapWindowHorizontalTxnRecomputesWindowColumnMetadata() throws {
        let workspace = WorkspaceDescriptor(name: "txn-swap-horizontal")
        let engine = NiriLayoutEngine(infiniteLoop: false)
        let root = engine.ensureRoot(for: workspace.id)
        let sourceColumn = try XCTUnwrap(root.columns.first)

        let sourceActiveWindow = makeWindow()
        let sourceSecondaryWindow = makeWindow()
        sourceColumn.appendChild(sourceActiveWindow)
        sourceColumn.appendChild(sourceSecondaryWindow)
        sourceColumn.setActiveTileIdx(0)

        let targetColumn = NiriContainer()
        root.appendChild(targetColumn)
        let targetActiveWindow = makeWindow()
        targetColumn.appendChild(targetActiveWindow)
        targetColumn.setActiveTileIdx(0)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .swapWindowHorizontal,
            sourceWindowId: sourceActiveWindow.id,
            direction: .right,
            infiniteLoop: false
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(request: request)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        let delta = try XCTUnwrap(outcome.delta)

        let movedSourceRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == sourceActiveWindow.id })
        let movedTargetRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == targetActiveWindow.id })

        XCTAssertEqual(movedSourceRecord.columnOrderIndex, 1)
        XCTAssertEqual(movedTargetRecord.columnOrderIndex, 0)
    }

    func testWorkspaceTxnMutatesBothContextsAndExportsBothDeltas() throws {
        let sourceWorkspace = WorkspaceDescriptor(name: "txn-source")
        let targetWorkspace = WorkspaceDescriptor(name: "txn-target")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3, infiniteLoop: false)

        let sourceRoot = engine.ensureRoot(for: sourceWorkspace.id)
        let sourceColumn = try XCTUnwrap(sourceRoot.columns.first)
        let movingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)

        let targetRoot = engine.ensureRoot(for: targetWorkspace.id)
        XCTAssertEqual(targetRoot.allWindows.count, 0)

        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        let sourceContext = try XCTUnwrap(engine.ensureLayoutContext(for: sourceWorkspace.id))
        let targetContext = try XCTUnwrap(engine.ensureLayoutContext(for: targetWorkspace.id))

        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: sourceContext, snapshot: sourceSnapshot),
            Int32(OMNI_OK)
        )
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: targetContext, snapshot: targetSnapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveWindowToWorkspace,
            sourceWindowId: movingWindow.id,
            maxVisibleColumns: engine.maxVisibleColumns
        )

        let outcome = NiriStateZigKernel.applyWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: .init(
                request: request,
                targetCreatedColumnId: UUID(),
                sourcePlaceholderColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        XCTAssertNotNil(outcome.sourceDelta)
        XCTAssertNotNil(outcome.targetDelta)
        XCTAssertEqual(outcome.sourceDelta?.windows.count, 0)
        XCTAssertEqual(outcome.targetDelta?.windows.count, 1)
        XCTAssertNotNil(outcome.movedWindowId)
    }

    func testMutationTxnFailsClosedForMissingRuntimeIds() throws {
        let workspace = WorkspaceDescriptor(name: "txn-invalid")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)
        let window = makeWindow()
        column.appendChild(window)

        let context = try XCTUnwrap(NiriLayoutZigKernel.LayoutContext())
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(
                context: context,
                export: NiriStateZigKernel.RuntimeStateExport(columns: [], windows: [])
            ),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .removeWindow,
            sourceWindowId: window.id
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(
                request: request,
                placeholderColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_OUT_OF_RANGE))
        XCTAssertFalse(outcome.applied)
        XCTAssertNil(outcome.delta)

        let exported = NiriStateZigKernel.exportDelta(context: context)
        XCTAssertEqual(exported.rc, Int32(OMNI_OK))
        XCTAssertEqual(exported.export.columns.count, 0)
        XCTAssertEqual(exported.export.windows.count, 0)
    }

    func testNavigationTxnRejectsUnknownSourceWindowId() throws {
        let workspace = WorkspaceDescriptor(name: "txn-nav-out-of-range")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)
        column.appendChild(makeWindow())

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.NavigationRequest(
            op: .focusWindowBottom,
            sourceWindowId: NodeId(uuid: UUID())
        )
        let outcome = NiriStateZigKernel.applyNavigation(
            context: context,
            request: .init(request: request)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_OUT_OF_RANGE))
        XCTAssertFalse(outcome.applied)
    }

    func testMutationTxnValidateSelectionUsesSelectedAndFocusedWindowIds() throws {
        let workspace = WorkspaceDescriptor(name: "txn-selected-focused-coherence")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)
        let selectedWindow = makeWindow()
        column.appendChild(selectedWindow)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .validateSelection,
            selectedNodeId: selectedWindow.id,
            focusedWindowId: selectedWindow.id
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(request: request)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertEqual(outcome.targetNode?.kind, .window)
        XCTAssertEqual(outcome.targetNode?.nodeId, selectedWindow.id)
    }

    func testMutationTxnMoveWindowToColumnHonorsSourceAndTargetIds() throws {
        let workspace = WorkspaceDescriptor(name: "txn-source-target-coherence")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let root = engine.ensureRoot(for: workspace.id)
        let sourceColumn = try XCTUnwrap(root.columns.first)
        let movingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)

        let targetColumn = NiriContainer()
        root.appendChild(targetColumn)
        let targetResidentWindow = makeWindow()
        targetColumn.appendChild(targetResidentWindow)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .moveWindowToColumn,
            sourceWindowId: movingWindow.id,
            maxWindowsPerColumn: engine.maxWindowsPerColumn,
            targetColumnId: targetColumn.id
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(request: request, placeholderColumnId: UUID())
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        let movedRecord = try XCTUnwrap(outcome.delta?.windows.first { $0.window.windowId == movingWindow.id })
        let targetResidentRecord = try XCTUnwrap(
            outcome.delta?.windows.first { $0.window.windowId == targetResidentWindow.id }
        )
        XCTAssertEqual(movedRecord.window.columnId, targetResidentRecord.window.columnId)
    }

    func testWorkspaceTxnRejectsUnknownSourceWindowId() throws {
        let sourceWorkspace = WorkspaceDescriptor(name: "txn-source-out-of-range")
        let targetWorkspace = WorkspaceDescriptor(name: "txn-target-out-of-range")
        let engine = NiriLayoutEngine(maxVisibleColumns: 3)

        let sourceRoot = engine.ensureRoot(for: sourceWorkspace.id)
        let sourceColumn = try XCTUnwrap(sourceRoot.columns.first)
        sourceColumn.appendChild(makeWindow())

        let targetRoot = engine.ensureRoot(for: targetWorkspace.id)
        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        let sourceContext = try XCTUnwrap(engine.ensureLayoutContext(for: sourceWorkspace.id))
        let targetContext = try XCTUnwrap(engine.ensureLayoutContext(for: targetWorkspace.id))

        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: sourceContext, snapshot: sourceSnapshot),
            Int32(OMNI_OK)
        )
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: targetContext, snapshot: targetSnapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveWindowToWorkspace,
            sourceWindowId: NodeId(uuid: UUID()),
            maxVisibleColumns: engine.maxVisibleColumns
        )
        let outcome = NiriStateZigKernel.applyWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: .init(
                request: request,
                targetCreatedColumnId: UUID(),
                sourcePlaceholderColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_OUT_OF_RANGE))
        XCTAssertFalse(outcome.applied)
    }

    func testMutationTxnRejectsMissingRequiredSourceWindowId() throws {
        let workspace = WorkspaceDescriptor(name: "txn-missing-source-id")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)
        column.appendChild(makeWindow())

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(op: .removeWindow)
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(
                request: request,
                placeholderColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_INVALID_ARGS))
        XCTAssertFalse(outcome.applied)
    }

    func testMutationTxnRejectsUnknownTargetColumnId() throws {
        let workspace = WorkspaceDescriptor(name: "txn-unknown-target-column")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let root = engine.ensureRoot(for: workspace.id)
        let sourceColumn = try XCTUnwrap(root.columns.first)
        let movingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)

        let targetColumn = NiriContainer()
        root.appendChild(targetColumn)
        targetColumn.appendChild(makeWindow())

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.MutationRequest(
            op: .moveWindowToColumn,
            sourceWindowId: movingWindow.id,
            maxWindowsPerColumn: engine.maxWindowsPerColumn,
            targetColumnId: NodeId(uuid: UUID())
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(request: request, placeholderColumnId: UUID())
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_OUT_OF_RANGE))
        XCTAssertFalse(outcome.applied)
    }

    func testWorkspaceTxnRejectsSourceWindowIdFromWrongWorkspace() throws {
        let sourceWorkspace = WorkspaceDescriptor(name: "txn-source-ownership")
        let targetWorkspace = WorkspaceDescriptor(name: "txn-target-ownership")
        let engine = NiriLayoutEngine(maxVisibleColumns: 3)

        let sourceRoot = engine.ensureRoot(for: sourceWorkspace.id)
        let sourceColumn = try XCTUnwrap(sourceRoot.columns.first)
        sourceColumn.appendChild(makeWindow())

        let targetRoot = engine.ensureRoot(for: targetWorkspace.id)
        let targetColumn = try XCTUnwrap(targetRoot.columns.first)
        let targetWindow = makeWindow()
        targetColumn.appendChild(targetWindow)

        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        let sourceContext = try XCTUnwrap(engine.ensureLayoutContext(for: sourceWorkspace.id))
        let targetContext = try XCTUnwrap(engine.ensureLayoutContext(for: targetWorkspace.id))

        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: sourceContext, snapshot: sourceSnapshot),
            Int32(OMNI_OK)
        )
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: targetContext, snapshot: targetSnapshot),
            Int32(OMNI_OK)
        )

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveWindowToWorkspace,
            sourceWindowId: targetWindow.id,
            maxVisibleColumns: engine.maxVisibleColumns
        )
        let outcome = NiriStateZigKernel.applyWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: .init(
                request: request,
                targetCreatedColumnId: UUID(),
                sourcePlaceholderColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_OUT_OF_RANGE))
        XCTAssertFalse(outcome.applied)
    }

    func testMutationTxnRequiredIdGuardsRejectMissingIds() throws {
        let fixture = try makeSeededSingleWindowContext(workspaceName: "txn-required-id-guards")

        let missingSourceWindowOps: [NiriStateZigKernel.MutationOp] = [
            .moveWindowVertical,
            .swapWindowVertical,
            .moveWindowHorizontal,
            .swapWindowHorizontal,
            .swapWindowsByMove,
            .insertWindowByMove,
            .moveWindowToColumn,
            .createColumnAndMove,
            .insertWindowInNewColumn,
            .consumeWindow,
            .expelWindow,
            .removeWindow,
            .fallbackSelectionOnRemoval,
        ]
        for op in missingSourceWindowOps {
            let request = NiriStateZigKernel.MutationRequest(op: op)
            let outcome = NiriStateZigKernel.applyMutation(
                context: fixture.context,
                request: .init(request: request)
            )
            XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_INVALID_ARGS), "Expected missing source window ID rejection for \(op)")
            XCTAssertFalse(outcome.applied)
        }

        let missingSourceColumnOps: [NiriStateZigKernel.MutationOp] = [
            .moveColumn,
            .cleanupEmptyColumn,
            .normalizeWindowSizes,
        ]
        for op in missingSourceColumnOps {
            let request = NiriStateZigKernel.MutationRequest(op: op)
            let outcome = NiriStateZigKernel.applyMutation(
                context: fixture.context,
                request: .init(request: request)
            )
            XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_INVALID_ARGS), "Expected missing source column ID rejection for \(op)")
            XCTAssertFalse(outcome.applied)
        }

        let missingTargetColumnOps: [NiriStateZigKernel.MutationOp] = [
            .moveWindowToColumn,
        ]
        for op in missingTargetColumnOps {
            let request = NiriStateZigKernel.MutationRequest(
                op: op,
                sourceWindowId: fixture.window.id,
                maxWindowsPerColumn: fixture.engine.maxWindowsPerColumn
            )
            let outcome = NiriStateZigKernel.applyMutation(
                context: fixture.context,
                request: .init(request: request)
            )
            XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_INVALID_ARGS), "Expected missing target column ID rejection for \(op)")
            XCTAssertFalse(outcome.applied)
        }
    }

    func testNavigationTxnRequiredSelectionGuardsRejectMissingSelectionIds() throws {
        let fixture = try makeSeededSingleWindowContext(workspaceName: "txn-required-nav-selection")

        let requiredSelectionOps: [NiriStateZigKernel.NavigationOp] = [
            .moveByColumns,
            .moveVertical,
            .focusTarget,
            .focusDownOrLeft,
            .focusUpOrRight,
            .focusWindowIndex,
            .focusWindowTop,
            .focusWindowBottom,
        ]

        for op in requiredSelectionOps {
            let request = NiriStateZigKernel.NavigationRequest(op: op)
            let outcome = NiriStateZigKernel.applyNavigation(
                context: fixture.context,
                request: .init(request: request)
            )
            XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_INVALID_ARGS), "Expected missing navigation selection ID rejection for \(op)")
            XCTAssertFalse(outcome.applied)
        }
    }

    func testEngineAddWindowIgnoresUnknownSelectedNodeId() {
        let workspace = WorkspaceDescriptor(name: "txn-engine-add-window-stale-selection")
        let engine = NiriLayoutEngine(maxVisibleColumns: 3)
        _ = engine.ensureRoot(for: workspace.id)

        let pid = getpid()
        let handle = WindowHandle(
            id: UUID(),
            pid: pid,
            axElement: AXUIElementCreateApplication(pid)
        )

        let added = engine.addWindow(
            handle: handle,
            to: workspace.id,
            afterSelection: NodeId(uuid: UUID())
        )

        XCTAssertEqual(added.windowId, handle.id)
        XCTAssertNotNil(engine.findNode(by: added.id))
    }

    func testMutationTxnValidateSelectionAcceptsUnknownSelectedNodeId() throws {
        let fixture = try makeSeededSingleWindowContext(workspaceName: "txn-validate-selection-unknown-selected-id")
        let request = NiriStateZigKernel.MutationRequest(
            op: .validateSelection,
            selectedNodeId: NodeId(uuid: UUID())
        )
        let outcome = NiriStateZigKernel.applyTxn(
            .mutation(
                context: fixture.context,
                request: .init(request: request)
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertFalse(outcome.applied)
        XCTAssertEqual(outcome.targetNode?.kind, .window)
        XCTAssertEqual(outcome.targetNode?.nodeId, fixture.window.id)
    }

    func testRuntimeWorkspaceStoreMutationCommandProjectsIntoSwiftGraph() throws {
        let workspace = WorkspaceDescriptor(name: "txn-runtime-store-mutation")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspace.id)
        let sourceColumn = try XCTUnwrap(root.columns.first)
        let movingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)

        let targetColumn = NiriContainer()
        root.appendChild(targetColumn)
        targetColumn.appendChild(makeWindow())

        let store = engine.runtimeStore(for: workspace.id)
        let outcome: NiriRuntimeMutationOutcome
        switch store.executeMutation(
            .moveWindowHorizontal(
                sourceWindowId: movingWindow.id,
                direction: .right
            )
        ) {
        case let .success(resolved):
            outcome = resolved
        case let .failure(error):
            XCTFail("runtime mutation command failed: \(error)")
            return
        }

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)

        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movingWindow, in: workspace.id))
        XCTAssertEqual(movedColumn.id, targetColumn.id)
    }

    func testRuntimeWorkspaceStoreQueryViewReflectsRuntimeOrderAndHandles() throws {
        let workspace = WorkspaceDescriptor(name: "txn-runtime-store-view")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspace.id)
        let firstColumn = try XCTUnwrap(root.columns.first)
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        firstColumn.appendChild(firstWindow)
        firstColumn.appendChild(secondWindow)
        firstColumn.setActiveTileIdx(1)

        let secondColumn = NiriContainer()
        root.appendChild(secondColumn)
        let thirdWindow = makeWindow()
        secondColumn.appendChild(thirdWindow)

        engine.handleToNode[firstWindow.handle] = firstWindow
        engine.handleToNode[secondWindow.handle] = secondWindow
        engine.handleToNode[thirdWindow.handle] = thirdWindow

        let store = engine.runtimeStore(for: workspace.id)
        let view: NiriRuntimeWorkspaceView
        switch store.queryView() {
        case let .success(resolved):
            view = resolved
        case let .failure(error):
            XCTFail("runtime query view failed: \(error)")
            return
        }

        XCTAssertEqual(view.columns.count, 2)
        XCTAssertEqual(view.windows.count, 3)
        XCTAssertEqual(view.columns.first?.windowIds, [firstWindow.id, secondWindow.id])
        XCTAssertEqual(view.columns.first?.activeTileIndex, 1)
        XCTAssertEqual(view.window(for: firstWindow.id)?.handle, firstWindow.handle)
        XCTAssertEqual(view.window(for: thirdWindow.id)?.columnId, secondColumn.id)
    }

    func testRuntimeWorkspaceStoreWorkspaceCommandMovesWindowAcrossContexts() throws {
        let sourceWorkspace = WorkspaceDescriptor(name: "txn-runtime-store-workspace-source")
        let targetWorkspace = WorkspaceDescriptor(name: "txn-runtime-store-workspace-target")
        let engine = NiriLayoutEngine(maxVisibleColumns: 3)

        let sourceRoot = engine.ensureRoot(for: sourceWorkspace.id)
        let sourceColumn = try XCTUnwrap(sourceRoot.columns.first)
        let movingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)

        _ = engine.ensureRoot(for: targetWorkspace.id)

        let sourceStore = engine.runtimeStore(for: sourceWorkspace.id)
        let targetStore = engine.runtimeStore(for: targetWorkspace.id, ensureWorkspaceRoot: true)

        let outcome: NiriRuntimeWorkspaceOutcome
        switch sourceStore.executeWorkspace(
            .moveWindowToWorkspace(
                sourceWindowId: movingWindow.id,
                targetCreatedColumnId: UUID(),
                sourcePlaceholderColumnId: UUID()
            ),
            targetStore: targetStore
        ) {
        case let .success(resolved):
            outcome = resolved
        case let .failure(error):
            XCTFail("runtime workspace command failed: \(error)")
            return
        }

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        XCTAssertNotNil(outcome.movedWindowId)
        XCTAssertEqual(outcome.sourceDelta?.windows.count, 0)
        XCTAssertEqual(outcome.targetDelta?.windows.count, 1)
    }

    func testRuntimeRenderReturnsTypedMismatchAndRecoversAfterExplicitReseed() throws {
        let workspace = WorkspaceDescriptor(name: "txn-runtime-render-retry")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))

        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(
                context: context,
                export: NiriStateZigKernel.RuntimeStateExport(columns: [], windows: [])
            ),
            Int32(OMNI_OK)
        )

        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        column.resolveAndCacheWidth(workingAreaWidth: frame.width, gaps: 10)
        XCTAssertThrowsError(
            try NiriLayoutZigKernel.run(
                context: context,
                columns: engine.columns(in: workspace.id),
                orientation: .horizontal,
                primaryGap: 10,
                secondaryGap: 10,
                workingFrame: frame,
                viewFrame: frame,
                fullscreenFrame: frame,
                viewStart: 0,
                viewportSpan: frame.width,
                workspaceOffset: 0,
                scale: 2,
                tabIndicatorWidth: 0,
                time: 0
            )
        ) { error in
            guard case let NiriLayoutZigKernel.KernelCallError.runtimeRenderStateMismatch(rc, columns, windows) = error else {
                return XCTFail("Expected runtimeRenderStateMismatch, got \(error)")
            }
            XCTAssertEqual(rc, Int32(OMNI_ERR_OUT_OF_RANGE))
            XCTAssertEqual(columns, 1)
            XCTAssertEqual(windows, 0)
        }

        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(
                context: context,
                snapshot: NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
            ),
            Int32(OMNI_OK)
        )

        let result = try NiriLayoutZigKernel.run(
            context: context,
            columns: engine.columns(in: workspace.id),
            orientation: .horizontal,
            primaryGap: 10,
            secondaryGap: 10,
            workingFrame: frame,
            viewFrame: frame,
            fullscreenFrame: frame,
            viewStart: 0,
            viewportSpan: frame.width,
            workspaceOffset: 0,
            scale: 2,
            tabIndicatorWidth: 0,
            time: 0
        )

        XCTAssertEqual(result.columns.count, 1)
        XCTAssertEqual(result.windows.count, 0)

        let exported = NiriStateZigKernel.snapshotRuntimeState(context: context)
        XCTAssertEqual(exported.rc, Int32(OMNI_OK))
        XCTAssertEqual(exported.export.columns.count, 1)
        XCTAssertEqual(exported.export.windows.count, 0)
    }
}
