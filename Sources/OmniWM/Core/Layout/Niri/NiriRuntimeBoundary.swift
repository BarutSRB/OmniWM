import CZigLayout
import Foundation

struct NiriRuntimeWorkspaceView {
    struct ColumnView {
        let columnId: NodeId
        let orderIndex: Int
        let windowIds: [NodeId]
        let activeTileIndex: Int
        let isTabbed: Bool
        let widthKind: UInt8
        let widthValue: Double
        let width: ProportionalSize?
        let isFullWidth: Bool
        let hasSavedWidth: Bool
        let savedWidthKind: UInt8
        let savedWidthValue: Double
        let savedWidth: ProportionalSize?
    }

    struct WindowView {
        let windowId: NodeId
        let columnId: NodeId
        let columnOrderIndex: Int
        let rowIndex: Int
        let sizeValue: Double
        let heightKind: UInt8
        let heightValue: Double
        let height: WeightedSize?
        let handle: WindowHandle?
    }

    let workspaceId: WorkspaceDescriptor.ID
    let columns: [ColumnView]
    let windows: [WindowView]
    let columnsById: [NodeId: ColumnView]
    let windowsById: [NodeId: WindowView]

    func column(for columnId: NodeId) -> ColumnView? {
        columnsById[columnId]
    }

    func window(for windowId: NodeId) -> WindowView? {
        windowsById[windowId]
    }
}

enum NiriRuntimeSelectionAnchor: Equatable {
    case window(windowId: NodeId, columnId: NodeId?)
    case column(columnId: NodeId)

    var sourceWindowId: NodeId? {
        switch self {
        case let .window(windowId, _):
            return windowId
        case .column:
            return nil
        }
    }

    var sourceColumnId: NodeId? {
        switch self {
        case let .window(_, columnId):
            return columnId
        case let .column(columnId):
            return columnId
        }
    }
}

enum NiriRuntimeNavigationCommand {
    case moveByColumns(selection: NiriRuntimeSelectionAnchor, step: Int, targetRowIndex: Int?)
    case moveVertical(selection: NiriRuntimeSelectionAnchor, direction: Direction, orientation: Monitor.Orientation)
    case focusTarget(selection: NiriRuntimeSelectionAnchor, direction: Direction, orientation: Monitor.Orientation)
    case focusDownOrLeft(selection: NiriRuntimeSelectionAnchor)
    case focusUpOrRight(selection: NiriRuntimeSelectionAnchor)
    case focusColumnFirst(selection: NiriRuntimeSelectionAnchor?)
    case focusColumnLast(selection: NiriRuntimeSelectionAnchor?)
    case focusColumnIndex(selection: NiriRuntimeSelectionAnchor?, columnIndex: Int)
    case focusWindowIndex(selection: NiriRuntimeSelectionAnchor, windowIndex: Int)
    case focusWindowTop(selection: NiriRuntimeSelectionAnchor)
    case focusWindowBottom(selection: NiriRuntimeSelectionAnchor)
}

enum NiriRuntimeMutationCommand {
    case moveWindowVertical(sourceWindowId: NodeId, direction: Direction)
    case swapWindowVertical(sourceWindowId: NodeId, direction: Direction)
    case moveWindowHorizontal(sourceWindowId: NodeId, direction: Direction)
    case swapWindowHorizontal(sourceWindowId: NodeId, direction: Direction)
    case swapWindowsByMove(sourceWindowId: NodeId, targetWindowId: NodeId)
    case insertWindowByMove(sourceWindowId: NodeId, targetWindowId: NodeId, position: InsertPosition)
    case moveWindowToColumn(sourceWindowId: NodeId, targetColumnId: NodeId, placeholderColumnId: UUID)
    case createColumnAndMove(sourceWindowId: NodeId, direction: Direction, createdColumnId: UUID, placeholderColumnId: UUID)
    case insertWindowInNewColumn(sourceWindowId: NodeId, insertColumnIndex: Int, createdColumnId: UUID, placeholderColumnId: UUID)
    case moveColumn(sourceColumnId: NodeId, direction: Direction)
    case consumeWindow(sourceWindowId: NodeId, direction: Direction, placeholderColumnId: UUID)
    case expelWindow(sourceWindowId: NodeId, direction: Direction, createdColumnId: UUID, placeholderColumnId: UUID)
    case cleanupEmptyColumn(sourceColumnId: NodeId, placeholderColumnId: UUID)
    case normalizeColumnSizes
    case normalizeWindowSizes(sourceColumnId: NodeId)
    case balanceSizes
    case setColumnDisplay(sourceColumnId: NodeId, mode: ColumnDisplay)
    case setColumnActiveTile(sourceColumnId: NodeId, tileIndex: Int)
    case setColumnWidth(
        sourceColumnId: NodeId,
        width: ProportionalSize,
        isFullWidth: Bool,
        savedWidth: ProportionalSize?
    )
    case setWindowHeight(sourceWindowId: NodeId, height: WeightedSize)
    case setWindowSizingMode(sourceWindowId: NodeId, mode: SizingMode)
}

enum NiriRuntimeLifecycleCommand {
    case addWindow(
        incomingHandle: WindowHandle,
        selectedNodeId: NodeId?,
        focusedWindowId: NodeId?,
        createdColumnId: UUID,
        placeholderColumnId: UUID
    )
    case removeWindow(sourceWindowId: NodeId, placeholderColumnId: UUID)
    case validateSelection(selectedNodeId: NodeId?, focusedWindowId: NodeId?)
    case fallbackSelectionOnRemoval(sourceWindowId: NodeId)
}

