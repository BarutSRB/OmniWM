import AppKit
import Foundation

@MainActor
final class WorkspaceNavigationHandler {
    private weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func focusMonitorInDirection(_ direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        guard let targetMonitor = controller.internalWorkspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        switchToMonitor(targetMonitor.id, fromMonitor: currentMonitorId)
    }

    func focusMonitorCyclic(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        let targetMonitor: Monitor? = if previous {
            controller.internalWorkspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            controller.internalWorkspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let target = targetMonitor else { return }
        switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    func focusLastMonitor() {
        guard let controller else { return }
        guard let previousId = controller.internalPreviousMonitorId else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        guard controller.internalWorkspaceManager.monitors.contains(where: { $0.id == previousId }) else {
            controller.internalPreviousMonitorId = nil
            return
        }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    private func switchToMonitor(_ targetMonitorId: Monitor.ID, fromMonitor currentMonitorId: Monitor.ID) {
        guard let controller else { return }
        controller.internalPreviousMonitorId = currentMonitorId

        guard let targetWorkspace = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: targetMonitorId)
        else {
            return
        }

        controller.internalActiveMonitorId = targetMonitorId

        let targetHandle = controller.internalLastFocusedByWorkspace[targetWorkspace.id] ??
            controller.internalWorkspaceManager.entries(in: targetWorkspace.id).first?.handle

        if let handle = targetHandle {
            controller.internalFocusedHandle = handle
            controller.focusWindow(handle)
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func moveCurrentWorkspaceToMonitor(direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetMonitor = controller.internalWorkspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        guard controller.internalWorkspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        controller.internalPreviousMonitorId = currentMonitorId
        controller.internalActiveMonitorId = targetMonitor.id

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func moveColumnToMonitorInDirection(_ direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetMonitor = controller.internalWorkspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        var sourceState = controller.internalWorkspaceManager.niriViewportState(for: wsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let targetWorkspace = controller.internalWorkspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id)
        else {
            return
        }

        var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWorkspace.id)

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWorkspace.id,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        controller.internalWorkspaceManager.updateNiriViewportState(sourceState, for: wsId)
        controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: targetWorkspace.id)

        for window in column.windowNodes {
            controller.internalWorkspaceManager.setWorkspace(for: window.handle, to: targetWorkspace.id)
        }

        controller.internalPreviousMonitorId = currentMonitorId
        controller.internalActiveMonitorId = targetMonitor.id

        if let movedHandle = result.movedHandle {
            controller.internalFocusedHandle = movedHandle
            controller.internalLastFocusedByWorkspace[targetWorkspace.id] = movedHandle
            controller.focusWindow(movedHandle)
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func switchWorkspace(index: Int) {
        guard let controller else { return }
        controller.internalBorderManager.hideBorder()

        if let currentWorkspace = controller.activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let targetName = String(max(0, index) + 1)
        guard let result = controller.internalWorkspaceManager.focusWorkspace(named: targetName) else { return }

        let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            controller.internalPreviousMonitorId = currentMonitorId
        }
        controller.internalActiveMonitorId = result.monitor.id

        controller.internalFocusedHandle = controller.internalLastFocusedByWorkspace[result.workspace.id]
            ?? controller.internalWorkspaceManager.entries(in: result.workspace.id).first?.handle

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        var state = controller.internalWorkspaceManager.niriViewportState(for: workspaceId)

        if let focused = controller.internalFocusedHandle,
           controller.internalWorkspaceManager.workspace(for: focused) == workspaceId,
           let focusedNode = engine.findNode(for: focused)
        {
            state.selectedNodeId = focusedNode.id
        }

        controller.internalWorkspaceManager.updateNiriViewportState(state, for: workspaceId)
    }

    func summonWorkspace(index: Int) {
        guard let controller else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = controller.internalWorkspaceManager.workspaceId(for: targetName, createIfMissing: false)
        else { return }

        guard let targetMonitorId = controller.internalWorkspaceManager.monitorId(for: targetWsId),
              targetMonitorId != currentMonitorId
        else {
            switchWorkspace(index: index)
            return
        }

        guard controller.internalWorkspaceManager.summonWorkspace(targetWsId, to: currentMonitorId) else { return }

        controller.syncMonitorsToNiriEngine()

        controller.internalFocusedHandle = controller.internalLastFocusedByWorkspace[targetWsId]
            ?? controller.internalWorkspaceManager.entries(in: targetWsId).first?.handle

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        guard let monitor = controller.monitorForInteraction() else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        let workspaceIds = controller.internalWorkspaceManager.workspaces(on: monitor.id).map(\.id)

        guard let targetWsId = engine.adjacentWorkspace(
            from: wsId,
            direction: direction,
            workspaceIds: workspaceIds
        ) else {
            return
        }

        var sourceState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
        var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow
        else {
            return
        }

        guard let result = engine.moveWindowToWorkspace(
            windowNode,
            from: wsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        controller.internalWorkspaceManager.updateNiriViewportState(sourceState, for: wsId)
        controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            controller.internalFocusedHandle = newFocusNode.handle
            controller.internalLastFocusedByWorkspace[wsId] = newFocusNode.handle
        } else {
            controller.internalFocusedHandle = controller.internalWorkspaceManager.entries(in: wsId).first?.handle
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()

        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        guard let monitor = controller.monitorForInteraction() else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        let workspaceIds = controller.internalWorkspaceManager.workspaces(on: monitor.id).map(\.id)

        guard let targetWsId = engine.adjacentWorkspace(
            from: wsId,
            direction: direction,
            workspaceIds: workspaceIds
        ) else {
            return
        }

        var sourceState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
        var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        controller.internalWorkspaceManager.updateNiriViewportState(sourceState, for: wsId)
        controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            controller.internalFocusedHandle = newFocusNode.handle
            controller.internalLastFocusedByWorkspace[wsId] = newFocusNode.handle
        } else {
            controller.internalFocusedHandle = controller.internalWorkspaceManager.entries(in: wsId).first?.handle
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()

        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = controller.internalWorkspaceManager.workspaceId(for: targetName, createIfMissing: true)
        else { return }

        guard targetWsId != wsId else { return }

        var sourceState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
        var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        controller.internalWorkspaceManager.updateNiriViewportState(sourceState, for: wsId)
        controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            controller.internalFocusedHandle = newFocusNode.handle
            controller.internalLastFocusedByWorkspace[wsId] = newFocusNode.handle
        } else {
            controller.internalFocusedHandle = controller.internalWorkspaceManager.entries(in: wsId).first?.handle
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()

        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let controller else { return }
        guard let handle = controller.internalFocusedHandle else { return }
        let targetName = String(max(0, index) + 1)
        guard let targetId = controller.internalWorkspaceManager.workspaceId(for: targetName, createIfMissing: true),
              let target = controller.internalWorkspaceManager.descriptor(for: targetId)
        else {
            return
        }
        let currentWorkspaceId = controller.internalWorkspaceManager.workspace(for: handle)

        if let engine = controller.internalNiriEngine, let sourceWsId = currentWorkspaceId {
            var sourceState = controller.internalWorkspaceManager.niriViewportState(for: sourceWsId)

            if let currentNode = engine.findNode(for: handle),
               sourceState.selectedNodeId == currentNode.id
            {
                sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                    removing: currentNode.id,
                    in: sourceWsId
                )
                controller.internalWorkspaceManager.updateNiriViewportState(sourceState, for: sourceWsId)
            }
        }

        controller.internalWorkspaceManager.setWorkspace(for: handle, to: target.id)

        if target.id != controller.activeWorkspace()?.id, let currentWorkspaceId {
            if let engine = controller.internalNiriEngine {
                let sourceState = controller.internalWorkspaceManager.niriViewportState(for: currentWorkspaceId)
                if let newSelectedId = sourceState.selectedNodeId,
                   let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
                {
                    controller.internalFocusedHandle = newSelectedNode.handle
                } else {
                    controller.internalFocusedHandle = controller.internalWorkspaceManager
                        .entries(in: currentWorkspaceId).first?.handle
                }
            } else {
                controller.internalFocusedHandle = controller.internalWorkspaceManager.entries(in: currentWorkspaceId)
                    .first?.handle
            }
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()

        if target.id == controller.activeWorkspace()?.id {
            if let engine = controller.internalNiriEngine,
               let movedNode = engine.findNode(for: handle),
               let monitor = controller.internalWorkspaceManager.monitor(for: target.id)
            {
                var targetState = controller.internalWorkspaceManager.niriViewportState(for: target.id)
                targetState.selectedNodeId = movedNode.id

                let gap = CGFloat(controller.internalWorkspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: target.id,
                    state: &targetState,
                    edge: .left,
                    workingFrame: monitor.visibleFrame,
                    gaps: gap,
                    alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                )
                controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: target.id)
            }
            controller.focusWindow(handle)
        }
    }

    func moveFocusedWindowToMonitor(direction: Direction) {
        guard let controller else { return }
        guard let handle = controller.internalFocusedHandle,
              let currentWorkspaceId = controller.internalWorkspaceManager.workspace(for: handle),
              let targetWorkspace = controller.internalWorkspaceManager
              .move(handle: handle, from: currentWorkspaceId, direction: direction) else { return }

        if let monitor = controller.internalWorkspaceManager.monitor(for: targetWorkspace.id) {
            _ = controller.internalWorkspaceManager.setActiveWorkspace(targetWorkspace.id, on: monitor.id)
        }
        controller.internalFocusedHandle = handle
        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
        controller.focusWindow(handle)
    }
}
