import AppKit
import Foundation

fileprivate struct WindowTransferResult {
    let succeeded: Bool
    let newSourceFocusHandle: WindowHandle?
}

extension WMController {
    private func startWorkspaceSwitchAnimation(
        from previousWorkspace: WorkspaceDescriptor?,
        to targetWorkspace: WorkspaceDescriptor,
        monitor: Monitor
    ) -> Bool {
        guard settings.animationsEnabled,
              settings.layoutType(for: targetWorkspace.name) != .dwindle,
              let engine = niriEngine else {
            return false
        }
        if previousWorkspace?.id == targetWorkspace.id {
            return false
        }

        let niriMonitor = engine.monitor(for: monitor.id)
            ?? engine.ensureMonitor(for: monitor.id, monitor: monitor)
        niriMonitor.workspaceOrder = workspaceManager.workspaces(on: monitor.id).map(\.id)
        niriMonitor.animationClock = animationClock
        if let previousWorkspace {
            niriMonitor.activateWorkspace(previousWorkspace.id)
        }
        niriMonitor.activateWorkspaceAnimated(targetWorkspace.id)
        return niriMonitor.isWorkspaceSwitchAnimating
    }

    func focusMonitorInDirection(_ direction: Direction) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        switchToMonitor(targetMonitor.id, fromMonitor: currentMonitorId)
    }

    func focusMonitorCyclic(previous: Bool) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }

        let targetMonitor: Monitor? = if previous {
            workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let target = targetMonitor else { return }
        switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    func focusLastMonitor() {
        guard let previousId = previousMonitorId else { return }
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }

        guard workspaceManager.monitors.contains(where: { $0.id == previousId }) else {
            previousMonitorId = nil
            return
        }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    private func switchToMonitor(_ targetMonitorId: Monitor.ID, fromMonitor currentMonitorId: Monitor.ID) {
        previousMonitorId = currentMonitorId

        guard let targetWorkspace = workspaceManager.activeWorkspaceOrFirst(on: targetMonitorId)
        else {
            return
        }

        activeMonitorId = targetMonitorId

        applyLayoutForWorkspaces([targetWorkspace.id])

        let targetHandle = resolveWorkspaceFocus(for: targetWorkspace.id)

        withSuppressedMonitorUpdate {
            if let handle = targetHandle {
                focusedHandle = handle
                focusWindow(handle)
            }
        }

        refreshWindowsAndLayout()
    }

    func moveCurrentWorkspaceToMonitor(direction: Direction) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        let sourceWsOnTarget = workspaceManager.activeWorkspace(on: targetMonitor.id)?.id

        guard workspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [wsId]
        if let sourceWsOnTarget { affectedWorkspaces.insert(sourceWsOnTarget) }

        applyLayoutForWorkspaces(affectedWorkspaces)

        previousMonitorId = currentMonitorId
        activeMonitorId = targetMonitor.id

        withSuppressedMonitorUpdate {
            let targetHandle = resolveWorkspaceFocus(for: wsId)
            if let handle = targetHandle {
                focusedHandle = handle
                focusWindow(handle)
            }
        }

        refreshWindowsAndLayout()
    }

    func moveCurrentWorkspaceToMonitorRelative(previous: Bool) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        let targetMonitor: Monitor? = if previous {
            workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let targetMonitor, targetMonitor.id != currentMonitorId else { return }

        let sourceWsOnTarget = workspaceManager.activeWorkspace(on: targetMonitor.id)?.id

        guard workspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [wsId]
        if let sourceWsOnTarget { affectedWorkspaces.insert(sourceWsOnTarget) }

        applyLayoutForWorkspaces(affectedWorkspaces)

        previousMonitorId = currentMonitorId
        activeMonitorId = targetMonitor.id

        withSuppressedMonitorUpdate {
            let targetHandle = resolveWorkspaceFocus(for: wsId)
            if let handle = targetHandle {
                focusedHandle = handle
                focusWindow(handle)
            }
        }

        refreshWindowsAndLayout()
    }

    func swapCurrentWorkspaceWithMonitor(direction: Direction) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let currentWsId = activeWorkspace()?.id else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        guard let targetWsId = workspaceManager.activeWorkspace(on: targetMonitor.id)?.id
        else { return }

        saveNiriViewportState(for: currentWsId)
        if let engine = niriEngine {
            var targetState = workspaceManager.niriViewportState(for: targetWsId)
            if let targetHandle = lastFocusedByWorkspace[targetWsId],
               let targetNode = engine.findNode(for: targetHandle)
            {
                targetState.selectedNodeId = targetNode.id
                workspaceManager.updateNiriViewportState(targetState, for: targetWsId)
            }
        }

        guard workspaceManager.swapWorkspaces(
            currentWsId, on: currentMonitorId,
            with: targetWsId, on: targetMonitor.id
        ) else { return }

        syncMonitorsToNiriEngine()

        applyLayoutForWorkspaces([currentWsId, targetWsId])

        withSuppressedMonitorUpdate {
            focusedHandle = resolveWorkspaceFocus(for: targetWsId)
        }

        if let handle = focusedHandle {
            focusWindow(handle)
        }

        refreshWindowsAndLayout()
    }

    func moveColumnToMonitorInDirection(_ direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        var sourceState = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let targetWorkspace = workspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id)
        else {
            return
        }

        var targetState = workspaceManager.niriViewportState(for: targetWorkspace.id)

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWorkspace.id,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        workspaceManager.updateNiriViewportState(targetState, for: targetWorkspace.id)

        for window in column.windowNodes {
            workspaceManager.setWorkspace(for: window.handle, to: targetWorkspace.id)
        }

        syncMonitorsToNiriEngine()

        applyLayoutForWorkspaces([wsId, targetWorkspace.id])

        previousMonitorId = currentMonitorId
        activeMonitorId = targetMonitor.id

        withSuppressedMonitorUpdate {
            if let movedHandle = result.movedHandle {
                setFocus(movedHandle, in: targetWorkspace.id)
                focusWindow(movedHandle)
            }
        }

        refreshWindowsAndLayout()
    }

    func switchWorkspace(index: Int) {
        borderManager.hideBorder()

        let targetName = String(max(0, index) + 1)
        if let currentWorkspace = activeWorkspace(),
           currentWorkspace.name == targetName
        {
            workspaceBackAndForth()
            return
        }

        if let currentWorkspace = activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = workspaceManager.focusWorkspace(named: targetName) else { return }
        let previousWorkspaceOnTarget = workspaceManager.previousWorkspace(on: result.monitor.id)

        let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            previousMonitorId = currentMonitorId
        }
        activeMonitorId = result.monitor.id

        focusedHandle = resolveWorkspaceFocus(for: result.workspace.id)

        let workspaceSwitchAnimated = startWorkspaceSwitchAnimation(
            from: previousWorkspaceOnTarget,
            to: result.workspace,
            monitor: result.monitor
        )
        executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            startScrollAnimation(for: result.workspace.id)
        }
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func switchWorkspaceRelative(isNext: Bool, wrapAround: Bool = true) {
        borderManager.hideBorder()

        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let currentWorkspace = activeWorkspace() else { return }
        let previousWorkspace = currentWorkspace

        let targetWorkspace: WorkspaceDescriptor? = if isNext {
            workspaceManager.nextWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        } else {
            workspaceManager.previousWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        }

        guard let targetWorkspace else { return }

        saveNiriViewportState(for: currentWorkspace.id)
        guard workspaceManager.setActiveWorkspace(targetWorkspace.id, on: currentMonitorId) else {
            return
        }

        activeMonitorId = currentMonitorId

        focusedHandle = resolveWorkspaceFocus(for: targetWorkspace.id)

        let monitor = workspaceManager.monitor(for: targetWorkspace.id)
            ?? workspaceManager.monitors.first(where: { $0.id == currentMonitorId })
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: previousWorkspace,
                to: targetWorkspace,
                monitor: monitor
            )
        } ?? false
        executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            startScrollAnimation(for: targetWorkspace.id)
        }
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let engine = niriEngine else { return }
        var state = workspaceManager.niriViewportState(for: workspaceId)

        if let focused = focusedHandle,
           workspaceManager.workspace(for: focused) == workspaceId,
           let focusedNode = engine.findNode(for: focused)
        {
            state.selectedNodeId = focusedNode.id
        }

        workspaceManager.updateNiriViewportState(state, for: workspaceId)
    }

    func summonWorkspace(index: Int) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = workspaceManager.workspaceId(for: targetName, createIfMissing: false)
        else { return }

        guard let targetMonitorId = workspaceManager.monitorId(for: targetWsId),
              targetMonitorId != currentMonitorId
        else {
            switchWorkspace(index: index)
            return
        }

        let previousWsOnCurrent = activeWorkspace()?.id

        guard workspaceManager.summonWorkspace(targetWsId, to: currentMonitorId) else { return }

        syncMonitorsToNiriEngine()

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [targetWsId]
        if let previousWsOnCurrent { affectedWorkspaces.insert(previousWsOnCurrent) }

        applyLayoutForWorkspaces(affectedWorkspaces)

        withSuppressedMonitorUpdate {
            focusedHandle = resolveWorkspaceFocus(for: targetWsId)
        }

        if let handle = focusedHandle {
            focusWindow(handle)
        }

        refreshWindowsAndLayout()
    }

    func focusWorkspaceAnywhere(index: Int) {
        borderManager.hideBorder()

        let targetName = String(max(0, index) + 1)

        guard let targetWsId = workspaceManager.workspaceId(named: targetName) else { return }
        guard let targetMonitor = workspaceManager.monitorForWorkspace(targetWsId) else { return }
        let previousWorkspaceOnTarget = workspaceManager.activeWorkspace(on: targetMonitor.id)

        if let currentWorkspace = activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = workspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard workspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return }

        syncMonitorsToNiriEngine()

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            previousMonitorId = currentMonitorId
        }
        activeMonitorId = targetMonitor.id

        focusedHandle = resolveWorkspaceFocus(for: targetWsId)

        let targetWorkspace = workspaceManager.descriptor(for: targetWsId)
        let workspaceSwitchAnimated = targetWorkspace.map { targetWorkspace in
            startWorkspaceSwitchAnimation(
                from: previousWorkspaceOnTarget,
                to: targetWorkspace,
                monitor: targetMonitor
            )
        } ?? false
        executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            startScrollAnimation(for: targetWsId)
        }
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func workspaceBackAndForth() {
        borderManager.hideBorder()

        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }

        guard let prevWorkspace = workspaceManager.previousWorkspace(on: currentMonitorId) else {
            return
        }

        let currentWorkspace = activeWorkspace()
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard workspaceManager.setActiveWorkspace(prevWorkspace.id, on: currentMonitorId) else {
            return
        }

        activeMonitorId = currentMonitorId

        focusedHandle = resolveWorkspaceFocus(for: prevWorkspace.id)

        let monitor = workspaceManager.monitor(for: prevWorkspace.id)
            ?? workspaceManager.monitors.first(where: { $0.id == currentMonitorId })
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: currentWorkspace,
                to: prevWorkspace,
                monitor: monitor
            )
        } ?? false
        executeLayoutRefreshImmediate()
        if workspaceSwitchAnimated {
            startScrollAnimation(for: prevWorkspace.id)
        }
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    private func resolveOrCreateAdjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        on monitorId: Monitor.ID
    ) -> WorkspaceDescriptor? {
        let wm = workspaceManager

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
        let sourceLayout: LayoutType = sourceWsId
            .flatMap { workspaceManager.descriptor(for: $0)?.name }
            .map { settings.layoutType(for: $0) } ?? .defaultLayout
        let targetLayout: LayoutType = workspaceManager.descriptor(for: targetWsId)
            .map { settings.layoutType(for: $0.name) } ?? .defaultLayout
        let sourceIsDwindle = sourceLayout == .dwindle
        let targetIsDwindle = targetLayout == .dwindle

        var newSourceFocusHandle: WindowHandle?
        var movedWithNiri = false

        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWsId,
           let engine = niriEngine,
           let windowNode = engine.findNode(for: handle)
        {
            var sourceState = workspaceManager.niriViewportState(for: sourceWsId)
            var targetState = workspaceManager.niriViewportState(for: targetWsId)
            if let result = engine.moveWindowToWorkspace(
                windowNode,
                from: sourceWsId,
                to: targetWsId,
                sourceState: &sourceState,
                targetState: &targetState
            ) {
                workspaceManager.updateNiriViewportState(sourceState, for: sourceWsId)
                workspaceManager.updateNiriViewportState(targetState, for: targetWsId)
                if let newFocusId = result.newFocusNodeId,
                   let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
                {
                    lastFocusedByWorkspace[sourceWsId] = newFocusNode.handle
                    newSourceFocusHandle = newFocusNode.handle
                }
                movedWithNiri = true
            }
        }

        if !movedWithNiri,
           !sourceIsDwindle,
           let sourceWsId,
           let engine = niriEngine
        {
            var sourceState = workspaceManager.niriViewportState(for: sourceWsId)

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
                lastFocusedByWorkspace[sourceWsId] = selectedNode.handle
                newSourceFocusHandle = selectedNode.handle
            }

            workspaceManager.updateNiriViewportState(sourceState, for: sourceWsId)
        } else if sourceIsDwindle,
                  let sourceWsId,
                  let dwindleEngine
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
        guard let handle = focusedHandle else { return }
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        let transferResult = transferWindowFromSourceEngine(handle: handle, from: wsId, to: targetWorkspace.id)
        guard transferResult.succeeded else { return }

        workspaceManager.setWorkspace(for: handle, to: targetWorkspace.id)
        lastFocusedByWorkspace[targetWorkspace.id] = handle

        if let engine = niriEngine {
            let sourceState = workspaceManager.niriViewportState(for: wsId)
            if let newSelectedId = sourceState.selectedNodeId,
               let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
            {
                focusedHandle = newSelectedNode.handle
            } else {
                focusedHandle = workspaceManager
                    .entries(in: wsId).first?.handle
            }
        } else {
            focusedHandle = workspaceManager.entries(in: wsId).first?.handle
        }

        refreshWindowsAndLayout()

        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let handle = focusedHandle else { return }
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        var sourceState = workspaceManager.niriViewportState(for: wsId)
        var targetState = workspaceManager.niriViewportState(for: targetWorkspace.id)

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

        workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        workspaceManager.updateNiriViewportState(targetState, for: targetWorkspace.id)

        for window in column.windowNodes {
            workspaceManager.setWorkspace(for: window.handle, to: targetWorkspace.id)
        }

        lastFocusedByWorkspace[targetWorkspace.id] = handle

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            setFocus(newFocusNode.handle, in: wsId)
        } else {
            focusedHandle = workspaceManager.entries(in: wsId).first?.handle
        }

        refreshWindowsAndLayout()

        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = workspaceManager.workspaceId(for: targetName, createIfMissing: true)
        else { return }

        guard targetWsId != wsId else { return }

        var sourceState = workspaceManager.niriViewportState(for: wsId)
        var targetState = workspaceManager.niriViewportState(for: targetWsId)

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

        workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        workspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            setFocus(newFocusNode.handle, in: wsId)
        } else {
            focusedHandle = workspaceManager.entries(in: wsId).first?.handle
        }

        refreshWindowsAndLayout()

        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let handle = focusedHandle else { return }
        let targetName = String(max(0, index) + 1)
        guard let targetId = workspaceManager.workspaceId(for: targetName, createIfMissing: true),
              let target = workspaceManager.descriptor(for: targetId)
        else {
            return
        }
        let currentWorkspaceId = workspaceManager.workspace(for: handle)

        let transferResult = transferWindowFromSourceEngine(handle: handle, from: currentWorkspaceId, to: target.id)
        guard transferResult.succeeded else { return }

        workspaceManager.setWorkspace(for: handle, to: target.id)

        if let targetMonitor = workspaceManager.monitorForWorkspace(target.id) {
            _ = workspaceManager.setActiveWorkspace(target.id, on: targetMonitor.id)
        }

        if target.id != activeWorkspace()?.id, let currentWorkspaceId {
            if let engine = niriEngine {
                let sourceState = workspaceManager.niriViewportState(for: currentWorkspaceId)
                if let newSelectedId = sourceState.selectedNodeId,
                   let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
                {
                    focusedHandle = newSelectedNode.handle
                } else {
                    focusedHandle = workspaceManager
                        .entries(in: currentWorkspaceId).first?.handle
                }
            } else {
                focusedHandle = workspaceManager.entries(in: currentWorkspaceId)
                    .first?.handle
            }
        }

        refreshWindowsAndLayout()

        if target.id == activeWorkspace()?.id {
            if let engine = niriEngine,
               let movedNode = engine.findNode(for: handle),
               let monitor = workspaceManager.monitor(for: target.id)
            {
                var targetState = workspaceManager.niriViewportState(for: target.id)
                targetState.selectedNodeId = movedNode.id

                let gap = CGFloat(workspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: target.id,
                    state: &targetState,
                    workingFrame: monitor.visibleFrame,
                    gaps: gap,
                    alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                )
                workspaceManager.updateNiriViewportState(targetState, for: target.id)
            }
            focusWindow(handle)
        }
    }

    func moveFocusedWindowToMonitor(direction: Direction) {
        guard let handle = focusedHandle,
              let currentWorkspaceId = workspaceManager.workspace(for: handle),
              let currentMonitorId = workspaceManager.monitorId(for: currentWorkspaceId)
        else { return }

        guard let target = workspaceManager
            .resolveTargetForMonitorMove(from: currentWorkspaceId, direction: direction)
        else { return }

        let targetWorkspace = target.workspace
        let targetMonitor = target.monitor

        let transferResult = transferWindowFromSourceEngine(
            handle: handle, from: currentWorkspaceId, to: targetWorkspace.id
        )
        guard transferResult.succeeded else { return }

        workspaceManager.setWorkspace(for: handle, to: targetWorkspace.id)

        _ = workspaceManager.setActiveWorkspace(targetWorkspace.id, on: targetMonitor.id)

        syncMonitorsToNiriEngine()

        applyLayoutForWorkspaces(
            [currentWorkspaceId, targetWorkspace.id]
        )

        let shouldFollowFocus = settings.focusFollowsWindowToMonitor
        withSuppressedMonitorUpdate {
            if shouldFollowFocus {
                previousMonitorId = currentMonitorId
                activeMonitorId = targetMonitor.id
                setFocus(handle, in: targetWorkspace.id)
            } else {
                let sourceState = workspaceManager.niriViewportState(for: currentWorkspaceId)
                if let engine = niriEngine,
                   let newSelectedId = sourceState.selectedNodeId,
                   let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
                {
                    focusedHandle = newSelectedNode.handle
                } else {
                    focusedHandle = workspaceManager
                        .entries(in: currentWorkspaceId).first?.handle
                }
            }
        }

        if let focusHandle = focusedHandle {
            focusWindow(focusHandle)
        }

        refreshWindowsAndLayout()
    }

    func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
        guard let handle = focusedHandle else { return }
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        else { return }
        guard let currentWorkspaceId = workspaceManager.workspace(for: handle) else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: monitorDirection
        ) else { return }

        let targetName = String(max(0, workspaceIndex) + 1)
        guard let targetWsId = workspaceManager.workspaceId(for: targetName, createIfMissing: true)
        else { return }

        if workspaceManager.monitorId(for: targetWsId) != targetMonitor.id {
            _ = workspaceManager.moveWorkspaceToMonitor(targetWsId, to: targetMonitor.id)
            syncMonitorsToNiriEngine()
        }

        let transferResult = transferWindowFromSourceEngine(
            handle: handle, from: currentWorkspaceId, to: targetWsId
        )
        guard transferResult.succeeded else { return }

        workspaceManager.setWorkspace(for: handle, to: targetWsId)

        let shouldFollowFocus = settings.focusFollowsWindowToMonitor

        if shouldFollowFocus {
            previousMonitorId = currentMonitorId
            activeMonitorId = targetMonitor.id

            if let monitor = workspaceManager.monitorForWorkspace(targetWsId) {
                _ = workspaceManager.setActiveWorkspace(targetWsId, on: monitor.id)
            }

            setFocus(handle, in: targetWsId)

            refreshWindowsAndLayout()
            focusWindow(handle)

            if let engine = niriEngine,
               let movedNode = engine.findNode(for: handle),
               let monitor = workspaceManager.monitor(for: targetWsId)
            {
                var targetState = workspaceManager.niriViewportState(for: targetWsId)
                targetState.selectedNodeId = movedNode.id

                let gap = CGFloat(workspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: targetWsId,
                    state: &targetState,
                    workingFrame: monitor.visibleFrame,
                    gaps: gap,
                    alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                )
                workspaceManager.updateNiriViewportState(targetState, for: targetWsId)
            }
        } else {
            if let engine = niriEngine {
                let sourceState = workspaceManager.niriViewportState(for: currentWorkspaceId)
                if let newSelectedId = sourceState.selectedNodeId,
                   let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
                {
                    focusedHandle = newSelectedNode.handle
                } else {
                    focusedHandle = workspaceManager
                        .entries(in: currentWorkspaceId).first?.handle
                }
            }

            refreshWindowsAndLayout()
            if let newHandle = focusedHandle {
                focusWindow(newHandle)
            }
        }
    }
}
