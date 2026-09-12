// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func consumeOrExpelWindow(direction: Direction) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(consumeOrExpelWindow(handle: handle, direction: direction))
    }

    func consumeOrExpelWindow(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .left || direction == .right else { return .unchanged }
        return performStructuralMutation(handle: handle) { ctx, state in
            guard ctx.engine.consumeOrExpelWindow(
                ctx.windowNode,
                direction: direction,
                context: .init(
                    workspaceId: ctx.wsId,
                    motion: ctx.motion,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                ),
                state: &state,
                allowEdgeWrap: false
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                movedTokens: [ctx.windowNode.token],
                operation: .windowConsumedOrExpelled(token: ctx.windowNode.token)
            )
        }
    }

    func consumeWindowIntoColumn() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(consumeWindowIntoColumn(containing: handle))
    }

    func consumeWindowIntoColumn(containing handle: WindowHandle) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return nil
            }
            let projectedColumns = ctx.engine.projectedColumns(in: ctx.wsId)
            guard let projectedIndex = projectedColumns.firstIndex(where: { $0.column === column }),
                  projectedColumns.indices.contains(projectedIndex + 1),
                  let movedToken = projectedColumns[projectedIndex + 1].windows.last?.token
            else { return nil }
            guard ctx.engine.consumeWindowIntoColumn(
                focusedColumn: column,
                context: .init(
                    workspaceId: ctx.wsId,
                    motion: ctx.motion,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                ),
                state: &state
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                movedTokens: [movedToken],
                operation: .windowConsumedOrExpelled(token: movedToken)
            )
        }
    }

    func expelWindowFromColumn() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(expelWindowFromColumn(containing: handle))
    }

    func expelWindowFromColumn(containing handle: WindowHandle) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return nil
            }
            guard let movedToken = ctx.engine.projectedWindows(
                in: column,
                workspaceId: ctx.wsId
            ).first?.token else { return nil }
            guard ctx.engine.expelWindowFromColumn(
                focusedColumn: column,
                context: .init(
                    workspaceId: ctx.wsId,
                    motion: ctx.motion,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                ),
                state: &state
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                movedTokens: [movedToken],
                operation: .windowConsumedOrExpelled(token: movedToken)
            )
        }
    }

    func moveColumn(direction: Direction) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumn(containing: handle, direction: direction))
    }

    func moveColumn(
        containing handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .direction(direction))
    }

    func moveColumnToFirst() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumnToFirst(containing: handle))
    }

    func moveColumnToFirst(containing handle: WindowHandle) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .first)
    }

    func moveColumnToLast() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumnToLast(containing: handle))
    }

    func moveColumnToLast(containing handle: WindowHandle) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .last)
    }

    func moveColumn(toOneBasedIndex index: Int) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumn(containing: handle, toOneBasedIndex: index))
    }

    func moveColumnToIndex(_ index: Int) {
        moveColumn(toOneBasedIndex: index)
    }

    func moveColumn(
        containing handle: WindowHandle,
        toOneBasedIndex index: Int
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .index(index))
    }

    func moveColumn(
        containing handle: WindowHandle,
        target: ColumnMoveTarget
    ) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else { return nil }
            let movedTokens = column.windowNodes.map(\.token)
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            let interactionContext = NiriInteractionContext(
                workspaceId: ctx.wsId,
                motion: ctx.motion,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps,
                orientation: ctx.orientation
            )
            let moved = switch target {
            case let .direction(direction):
                ctx.engine.moveColumn(
                    column,
                    direction: direction,
                    context: interactionContext,
                    state: &state
                )
            case .first:
                ctx.engine.moveColumnToFirst(
                    column,
                    context: interactionContext,
                    state: &state
                )
            case .last:
                ctx.engine.moveColumnToLast(
                    column,
                    context: interactionContext,
                    state: &state
                )
            case let .index(index):
                ctx.engine.moveColumnToIndex(
                    column,
                    index,
                    context: interactionContext,
                    state: &state
                )
            }
            guard moved else { return nil }
            ctx.prepareCapturedAnimation(oldFrames: oldFrames)
            return NiriStructuralMutation(movedTokens: movedTokens, operation: .columnMoved)
        }
    }
}
