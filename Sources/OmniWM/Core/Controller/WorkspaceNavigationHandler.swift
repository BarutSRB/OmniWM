import AppKit
import Foundation

@MainActor
final class WorkspaceNavigationHandler {
    private weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    private func startWorkspaceSwitchAnimation(
        from previousWorkspace: WorkspaceDescriptor?,
        to targetWorkspace: WorkspaceDescriptor,
        monitor: Monitor
    ) -> Bool {
        guard let controller,
              controller.internalSettings.animationsEnabled,
              controller.internalSettings.layoutType(for: targetWorkspace.name) != .dwindle,
              let engine = controller.internalNiriEngine else {
            return false
        }
        if previousWorkspace?.id == targetWorkspace.id {
            return false
        }

        let niriMonitor = engine.monitor(for: monitor.id)
            ?? engine.ensureMonitor(for: monitor.id, monitor: monitor)
        niriMonitor.workspaceOrder = controller.internalWorkspaceManager.workspaces(on: monitor.id).map(\.id)
        niriMonitor.animationClock = controller.animationClock
        if let previousWorkspace {
            niriMonitor.activateWorkspace(previousWorkspace.id)
        }
        niriMonitor.activateWorkspaceAnimated(targetWorkspace.id)
        return niriMonitor.isWorkspaceSwitchAnimating
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

        controller.internalLayoutRefreshController?.applyLayoutForWorkspaces([targetWorkspace.id])

        let targetHandle = controller.internalResolveWorkspaceFocus(for: targetWorkspace.id)

        controller.internalSuppressActiveMonitorUpdate = true
        if let handle = targetHandle {
            controller.internalFocusedHandle = handle
            controller.focusWindow(handle)
        }
        controller.internalSuppressActiveMonitorUpdate = false

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

        let sourceWsOnTarget = controller.internalWorkspaceManager.activeWorkspace(on: targetMonitor.id)?.id

        guard controller.internalWorkspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [wsId]
        if let sourceWsOnTarget { affectedWorkspaces.insert(sourceWsOnTarget) }

        controller.internalLayoutRefreshController?.applyLayoutForWorkspaces(affectedWorkspaces)

        controller.internalPreviousMonitorId = currentMonitorId
        controller.internalActiveMonitorId = targetMonitor.id

        controller.internalSuppressActiveMonitorUpdate = true
        let targetHandle = controller.internalResolveWorkspaceFocus(for: wsId)
        if let handle = targetHandle {
            controller.internalFocusedHandle = handle
            controller.focusWindow(handle)
        }
        controller.internalSuppressActiveMonitorUpdate = false

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func moveCurrentWorkspaceToMonitorRelative(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        let targetMonitor: Monitor? = if previous {
            controller.internalWorkspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            controller.internalWorkspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let targetMonitor, targetMonitor.id != currentMonitorId else { return }

        let sourceWsOnTarget = controller.internalWorkspaceManager.activeWorkspace(on: targetMonitor.id)?.id

        guard controller.internalWorkspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [wsId]
        if let sourceWsOnTarget { affectedWorkspaces.insert(sourceWsOnTarget) }

        controller.internalLayoutRefreshController?.applyLayoutForWorkspaces(affectedWorkspaces)

        controller.internalPreviousMonitorId = currentMonitorId
        controller.internalActiveMonitorId = targetMonitor.id

        controller.internalSuppressActiveMonitorUpdate = true
        let targetHandle = controller.internalResolveWorkspaceFocus(for: wsId)
        if let handle = targetHandle {
            controller.internalFocusedHandle = handle
            controller.focusWindow(handle)
        }
        controller.internalSuppressActiveMonitorUpdate = false

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func swapCurrentWorkspaceWithMonitor(direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let currentWsId = controller.activeWorkspace()?.id else { return }

        guard let targetMonitor = controller.internalWorkspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        guard let targetWsId = controller.internalWorkspaceManager.activeWorkspace(on: targetMonitor.id)?.id
        else { return }

        saveNiriViewportState(for: currentWsId)
        if let engine = controller.internalNiriEngine {
            var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWsId)
            if let targetHandle = controller.internalLastFocusedByWorkspace[targetWsId],
               let targetNode = engine.findNode(for: targetHandle)
            {
                targetState.selectedNodeId = targetNode.id
                controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: targetWsId)
            }
        }

        guard controller.internalWorkspaceManager.swapWorkspaces(
            currentWsId, on: currentMonitorId,
            with: targetWsId, on: targetMonitor.id
        ) else { return }

        controller.syncMonitorsToNiriEngine()

        controller.internalLayoutRefreshController?.applyLayoutForWorkspaces([currentWsId, targetWsId])

        controller.internalSuppressActiveMonitorUpdate = true
        controller.internalFocusedHandle = controller.internalResolveWorkspaceFocus(for: targetWsId)
        controller.internalSuppressActiveMonitorUpdate = false

        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }

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

        controller.syncMonitorsToNiriEngine()

        controller.internalLayoutRefreshController?.applyLayoutForWorkspaces([wsId, targetWorkspace.id])

        controller.internalPreviousMonitorId = currentMonitorId
        controller.internalActiveMonitorId = targetMonitor.id

        controller.internalSuppressActiveMonitorUpdate = true
        if let movedHandle = result.movedHandle {
            controller.internalSetFocus(movedHandle, in: targetWorkspace.id)
            controller.focusWindow(movedHandle)
        }
        controller.internalSuppressActiveMonitorUpdate = false

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func switchWorkspace(index: Int) {
        guard let controller else { return }
        controller.internalBorderManager.hideBorder()

        let targetName = String(max(0, index) + 1)
        if let currentWorkspace = controller.activeWorkspace(),
           currentWorkspace.name == targetName
        {
            workspaceBackAndForth()
            return
        }

        if let currentWorkspace = controller.activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.internalWorkspaceManager.focusWorkspace(named: targetName) else { return }
        let previousWorkspaceOnTarget = controller.internalWorkspaceManager.previousWorkspace(on: result.monitor.id)

        let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            controller.internalPreviousMonitorId = currentMonitorId
        }
        controller.internalActiveMonitorId = result.monitor.id

        controller.internalFocusedHandle = controller.internalResolveWorkspaceFocus(for: result.workspace.id)

        let workspaceSwitchAnimated = startWorkspaceSwitchAnimation(
            from: previousWorkspaceOnTarget,
            to: result.workspace,
            monitor: result.monitor
        )
        controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: result.workspace.id)
        }
        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    func switchWorkspaceRelative(isNext: Bool, wrapAround: Bool = true) {
        guard let controller else { return }
        controller.internalBorderManager.hideBorder()

        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let currentWorkspace = controller.activeWorkspace() else { return }
        let previousWorkspace = currentWorkspace

        let targetWorkspace: WorkspaceDescriptor? = if isNext {
            controller.internalWorkspaceManager.nextWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        } else {
            controller.internalWorkspaceManager.previousWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        }

        guard let targetWorkspace else { return }

        saveNiriViewportState(for: currentWorkspace.id)
        guard controller.internalWorkspaceManager.setActiveWorkspace(targetWorkspace.id, on: currentMonitorId) else {
            return
        }

        controller.internalActiveMonitorId = currentMonitorId

        controller.internalFocusedHandle = controller.internalResolveWorkspaceFocus(for: targetWorkspace.id)

        let monitor = controller.internalWorkspaceManager.monitor(for: targetWorkspace.id)
            ?? controller.internalWorkspaceManager.monitors.first(where: { $0.id == currentMonitorId })
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: previousWorkspace,
                to: targetWorkspace,
                monitor: monitor
            )
        } ?? false
        controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: targetWorkspace.id)
        }
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

        let previousWsOnCurrent = controller.activeWorkspace()?.id

        guard controller.internalWorkspaceManager.summonWorkspace(targetWsId, to: currentMonitorId) else { return }

        controller.syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [targetWsId]
        if let previousWsOnCurrent { affectedWorkspaces.insert(previousWsOnCurrent) }

        controller.internalLayoutRefreshController?.applyLayoutForWorkspaces(affectedWorkspaces)

        controller.internalSuppressActiveMonitorUpdate = true
        controller.internalFocusedHandle = controller.internalResolveWorkspaceFocus(for: targetWsId)
        controller.internalSuppressActiveMonitorUpdate = false

        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func focusWorkspaceAnywhere(index: Int) {
        guard let controller else { return }
        controller.internalBorderManager.hideBorder()

        let targetName = String(max(0, index) + 1)

        guard let targetWsId = controller.internalWorkspaceManager.workspaceId(named: targetName) else { return }
        guard let targetMonitor = controller.internalWorkspaceManager.monitorForWorkspace(targetWsId) else { return }
        let previousWorkspaceOnTarget = controller.internalWorkspaceManager.activeWorkspace(on: targetMonitor.id)

        if let currentWorkspace = controller.activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = controller.internalWorkspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard controller.internalWorkspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            controller.internalPreviousMonitorId = currentMonitorId
        }
        controller.internalActiveMonitorId = targetMonitor.id

        controller.internalFocusedHandle = controller.internalResolveWorkspaceFocus(for: targetWsId)

        let targetWorkspace = controller.internalWorkspaceManager.descriptor(for: targetWsId)
        let workspaceSwitchAnimated = targetWorkspace.map { targetWorkspace in
            startWorkspaceSwitchAnimation(
                from: previousWorkspaceOnTarget,
                to: targetWorkspace,
                monitor: targetMonitor
            )
        } ?? false
        controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: targetWsId)
        }
        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        controller.internalBorderManager.hideBorder()

        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        guard let prevWorkspace = controller.internalWorkspaceManager.previousWorkspace(on: currentMonitorId) else {
            return
        }

        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard controller.internalWorkspaceManager.setActiveWorkspace(prevWorkspace.id, on: currentMonitorId) else {
            return
        }

        controller.internalActiveMonitorId = currentMonitorId

        controller.internalFocusedHandle = controller.internalResolveWorkspaceFocus(for: prevWorkspace.id)

        let monitor = controller.internalWorkspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.internalWorkspaceManager.monitors.first(where: { $0.id == currentMonitorId })
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: currentWorkspace,
                to: prevWorkspace,
                monitor: monitor
            )
        } ?? false
        controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: prevWorkspace.id)
        }
        if let handle = controller.internalFocusedHandle {
            controller.focusWindow(handle)
        }
    }

    private func resolveOrCreateAdjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        on monitorId: Monitor.ID
    ) -> WorkspaceDescriptor? {
        guard let controller else { return nil }
        let wm = controller.internalWorkspaceManager

        let existing: WorkspaceDescriptor? = if direction == .down {
            wm.nextWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        } else {
            wm.previousWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        }
        if let existing { return existing }

        guard let currentName = wm.descriptor(for: workspaceId)?.name,
              let currentNumber = Int(currentName)
        else { return nil }

        let candidateNumber = direction == .down ? currentNumber + 1 : currentNumber - 1
        guard candidateNumber > 0 else { return nil }

        let candidateName = String(candidateNumber)
        guard wm.workspaceId(named: candidateName) == nil else { return nil }

        guard let targetId = wm.workspaceId(for: candidateName, createIfMissing: true) else { return nil }
        wm.assignWorkspaceToMonitor(targetId, monitorId: monitorId)
        return wm.descriptor(for: targetId)
    }

    private struct WindowTransferResult {
        let succeeded: Bool
        let newSourceFocusHandle: WindowHandle?
    }

    private func transferWindowFromSourceEngine(
        handle: WindowHandle,
        from sourceWsId: WorkspaceDescriptor.ID?,
        to targetWsId: WorkspaceDescriptor.ID
    ) -> WindowTransferResult {
        guard let controller else { return WindowTransferResult(succeeded: false, newSourceFocusHandle: nil) }

        let sourceLayout: LayoutType = sourceWsId
            .flatMap { controller.internalWorkspaceManager.descriptor(for: $0)?.name }
            .map { controller.internalSettings.layoutType(for: $0) } ?? .defaultLayout
        let targetLayout: LayoutType = controller.internalWorkspaceManager.descriptor(for: targetWsId)
            .map { controller.internalSettings.layoutType(for: $0.name) } ?? .defaultLayout
        let sourceIsDwindle = sourceLayout == .dwindle
        let targetIsDwindle = targetLayout == .dwindle

        var newSourceFocusHandle: WindowHandle?
        var movedWithNiri = false

        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWsId,
           let engine = controller.internalNiriEngine,
           let windowNode = engine.findNode(for: handle)
        {
            var sourceState = controller.internalWorkspaceManager.niriViewportState(for: sourceWsId)
            var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWsId)
            if let result = engine.moveWindowToWorkspace(
                windowNode,
                from: sourceWsId,
                to: targetWsId,
                sourceState: &sourceState,
                targetState: &targetState
            ) {
                controller.internalWorkspaceManager.updateNiriViewportState(sourceState, for: sourceWsId)
                controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: targetWsId)
                if let newFocusId = result.newFocusNodeId,
                   let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
                {
                    controller.internalLastFocusedByWorkspace[sourceWsId] = newFocusNode.handle
                    newSourceFocusHandle = newFocusNode.handle
                }
                movedWithNiri = true
            }
        }

        if !movedWithNiri,
           !sourceIsDwindle,
           let sourceWsId,
           let engine = controller.internalNiriEngine
        {
            var sourceState = controller.internalWorkspaceManager.niriViewportState(for: sourceWsId)

            if let currentNode = engine.findNode(for: handle),
               sourceState.selectedNodeId == currentNode.id
            {
                sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                    removing: currentNode.id,
                    in: sourceWsId
                )
            }

            if targetIsDwindle, engine.findNode(for: handle) != nil {
                engine.removeWindow(handle: handle)
            }

            if let selectedId = sourceState.selectedNodeId,
               engine.findNode(by: selectedId) == nil
            {
                sourceState.selectedNodeId = engine.validateSelection(selectedId, in: sourceWsId)
            }

            if let selectedId = sourceState.selectedNodeId,
               let selectedNode = engine.findNode(by: selectedId) as? NiriWindow
            {
                controller.internalLastFocusedByWorkspace[sourceWsId] = selectedNode.handle
                newSourceFocusHandle = selectedNode.handle
            }

            controller.internalWorkspaceManager.updateNiriViewportState(sourceState, for: sourceWsId)
        } else if sourceIsDwindle,
                  let sourceWsId,
                  let dwindleEngine = controller.internalDwindleEngine
        {
            dwindleEngine.removeWindow(handle: handle, from: sourceWsId)
        }

        let succeeded: Bool
        if movedWithNiri {
            succeeded = true
        } else if sourceWsId == nil {
            succeeded = true
        } else if !sourceIsDwindle && !targetIsDwindle {
            succeeded = false
        } else {
            succeeded = true
        }

        return WindowTransferResult(succeeded: succeeded, newSourceFocusHandle: newSourceFocusHandle)
    }

    func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let handle = controller.internalFocusedHandle else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        let transferResult = transferWindowFromSourceEngine(handle: handle, from: wsId, to: targetWorkspace.id)
        guard transferResult.succeeded else { return }

        controller.internalWorkspaceManager.setWorkspace(for: handle, to: targetWorkspace.id)
        controller.internalLastFocusedByWorkspace[targetWorkspace.id] = handle

        if let engine = controller.internalNiriEngine {
            let sourceState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            if let newSelectedId = sourceState.selectedNodeId,
               let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
            {
                controller.internalFocusedHandle = newSelectedNode.handle
            } else {
                controller.internalFocusedHandle = controller.internalWorkspaceManager
                    .entries(in: wsId).first?.handle
            }
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
        guard let handle = controller.internalFocusedHandle else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        var sourceState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
        var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWorkspace.id)

        guard let windowNode = engine.findNode(for: handle),
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

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

        controller.internalLastFocusedByWorkspace[targetWorkspace.id] = handle

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            controller.internalSetFocus(newFocusNode.handle, in: wsId)
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
            controller.internalSetFocus(newFocusNode.handle, in: wsId)
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

        let transferResult = transferWindowFromSourceEngine(handle: handle, from: currentWorkspaceId, to: target.id)
        guard transferResult.succeeded else { return }

        controller.internalWorkspaceManager.setWorkspace(for: handle, to: target.id)

        if let targetMonitor = controller.internalWorkspaceManager.monitorForWorkspace(target.id) {
            _ = controller.internalWorkspaceManager.setActiveWorkspace(target.id, on: targetMonitor.id)
        }

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
              let currentMonitorId = controller.internalWorkspaceManager.monitorId(for: currentWorkspaceId)
        else { return }

        guard let target = controller.internalWorkspaceManager
            .resolveTargetForMonitorMove(from: currentWorkspaceId, direction: direction)
        else { return }

        let targetWorkspace = target.workspace
        let targetMonitor = target.monitor

        let transferResult = transferWindowFromSourceEngine(
            handle: handle, from: currentWorkspaceId, to: targetWorkspace.id
        )
        guard transferResult.succeeded else { return }

        controller.internalWorkspaceManager.setWorkspace(for: handle, to: targetWorkspace.id)

        _ = controller.internalWorkspaceManager.setActiveWorkspace(targetWorkspace.id, on: targetMonitor.id)

        controller.syncMonitorsToNiriEngine()

        controller.internalLayoutRefreshController?.applyLayoutForWorkspaces(
            [currentWorkspaceId, targetWorkspace.id]
        )

        let shouldFollowFocus = controller.internalSettings.focusFollowsWindowToMonitor
        controller.internalSuppressActiveMonitorUpdate = true
        if shouldFollowFocus {
            controller.internalPreviousMonitorId = currentMonitorId
            controller.internalActiveMonitorId = targetMonitor.id
            controller.internalSetFocus(handle, in: targetWorkspace.id)
        } else {
            let sourceState = controller.internalWorkspaceManager.niriViewportState(for: currentWorkspaceId)
            if let engine = controller.internalNiriEngine,
               let newSelectedId = sourceState.selectedNodeId,
               let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
            {
                controller.internalFocusedHandle = newSelectedNode.handle
            } else {
                controller.internalFocusedHandle = controller.internalWorkspaceManager
                    .entries(in: currentWorkspaceId).first?.handle
            }
        }
        controller.internalSuppressActiveMonitorUpdate = false

        if let focusHandle = controller.internalFocusedHandle {
            controller.focusWindow(focusHandle)
        }

        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }

    func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
        guard let controller else { return }
        guard let handle = controller.internalFocusedHandle else { return }
        guard let currentMonitorId = controller.internalActiveMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let currentWorkspaceId = controller.internalWorkspaceManager.workspace(for: handle) else { return }

        guard let targetMonitor = controller.internalWorkspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: monitorDirection
        ) else { return }

        let targetName = String(max(0, workspaceIndex) + 1)
        guard let targetWsId = controller.internalWorkspaceManager.workspaceId(for: targetName, createIfMissing: true)
        else { return }

        if controller.internalWorkspaceManager.monitorId(for: targetWsId) != targetMonitor.id {
            _ = controller.internalWorkspaceManager.moveWorkspaceToMonitor(targetWsId, to: targetMonitor.id)
            controller.syncMonitorsToNiriEngine()
        }

        let transferResult = transferWindowFromSourceEngine(
            handle: handle, from: currentWorkspaceId, to: targetWsId
        )
        guard transferResult.succeeded else { return }

        controller.internalWorkspaceManager.setWorkspace(for: handle, to: targetWsId)

        let shouldFollowFocus = controller.internalSettings.focusFollowsWindowToMonitor

        if shouldFollowFocus {
            controller.internalPreviousMonitorId = currentMonitorId
            controller.internalActiveMonitorId = targetMonitor.id

            if let monitor = controller.internalWorkspaceManager.monitorForWorkspace(targetWsId) {
                _ = controller.internalWorkspaceManager.setActiveWorkspace(targetWsId, on: monitor.id)
            }

            controller.internalSetFocus(handle, in: targetWsId)

            controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
            controller.focusWindow(handle)

            if let engine = controller.internalNiriEngine,
               let movedNode = engine.findNode(for: handle),
               let monitor = controller.internalWorkspaceManager.monitor(for: targetWsId)
            {
                var targetState = controller.internalWorkspaceManager.niriViewportState(for: targetWsId)
                targetState.selectedNodeId = movedNode.id

                let gap = CGFloat(controller.internalWorkspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: targetWsId,
                    state: &targetState,
                    workingFrame: monitor.visibleFrame,
                    gaps: gap,
                    alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                )
                controller.internalWorkspaceManager.updateNiriViewportState(targetState, for: targetWsId)
            }
        } else {
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
            }

            controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
            if let newHandle = controller.internalFocusedHandle {
                controller.focusWindow(newHandle)
            }
        }
    }
}
