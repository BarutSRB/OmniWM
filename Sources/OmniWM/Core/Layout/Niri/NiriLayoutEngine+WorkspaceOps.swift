import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct WorkspacePreparedRequest {
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let sourceStore: NiriRuntimeWorkspaceStore
        let targetStore: NiriRuntimeWorkspaceStore
        let op: NiriStateZigKernel.WorkspaceOp
        let sourceWindowId: NodeId?
        let sourceColumnId: NodeId?
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
        guard let command = workspaceCommand(
            prepared: prepared,
            targetCreatedColumnId: targetCreatedColumnId,
            sourcePlaceholderColumnId: sourcePlaceholderColumnId
        )
        else {
            return nil
        }

        let applyOutcome: NiriRuntimeWorkspaceOutcome
        switch prepared.sourceStore.executeWorkspace(command, targetStore: prepared.targetStore) {
        case let .success(outcome):
            applyOutcome = outcome
        case .failure:
            return nil
        }

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

        let movedHandle: WindowHandle?
        if let movedWindowId = applyOutcome.movedWindowId {
            guard let movedWindowView = runtimeWindowView(
                for: movedWindowId,
                in: prepared.targetWorkspaceId
            ),
                let handle = movedWindowView.handle
            else {
                return nil
            }
            movedHandle = handle
        } else {
            movedHandle = nil
        }

        return WorkspaceApplyOutcome(
            applied: true,
            newSourceFocusNodeId: applyOutcome.sourceSelectionWindowId,
            targetSelectionNodeId: applyOutcome.targetSelectionWindowId,
            movedHandle: movedHandle
        )
    }

    private func workspaceCommand(
        prepared: WorkspacePreparedRequest,
        targetCreatedColumnId: UUID?,
        sourcePlaceholderColumnId: UUID?
    ) -> NiriRuntimeWorkspaceCommand? {
        switch prepared.op {
        case .moveWindowToWorkspace:
            guard let sourceWindowId = prepared.sourceWindowId,
                  let targetCreatedColumnId,
                  let sourcePlaceholderColumnId
            else {
                return nil
            }
            return .moveWindowToWorkspace(
                sourceWindowId: sourceWindowId,
                targetCreatedColumnId: targetCreatedColumnId,
                sourcePlaceholderColumnId: sourcePlaceholderColumnId
            )
        case .moveColumnToWorkspace:
            guard let sourceColumnId = prepared.sourceColumnId else {
                return nil
            }
            return .moveColumnToWorkspace(
                sourceColumnId: sourceColumnId,
                sourcePlaceholderColumnId: sourcePlaceholderColumnId
            )
        }
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
        guard runtimeWindowView(
            for: window.id,
            in: sourceWorkspaceId
        ) != nil else {
            return nil
        }

        guard roots[sourceWorkspaceId] != nil else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        _ = targetRoot.columns

        return WorkspacePreparedRequest(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            sourceStore: runtimeStore(for: sourceWorkspaceId),
            targetStore: runtimeStore(for: targetWorkspaceId, ensureWorkspaceRoot: true),
            op: .moveWindowToWorkspace,
            sourceWindowId: window.id,
            sourceColumnId: nil
        )
    }

    private func prepareMoveColumnToWorkspaceRequest(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> WorkspacePreparedRequest? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }
        guard runtimeColumnView(
            for: column.id,
            in: sourceWorkspaceId
        ) != nil else {
            return nil
        }

        guard roots[sourceWorkspaceId] != nil else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)
        _ = targetRoot.columns

        return WorkspacePreparedRequest(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            sourceStore: runtimeStore(for: sourceWorkspaceId),
            targetStore: runtimeStore(for: targetWorkspaceId, ensureWorkspaceRoot: true),
            op: .moveColumnToWorkspace,
            sourceWindowId: nil,
            sourceColumnId: column.id
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