enum NiriRuntimeWorkspaceCommand {
    case moveWindowToWorkspace(
        sourceWindowId: NodeId,
        targetCreatedColumnId: UUID,
        sourcePlaceholderColumnId: UUID
    )
    case moveColumnToWorkspace(
        sourceColumnId: NodeId,
        sourcePlaceholderColumnId: UUID?
    )
}

enum NiriRuntimeCommand {
    case navigation(NiriRuntimeNavigationCommand)
    case mutation(NiriRuntimeMutationCommand)
    case lifecycle(NiriRuntimeLifecycleCommand)
    case workspace(NiriRuntimeWorkspaceCommand)
}

struct NiriRuntimeNavigationOutcome {
    let rc: Int32
    let applied: Bool
    let targetWindowId: NodeId?
    let refreshColumnIds: [NodeId]
    let delta: NiriStateZigKernel.DeltaExport?
}

struct NiriRuntimeMutationOutcome {
    let rc: Int32
    let applied: Bool
    let targetWindowId: NodeId?
    let targetNode: NiriStateZigKernel.RuntimeNodeTarget?
    let delta: NiriStateZigKernel.DeltaExport?
}

struct NiriRuntimeLifecycleOutcome {
    let rc: Int32
    let applied: Bool
    let targetWindowId: NodeId?
    let targetNode: NiriStateZigKernel.RuntimeNodeTarget?
    let delta: NiriStateZigKernel.DeltaExport?
}

struct NiriRuntimeWorkspaceOutcome {
    let rc: Int32
    let applied: Bool
    let sourceSelectionWindowId: NodeId?
    let targetSelectionWindowId: NodeId?
    let movedWindowId: NodeId?
    let sourceDelta: NiriStateZigKernel.DeltaExport?
    let targetDelta: NiriStateZigKernel.DeltaExport?
}

enum NiriRuntimeCommandOutcome {
    case navigation(NiriRuntimeNavigationOutcome)
    case mutation(NiriRuntimeMutationOutcome)
    case lifecycle(NiriRuntimeLifecycleOutcome)
    case workspace(NiriRuntimeWorkspaceOutcome)
}

enum NiriRuntimeBoundaryError: Error, CustomStringConvertible {
    case missingWorkspaceRoot(workspaceId: WorkspaceDescriptor.ID)
    case missingRuntimeContext(workspaceId: WorkspaceDescriptor.ID)
    case workspaceTargetRequired
    case projection(NiriLayoutEngine.RuntimeProjectionError)
    case runtimeSnapshot(workspaceId: WorkspaceDescriptor.ID, error: NiriStateZigKernel.RuntimeExportDecodeError)

    var description: String {
        switch self {
        case let .missingWorkspaceRoot(workspaceId):
            return "runtime boundary missing workspace root for \(workspaceId)"
        case let .missingRuntimeContext(workspaceId):
            return "runtime boundary missing runtime context for \(workspaceId)"
        case .workspaceTargetRequired:
            return "workspace command requires a target workspace store"
        case let .projection(error):
            return error.description
        case let .runtimeSnapshot(workspaceId, error):
            return "runtime snapshot failed workspace=\(workspaceId): \(error.description)"
        }
    }
}

final class NiriRuntimeWorkspaceStore {
    let workspaceId: WorkspaceDescriptor.ID

    private unowned let engine: NiriLayoutEngine
    private let ensureWorkspaceRoot: Bool

    init(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        ensureWorkspaceRoot: Bool
    ) {
        self.engine = engine
        self.workspaceId = workspaceId
        self.ensureWorkspaceRoot = ensureWorkspaceRoot
    }

    func execute(
        _ command: NiriRuntimeCommand,
        targetStore: NiriRuntimeWorkspaceStore? = nil
    ) -> Result<NiriRuntimeCommandOutcome, NiriRuntimeBoundaryError> {
        switch command {
        case let .navigation(command):
            switch executeNavigation(command) {
            case let .success(outcome):
                return .success(.navigation(outcome))
            case let .failure(error):
                return .failure(error)
            }
        case let .mutation(command):
            switch executeMutation(command) {
            case let .success(outcome):
                return .success(.mutation(outcome))
            case let .failure(error):
                return .failure(error)
            }
        case let .lifecycle(command):
            switch executeLifecycle(command) {
            case let .success(outcome):
                return .success(.lifecycle(outcome))
            case let .failure(error):
                return .failure(error)
            }
        case let .workspace(command):
            guard let targetStore else {
                return .failure(.workspaceTargetRequired)
            }
            switch executeWorkspace(command, targetStore: targetStore) {
            case let .success(outcome):
                return .success(.workspace(outcome))
            case let .failure(error):
                return .failure(error)
            }
        }
    }

    func executeNavigation(
        _ command: NiriRuntimeNavigationCommand
    ) -> Result<NiriRuntimeNavigationOutcome, NiriRuntimeBoundaryError> {
        guard let context = prepareContext() else {
            return .failure(.missingRuntimeContext(workspaceId: workspaceId))
        }

        let request = navigationRequest(for: command)
        let outcome = NiriStateZigKernel.applyNavigation(
            context: context,
            request: .init(request: request)
        )

        if outcome.rc == 0 {
            switch engine.applyProjectedRuntimeExport(
                context: context,
                workspaceId: workspaceId,
                delta: outcome.delta
            ) {
            case .success:
                break
            case let .failure(error):
                return .failure(.projection(error))
            }
        }

        return .success(
            NiriRuntimeNavigationOutcome(
                rc: outcome.rc,
                applied: outcome.applied,
                targetWindowId: outcome.targetWindowId,
                refreshColumnIds: engine.navigationRefreshColumnIds(
                    sourceColumnId: outcome.refreshSourceColumnId,
                    targetColumnId: outcome.refreshTargetColumnId
                ),
                delta: outcome.delta
            )
        )
    }

