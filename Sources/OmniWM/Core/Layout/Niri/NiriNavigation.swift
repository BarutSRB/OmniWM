import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveSelectionByColumns(
        steps: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        guard steps != 0 else { return currentSelection }
        let direction: Direction = steps > 0 ? .right : .left
        var state = ViewportState()
        state.selectedNodeId = currentSelection.id
        guard let plan = callTopologyKernel(
            operation: .focus,
            workspaceId: workspaceId,
            state: state,
            workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            gaps: 0,
            direction: direction,
            insertIndex: abs(steps),
            targetIndex: targetRowIndex ?? -1,
            motion: .disabled
        ) else {
            return nil
        }
        guard plan.didApply else { return nil }
        return findWindow(in: plan, id: plan.result.selected_window_id)
    }

    func moveSelectionHorizontal(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        targetRowIndex _: Int? = nil
    ) -> NiriNode? {
        focusTarget(
            direction: direction,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func moveSelectionVertical(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        guard let workspaceId else {
            var state = ViewportState()
            state.selectedNodeId = currentSelection.id
            return focusTargetWithoutViewport(
                operation: .focus,
                direction: direction,
                currentSelection: currentSelection,
                workspaceId: currentSelection.findRoot()?.workspaceId,
                state: &state
            )
        }
        var state = ViewportState()
        state.selectedNodeId = currentSelection.id
        return focusTargetWithoutViewport(
            operation: .focus,
            direction: direction,
            currentSelection: currentSelection,
            workspaceId: workspaceId,
            state: &state
        )
    }

    private func focusTargetWithoutViewport(
        operation: NiriTopologyKernelOperation,
        direction: Direction?,
        currentSelection _: NiriNode,
        workspaceId: WorkspaceDescriptor.ID?,
        state: inout ViewportState,
        targetIndex: Int = 0
    ) -> NiriNode? {
        guard let workspaceId,
              let plan = callTopologyKernel(
                  operation: operation,
                  workspaceId: workspaceId,
                  state: state,
                  workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                  gaps: 0,
                  direction: direction,
                  targetIndex: targetIndex,
                  motion: .disabled
              )
        else { return nil }

        guard plan.didApply else { return nil }
        return findWindow(in: plan, id: plan.result.selected_window_id)
    }

    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        guard let window = node as? NiriWindow,
              let plan = callTopologyKernel(
                  operation: .ensureVisible,
                  workspaceId: workspaceId,
                  state: state,
                  workingFrame: workingFrame,
                  gaps: gaps,
                  subject: window,
                  fromColumnIndex: fromContainerIndex,
                  previousActivePosition: previousActiveContainerPosition,
                  motion: motion,
                  orientation: orientation
              )
        else {
            return
        }

        applyTopologyViewport(
            plan.result,
            state: &state,
            motion: motion,
            animationConfig: animationConfig,
            scale: displayScale(in: workspaceId)
        )
    }

    func focusTarget(
        direction: Direction,
        currentSelection _: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal
    ) -> NiriNode? {
        guard let plan = callTopologyKernel(
            operation: .focus,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            direction: direction,
            motion: motion,
            orientation: orientation
        ) else {
            return nil
        }

        return applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
    }

    private func focusCombined(
        direction: Direction,
        currentSelection _: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        guard let plan = callTopologyKernel(
            operation: .focusCombined,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            direction: direction,
            motion: motion
        ) else {
            return nil
        }

        return applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
    }

    func focusDownOrLeft(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        focusCombined(
            direction: .left,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func focusUpOrRight(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        focusCombined(
            direction: .right,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func focusColumnFirst(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        focusColumn(
            0,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func focusColumnLast(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        focusColumn(
            max(0, columns(in: workspaceId).count - 1),
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func focusColumn(
        _ columnIndex: Int,
        currentSelection _: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        guard let plan = callTopologyKernel(
            operation: .focusColumn,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            targetIndex: columnIndex,
            motion: motion
        ) else {
            return nil
        }

        return applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
    }

    func focusWindowInColumn(
        _ windowIndex: Int,
        currentSelection _: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> NiriNode? {
        guard let plan = callTopologyKernel(
            operation: .focusWindowInColumn,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            targetIndex: windowIndex,
            motion: motion
        ) else {
            return nil
        }

        return applyTopologyPlan(plan, in: workspaceId, state: &state, motion: motion)
    }

    func focusPrevious(
        currentNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        limitToWorkspace: Bool = true
    ) -> NiriWindow? {
        let searchWorkspaceId = limitToWorkspace ? workspaceId : nil
        guard let previousWindow = findMostRecentlyFocusedWindow(
            excluding: currentNodeId,
            in: searchWorkspaceId
        ) else {
            return nil
        }

        ensureSelectionVisible(
            node: previousWindow,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

        return previousWindow
    }
}
