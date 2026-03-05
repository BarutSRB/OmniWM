import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct WorkspacePreparedRequest {
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let sourceSnapshot: NiriStateZigKernel.Snapshot
        let targetSnapshot: NiriStateZigKernel.Snapshot
        let request: NiriStateZigKernel.WorkspaceRequest
    }

    private struct WorkspaceApplyOutcome {
        let applied: Bool
        let newSourceFocusNodeId: NodeId?
        let targetSelectionNodeId: NodeId?
        let movedHandle: WindowHandle?
    }

    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedHandle: WindowHandle?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    private func applyRuntimeWorkspaceMutation(
        _ prepared: WorkspacePreparedRequest,
        targetCreatedColumnId: UUID?,
        sourcePlaceholderColumnId: UUID?
    ) -> WorkspaceApplyOutcome? {
        guard let sourceContext = prepareSeededRuntimeContext(
            for: prepared.sourceWorkspaceId,
            snapshot: prepared.sourceSnapshot
        ),
            let targetContext = prepareSeededRuntimeContext(
                for: prepared.targetWorkspaceId,
                snapshot: prepared.targetSnapshot
            )
        else {
            return nil
        }

        let applyOutcome = NiriStateZigKernel.applyWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: .init(
                request: prepared.request,
                sourceSnapshot: prepared.sourceSnapshot,
                targetCreatedColumnId: targetCreatedColumnId,
                sourcePlaceholderColumnId: sourcePlaceholderColumnId
            )
        )
        guard applyOutcome.rc == 0 else {
            return nil
        }
        guard applyOutcome.applied else {
            return WorkspaceApplyOutcome(
                applied: false,
                newSourceFocusNodeId: nil,
                targetSelectionNodeId: nil,
                movedHandle: nil
            )
        }

        guard applyProjectedRuntimeExport(
            context: targetContext,
            workspaceId: prepared.targetWorkspaceId,
            delta: applyOutcome.targetDelta,
            refreshMirrorStateFromExport: false
        ) != nil else {
            return nil
        }

        guard applyProjectedRuntimeExport(
            context: sourceContext,
            workspaceId: prepared.sourceWorkspaceId,
            delta: applyOutcome.sourceDelta,
            refreshMirrorStateFromExport: false
        ) != nil else {
            return nil
        }

        let movedHandle: WindowHandle?
        if let movedWindowId = applyOutcome.movedWindowId {
            guard let movedWindow = root(for: prepared.targetWorkspaceId)?
                .findNode(by: movedWindowId) as? NiriWindow
            else {
                return nil
            }
            movedHandle = movedWindow.handle
        } else {
            movedHandle = nil
        }

        setRuntimeMirrorState(
            for: prepared.sourceWorkspaceId,
            columnCount: applyOutcome.sourceDelta?.columns.count ?? 0,
            windowCount: applyOutcome.sourceDelta?.windows.count ?? 0
        )
        setRuntimeMirrorState(
            for: prepared.targetWorkspaceId,
            columnCount: applyOutcome.targetDelta?.columns.count ?? 0,
            windowCount: applyOutcome.targetDelta?.windows.count ?? 0
        )

        return WorkspaceApplyOutcome(
            applied: true,
            newSourceFocusNodeId: applyOutcome.sourceSelectionWindowId,
            targetSelectionNodeId: applyOutcome.targetSelectionWindowId,
            movedHandle: movedHandle
        )
    }

    private func executePreparedWorkspaceMutation(
        _ prepared: WorkspacePreparedRequest,
        targetCreatedColumnId: UUID? = nil,
        sourcePlaceholderColumnId: UUID? = nil
    ) -> WorkspaceApplyOutcome? {
        applyRuntimeWorkspaceMutation(
            prepared,
            targetCreatedColumnId: targetCreatedColumnId,
            sourcePlaceholderColumnId: sourcePlaceholderColumnId
        )
    }

    private func prepareMoveWindowToWorkspaceRequest(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> WorkspacePreparedRequest? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              findColumn(containing: window, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        guard let sourceWindowIndex = sourceSnapshot.windowIndexByNodeId[window.id] else {
            return nil
        }

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveWindowToWorkspace,
            sourceWindowIndex: sourceWindowIndex,
            maxVisibleColumns: maxVisibleColumns
        )

        return WorkspacePreparedRequest(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            request: request
        )
    }

    private func prepareMoveColumnToWorkspaceRequest(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> WorkspacePreparedRequest? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        guard let sourceColumnIndex = sourceSnapshot.columnIndexByNodeId[column.id] else {
            return nil
        }

        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveColumnToWorkspace,
            sourceColumnIndex: sourceColumnIndex
        )

        return WorkspacePreparedRequest(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            request: request
        )
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        let latencyToken = NiriLatencyProbe.begin(.workspaceMove)
        defer { NiriLatencyProbe.end(latencyToken) }

        guard let prepared = prepareMoveWindowToWorkspaceRequest(
            window,
            from: sourceWorkspaceId,
            to: targetWorkspaceId
        ) else {
            return nil
        }

        guard let applyOutcome = executePreparedWorkspaceMutation(
            prepared,
            targetCreatedColumnId: UUID(),
            sourcePlaceholderColumnId: UUID()
        ) else {
            return nil
        }
        guard applyOutcome.applied else {
            return nil
        }

        sourceState.selectedNodeId = applyOutcome.newSourceFocusNodeId
        targetState.selectedNodeId = applyOutcome.targetSelectionNodeId

        return WorkspaceMoveResult(
            newFocusNodeId: applyOutcome.newSourceFocusNodeId,
            movedHandle: applyOutcome.movedHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func moveColumnToWorkspace(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard let prepared = prepareMoveColumnToWorkspaceRequest(
            column,
            from: sourceWorkspaceId,
            to: targetWorkspaceId
        ) else {
            return nil
        }

        guard let applyOutcome = executePreparedWorkspaceMutation(
            prepared,
            sourcePlaceholderColumnId: UUID()
        ) else {
            return nil
        }
        guard applyOutcome.applied else {
            return nil
        }

        sourceState.selectedNodeId = applyOutcome.newSourceFocusNodeId
        targetState.selectedNodeId = applyOutcome.targetSelectionNodeId

        return WorkspaceMoveResult(
            newFocusNodeId: applyOutcome.newSourceFocusNodeId,
            movedHandle: applyOutcome.movedHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }
}
