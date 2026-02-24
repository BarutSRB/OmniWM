import AppKit
import Foundation

@MainActor
final class WorkspaceNavigationHandler {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    private struct WindowTransferResult {
        let succeeded: Bool
        let newSourceFocusHandle: WindowHandle?
    }

    private func startWorkspaceSwitchAnimation(
        from previousWorkspace: WorkspaceDescriptor?,
        to targetWorkspace: WorkspaceDescriptor,
        monitor: Monitor
    ) -> Bool {
        guard let controller else { return false }
        guard controller.settings.animationsEnabled,
              controller.settings.layoutType(for: targetWorkspace.name) != .dwindle,
              let engine = controller.niriEngine else {
            return false
        }
        if previousWorkspace?.id == targetWorkspace.id {
            return false
        }

        let niriMonitor = engine.monitor(for: monitor.id)
            ?? engine.ensureMonitor(for: monitor.id, monitor: monitor)
        niriMonitor.workspaceOrder = controller.workspaceManager.workspaces(on: monitor.id).map(\.id)
        niriMonitor.animationClock = controller.animationClock
        if let previousWorkspace {
            niriMonitor.activateWorkspace(previousWorkspace.id)
        }
        niriMonitor.activateWorkspaceAnimated(targetWorkspace.id)
        return niriMonitor.isWorkspaceSwitchAnimating
    }

    func focusMonitorInDirection(_ direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        switchToMonitor(targetMonitor.id, fromMonitor: currentMonitorId)
    }