    func executeMutation(
        _ command: NiriRuntimeMutationCommand
    ) -> Result<NiriRuntimeMutationOutcome, NiriRuntimeBoundaryError> {
        guard let context = prepareContext() else {
            return .failure(.missingRuntimeContext(workspaceId: workspaceId))
        }

        switch command {
        case let .setColumnDisplay(sourceColumnId, mode):
            return executeRuntimeSnapshotMutation(context: context) { export in
                guard let columnIndex = export.columns.firstIndex(where: { $0.columnId == sourceColumnId }) else {
                    return nil
                }
                let column = export.columns[columnIndex]
                let isTabbed = mode == .tabbed
                if column.isTabbed == isTabbed {
                    return (
                        applied: false,
                        targetWindowId: nil,
                        targetNode: nil
                    )
                }
                let nextActiveTile: Int
                if column.windowCount == 0 {
                    nextActiveTile = 0
                } else {
                    nextActiveTile = min(column.activeTileIdx, column.windowCount - 1)
                }
                let updatedColumn = NiriStateZigKernel.RuntimeColumnState(
                    columnId: column.columnId,
                    windowStart: column.windowStart,
                    windowCount: column.windowCount,
                    activeTileIdx: nextActiveTile,
                    isTabbed: isTabbed,
                    sizeValue: column.sizeValue,
                    widthKind: column.widthKind,
                    isFullWidth: column.isFullWidth,
                    hasSavedWidth: column.hasSavedWidth,
                    savedWidthKind: column.savedWidthKind,
                    savedWidthValue: column.savedWidthValue
                )
                export.columns[columnIndex] = updatedColumn
                return (
                    applied: true,
                    targetWindowId: runtimeColumnTargetWindowId(updatedColumn, export: export),
                    targetNode: .init(kind: .column, nodeId: sourceColumnId)
                )
            }
        case let .setColumnActiveTile(sourceColumnId, tileIndex):
            return executeRuntimeSnapshotMutation(context: context) { export in
                guard let columnIndex = export.columns.firstIndex(where: { $0.columnId == sourceColumnId }) else {
                    return nil
                }
                let column = export.columns[columnIndex]
                guard column.windowCount > 0 else {
                    return (
                        applied: false,
                        targetWindowId: nil,
                        targetNode: .init(kind: .column, nodeId: sourceColumnId)
                    )
                }
                let clampedTileIndex = max(0, min(tileIndex, column.windowCount - 1))
                if column.activeTileIdx == clampedTileIndex {
                    return (
                        applied: false,
                        targetWindowId: runtimeColumnTargetWindowId(column, export: export),
                        targetNode: .init(kind: .column, nodeId: sourceColumnId)
                    )
                }
                let updatedColumn = NiriStateZigKernel.RuntimeColumnState(
                    columnId: column.columnId,
                    windowStart: column.windowStart,
                    windowCount: column.windowCount,
                    activeTileIdx: clampedTileIndex,
                    isTabbed: column.isTabbed,
                    sizeValue: column.sizeValue,
                    widthKind: column.widthKind,
                    isFullWidth: column.isFullWidth,
                    hasSavedWidth: column.hasSavedWidth,
                    savedWidthKind: column.savedWidthKind,
                    savedWidthValue: column.savedWidthValue
                )
                export.columns[columnIndex] = updatedColumn
                return (
                    applied: true,
                    targetWindowId: runtimeColumnTargetWindowId(updatedColumn, export: export),
                    targetNode: .init(kind: .column, nodeId: sourceColumnId)
                )
            }
        case let .setColumnWidth(sourceColumnId, width, isFullWidth, savedWidth):
            return executeRuntimeSnapshotMutation(context: context) { export in
                guard let columnIndex = export.columns.firstIndex(where: { $0.columnId == sourceColumnId }) else {
                    return nil
                }
                let column = export.columns[columnIndex]
                let encodedWidth = NiriStateZigKernel.encodeWidth(width)
                let encodedSavedWidth = savedWidth.map(NiriStateZigKernel.encodeWidth)

                let hasSavedWidth = encodedSavedWidth != nil
                if column.sizeValue == encodedWidth.value,
                   column.widthKind == encodedWidth.kind,
                   column.isFullWidth == isFullWidth,
                   column.hasSavedWidth == hasSavedWidth,
                   column.savedWidthKind == (encodedSavedWidth?.kind ?? NiriStateZigKernel.sizeKindProportion),
                   column.savedWidthValue == (encodedSavedWidth?.value ?? 1.0)
                {
                    return (
                        applied: false,
                        targetWindowId: runtimeColumnTargetWindowId(column, export: export),
                        targetNode: .init(kind: .column, nodeId: sourceColumnId)
                    )
                }

                let updatedColumn = NiriStateZigKernel.RuntimeColumnState(
                    columnId: column.columnId,
                    windowStart: column.windowStart,
                    windowCount: column.windowCount,
                    activeTileIdx: column.activeTileIdx,
                    isTabbed: column.isTabbed,
                    sizeValue: encodedWidth.value,
                    widthKind: encodedWidth.kind,
                    isFullWidth: isFullWidth,
                    hasSavedWidth: hasSavedWidth,
                    savedWidthKind: encodedSavedWidth?.kind ?? NiriStateZigKernel.sizeKindProportion,
                    savedWidthValue: encodedSavedWidth?.value ?? 1.0
                )
                export.columns[columnIndex] = updatedColumn

                return (
                    applied: true,
                    targetWindowId: runtimeColumnTargetWindowId(updatedColumn, export: export),
                    targetNode: .init(kind: .column, nodeId: sourceColumnId)
                )
            }
        case let .setWindowHeight(sourceWindowId, height):
            return executeRuntimeSnapshotMutation(context: context) { export in
                guard let windowIndex = export.windows.firstIndex(where: { $0.windowId == sourceWindowId }) else {
                    return nil
                }

                let window = export.windows[windowIndex]
                let encodedHeight = NiriStateZigKernel.encodeHeight(height)
                let sizeValue: Double
                switch height {
                case let .auto(weight):
                    sizeValue = Double(weight)
                case .fixed:
                    sizeValue = 1.0
                }

                if window.heightKind == encodedHeight.kind,
                   window.heightValue == encodedHeight.value,
                   window.sizeValue == sizeValue
                {
                    return (
                        applied: false,
                        targetWindowId: sourceWindowId,
                        targetNode: .init(kind: .window, nodeId: sourceWindowId)
                    )
                }

                let updatedWindow = NiriStateZigKernel.RuntimeWindowState(
                    windowId: window.windowId,
                    columnId: window.columnId,
                    columnIndex: window.columnIndex,
                    sizeValue: sizeValue,
                    heightKind: encodedHeight.kind,
                    heightValue: encodedHeight.value
                )
                export.windows[windowIndex] = updatedWindow
                return (
                    applied: true,
                    targetWindowId: sourceWindowId,
                    targetNode: .init(kind: .window, nodeId: sourceWindowId)
                )
            }
        case let .setWindowSizingMode(sourceWindowId, mode):
            guard let window = engine.runtimeWindowNode(
                for: sourceWindowId,
                in: workspaceId
            )
            else {
                return .success(
                    .init(
                        rc: Int32(OMNI_ERR_OUT_OF_RANGE),
                        applied: false,
                        targetWindowId: nil,
                        targetNode: nil,
                        delta: nil
                    )
                )
            }

            let previousMode = window.sizingMode
            guard previousMode != mode else {
                return .success(
                    .init(
                        rc: Int32(OMNI_OK),
                        applied: false,
                        targetWindowId: sourceWindowId,
                        targetNode: .init(kind: .window, nodeId: sourceWindowId),
                        delta: nil
                    )
                )
            }

            var heightRestoreResult: Result<NiriRuntimeMutationOutcome, NiriRuntimeBoundaryError>?
            if previousMode == .fullscreen, mode == .normal, let savedHeight = window.savedHeight {
                heightRestoreResult = executeRuntimeSnapshotMutation(context: context) { export in
                    guard let windowIndex = export.windows.firstIndex(where: { $0.windowId == sourceWindowId }) else {
                        return nil
                    }
                    let runtimeWindow = export.windows[windowIndex]
                    let encodedHeight = NiriStateZigKernel.encodeHeight(savedHeight)
                    let sizeValue: Double
                    switch savedHeight {
                    case let .auto(weight):
                        sizeValue = Double(weight)
                    case .fixed:
                        sizeValue = 1.0
                    }
                    export.windows[windowIndex] = NiriStateZigKernel.RuntimeWindowState(
                        windowId: runtimeWindow.windowId,
                        columnId: runtimeWindow.columnId,
                        columnIndex: runtimeWindow.columnIndex,
                        sizeValue: sizeValue,
                        heightKind: encodedHeight.kind,
                        heightValue: encodedHeight.value
                    )
                    return (
                        applied: true,
                        targetWindowId: sourceWindowId,
                        targetNode: .init(kind: .window, nodeId: sourceWindowId)
                    )
                }
            }

            if case let .failure(error) = heightRestoreResult {
                return .failure(error)
            }
            if case let .success(heightOutcome)? = heightRestoreResult, heightOutcome.rc != OMNI_OK {
                return .success(heightOutcome)
            }

            if previousMode == .normal, mode == .fullscreen {
                window.savedHeight = window.height
            } else if previousMode == .fullscreen, mode == .normal {
                window.savedHeight = nil
            }
            window.sizingMode = mode

            return .success(
                .init(
                    rc: Int32(OMNI_OK),
                    applied: true,
                    targetWindowId: sourceWindowId,
                    targetNode: .init(kind: .window, nodeId: sourceWindowId),
                    delta: nil
                )
            )
        default:
            break
        }

        let request = mutationRequest(for: command)
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: request
        )

