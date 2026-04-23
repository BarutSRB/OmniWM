// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

extension NiriLayoutEngine {
    func createColumnAndMove(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        guard let sourceIndex = columnIndex(of: sourceColumn, in: workspaceId) else { return }
        let insertIndex = direction == .right ? sourceIndex + 1 : sourceIndex
        _ = insertWindowInNewColumn(
            node,
            insertIndex: insertIndex,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: workingAreaWidth, height: 1),
            gaps: gaps
        )
    }

    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let plan = callTopologyKernel(
            operation: .insertWindowInNewColumn,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            subject: window,
            insertIndex: insertIndex,
            motion: motion
        ) else {
            return false
        }

        let animationPreparation = prepareAnimationsForTopologyPlan(
            plan,
            in: workspaceId,
            state: state,
            gaps: gaps,
            motion: motion
        )
        _ = applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
        finalizeAnimationsForTopologyPlan(
            plan,
            preparation: animationPreparation,
            in: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            motion: motion
        )
        return true
    }

    func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state _: inout ViewportState
    ) {
        guard column.children.isEmpty else { return }

        column.remove()

        if let root = roots[workspaceId], root.columns.isEmpty {
            let emptyColumn = NiriContainer()
            root.appendChild(emptyColumn)
        }
    }

    func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
        let cols = columns(in: workspaceId)
        guard cols.count > 1 else { return }

        let totalSize = cols.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(cols.count)

        for col in cols {
            let normalized = col.size / avgSize
            col.size = max(0.5, min(2.0, normalized))
        }
    }

    func normalizeWindowSizes(in column: NiriContainer) {
        let windows = column.children.compactMap { $0 as? NiriWindow }
        guard !windows.isEmpty else { return }

        let totalSize = windows.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(windows.count)

        for window in windows {
            let normalized = window.size / avgSize
            window.size = max(0.5, min(2.0, normalized))
        }
    }

    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        workingAreaWidth: CGFloat,
        gaps: CGFloat
    ) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
        let targetPixels = (workingAreaWidth - gaps) * resolvedWidth.proportion

        for column in cols {
            column.width = .proportion(resolvedWidth.proportion)
            column.isFullWidth = false
            column.savedWidth = nil
            column.presetWidthIdx = resolvedWidth.presetWidthIdx
            column.hasManualSingleWindowWidthOverride = false

            column.animateWidthTo(
                newWidth: targetPixels,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate,
                animated: motion.animationsEnabled
            )

            for window in column.windowNodes {
                window.size = 1.0
            }
        }
    }

    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right,
              let subject = column.windowNodes.first,
              let plan = callTopologyKernel(
                  operation: .moveColumn,
                  workspaceId: workspaceId,
                  state: state,
                  workingFrame: workingFrame,
                  gaps: gaps,
                  direction: direction,
                  subject: subject,
                  motion: motion
              )
        else { return false }
        guard plan.effectKind != .none else { return false }

        let animationPreparation = prepareAnimationsForTopologyPlan(
            plan,
            in: workspaceId,
            state: state,
            gaps: gaps,
            motion: motion
        )
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
        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        moveWindow(
            window,
            direction: direction,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }
}