    func focusMonitorCyclic(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        let targetMonitor: Monitor? = if previous {
            controller.workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            controller.workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let target = targetMonitor else { return }
        switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    func focusLastMonitor() {
        guard let controller else { return }
        guard let previousId = controller.previousMonitorId else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        guard controller.workspaceManager.monitors.contains(where: { $0.id == previousId }) else {
            controller.previousMonitorId = nil
            return
        }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    private func switchToMonitor(_ targetMonitorId: Monitor.ID, fromMonitor currentMonitorId: Monitor.ID) {
        guard let controller else { return }
        controller.previousMonitorId = currentMonitorId

        guard let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitorId)
        else {
            return
        }

        controller.activeMonitorId = targetMonitorId

        controller.layoutRefreshController.applyLayoutForWorkspaces([targetWorkspace.id])

        controller.withSuppressedMonitorUpdate {
            if let handle = controller.resolveAndSetWorkspaceFocus(for: targetWorkspace.id) {
                controller.focusWindow(handle)
            }
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func moveCurrentWorkspaceToMonitor(direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        let sourceWsOnTarget = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)?.id

        guard controller.workspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [wsId]
        if let sourceWsOnTarget { affectedWorkspaces.insert(sourceWsOnTarget) }

        controller.layoutRefreshController.applyLayoutForWorkspaces(affectedWorkspaces)

        controller.previousMonitorId = currentMonitorId
        controller.activeMonitorId = targetMonitor.id

        controller.withSuppressedMonitorUpdate {
            if let handle = controller.resolveAndSetWorkspaceFocus(for: wsId) {
                controller.focusWindow(handle)
            }
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func moveCurrentWorkspaceToMonitorRelative(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        let targetMonitor: Monitor? = if previous {
            controller.workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            controller.workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let targetMonitor, targetMonitor.id != currentMonitorId else { return }

        let sourceWsOnTarget = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)?.id

        guard controller.workspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [wsId]
        if let sourceWsOnTarget { affectedWorkspaces.insert(sourceWsOnTarget) }

        controller.layoutRefreshController.applyLayoutForWorkspaces(affectedWorkspaces)

        controller.previousMonitorId = currentMonitorId
        controller.activeMonitorId = targetMonitor.id

        controller.withSuppressedMonitorUpdate {
            if let handle = controller.resolveAndSetWorkspaceFocus(for: wsId) {
                controller.focusWindow(handle)
            }
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func swapCurrentWorkspaceWithMonitor(direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let currentWsId = controller.activeWorkspace()?.id else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        guard let targetWsId = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)?.id
        else { return }

        saveNiriViewportState(for: currentWsId)
        if let engine = controller.niriEngine {
            if let targetHandle = controller.focusManager.lastFocusedByWorkspace[targetWsId],
               let targetNode = engine.findNode(for: targetHandle)
            {
                controller.workspaceManager.setSelection(targetNode.id, for: targetWsId)
            }
        }

        guard controller.workspaceManager.swapWorkspaces(
            currentWsId, on: currentMonitorId,
            with: targetWsId, on: targetMonitor.id
        ) else { return }

        controller.syncMonitorsToNiriEngine()

        controller.layoutRefreshController.applyLayoutForWorkspaces([currentWsId, targetWsId])

        controller.withSuppressedMonitorUpdate {
            controller.resolveAndSetWorkspaceFocus(for: targetWsId)
        }

        if let handle = controller.focusedHandle {
            controller.focusWindow(handle)
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func moveColumnToMonitorInDirection(_ direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        var sourceState = controller.workspaceManager.niriViewportState(for: wsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id)
        else {
            return
        }

        var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspace.id)

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWorkspace.id,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        controller.workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        controller.workspaceManager.updateNiriViewportState(targetState, for: targetWorkspace.id)

        for window in column.windowNodes {
            controller.workspaceManager.setWorkspace(for: window.handle, to: targetWorkspace.id)
        }

        controller.syncMonitorsToNiriEngine()

        controller.layoutRefreshController.applyLayoutForWorkspaces([wsId, targetWorkspace.id])

        controller.previousMonitorId = currentMonitorId
        controller.activeMonitorId = targetMonitor.id

        controller.withSuppressedMonitorUpdate {
            if let movedHandle = result.movedHandle {
                controller.focusManager.setFocus(movedHandle, in: targetWorkspace.id)
                controller.focusWindow(movedHandle)
            }
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func switchWorkspace(index: Int) {
        guard let controller else { return }
        controller.borderManager.hideBorder()

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

        guard let result = controller.workspaceManager.focusWorkspace(named: targetName) else { return }
        let previousWorkspaceOnTarget = controller.workspaceManager.previousWorkspace(on: result.monitor.id)

        let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            controller.previousMonitorId = currentMonitorId
        }
        controller.activeMonitorId = result.monitor.id

        controller.resolveAndSetWorkspaceFocus(for: result.workspace.id)

        let workspaceSwitchAnimated = startWorkspaceSwitchAnimation(
            from: previousWorkspaceOnTarget,
            to: result.workspace,
            monitor: result.monitor
        )
        controller.layoutRefreshController.stopScrollAnimation(for: result.monitor.displayId)
        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        controller.layoutRefreshController.executeLayoutRefreshImmediate { [weak controller] in
            if let handle = controller?.focusedHandle {
                controller?.focusWindow(handle)
            }
        }
        if workspaceSwitchAnimated {
            controller.layoutRefreshController.startScrollAnimation(for: result.workspace.id)
        }
    }

    func switchWorkspaceRelative(isNext: Bool, wrapAround: Bool = true) {
        guard let controller else { return }
        controller.borderManager.hideBorder()

        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let currentWorkspace = controller.activeWorkspace() else { return }
        let previousWorkspace = currentWorkspace

        let targetWorkspace: WorkspaceDescriptor? = if isNext {
            controller.workspaceManager.nextWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        } else {
            controller.workspaceManager.previousWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        }

        guard let targetWorkspace else { return }

        saveNiriViewportState(for: currentWorkspace.id)
        guard controller.workspaceManager.setActiveWorkspace(targetWorkspace.id, on: currentMonitorId) else {
            return
        }

        controller.activeMonitorId = currentMonitorId

        controller.resolveAndSetWorkspaceFocus(for: targetWorkspace.id)

        let monitor = controller.workspaceManager.monitor(for: targetWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: previousWorkspace,
                to: targetWorkspace,
                monitor: monitor
            )
        } ?? false
        if let monitor {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        controller.layoutRefreshController.executeLayoutRefreshImmediate { [weak controller] in
            if let handle = controller?.focusedHandle {
                controller?.focusWindow(handle)
            }
        }
        if workspaceSwitchAnimated {
            controller.layoutRefreshController.startScrollAnimation(for: targetWorkspace.id)
        }
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }

        if let focused = controller.focusedHandle,
           controller.workspaceManager.workspace(for: focused) == workspaceId,
           let focusedNode = engine.findNode(for: focused)
        {
            controller.workspaceManager.setSelection(focusedNode.id, for: workspaceId)
        }
    }

    func summonWorkspace(index: Int) {
        guard let controller else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = controller.workspaceManager.workspaceId(for: targetName, createIfMissing: false)
        else { return }

        guard let targetMonitorId = controller.workspaceManager.monitorId(for: targetWsId),
              targetMonitorId != currentMonitorId
        else {
            switchWorkspace(index: index)
            return
        }

        let previousWsOnCurrent = controller.activeWorkspace()?.id

        guard controller.workspaceManager.summonWorkspace(targetWsId, to: currentMonitorId) else { return }

        controller.syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [targetWsId]
        if let previousWsOnCurrent { affectedWorkspaces.insert(previousWsOnCurrent) }

        controller.layoutRefreshController.applyLayoutForWorkspaces(affectedWorkspaces)

        controller.withSuppressedMonitorUpdate {
            controller.resolveAndSetWorkspaceFocus(for: targetWsId)
        }

        if let handle = controller.focusedHandle {
            controller.focusWindow(handle)
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func focusWorkspaceAnywhere(index: Int) {
        guard let controller else { return }
        controller.borderManager.hideBorder()

        let targetName = String(max(0, index) + 1)

        guard let targetWsId = controller.workspaceManager.workspaceId(named: targetName) else { return }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWsId) else { return }
        let previousWorkspaceOnTarget = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)

        if let currentWorkspace = controller.activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = controller.workspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard controller.workspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            controller.previousMonitorId = currentMonitorId
        }
        controller.activeMonitorId = targetMonitor.id

        controller.resolveAndSetWorkspaceFocus(for: targetWsId)

        let targetWorkspace = controller.workspaceManager.descriptor(for: targetWsId)
        let workspaceSwitchAnimated = targetWorkspace.map { targetWorkspace in
            startWorkspaceSwitchAnimation(
                from: previousWorkspaceOnTarget,
                to: targetWorkspace,
                monitor: targetMonitor
            )
        } ?? false
        controller.layoutRefreshController.stopScrollAnimation(for: targetMonitor.displayId)
        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        controller.layoutRefreshController.executeLayoutRefreshImmediate { [weak controller] in
            if let handle = controller?.focusedHandle {
                controller?.focusWindow(handle)
            }
        }
        if workspaceSwitchAnimated {
            controller.layoutRefreshController.startScrollAnimation(for: targetWsId)
        }
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        controller.borderManager.hideBorder()

        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }

        guard let prevWorkspace = controller.workspaceManager.previousWorkspace(on: currentMonitorId) else {
            return
        }

        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard controller.workspaceManager.setActiveWorkspace(prevWorkspace.id, on: currentMonitorId) else {
            return
        }

        controller.activeMonitorId = currentMonitorId

        controller.resolveAndSetWorkspaceFocus(for: prevWorkspace.id)

        let monitor = controller.workspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: currentWorkspace,
                to: prevWorkspace,
                monitor: monitor
            )
        } ?? false
        if let monitor {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        controller.layoutRefreshController.executeLayoutRefreshImmediate { [weak controller] in
            if let handle = controller?.focusedHandle {
                controller?.focusWindow(handle)
            }
        }
        if workspaceSwitchAnimated {
            controller.layoutRefreshController.startScrollAnimation(for: prevWorkspace.id)
        }
    }

    private func resolveOrCreateAdjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        on monitorId: Monitor.ID
    ) -> WorkspaceDescriptor? {
        guard let controller else { return nil }
        let wm = controller.workspaceManager

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

    private func transferWindowFromSourceEngine(
        handle: WindowHandle,
        from sourceWsId: WorkspaceDescriptor.ID?,
        to targetWsId: WorkspaceDescriptor.ID
    ) -> WindowTransferResult {
        guard let controller else {
            return WindowTransferResult(succeeded: false, newSourceFocusHandle: nil)
        }
        let sourceLayout: LayoutType = sourceWsId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout
        let targetLayout: LayoutType = controller.workspaceManager.descriptor(for: targetWsId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        let sourceIsDwindle = sourceLayout == .dwindle
        let targetIsDwindle = targetLayout == .dwindle
        var newSourceFocusHandle: WindowHandle?
        var movedWithNiri = false

        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine,
           let windowNode = engine.findNode(for: handle)
        {
            var sourceState = controller.workspaceManager.niriViewportState(for: sourceWsId)
            var targetState = controller.workspaceManager.niriViewportState(for: targetWsId)
            if let result = engine.moveWindowToWorkspace(
                windowNode,
                from: sourceWsId,
                to: targetWsId,
                sourceState: &sourceState,
                targetState: &targetState
            ) {
                controller.workspaceManager.updateNiriViewportState(sourceState, for: sourceWsId)
                controller.workspaceManager.updateNiriViewportState(targetState, for: targetWsId)
                if let newFocusId = result.newFocusNodeId,
                   let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
                {
                    controller.focusManager.updateWorkspaceFocusMemory(newFocusNode.handle, for: sourceWsId)
                    newSourceFocusHandle = newFocusNode.handle
                }
                movedWithNiri = true
            }
        }

        if !movedWithNiri,
           !sourceIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine
        {
            controller.workspaceManager.withNiriViewportState(for: sourceWsId) { sourceState in
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
                    controller.focusManager.updateWorkspaceFocusMemory(selectedNode.handle, for: sourceWsId)
                    newSourceFocusHandle = selectedNode.handle
                }
            }
        } else if sourceIsDwindle,
                  let sourceWsId,
                  let dwindleEngine = controller.dwindleEngine
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
        guard let handle = controller.focusedHandle else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        let transferResult = transferWindowFromSourceEngine(handle: handle, from: wsId, to: targetWorkspace.id)
        guard transferResult.succeeded else { return }

        controller.workspaceManager.setWorkspace(for: handle, to: targetWorkspace.id)
        controller.focusManager.updateWorkspaceFocusMemory(handle, for: targetWorkspace.id)

        let sourceState = controller.workspaceManager.niriViewportState(for: wsId)
        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: sourceState.selectedNodeId)

        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        controller.layoutRefreshController.refreshWindowsAndLayout()

        if let handle = controller.focusedHandle {
            controller.focusWindow(handle)
        }
    }

    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let handle = controller.focusedHandle else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        var sourceState = controller.workspaceManager.niriViewportState(for: wsId)
        var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspace.id)

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

        controller.workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        controller.workspaceManager.updateNiriViewportState(targetState, for: targetWorkspace.id)

        for window in column.windowNodes {
            controller.workspaceManager.setWorkspace(for: window.handle, to: targetWorkspace.id)
        }

        controller.focusManager.updateWorkspaceFocusMemory(handle, for: targetWorkspace.id)

        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: result.newFocusNodeId)

        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        controller.layoutRefreshController.refreshWindowsAndLayout()

        if let handle = controller.focusedHandle {
            controller.focusWindow(handle)
        }
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let handle = controller.focusedHandle else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = controller.workspaceManager.workspaceId(for: targetName, createIfMissing: true)
        else { return }

        guard targetWsId != wsId else { return }

        saveNiriViewportState(for: wsId)

        var sourceState = controller.workspaceManager.niriViewportState(for: wsId)
        var targetState = controller.workspaceManager.niriViewportState(for: targetWsId)

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

        controller.workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        controller.workspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        for window in column.windowNodes {
            controller.workspaceManager.setWorkspace(for: window.handle, to: targetWsId)
        }

        controller.focusManager.updateWorkspaceFocusMemory(handle, for: targetWsId)

        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: result.newFocusNodeId)

        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        controller.layoutRefreshController.refreshWindowsAndLayout()