        if outcome.rc == 0, outcome.applied {
            switch engine.applyProjectedRuntimeExport(
                context: context,
                workspaceId: workspaceId,
                delta: outcome.delta
            ) {
            case .success:
                break
            case let .failure(error):
                return .failure(.projection(error))
            }
        }

        return .success(
            NiriRuntimeMutationOutcome(
                rc: outcome.rc,
                applied: outcome.applied,
                targetWindowId: outcome.targetWindowId,
                targetNode: outcome.targetNode,
                delta: outcome.delta
            )
        )
    }

    func executeLifecycle(
        _ command: NiriRuntimeLifecycleCommand
    ) -> Result<NiriRuntimeLifecycleOutcome, NiriRuntimeBoundaryError> {
        guard let context = prepareContext() else {
            return .failure(.missingRuntimeContext(workspaceId: workspaceId))
        }

        let request = lifecycleRequest(for: command)
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: request.applyRequest
        )

        if outcome.rc == 0, outcome.applied {
            switch request.projectionMode {
            case .none:
                break
            case .defaultSnapshot:
                switch engine.applyProjectedRuntimeExport(
                    context: context,
                    workspaceId: workspaceId,
                    delta: outcome.delta
                ) {
                case .success:
                    break
                case let .failure(error):
                    return .failure(.projection(error))
                }
            case let .lifecycle(incomingHandlesById):
                switch engine.applyProjectedLifecycleRuntimeExport(
                    context: context,
                    workspaceId: workspaceId,
                    incomingHandlesById: incomingHandlesById,
                    delta: outcome.delta
                ) {
                case .success:
                    break
                case let .failure(error):
                    return .failure(.projection(error))
                }
            }
        }

        return .success(
            NiriRuntimeLifecycleOutcome(
                rc: outcome.rc,
                applied: outcome.applied,
                targetWindowId: outcome.targetWindowId,
                targetNode: outcome.targetNode,
                delta: outcome.delta
            )
        )
    }

    func executeWorkspace(
        _ command: NiriRuntimeWorkspaceCommand,
        targetStore: NiriRuntimeWorkspaceStore
    ) -> Result<NiriRuntimeWorkspaceOutcome, NiriRuntimeBoundaryError> {
        guard let sourceContext = prepareContext() else {
            return .failure(.missingRuntimeContext(workspaceId: workspaceId))
        }
        guard let targetContext = targetStore.prepareContext() else {
            return .failure(.missingRuntimeContext(workspaceId: targetStore.workspaceId))
        }

        let request = workspaceRequest(for: command)
        let outcome = NiriStateZigKernel.applyWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: request
        )

        if outcome.rc == 0, outcome.applied {
            switch engine.applyProjectedWorkspaceRuntimeExports(
                sourceContext: sourceContext,
                sourceWorkspaceId: workspaceId,
                targetContext: targetContext,
                targetWorkspaceId: targetStore.workspaceId,
                sourceDelta: outcome.sourceDelta,
                targetDelta: outcome.targetDelta,
                refreshMirrorStateFromExport: false
            ) {
            case .success:
                break
            case let .failure(error):
                return .failure(.projection(error))
            }
        }

        return .success(
            NiriRuntimeWorkspaceOutcome(
                rc: outcome.rc,
                applied: outcome.applied,
                sourceSelectionWindowId: outcome.sourceSelectionWindowId,
                targetSelectionWindowId: outcome.targetSelectionWindowId,
                movedWindowId: outcome.movedWindowId,
                sourceDelta: outcome.sourceDelta,
                targetDelta: outcome.targetDelta
            )
        )
    }

    func queryView() -> Result<NiriRuntimeWorkspaceView, NiriRuntimeBoundaryError> {
        guard let context = prepareContext() else {
            return .failure(.missingRuntimeContext(workspaceId: workspaceId))
        }

        let export: NiriStateZigKernel.RuntimeStateExport
        switch NiriStateZigKernel.snapshotRuntimeStateResult(context: context) {
        case let .success(snapshot):
            export = snapshot
        case let .failure(error):
            return .failure(.runtimeSnapshot(workspaceId: workspaceId, error: error))
        }

        var windowHandlesByNodeId: [NodeId: WindowHandle] = [:]
        if let root = engine.root(for: workspaceId) {
            windowHandlesByNodeId.reserveCapacity(root.allWindows.count)
            for window in root.allWindows {
                windowHandlesByNodeId[window.id] = window.handle
            }
        }

        var rowByWindowId: [NodeId: Int] = [:]
        rowByWindowId.reserveCapacity(export.windows.count)
        for column in export.columns {
            let start = column.windowStart
            let count = column.windowCount
            guard start >= 0,
                  count >= 0,
                  start <= export.windows.count,
                  count <= export.windows.count - start
            else {
                continue
            }

            let end = start + count
            var rowIndex = 0
            for runtimeWindow in export.windows[start ..< end] {
                rowByWindowId[runtimeWindow.windowId] = rowIndex
                rowIndex += 1
            }
        }

        var windows: [NiriRuntimeWorkspaceView.WindowView] = []
        windows.reserveCapacity(export.windows.count)
        for runtimeWindow in export.windows {
            windows.append(
                NiriRuntimeWorkspaceView.WindowView(
                    windowId: runtimeWindow.windowId,
                    columnId: runtimeWindow.columnId,
                    columnOrderIndex: runtimeWindow.columnIndex,
                    rowIndex: rowByWindowId[runtimeWindow.windowId] ?? 0,
                    sizeValue: runtimeWindow.sizeValue,
                    heightKind: runtimeWindow.heightKind,
                    heightValue: runtimeWindow.heightValue,
                    height: NiriStateZigKernel.decodeHeight(
                        kind: runtimeWindow.heightKind,
                        value: runtimeWindow.heightValue
                    ),
                    handle: windowHandlesByNodeId[runtimeWindow.windowId]
                )
            )
        }

        var columns: [NiriRuntimeWorkspaceView.ColumnView] = []
        columns.reserveCapacity(export.columns.count)
        for (orderIndex, runtimeColumn) in export.columns.enumerated() {
            let start = runtimeColumn.windowStart
            let count = runtimeColumn.windowCount

            let windowIds: [NodeId]
            if start >= 0,
               count >= 0,
               start <= export.windows.count,
               count <= export.windows.count - start
            {
                let end = start + count
                windowIds = export.windows[start ..< end].map(\.windowId)
            } else {
                windowIds = []
            }

            let resolvedWidth = NiriStateZigKernel.decodeWidth(
                kind: runtimeColumn.widthKind,
                value: runtimeColumn.sizeValue
            )
            let resolvedSavedWidth: ProportionalSize?
            if runtimeColumn.hasSavedWidth {
                resolvedSavedWidth = NiriStateZigKernel.decodeWidth(
                    kind: runtimeColumn.savedWidthKind,
                    value: runtimeColumn.savedWidthValue
                )
            } else {
                resolvedSavedWidth = nil
            }

            columns.append(
                NiriRuntimeWorkspaceView.ColumnView(
                    columnId: runtimeColumn.columnId,
                    orderIndex: orderIndex,
                    windowIds: windowIds,
                    activeTileIndex: runtimeColumn.activeTileIdx,
                    isTabbed: runtimeColumn.isTabbed,
                    widthKind: runtimeColumn.widthKind,
                    widthValue: runtimeColumn.sizeValue,
                    width: resolvedWidth,
                    isFullWidth: runtimeColumn.isFullWidth,
                    hasSavedWidth: runtimeColumn.hasSavedWidth,
                    savedWidthKind: runtimeColumn.savedWidthKind,
                    savedWidthValue: runtimeColumn.savedWidthValue,
                    savedWidth: resolvedSavedWidth
                )
            )
        }

        var columnsById: [NodeId: NiriRuntimeWorkspaceView.ColumnView] = [:]
        columnsById.reserveCapacity(columns.count)
        for column in columns {
            columnsById[column.columnId] = column
        }

        var windowsById: [NodeId: NiriRuntimeWorkspaceView.WindowView] = [:]
        windowsById.reserveCapacity(windows.count)
        for window in windows {
            windowsById[window.windowId] = window
        }

        return .success(
            NiriRuntimeWorkspaceView(
                workspaceId: workspaceId,
                columns: columns,
                windows: windows,
                columnsById: columnsById,
                windowsById: windowsById
            )
        )
    }

    private func workspaceColumns() -> [NiriContainer]? {
        if ensureWorkspaceRoot {
            return engine.ensureRoot(for: workspaceId).columns
        }
        guard let root = engine.root(for: workspaceId) else {
            return nil
        }
        return root.columns
    }

    private typealias RuntimeSnapshotMutationResult = (
        applied: Bool,
        targetWindowId: NodeId?,
        targetNode: NiriStateZigKernel.RuntimeNodeTarget?
    )

    private func executeRuntimeSnapshotMutation(
        context: NiriLayoutZigKernel.LayoutContext,
        mutate: (inout NiriStateZigKernel.RuntimeStateExport) -> RuntimeSnapshotMutationResult?
    ) -> Result<NiriRuntimeMutationOutcome, NiriRuntimeBoundaryError> {
        var export: NiriStateZigKernel.RuntimeStateExport
        switch NiriStateZigKernel.snapshotRuntimeStateResult(context: context) {
        case let .success(snapshot):
            export = snapshot
        case let .failure(error):
            return .failure(.runtimeSnapshot(workspaceId: workspaceId, error: error))
        }

        guard let mutation = mutate(&export) else {
            return .success(
                .init(
                    rc: Int32(OMNI_ERR_OUT_OF_RANGE),
                    applied: false,
                    targetWindowId: nil,
                    targetNode: nil,
                    delta: nil
                )
            )
        }

        guard mutation.applied else {
            return .success(
                .init(
                    rc: Int32(OMNI_OK),
                    applied: false,
                    targetWindowId: mutation.targetWindowId,
                    targetNode: mutation.targetNode,
                    delta: nil
                )
            )
        }

        let seedRC = NiriStateZigKernel.seedRuntimeState(
            context: context,
            export: export
        )
        guard seedRC == OMNI_OK else {
            return .success(
                .init(
                    rc: seedRC,
                    applied: false,
                    targetWindowId: nil,
                    targetNode: nil,
                    delta: nil
                )
            )
        }

        switch engine.applyProjectedRuntimeExport(
            context: context,
            workspaceId: workspaceId,
            refreshMirrorStateFromExport: false
        ) {
        case .success:
            return .success(
                .init(
                    rc: Int32(OMNI_OK),
                    applied: true,
                    targetWindowId: mutation.targetWindowId,
                    targetNode: mutation.targetNode,
                    delta: nil
                )
            )
        case let .failure(error):
            return .failure(.projection(error))
        }
    }

    private func runtimeColumnTargetWindowId(
        _ column: NiriStateZigKernel.RuntimeColumnState,
        export: NiriStateZigKernel.RuntimeStateExport
    ) -> NodeId? {
        guard column.windowCount > 0,
              column.windowStart >= 0,
              column.windowStart <= export.windows.count,
              column.windowCount <= export.windows.count - column.windowStart
        else {
            return nil
        }
        let rowIndex = min(column.activeTileIdx, column.windowCount - 1)
        let windowIndex = column.windowStart + rowIndex
        guard export.windows.indices.contains(windowIndex) else {
            return nil
        }
        return export.windows[windowIndex].windowId
    }

    private func prepareContext() -> NiriLayoutZigKernel.LayoutContext? {
        guard let workspaceColumns = workspaceColumns() else {
            return nil
        }
        return engine.prepareSeededRuntimeContext(
            for: workspaceId,
            snapshot: NiriStateZigKernel.makeSnapshot(columns: workspaceColumns)
        )
    }

    private func navigationRequest(
        for command: NiriRuntimeNavigationCommand
    ) -> NiriStateZigKernel.NavigationRequest {
        switch command {
        case let .moveByColumns(selection, step, targetRowIndex):
            return NiriStateZigKernel.NavigationRequest(
                op: .moveByColumns,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                infiniteLoop: engine.infiniteLoop,
                step: step,
                targetRowIndex: targetRowIndex ?? -1
            )
        case let .moveVertical(selection, direction, orientation):
            return NiriStateZigKernel.NavigationRequest(
                op: .moveVertical,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                direction: direction,
                orientation: orientation,
                infiniteLoop: engine.infiniteLoop
            )
        case let .focusTarget(selection, direction, orientation):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusTarget,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                direction: direction,
                orientation: orientation,
                infiniteLoop: engine.infiniteLoop
            )
        case let .focusDownOrLeft(selection):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusDownOrLeft,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                infiniteLoop: engine.infiniteLoop
            )
        case let .focusUpOrRight(selection):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusUpOrRight,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                infiniteLoop: engine.infiniteLoop
            )
        case let .focusColumnFirst(selection):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusColumnFirst,
                sourceWindowId: selection?.sourceWindowId,
                sourceColumnId: selection?.sourceColumnId,
                infiniteLoop: engine.infiniteLoop
            )
        case let .focusColumnLast(selection):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusColumnLast,
                sourceWindowId: selection?.sourceWindowId,
                sourceColumnId: selection?.sourceColumnId,
                infiniteLoop: engine.infiniteLoop
            )
        case let .focusColumnIndex(selection, columnIndex):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusColumnIndex,
                sourceWindowId: selection?.sourceWindowId,
                sourceColumnId: selection?.sourceColumnId,
                infiniteLoop: engine.infiniteLoop,
                focusColumnIndex: columnIndex
            )
        case let .focusWindowIndex(selection, windowIndex):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusWindowIndex,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                infiniteLoop: engine.infiniteLoop,
                focusWindowIndex: windowIndex
            )
        case let .focusWindowTop(selection):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusWindowTop,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                infiniteLoop: engine.infiniteLoop
            )
        case let .focusWindowBottom(selection):
            return NiriStateZigKernel.NavigationRequest(
                op: .focusWindowBottom,
                sourceWindowId: selection.sourceWindowId,
                sourceColumnId: selection.sourceColumnId,
                infiniteLoop: engine.infiniteLoop
            )
        }
    }

    private func mutationRequest(
        for command: NiriRuntimeMutationCommand
    ) -> NiriStateZigKernel.MutationApplyRequest {
        switch command {
        case let .moveWindowVertical(sourceWindowId, direction):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .moveWindowVertical,
                    sourceWindowId: sourceWindowId,
                    direction: direction,
                    infiniteLoop: engine.infiniteLoop,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn
                )
            )
        case let .swapWindowVertical(sourceWindowId, direction):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .swapWindowVertical,
                    sourceWindowId: sourceWindowId,
                    direction: direction,
                    infiniteLoop: engine.infiniteLoop,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn
                )
            )
        case let .moveWindowHorizontal(sourceWindowId, direction):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .moveWindowHorizontal,
                    sourceWindowId: sourceWindowId,
                    direction: direction,
                    infiniteLoop: engine.infiniteLoop,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn
                )
            )
        case let .swapWindowHorizontal(sourceWindowId, direction):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .swapWindowHorizontal,
                    sourceWindowId: sourceWindowId,
                    direction: direction,
                    infiniteLoop: engine.infiniteLoop,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn
                )
            )
        case let .swapWindowsByMove(sourceWindowId, targetWindowId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .swapWindowsByMove,
                    sourceWindowId: sourceWindowId,
                    targetWindowId: targetWindowId,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn
                )
            )
        case let .insertWindowByMove(sourceWindowId, targetWindowId, position):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .insertWindowByMove,
                    sourceWindowId: sourceWindowId,
                    targetWindowId: targetWindowId,
                    insertPosition: position,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn
                )
            )
        case let .moveWindowToColumn(sourceWindowId, targetColumnId, placeholderColumnId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .moveWindowToColumn,
                    sourceWindowId: sourceWindowId,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn,
                    targetColumnId: targetColumnId
                ),
                placeholderColumnId: placeholderColumnId
            )
        case let .createColumnAndMove(sourceWindowId, direction, createdColumnId, placeholderColumnId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .createColumnAndMove,
                    sourceWindowId: sourceWindowId,
                    direction: direction,
                    maxVisibleColumns: engine.maxVisibleColumns
                ),
                createdColumnId: createdColumnId,
                placeholderColumnId: placeholderColumnId
            )
        case let .insertWindowInNewColumn(sourceWindowId, insertColumnIndex, createdColumnId, placeholderColumnId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .insertWindowInNewColumn,
                    sourceWindowId: sourceWindowId,
                    insertColumnIndex: insertColumnIndex,
                    maxVisibleColumns: engine.maxVisibleColumns
                ),
                createdColumnId: createdColumnId,
                placeholderColumnId: placeholderColumnId
            )
        case let .moveColumn(sourceColumnId, direction):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .moveColumn,
                    direction: direction,
                    infiniteLoop: engine.infiniteLoop,
                    sourceColumnId: sourceColumnId,
                )
            )
        case let .consumeWindow(sourceWindowId, direction, placeholderColumnId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .consumeWindow,
                    sourceWindowId: sourceWindowId,
                    direction: direction,
                    infiniteLoop: engine.infiniteLoop,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn,
                ),
                placeholderColumnId: placeholderColumnId
            )
        case let .expelWindow(sourceWindowId, direction, createdColumnId, placeholderColumnId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .expelWindow,
                    sourceWindowId: sourceWindowId,
                    direction: direction,
                    infiniteLoop: engine.infiniteLoop,
                    maxWindowsPerColumn: engine.maxWindowsPerColumn,
                    maxVisibleColumns: engine.maxVisibleColumns
                ),
                createdColumnId: createdColumnId,
                placeholderColumnId: placeholderColumnId
            )
        case let .cleanupEmptyColumn(sourceColumnId, placeholderColumnId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .cleanupEmptyColumn,
                    sourceColumnId: sourceColumnId
                ),
                placeholderColumnId: placeholderColumnId
            )
        case .normalizeColumnSizes:
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .normalizeColumnSizes
                )
            )
        case let .normalizeWindowSizes(sourceColumnId):
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .normalizeWindowSizes,
                    sourceColumnId: sourceColumnId
                )
            )
        case .balanceSizes:
            return .init(
                request: NiriStateZigKernel.MutationRequest(
                    op: .balanceSizes,
                    maxVisibleColumns: engine.maxVisibleColumns
                )
            )
        case .setColumnDisplay,
             .setColumnActiveTile,
             .setColumnWidth,
             .setWindowHeight,
             .setWindowSizingMode:
            preconditionFailure("custom runtime snapshot mutation commands do not map to mutation request payloads")
        }
    }

    private enum LifecycleProjectionMode {
        case none
        case defaultSnapshot
        case lifecycle(incomingHandlesById: [UUID: WindowHandle])
    }

    private typealias LifecycleApplyRequest = (
        applyRequest: NiriStateZigKernel.MutationApplyRequest,
        projectionMode: LifecycleProjectionMode
    )

    private func lifecycleRequest(
        for command: NiriRuntimeLifecycleCommand
    ) -> LifecycleApplyRequest {
        switch command {
        case let .addWindow(incomingHandle, selectedNodeId, focusedWindowId, createdColumnId, placeholderColumnId):
            return (
                applyRequest: .init(
                    request: NiriStateZigKernel.MutationRequest(
                        op: .addWindow,
                        maxVisibleColumns: engine.maxVisibleColumns,
                        selectedNodeId: selectedNodeId,
                        focusedWindowId: focusedWindowId
                    ),
                    incomingWindowId: incomingHandle.id,
                    createdColumnId: createdColumnId,
                    placeholderColumnId: placeholderColumnId
                ),
                projectionMode: .lifecycle(incomingHandlesById: [incomingHandle.id: incomingHandle])
            )
        case let .removeWindow(sourceWindowId, placeholderColumnId):
            return (
                applyRequest: .init(
                    request: NiriStateZigKernel.MutationRequest(
                        op: .removeWindow,
                        sourceWindowId: sourceWindowId
                    ),
                    placeholderColumnId: placeholderColumnId
                ),
                projectionMode: .defaultSnapshot
            )
        case let .validateSelection(selectedNodeId, focusedWindowId):
            return (
                applyRequest: .init(
                    request: NiriStateZigKernel.MutationRequest(
                        op: .validateSelection,
                        selectedNodeId: selectedNodeId,
                        focusedWindowId: focusedWindowId
                    )
                ),
                projectionMode: .none
            )
        case let .fallbackSelectionOnRemoval(sourceWindowId):
            return (
                applyRequest: .init(
                    request: NiriStateZigKernel.MutationRequest(
                        op: .fallbackSelectionOnRemoval,
                        sourceWindowId: sourceWindowId
                    )
                ),
                projectionMode: .none
            )
        }
    }

    private func workspaceRequest(
        for command: NiriRuntimeWorkspaceCommand
    ) -> NiriStateZigKernel.WorkspaceApplyRequest {
        switch command {
        case let .moveWindowToWorkspace(sourceWindowId, targetCreatedColumnId, sourcePlaceholderColumnId):
            return .init(
                request: NiriStateZigKernel.WorkspaceRequest(
                    op: .moveWindowToWorkspace,
                    sourceWindowId: sourceWindowId,
                    maxVisibleColumns: engine.maxVisibleColumns
                ),
                targetCreatedColumnId: targetCreatedColumnId,
                sourcePlaceholderColumnId: sourcePlaceholderColumnId
            )
        case let .moveColumnToWorkspace(sourceColumnId, sourcePlaceholderColumnId):
            return .init(
                request: NiriStateZigKernel.WorkspaceRequest(
                    op: .moveColumnToWorkspace,
                    sourceColumnId: sourceColumnId
                ),
                sourcePlaceholderColumnId: sourcePlaceholderColumnId
            )
        }
    }
}

extension NiriLayoutEngine {
    func runtimeStore(
        for workspaceId: WorkspaceDescriptor.ID,
        ensureWorkspaceRoot: Bool = false
    ) -> NiriRuntimeWorkspaceStore {
        NiriRuntimeWorkspaceStore(
            engine: self,
            workspaceId: workspaceId,
            ensureWorkspaceRoot: ensureWorkspaceRoot
        )
    }

    func runtimeWorkspaceView(for workspaceId: WorkspaceDescriptor.ID) -> NiriRuntimeWorkspaceView? {
        let store = runtimeStore(for: workspaceId)
        guard case let .success(view) = store.queryView() else {
            return nil
        }
        return view
    }
}
