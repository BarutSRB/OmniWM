// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

extension OverviewStructuralActions {
    enum DragMutationOutcome {
        case changed(StructuralMutation)
        case awaitingAdmission(StructuralMutation, OverviewDragTarget)
        case unchanged
    }

    struct DragSession {
        let handle: WindowHandle
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let startPoint: CGPoint
    }
}

extension OverviewStructuralActions {
    func performDragAction(session: DragSession, target: OverviewDragTarget) -> DragMutationOutcome {
        guard let wmController,
              windowFacts.visibleManagedEntry(for: session.handle) != nil
        else {
            return .unchanged
        }

        switch target {
        case let .workspaceMove(targetWsId):
            guard targetWsId != session.workspaceId else { return .unchanged }
            guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            ) else { return .unchanged }
            return .changed(mutation)

        case let .niriWindowInsert(targetWsId, targetHandle, position):
            return insertWindow(
                session: session,
                target: target,
                targetWsId: targetWsId,
                targetHandle: targetHandle,
                position: position
            )

        case let .niriColumnInsert(targetWsId, insertIndex):
            return insertColumn(session: session, target: target, targetWsId: targetWsId, insertIndex: insertIndex)
        }
    }

    private func insertWindow(
        session: DragSession,
        target: OverviewDragTarget,
        targetWsId: WorkspaceDescriptor.ID,
        targetHandle: WindowHandle,
        position: InsertPosition
    ) -> DragMutationOutcome {
        guard let wmController else { return .unchanged }
        guard windowFacts.isNiriLayout(workspaceId: targetWsId),
              windowFacts.visibleManagedEntry(for: targetHandle) != nil
        else {
            return .unchanged
        }
        var transferMutation: StructuralMutation?
        if targetWsId != session.workspaceId {
            guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            ) else { return .unchanged }
            transferMutation = mutation
            if !windowFacts.isNiriLayout(workspaceId: session.workspaceId) {
                return .awaitingAdmission(mutation, target)
            }
        }
        let niriPosition = overviewInsertPositionToNiri(position)
        guard wmController.niriLayoutHandler.insertWindow(
            handle: session.handle,
            targetHandle: targetHandle,
            position: niriPosition,
            in: targetWsId,
            source: .mouse
        ) else {
            return transferMutation.map(DragMutationOutcome.changed) ?? .unchanged
        }
        return .changed(insertionMutation(session: session, destination: targetWsId))
    }

    private func insertColumn(
        session: DragSession,
        target: OverviewDragTarget,
        targetWsId: WorkspaceDescriptor.ID,
        insertIndex: Int
    ) -> DragMutationOutcome {
        guard let wmController else { return .unchanged }
        guard windowFacts.isNiriLayout(workspaceId: targetWsId) else { return .unchanged }
        let shouldInheritSizing = targetWsId != session.workspaceId
            && windowFacts.isNiriLayout(workspaceId: session.workspaceId)
        let sizingPolicy: NiriLayoutEngine.NewContainerSizingPolicy = shouldInheritSizing
            ? .inheritSource
            : .workspaceDefault
        var transferMutation: StructuralMutation?
        if targetWsId != session.workspaceId {
            guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            ) else { return .unchanged }
            transferMutation = mutation
            if !windowFacts.isNiriLayout(workspaceId: session.workspaceId) {
                return .awaitingAdmission(mutation, target)
            }
        }
        guard wmController.niriLayoutHandler.insertWindowInNewColumn(
            handle: session.handle,
            insertIndex: insertIndex,
            in: targetWsId,
            sizingPolicy: sizingPolicy,
            source: .mouse
        ) else {
            return transferMutation.map(DragMutationOutcome.changed) ?? .unchanged
        }
        return .changed(insertionMutation(session: session, destination: targetWsId))
    }

    private func insertionMutation(session: DragSession, destination: WorkspaceDescriptor.ID) -> StructuralMutation {
        StructuralMutation(
            sourceWorkspaceId: session.workspaceId,
            destinationWorkspaceId: destination,
            selectedHandle: session.handle,
            movedTokens: [session.handle.id],
            scrollWorkspaceId: destination
        )
    }

    func overviewInsertPositionToNiri(_ position: InsertPosition) -> InsertPosition {
        switch position {
        case .before:
            return .after
        case .after:
            return .before
        case .swap:
            return .swap
        }
    }

    static func deferredColumnInsertIndex(
        requestedIndex: Int,
        admittedColumnIndex: Int?
    ) -> Int {
        if let admittedColumnIndex, admittedColumnIndex < requestedIndex {
            return requestedIndex + 1
        }
        return requestedIndex
    }
}
