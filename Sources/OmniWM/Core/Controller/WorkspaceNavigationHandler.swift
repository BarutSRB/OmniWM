import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceNavigationHandler {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    private struct WindowTransferResult {
        let succeeded: Bool
        let newSourceFocusToken: WindowToken?
    }

    private func applySessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        viewportState: ViewportState? = nil,
        rememberedFocusToken: WindowToken? = nil
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: viewportState,
                rememberedFocusToken: rememberedFocusToken
            )
        )
    }

    private func applySessionTransfer(
        sourceWorkspaceId: WorkspaceDescriptor.ID?,
        sourceState: ViewportState?,
        sourceFocusedToken: WindowToken?,
        targetWorkspaceId: WorkspaceDescriptor.ID?,
        targetState: ViewportState?,
        targetFocusedToken: WindowToken?
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionTransfer(
            .init(
                sourcePatch: sourceWorkspaceId.map {
                    .init(
                        workspaceId: $0,
                        viewportState: sourceState,
                        rememberedFocusToken: sourceFocusedToken
                    )
                },
                targetPatch: targetWorkspaceId.map {
                    .init(
                        workspaceId: $0,
                        viewportState: targetState,
                        rememberedFocusToken: targetFocusedToken
                    )
                }
            )
        )
    }

    private func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeId,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitorId
        )
    }

    private func interactionMonitorId(for controller: WMController) -> Monitor.ID? {
        controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
    }

    private func startWorkspaceSwitchAnimation(
        from previousWorkspace: WorkspaceDescriptor?,
        to targetWorkspace: WorkspaceDescriptor,
        monitor: Monitor
    ) -> Bool {
        guard let controller else { return false }
        guard controller.settings.layoutType(for: targetWorkspace.name) != .dwindle,
              let engine = controller.niriEngine else {
            return false
        }
        if previousWorkspace?.id == targetWorkspace.id {
            return false
        }
        guard let previousWorkspace else { return false }

        let niriMonitor = engine.monitor(for: monitor.id)
            ?? engine.ensureMonitor(for: monitor.id, monitor: monitor)
        niriMonitor.animationClock = controller.animationClock
        niriMonitor.startWorkspaceSwitch(
            orderedWorkspaceIds: controller.workspaceManager.workspaces(on: monitor.id).map(\.id),
            from: previousWorkspace.id,
            to: targetWorkspace.id,
            animated: controller.motionPolicy.animationsEnabled
        )
        return niriMonitor.isWorkspaceSwitchAnimating
    }

    private func startWorkspaceSwitchAnimationIfNeeded(
        from previousWorkspace: WorkspaceDescriptor?,
        to targetWorkspace: WorkspaceDescriptor,
        monitor: Monitor,
        targetWasVisibleBeforeSwitch: Bool
    ) -> Bool {
        guard !targetWasVisibleBeforeSwitch else { return false }
        return startWorkspaceSwitchAnimation(
            from: previousWorkspace,
            to: targetWorkspace,
            monitor: monitor
        )
    }

    private struct WorkspaceTransitionFocusHandoff {
        let focusToken: WindowToken?
        let shouldClearManagedFocus: Bool
    }

    private func resolveWorkspaceTransitionFocusHandoff(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> WorkspaceTransitionFocusHandoff {
        guard let controller else {
            return WorkspaceTransitionFocusHandoff(
                focusToken: nil,
                shouldClearManagedFocus: false
            )
        }
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: workspaceId)
        let shouldClearManagedFocus = focusToken == nil && controller.workspaceManager.entries(in: workspaceId).isEmpty
        return WorkspaceTransitionFocusHandoff(
            focusToken: focusToken,
            shouldClearManagedFocus: shouldClearManagedFocus
        )
    }

    private func clearManagedFocusAfterEmptyWorkspaceSwitch() {
        guard let controller else { return }
        let canceledRequest = controller.focusBridge.cancelManagedRequest()
        if let canceledRequest {
            controller.focusBridge.discardPendingFocus(canceledRequest.token)
        }
        controller.clearKeyboardFocusTarget()
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
        controller.borderManager.hideBorder()
    }

    private func commitWorkspaceTransitionFocusHandoff(
        targetWorkspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor?,
        startScrollAnimation: Bool
    ) {
        guard let controller else { return }
        let handoff = resolveWorkspaceTransitionFocusHandoff(for: targetWorkspaceId)
        if let monitor {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition
        ) { [weak self, weak controller] in
            guard let controller else { return }
            if let focusToken = handoff.focusToken {
                controller.focusWindow(focusToken)
            } else if handoff.shouldClearManagedFocus {
                self?.clearManagedFocusAfterEmptyWorkspaceSwitch()
            }
            if startScrollAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: targetWorkspaceId)
            }
        }
    }

    func focusMonitorCyclic(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
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
        guard let previousId = controller.workspaceManager.previousInteractionMonitorId else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard controller.workspaceManager.monitors.contains(where: { $0.id == previousId }) else { return }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    private func switchToMonitor(_ targetMonitorId: Monitor.ID, fromMonitor currentMonitorId: Monitor.ID) {
        guard let controller else { return }

        guard let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitorId)
        else {
            return
        }

        _ = controller.workspaceManager.setInteractionMonitor(targetMonitorId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: targetWorkspace.id)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [targetWorkspace.id],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
    }

    func swapCurrentWorkspaceWithMonitor(direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
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
            if let targetToken = controller.workspaceManager.lastFocusedToken(in: targetWsId),
               let targetNode = engine.findNode(for: targetToken)
            {
                commitWorkspaceSelection(
                    nodeId: targetNode.id,
                    focusedToken: targetToken,
                    in: targetWsId
                )
            }
        }

        guard controller.workspaceManager.swapWorkspaces(
            currentWsId, on: currentMonitorId,
            with: targetWsId, on: targetMonitor.id
        ) else { return }

        controller.syncMonitorsToNiriEngine()

        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: targetWsId)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [currentWsId, targetWsId],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
    }

    func switchWorkspace(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        switchWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func switchWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace,
           currentWorkspace.name == rawWorkspaceID
        {
            return
        }

        controller.borderManager.hideBorder()

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false),
              let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWorkspaceId)
        else {
            return
        }

        let previousWorkspaceOnTarget = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)
        let targetWasVisibleBeforeSwitch = previousWorkspaceOnTarget?.id == targetWorkspaceId

        guard let result = controller.workspaceManager.focusWorkspace(named: rawWorkspaceID) else { return }

        let workspaceSwitchAnimated = startWorkspaceSwitchAnimationIfNeeded(
            from: previousWorkspaceOnTarget,
            to: result.workspace,
            monitor: result.monitor,
            targetWasVisibleBeforeSwitch: targetWasVisibleBeforeSwitch
        )
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: result.workspace.id,
            monitor: result.monitor,
            startScrollAnimation: workspaceSwitchAnimated
        )
    }

    func switchWorkspaceRelative(isNext: Bool, wrapAround: Bool = true) {
        guard let controller else { return }
        controller.borderManager.hideBorder()

        guard let currentMonitorId = interactionMonitorId(for: controller)
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

        let monitor = controller.workspaceManager.monitor(for: targetWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: previousWorkspace,
                to: targetWorkspace,
                monitor: monitor
            )
        } ?? false
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWorkspace.id,
            monitor: monitor,
            startScrollAnimation: workspaceSwitchAnimated
        )
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }

        if let focusedToken = controller.workspaceManager.focusedToken,
           controller.workspaceManager.workspace(for: focusedToken) == workspaceId,
           let focusedNode = engine.findNode(for: focusedToken)
        {
            commitWorkspaceSelection(
                nodeId: focusedNode.id,
                focusedToken: focusedToken,
                in: workspaceId
            )
        }
    }

    func focusWorkspaceAnywhere(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID)
    }

    func focusWorkspaceAnywhere(rawWorkspaceID: String) {
        guard let controller else { return }
        controller.borderManager.hideBorder()

        let currentWorkspace = controller.activeWorkspace()

        guard let targetWsId = controller.workspaceManager.workspaceId(named: rawWorkspaceID) else { return }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWsId) else { return }
        let previousWorkspaceOnTarget = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)
        let targetWasVisibleBeforeSwitch = previousWorkspaceOnTarget?.id == targetWsId

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = interactionMonitorId(for: controller)

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = controller.workspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard controller.workspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        let targetWorkspace = controller.workspaceManager.descriptor(for: targetWsId)
        let workspaceSwitchAnimated = targetWorkspace.map { targetWorkspace in
            startWorkspaceSwitchAnimationIfNeeded(
                from: previousWorkspaceOnTarget,
                to: targetWorkspace,
                monitor: targetMonitor,
                targetWasVisibleBeforeSwitch: targetWasVisibleBeforeSwitch
            )
        } ?? false
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWsId,
            monitor: targetMonitor,
            startScrollAnimation: workspaceSwitchAnimated
        )
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        controller.borderManager.hideBorder()

        guard let currentMonitorId = interactionMonitorId(for: controller)
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

        let monitor = controller.workspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        let workspaceSwitchAnimated = monitor.flatMap { monitor in
            startWorkspaceSwitchAnimation(
                from: currentWorkspace,
                to: prevWorkspace,
                monitor: monitor
            )
        } ?? false
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: prevWorkspace.id,
            monitor: monitor,
            startScrollAnimation: workspaceSwitchAnimated
        )
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

        guard let targetId = wm.workspaceId(for: candidateName, createIfMissing: false) else { return nil }
        wm.assignWorkspaceToMonitor(targetId, monitorId: monitorId)
        return wm.descriptor(for: targetId)
    }

    private func transferWindowFromSourceEngine(
        token: WindowToken,
        from sourceWsId: WorkspaceDescriptor.ID?,
        to targetWsId: WorkspaceDescriptor.ID
    ) -> WindowTransferResult {
        guard let controller else {
            return WindowTransferResult(succeeded: false, newSourceFocusToken: nil)
        }
        let sourceLayout: LayoutType = sourceWsId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout
        let targetLayout: LayoutType = controller.workspaceManager.descriptor(for: targetWsId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        let sourceIsDwindle = sourceLayout == .dwindle
        let targetIsDwindle = targetLayout == .dwindle
        var newSourceFocusToken: WindowToken?
        var movedWithNiri = false

        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine,
           let windowNode = engine.findNode(for: token)
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
                if let newFocusId = result.newFocusNodeId,
                   let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
                {
                    newSourceFocusToken = newFocusNode.token
                }
                applySessionTransfer(
                    sourceWorkspaceId: sourceWsId,
                    sourceState: sourceState,
                    sourceFocusedToken: newSourceFocusToken,
                    targetWorkspaceId: targetWsId,
                    targetState: targetState,
                    targetFocusedToken: nil
                )
                movedWithNiri = true
            }
        }

        if !movedWithNiri,
           !sourceIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine
        {
            var sourceState = controller.workspaceManager.niriViewportState(for: sourceWsId)
            if let currentNode = engine.findNode(for: token),
               sourceState.selectedNodeId == currentNode.id
            {
                sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                    removing: currentNode.id,
                    in: sourceWsId
                )
            }

            if targetIsDwindle, engine.findNode(for: token) != nil {
                engine.removeWindow(token: token)
            }

            if let selectedId = sourceState.selectedNodeId,
               engine.findNode(by: selectedId) == nil
            {
                sourceState.selectedNodeId = engine.validateSelection(selectedId, in: sourceWsId)
            }

            if let selectedId = sourceState.selectedNodeId,
               let selectedNode = engine.findNode(by: selectedId) as? NiriWindow
            {
                newSourceFocusToken = selectedNode.token
            }

            applySessionTransfer(
                sourceWorkspaceId: sourceWsId,
                sourceState: sourceState,
                sourceFocusedToken: newSourceFocusToken,
                targetWorkspaceId: nil,
                targetState: nil,
                targetFocusedToken: nil
            )
        } else if sourceIsDwindle,
                  let sourceWsId,
                  let dwindleEngine = controller.dwindleEngine
        {
            dwindleEngine.removeWindow(token: token, from: sourceWsId)
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

        return WindowTransferResult(succeeded: succeeded, newSourceFocusToken: newSourceFocusToken)
    }

    func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        let transferResult = transferWindowFromSourceEngine(token: token, from: wsId, to: targetWorkspace.id)
        guard transferResult.succeeded else { return }

        controller.reassignManagedWindow(token, to: targetWorkspace.id)
        applySessionPatch(workspaceId: targetWorkspace.id, rememberedFocusToken: token)

        let sourceState = controller.workspaceManager.niriViewportState(for: wsId)
        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: sourceState.selectedNodeId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: wsId)

        controller.layoutRefreshController.commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
    }

    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetWorkspace = resolveOrCreateAdjacentWorkspace(
            from: wsId, direction: direction, on: currentMonitorId
        ) else { return }

        saveNiriViewportState(for: wsId)

        var sourceState = controller.workspaceManager.niriViewportState(for: wsId)
        var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspace.id)

        guard let windowNode = engine.findNode(for: token),
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

        applySessionTransfer(
            sourceWorkspaceId: wsId,
            sourceState: sourceState,
            sourceFocusedToken: nil,
            targetWorkspaceId: targetWorkspace.id,
            targetState: targetState,
            targetFocusedToken: nil
        )

        for window in column.windowNodes {
            controller.reassignManagedWindow(window.token, to: targetWorkspace.id)
        }

        applySessionPatch(workspaceId: targetWorkspace.id, rememberedFocusToken: token)

        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: result.newFocusNodeId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: wsId)

        controller.layoutRefreshController.commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveColumnToWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func moveColumnToWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        guard let targetWsId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
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

        applySessionTransfer(
            sourceWorkspaceId: wsId,
            sourceState: sourceState,
            sourceFocusedToken: nil,
            targetWorkspaceId: targetWsId,
            targetState: targetState,
            targetFocusedToken: nil
        )

        for window in column.windowNodes {
            controller.reassignManagedWindow(window.token, to: targetWsId)
        }

        applySessionPatch(workspaceId: targetWsId, rememberedFocusToken: token)

        controller.recoverSourceFocusAfterMove(in: wsId, preferredNodeId: result.newFocusNodeId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: wsId)

        controller.layoutRefreshController.commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
    }

    func moveFocusedWindow(toRawWorkspaceID rawWorkspaceID: String) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let targetId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false),
              let target = controller.workspaceManager.descriptor(for: targetId)
        else {
            return
        }
        let currentWorkspaceId = controller.workspaceManager.workspace(for: token)
        let transferResult = transferWindowFromSourceEngine(token: token, from: currentWorkspaceId, to: target.id)
        guard transferResult.succeeded else { return }

        controller.reassignManagedWindow(token, to: target.id)

        let shouldFollowFocus = controller.settings.focusFollowsWindowToMonitor
        if shouldFollowFocus {
            controller.isTransferringWindow = true
            defer { controller.isTransferringWindow = false }

            let targetMonitor = controller.workspaceManager.monitorForWorkspace(target.id)
            if let targetMonitor {
                _ = controller.workspaceManager.setActiveWorkspace(target.id, on: targetMonitor.id)
            }

            if let currentWorkspaceId,
               let sourceMonitor = controller.workspaceManager.monitor(for: currentWorkspaceId) {
                controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
            }
            var targetState = controller.workspaceManager.niriViewportState(for: target.id)
            if let engine = controller.niriEngine,
               let movedNode = engine.findNode(for: token),
               let monitor = controller.workspaceManager.monitor(for: target.id)
            {
                targetState.selectedNodeId = movedNode.id
                let gap = CGFloat(controller.workspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: target.id,
                    motion: controller.motionPolicy.snapshot(),
                    state: &targetState,
                    workingFrame: monitor.visibleFrame,
                    gaps: gap
                )
            }
            applySessionPatch(
                workspaceId: target.id,
                viewportState: targetState,
                rememberedFocusToken: token
            )
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .workspaceTransition
            ) { [weak controller] in
                controller?.focusWindow(token)
            }
        } else {
            if let currentWorkspaceId {
                let sourceState = controller.workspaceManager.niriViewportState(for: currentWorkspaceId)
                controller.recoverSourceFocusAfterMove(in: currentWorkspaceId, preferredNodeId: sourceState.selectedNodeId)
            }
            let focusToken = currentWorkspaceId.flatMap { controller.resolveAndSetWorkspaceFocusToken(for: $0) }

            if let currentWorkspaceId,
               let sourceMonitor = controller.workspaceManager.monitor(for: currentWorkspaceId) {
                controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
            }
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .workspaceTransition
            ) { [weak controller] in
                if let focusToken {
                    controller?.focusWindow(focusToken)
                }
            }
        }
    }

    @discardableResult
    func moveWindow(handle: WindowHandle, toWorkspaceId targetWsId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }
        let token = handle.id

        let currentWorkspaceId = controller.workspaceManager.workspace(for: token)
        let transferResult = transferWindowFromSourceEngine(
            token: token,
            from: currentWorkspaceId,
            to: targetWsId
        )
        guard transferResult.succeeded else { return false }

        controller.reassignManagedWindow(token, to: targetWsId)
        applySessionPatch(workspaceId: targetWsId, rememberedFocusToken: token)

        if let currentWorkspaceId {
            let sourceState = controller.workspaceManager.niriViewportState(for: currentWorkspaceId)
            controller.recoverSourceFocusAfterMove(in: currentWorkspaceId, preferredNodeId: sourceState.selectedNodeId)
        }

        return true
    }

    func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else { return }
        moveWindowToWorkspaceOnMonitor(rawWorkspaceID: rawWorkspaceID, monitorDirection: monitorDirection)
    }

    func moveWindowToWorkspaceOnMonitor(rawWorkspaceID: String, monitorDirection: Direction) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let currentWorkspaceId = controller.workspaceManager.workspace(for: token) else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: monitorDirection
        ) else { return }

        guard let targetWsId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
        else { return }
        guard controller.workspaceManager.monitorId(for: targetWsId) == targetMonitor.id else { return }

        let transferResult = transferWindowFromSourceEngine(
            token: token, from: currentWorkspaceId, to: targetWsId
        )
        guard transferResult.succeeded else { return }

        controller.reassignManagedWindow(token, to: targetWsId)

        let shouldFollowFocus = controller.settings.focusFollowsWindowToMonitor

        if shouldFollowFocus {
            if let monitor = controller.workspaceManager.monitorForWorkspace(targetWsId) {
                _ = controller.workspaceManager.setActiveWorkspace(targetWsId, on: monitor.id)
            }

            var targetState = controller.workspaceManager.niriViewportState(for: targetWsId)
            if let engine = controller.niriEngine,
               let movedNode = engine.findNode(for: token),
               let monitor = controller.workspaceManager.monitor(for: targetWsId)
            {
                targetState.selectedNodeId = movedNode.id

                let gap = CGFloat(controller.workspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: targetWsId,
                    motion: controller.motionPolicy.snapshot(),
                    state: &targetState,
                    workingFrame: monitor.visibleFrame,
                    gaps: gap
                )
            }
            applySessionPatch(
                workspaceId: targetWsId,
                viewportState: targetState,
                rememberedFocusToken: token
            )

            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .workspaceTransition
            ) { [weak controller] in
                controller?.focusWindow(token)
            }
        } else {
            let sourceState = controller.workspaceManager.niriViewportState(for: currentWorkspaceId)
            controller.recoverSourceFocusAfterMove(in: currentWorkspaceId, preferredNodeId: sourceState.selectedNodeId)
            let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: currentWorkspaceId)

            controller.layoutRefreshController.commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
                if let focusToken {
                    controller?.focusWindow(focusToken)
                }
            }
        }
    }
}
