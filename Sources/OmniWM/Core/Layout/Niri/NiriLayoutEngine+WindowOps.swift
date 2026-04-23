// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let oldColumnIndex = findColumn(containing: node, in: workspaceId)
            .flatMap { columnIndex(of: $0, in: workspaceId) }
        let oldColumnPosition = oldColumnIndex.map {
            state.columnPlanningX(at: $0, columns: columns(in: workspaceId), gap: gaps)
        }
        let oldTileIndex = (node.parent as? NiriContainer)?.windowNodes.firstIndex { $0 === node } ?? 0
        let oldTileOffset = (node.parent as? NiriContainer).map {
            computeTileOffset(column: $0, tileIdx: oldTileIndex, gaps: gaps)
        } ?? 0

        guard let plan = callTopologyKernel(
            operation: .moveWindow,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            direction: direction,
            subject: node,
            motion: motion
        ) else {
            return false
        }

        let effect = plan.effectKind
        guard effect != .none else {
            return false
        }

        let animationPreparation = prepareAnimationsForTopologyPlan(
            plan,
            in: workspaceId,
            state: state,
            gaps: gaps,
            motion: motion
        )
        let targetColumnIndex = Int(plan.result.target_column_index)
        let targetWindowIndex = Int(plan.result.target_window_index)
        _ = applyTopologyPlan(
            plan,
            in: workspaceId,
            state: &state,
            motion: motion,
            animationConfig: windowMovementAnimationConfig
        )
        finalizeAnimationsForTopologyPlan(
            plan,
            preparation: animationPreparation,
            in: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            motion: motion
        )

        if direction == .left || direction == .right,
           let oldColumnPosition,
           targetColumnIndex >= 0,
           let movedWindow = findNode(for: node.token),
           let targetColumn = findColumn(containing: movedWindow, in: workspaceId)
        {
            let newColumns = columns(in: workspaceId)
            let targetColumnPosition = state.columnPlanningX(at: targetColumnIndex, columns: newColumns, gap: gaps)
            let targetTileOffset = computeTileOffset(
                column: targetColumn,
                tileIdx: max(0, targetWindowIndex),
                gaps: gaps
            )
            let columnDisplacement: CGFloat = if effect == .consumeWindow, direction == .right {
                targetColumn.planningWidth + gaps
            } else {
                0
            }
            let displacement = CGPoint(
                x: oldColumnPosition - targetColumnPosition - columnDisplacement,
                y: oldTileOffset - targetTileOffset
            )
            if displacement.x != 0 || displacement.y != 0 {
                movedWindow.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    animated: motion.animationsEnabled
                )
            }
        }

        return true
    }
}
