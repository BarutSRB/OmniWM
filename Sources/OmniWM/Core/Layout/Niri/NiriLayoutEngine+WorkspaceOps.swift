// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

extension NiriLayoutEngine {
    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedHandle: WindowHandle?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard roots[sourceWorkspaceId] != nil,
              let sourceColumn = findColumn(containing: window, in: sourceWorkspaceId)
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)

        let fallbackSelection = fallbackSelectionOnRemoval(removing: window.id, in: sourceWorkspaceId)

        window.detach()

        let targetColumn: NiriContainer
        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
            initializeNewColumnWidth(existingColumn, in: targetWorkspaceId)
            targetColumn = existingColumn
        } else {
            let newColumn = NiriContainer()
            initializeNewColumnWidth(newColumn, in: targetWorkspaceId)
            targetRoot.appendChild(newColumn)
            targetColumn = newColumn
        }
        targetColumn.appendChild(window)

        cleanupEmptyColumn(sourceColumn, in: sourceWorkspaceId, state: &sourceState)

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = window.id
        markWorkspaceBarProjectionInvalidated(in: sourceWorkspaceId)
        markWorkspaceBarProjectionInvalidated(in: targetWorkspaceId)

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: window.handle,
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
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)

        removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)

        var fallbackSelection: NodeId?
        if let colIdx = columnIndex(of: column, in: sourceWorkspaceId) {
            fallbackSelection = topologyFallbackSelectionOnColumnRemoval(
                columnIndex: colIdx,
                in: sourceWorkspaceId,
                state: sourceState
            )
        }

        column.detach()

        targetRoot.appendChild(column)

        if sourceRoot.columns.isEmpty {
            let emptyColumn = NiriContainer()
            sourceRoot.appendChild(emptyColumn)
        }

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = column.firstChild()?.id
        markWorkspaceBarProjectionInvalidated(in: sourceWorkspaceId)
        markWorkspaceBarProjectionInvalidated(in: targetWorkspaceId)

        let firstWindowHandle = column.windowNodes.first?.handle

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: firstWindowHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func adjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        workspaceIds: [WorkspaceDescriptor.ID]
    ) -> WorkspaceDescriptor.ID? {
        guard direction == .up || direction == .down else { return nil }

        guard let currentIdx = workspaceIds.firstIndex(of: workspaceId) else { return nil }

        let targetIdx: Int = if direction == .up {
            currentIdx - 1
        } else {
            currentIdx + 1
        }

        guard workspaceIds.indices.contains(targetIdx) else { return nil }
        return workspaceIds[targetIdx]
    }
}
