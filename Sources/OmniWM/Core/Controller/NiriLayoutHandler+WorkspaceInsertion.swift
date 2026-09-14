// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func moveColumnToIndex(
        containing handle: WindowHandle,
        index: Int
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, toOneBasedIndex: index)
    }

    func windowMoveOutcomeAtEdge(
        for node: NiriWindow,
        direction: Direction,
        engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) -> WindowMoveOutcome {
        guard node.parent is NiriContainer else {
            return .blocked
        }

        if let step = direction.secondaryStep(for: orientation) {
            guard let column = engine.findColumn(containing: node, in: workspaceId) else {
                return .blocked
            }
            let visibleWindows = engine.projectedWindows(in: column, workspaceId: workspaceId)
            guard let index = visibleWindows.firstIndex(where: { $0 === node }) else { return .blocked }
            return visibleWindows.indices.contains(index + step) ? .blocked : .atWorkspaceEdge
        }

        guard let step = direction.primaryStep(for: orientation) else { return .blocked }
        return isAtPrimaryWorkspaceEdge(node, step: step, engine: engine, in: workspaceId)
            ? .atWorkspaceEdge : .blocked
    }

    private func isAtPrimaryWorkspaceEdge(
        _ node: NiriWindow,
        step: Int,
        engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let column = engine.findColumn(containing: node, in: workspaceId),
              engine.projectedWindows(in: column, workspaceId: workspaceId).count == 1
        else {
            return false
        }

        let projectedColumns = engine.projectedColumns(in: workspaceId)
        guard let index = projectedColumns.firstIndex(where: { $0.column === column }) else { return false }
        return step > 0 ? index == projectedColumns.count - 1 : index == 0
    }

    func withNiriWorkspaceContext(
        perform: (
            NiriLayoutEngine,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            Monitor,
            CGRect,
            CGFloat,
            Monitor.Orientation
        ) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(for: wsId, monitor: monitor, engine: engine)
        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            _ = engine.reconcileProjectedSelection(state: &state, in: wsId)
            perform(engine, wsId, motion, &state, monitor, workingFrame, gaps, orientation)
        }
    }

    func withNiriWorkspaceContext(
        for workspaceId: WorkspaceDescriptor.ID,
        perform: (
            NiriLayoutEngine,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            Monitor,
            CGRect,
            CGFloat,
            Monitor.Orientation
        ) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(for: workspaceId, monitor: monitor, engine: engine)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            _ = engine.reconcileProjectedSelection(state: &state, in: workspaceId)
            perform(engine, workspaceId, motion, &state, monitor, workingFrame, gaps, orientation)
        }
    }

    @discardableResult
    func insertWindow(
        handle: WindowHandle,
        targetHandle: WindowHandle,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) -> Bool {
        guard let controller,
              let sourceEntry = controller.workspaceManager.entry(for: handle.id),
              sourceEntry.workspaceId == workspaceId,
              controller.workspaceManager.handle(for: handle.id) === handle,
              !controller.workspaceManager.isAppHidden(pid: sourceEntry.pid),
              let targetEntry = controller.workspaceManager.entry(for: targetHandle.id),
              targetEntry.workspaceId == workspaceId,
              controller.workspaceManager.handle(for: targetHandle.id) === targetHandle,
              !controller.workspaceManager.isAppHidden(pid: targetEntry.pid)
        else {
            return false
        }
        var didMove = false
        withNiriWorkspaceContext(
            for: workspaceId
        ) { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let sourceNode = engine.findNode(for: handle, in: wsId) else { return }
            guard let target = engine.findNode(for: targetHandle, in: wsId) else { return }
            didMove = engine.insertWindowByMove(
                sourceWindowId: sourceNode.id,
                targetWindowId: target.id,
                position: position,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
        }
        if didMove {
            recordLayoutOperation(.windowInserted(token: handle.id), in: workspaceId, source: source)
        }
        return didMove
    }

    @discardableResult
    func insertWindowInNewColumn(
        handle: WindowHandle,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        sizingPolicy: NiriLayoutEngine.NewContainerSizingPolicy = .workspaceDefault,
        source: WMEventSource = .command
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: handle.id),
              entry.workspaceId == workspaceId,
              controller.workspaceManager.handle(for: handle.id) === handle,
              !controller.workspaceManager.isAppHidden(pid: entry.pid)
        else {
            return false
        }
        var didMove = false
        withNiriWorkspaceContext(
            for: workspaceId
        ) { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let window = engine.findNode(for: handle, in: wsId) else { return }
            didMove = engine.insertWindowInNewColumn(
                window,
                insertIndex: insertIndex,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state,
                sizingPolicy: sizingPolicy
            )
        }
        if didMove {
            recordLayoutOperation(.windowInserted(token: handle.id), in: workspaceId, source: source)
        }
        return didMove
    }
}