        if let handle = controller.focusedHandle {
            controller.focusWindow(handle)
        }
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let controller else { return }
        guard let handle = controller.focusedHandle else { return }
        let targetName = String(max(0, index) + 1)
        guard let targetId = controller.workspaceManager.workspaceId(for: targetName, createIfMissing: true),
              let target = controller.workspaceManager.descriptor(for: targetId)
        else {
            return
        }
        let currentWorkspaceId = controller.workspaceManager.workspace(for: handle)
        let transferResult = transferWindowFromSourceEngine(handle: handle, from: currentWorkspaceId, to: target.id)
        guard transferResult.succeeded else { return }

        controller.workspaceManager.setWorkspace(for: handle, to: target.id)

        let shouldFollowFocus = controller.settings.focusFollowsWindowToMonitor
        if shouldFollowFocus {
            controller.isTransferringWindow = true
            defer { controller.isTransferringWindow = false }

            let targetMonitor = controller.workspaceManager.monitorForWorkspace(target.id)
            if let targetMonitor {
                _ = controller.workspaceManager.setActiveWorkspace(target.id, on: targetMonitor.id)
            }

            controller.focusManager.setFocus(handle, in: target.id)

            if let currentWorkspaceId,
               let sourceMonitor = controller.workspaceManager.monitor(for: currentWorkspaceId) {
                controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
            }
            controller.layoutRefreshController.hideInactiveWorkspacesSync()
            if let engine = controller.niriEngine,
               let movedNode = engine.findNode(for: handle),
               let monitor = controller.workspaceManager.monitor(for: target.id)
            {
                controller.workspaceManager.withNiriViewportState(for: target.id) { targetState in
                    targetState.selectedNodeId = movedNode.id
                    let gap = CGFloat(controller.workspaceManager.gaps)
                    engine.ensureSelectionVisible(
                        node: movedNode,
                        in: target.id,
                        state: &targetState,
                        workingFrame: monitor.visibleFrame,
                        gaps: gap,
                        alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                    )
                }
            }
            controller.layoutRefreshController.executeLayoutRefreshImmediate { [weak controller] in
                controller?.focusWindow(handle)
            }
        } else {
            if let currentWorkspaceId {
                let sourceState = controller.workspaceManager.niriViewportState(for: currentWorkspaceId)
                controller.recoverSourceFocusAfterMove(in: currentWorkspaceId, preferredNodeId: sourceState.selectedNodeId)
            }

            if let currentWorkspaceId,
               let sourceMonitor = controller.workspaceManager.monitor(for: currentWorkspaceId) {
                controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
            }
            controller.layoutRefreshController.hideInactiveWorkspacesSync()
            controller.layoutRefreshController.executeLayoutRefreshImmediate { [weak controller] in
                if let focusHandle = controller?.focusedHandle {
                    controller?.focusWindow(focusHandle)
                }
            }
        }
    }

    func moveFocusedWindowToMonitor(direction: Direction) {
        guard let controller else { return }
        guard let handle = controller.focusedHandle,
              let currentWorkspaceId = controller.workspaceManager.workspace(for: handle),
              let currentMonitorId = controller.workspaceManager.monitorId(for: currentWorkspaceId)
        else { return }

        guard let target = controller.workspaceManager
            .resolveTargetForMonitorMove(from: currentWorkspaceId, direction: direction)
        else { return }

        let targetWorkspace = target.workspace
        let targetMonitor = target.monitor

        let transferResult = transferWindowFromSourceEngine(
            handle: handle, from: currentWorkspaceId, to: targetWorkspace.id
        )
        guard transferResult.succeeded else { return }

        controller.workspaceManager.setWorkspace(for: handle, to: targetWorkspace.id)

        _ = controller.workspaceManager.setActiveWorkspace(targetWorkspace.id, on: targetMonitor.id)

        controller.syncMonitorsToNiriEngine()

        controller.layoutRefreshController.applyLayoutForWorkspaces(
            [currentWorkspaceId, targetWorkspace.id]
        )

        let shouldFollowFocus = controller.settings.focusFollowsWindowToMonitor
        controller.withSuppressedMonitorUpdate {
            if shouldFollowFocus {
                controller.previousMonitorId = currentMonitorId
                controller.activeMonitorId = targetMonitor.id
                controller.focusManager.setFocus(handle, in: targetWorkspace.id)
            } else {
                let sourceState = controller.workspaceManager.niriViewportState(for: currentWorkspaceId)
                controller.recoverSourceFocusAfterMove(in: currentWorkspaceId, preferredNodeId: sourceState.selectedNodeId)
            }
        }

        if let focusHandle = controller.focusedHandle {
            controller.focusWindow(focusHandle)
        }

        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
        guard let controller else { return }
        guard let handle = controller.focusedHandle else { return }
        guard let currentMonitorId = controller.activeMonitorId ?? controller.monitorForInteraction()?.id
        else { return }
        guard let currentWorkspaceId = controller.workspaceManager.workspace(for: handle) else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: monitorDirection
        ) else { return }

        let targetName = String(max(0, workspaceIndex) + 1)
        guard let targetWsId = controller.workspaceManager.workspaceId(for: targetName, createIfMissing: true)
        else { return }

        if controller.workspaceManager.monitorId(for: targetWsId) != targetMonitor.id {
            _ = controller.workspaceManager.moveWorkspaceToMonitor(targetWsId, to: targetMonitor.id)
            controller.syncMonitorsToNiriEngine()
        }

        let transferResult = transferWindowFromSourceEngine(
            handle: handle, from: currentWorkspaceId, to: targetWsId
        )
        guard transferResult.succeeded else { return }

        controller.workspaceManager.setWorkspace(for: handle, to: targetWsId)

        let shouldFollowFocus = controller.settings.focusFollowsWindowToMonitor

        if shouldFollowFocus {
            controller.previousMonitorId = currentMonitorId
            controller.activeMonitorId = targetMonitor.id

            if let monitor = controller.workspaceManager.monitorForWorkspace(targetWsId) {
                _ = controller.workspaceManager.setActiveWorkspace(targetWsId, on: monitor.id)
            }

            controller.focusManager.setFocus(handle, in: targetWsId)

            controller.layoutRefreshController.refreshWindowsAndLayout()
            controller.focusWindow(handle)

            if let engine = controller.niriEngine,
               let movedNode = engine.findNode(for: handle),
               let monitor = controller.workspaceManager.monitor(for: targetWsId)
            {
                controller.workspaceManager.withNiriViewportState(for: targetWsId) { targetState in
                    targetState.selectedNodeId = movedNode.id

                    let gap = CGFloat(controller.workspaceManager.gaps)
                    engine.ensureSelectionVisible(
                        node: movedNode,
                        in: targetWsId,
                        state: &targetState,
                        workingFrame: monitor.visibleFrame,
                        gaps: gap,
                        alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                    )
                }
            }
        } else {
            let sourceState = controller.workspaceManager.niriViewportState(for: currentWorkspaceId)
            controller.recoverSourceFocusAfterMove(in: currentWorkspaceId, preferredNodeId: sourceState.selectedNodeId)

            controller.layoutRefreshController.refreshWindowsAndLayout()
            if let newHandle = controller.focusedHandle {
                controller.focusWindow(newHandle)
            }
        }
    }
}
