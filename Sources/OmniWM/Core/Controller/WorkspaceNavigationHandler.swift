// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceNavigationHandler {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
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

    private func plan(
        _ intent: WorkspaceNavigationKernel.Intent
    ) -> WorkspaceNavigationKernel.Plan? {
        guard let controller else { return nil }
        return WorkspaceNavigationKernel.plan(
            .capture(
                controller: controller,
                intent: intent
            )
        )
    }

    private func clearManagedFocusAfterEmptyWorkspaceTransition() {
        guard let controller else { return }
        let canceledRequest = controller.focusBridge.cancelManagedRequest()
        if let canceledRequest {
            controller.focusBridge.discardPendingFocus(canceledRequest.token)
        }
        controller.clearKeyboardFocusTarget()
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
        controller.hideKeyboardFocusBorder(
            source: .workspaceActivation,
            reason: "cleared focus after empty workspace transition"
        )
    }

    private func commitWorkspaceTransition(
        _ plan: WorkspaceNavigationKernel.Plan,
        stopScrollAnimationOnTargetMonitor: Bool
    ) {
        guard let controller else { return }
        if stopScrollAnimationOnTargetMonitor,
           let targetMonitorId = plan.targetMonitorId,
           let monitor = controller.workspaceManager.monitor(byId: targetMonitorId)
        {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        if let targetWorkspaceId = plan.targetWorkspaceId,
           let resolvedFocusToken = plan.resolvedFocusToken
        {
            applySessionPatch(
                workspaceId: targetWorkspaceId,
                rememberedFocusToken: resolvedFocusToken
            )
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: plan.affectedWorkspaceIds,
            reason: .workspaceTransition
        ) { [weak self, weak controller] in
            guard let controller else { return }
            if let resolvedFocusToken = plan.resolvedFocusToken {
                controller.focusWindow(resolvedFocusToken)
            } else if plan.focusAction == .clearManagedFocus {
                self?.clearManagedFocusAfterEmptyWorkspaceTransition()
            }
        }
    }

    private func saveWorkspaces(_ workspaceIds: [WorkspaceDescriptor.ID]) {
        for workspaceId in workspaceIds {
            saveNiriViewportState(for: workspaceId)
        }
    }

    private func materializeTargetWorkspaceIfNeeded(
        _ plan: WorkspaceNavigationKernel.Plan
    ) -> WorkspaceNavigationKernel.Plan? {
        guard let rawWorkspaceID = plan.materializeTargetWorkspaceRawID else {
            return plan
        }
        guard let controller,
              let targetMonitorId = plan.targetMonitorId,
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceID,
                  createIfMissing: true
              )
        else {
            return nil
        }

        controller.workspaceManager.assignWorkspaceToMonitor(targetWorkspaceId, monitorId: targetMonitorId)
        if controller.niriEngine != nil {
            controller.syncMonitorsToNiriEngine()
        }

        var resolvedPlan = plan
        resolvedPlan.targetWorkspaceId = targetWorkspaceId
        resolvedPlan.materializeTargetWorkspaceRawID = nil
        resolvedPlan.affectedWorkspaceIds.insert(targetWorkspaceId)
        return resolvedPlan
    }

    private func hideFocusBorderIfNeeded(_ plan: WorkspaceNavigationKernel.Plan, reason: String) {
        guard plan.shouldHideFocusBorder, let controller else { return }
        controller.hideKeyboardFocusBorder(
            source: .workspaceActivation,
            reason: reason
        )
    }

    private func activateTargetWorkspaceIfNeeded(_ plan: WorkspaceNavigationKernel.Plan) -> Bool {
        guard let controller,
              let targetWorkspaceId = plan.targetWorkspaceId,
              let targetMonitorId = plan.targetMonitorId
        else {
            return false
        }

        guard plan.shouldActivateTargetWorkspace else {
            if plan.shouldSetInteractionMonitor {
                _ = controller.workspaceManager.setInteractionMonitor(targetMonitorId)
            }
            return true
        }

        return controller.workspaceManager.setActiveWorkspace(targetWorkspaceId, on: targetMonitorId)
    }

    private func commitFocusPlan(_ plan: WorkspaceNavigationKernel.Plan) {
        guard plan.shouldCommitWorkspaceTransition else {
            return
        }

        switch plan.focusAction {
        case .workspaceHandoff:
            commitWorkspaceTransition(plan, stopScrollAnimationOnTargetMonitor: true)

        case .resolveTargetIfPresent:
            commitWorkspaceTransition(plan, stopScrollAnimationOnTargetMonitor: false)

        case .clearManagedFocus:
            commitWorkspaceTransition(plan, stopScrollAnimationOnTargetMonitor: false)

        case .subject, .recoverSource, .none:
            break
        }
    }

    private func applySwitchPlan(
        _ plan: WorkspaceNavigationKernel.Plan,
        hideReason: String
    ) {
        guard plan.outcome == .execute else { return }
        hideFocusBorderIfNeeded(plan, reason: hideReason)
        saveWorkspaces(plan.saveWorkspaceIds)
        guard activateTargetWorkspaceIfNeeded(plan) else { return }
        if plan.shouldSyncMonitorsToNiri {
            controller?.syncMonitorsToNiriEngine()
        }
        commitFocusPlan(plan)
    }

    private func prepareSwapSelection(targetWorkspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let engine = controller.niriEngine,
              let targetToken = controller.workspaceManager.lastFocusedToken(in: targetWorkspaceId),
              let targetNode = engine.findNode(for: targetToken)
        else {
            return
        }

        commitWorkspaceSelection(
            nodeId: targetNode.id,
            focusedToken: targetToken,
            in: targetWorkspaceId
        )
    }

    private func transferWindowFromSourceEngine(
        token: WindowToken,
        from sourceWorkspaceId: WorkspaceDescriptor.ID?,
        to targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }

        let sourceLayout = sourceWorkspaceId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout
        let targetLayout = controller.workspaceManager.descriptor(for: targetWorkspaceId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        let sourceIsDwindle = sourceLayout == .dwindle
        let targetIsDwindle = targetLayout == .dwindle
        var movedWithNiri = false

        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWorkspaceId,
           let engine = controller.niriEngine,
           let windowNode = engine.findNode(for: token)
        {
            var sourceState = controller.workspaceManager.niriViewportState(for: sourceWorkspaceId)
            var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)
            if let result = engine.moveWindowToWorkspace(
                windowNode,
                from: sourceWorkspaceId,
                to: targetWorkspaceId,
                sourceState: &sourceState,
                targetState: &targetState
            ) {
                let sourceFocusedToken = result.newFocusNodeId
                    .flatMap { engine.findNode(by: $0) as? NiriWindow }?
                    .token
                applySessionTransfer(
                    sourceWorkspaceId: sourceWorkspaceId,
                    sourceState: sourceState,
                    sourceFocusedToken: sourceFocusedToken,
                    targetWorkspaceId: targetWorkspaceId,
                    targetState: targetState,
                    targetFocusedToken: nil
                )
                movedWithNiri = true
            }
        }

        if !movedWithNiri,
           !sourceIsDwindle,
           let sourceWorkspaceId,
           let engine = controller.niriEngine
        {
            var sourceState = controller.workspaceManager.niriViewportState(for: sourceWorkspaceId)
            if let currentNode = engine.findNode(for: token),
               sourceState.selectedNodeId == currentNode.id
            {
                sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                    removing: currentNode.id,
                    in: sourceWorkspaceId
                )
            }

            if targetIsDwindle, engine.findNode(for: token) != nil {
                engine.removeWindow(token: token)
            }

            if let selectedId = sourceState.selectedNodeId,
               engine.findNode(by: selectedId) == nil
            {
                sourceState.selectedNodeId = engine.validateSelection(selectedId, in: sourceWorkspaceId)
            }

            let sourceFocusedToken = sourceState.selectedNodeId
                .flatMap { engine.findNode(by: $0) as? NiriWindow }?
                .token

            applySessionTransfer(
                sourceWorkspaceId: sourceWorkspaceId,
                sourceState: sourceState,
                sourceFocusedToken: sourceFocusedToken,
                targetWorkspaceId: nil,
                targetState: nil,
                targetFocusedToken: nil
            )
        } else if sourceIsDwindle,
                  let sourceWorkspaceId,
                  let dwindleEngine = controller.dwindleEngine
        {
            dwindleEngine.removeWindow(token: token, from: sourceWorkspaceId)
        }

        if movedWithNiri {
            return true
        }
        if sourceWorkspaceId == nil {
            return true
        }
        if !sourceIsDwindle && !targetIsDwindle {
            return false
        }
        return true
    }

    private func performTransferFocus(
        _ plan: WorkspaceNavigationKernel.Plan,
        targetFocusToken: WindowToken,
        sourcePreferredNodeId: NodeId?,
        ensureTargetVisible: Bool,
        stopSourceScroll: Bool,
        markTransferringWindow: Bool
    ) {
        guard let controller else { return }

        if stopSourceScroll,
           let sourceWorkspaceId = plan.sourceWorkspaceId,
           let sourceMonitor = controller.workspaceManager.monitor(for: sourceWorkspaceId)
        {
            controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
        }

        switch plan.focusAction {
        case .subject:
            if markTransferringWindow {
                controller.isTransferringWindow = true
            }
            defer {
                if markTransferringWindow {
                    controller.isTransferringWindow = false
                }
            }

            guard let targetWorkspaceId = plan.targetWorkspaceId else { return }
            if let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWorkspaceId) {
                _ = controller.workspaceManager.setActiveWorkspace(targetWorkspaceId, on: targetMonitor.id)
            }

            var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)
            if ensureTargetVisible,
               let engine = controller.niriEngine,
               let movedNode = engine.findNode(for: targetFocusToken),
               let monitor = controller.workspaceManager.monitor(for: targetWorkspaceId)
            {
                targetState.selectedNodeId = movedNode.id
                let gap = CGFloat(controller.workspaceManager.gaps)
                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: targetWorkspaceId,
                    motion: controller.motionPolicy.snapshot(),
                    state: &targetState,
                    workingFrame: monitor.visibleFrame,
                    gaps: gap
                )
            }

            applySessionPatch(
                workspaceId: targetWorkspaceId,
                viewportState: targetState,
                rememberedFocusToken: targetFocusToken
            )

            if plan.shouldCommitWorkspaceTransition {
                controller.layoutRefreshController.commitWorkspaceTransition(
                    affectedWorkspaces: plan.affectedWorkspaceIds,
                    reason: .workspaceTransition
                ) { [weak controller] in
                    controller?.focusWindow(targetFocusToken)
                }
            }

        case .recoverSource:
            if let sourceWorkspaceId = plan.sourceWorkspaceId {
                controller.recoverSourceFocusAfterMove(
                    in: sourceWorkspaceId,
                    preferredNodeId: sourcePreferredNodeId
                )
            }
            let focusToken = plan.sourceWorkspaceId.flatMap { controller.resolveAndSetWorkspaceFocusToken(for: $0) }

            if plan.shouldCommitWorkspaceTransition {
                controller.layoutRefreshController.commitWorkspaceTransition(
                    affectedWorkspaces: plan.affectedWorkspaceIds,
                    reason: .workspaceTransition
                ) { [weak controller] in
                    if let focusToken {
                        controller?.focusWindow(focusToken)
                    }
                }
            }

        case .workspaceHandoff, .resolveTargetIfPresent, .clearManagedFocus, .none:
            break
        }
    }

    private func executeWindowTransferPlan(
        _ plan: WorkspaceNavigationKernel.Plan,
        rememberedTargetFocusToken: WindowToken,
        stopSourceScroll: Bool,
        markTransferringWindow: Bool
    ) -> Bool {
        guard let controller,
              let targetWorkspaceId = plan.targetWorkspaceId
        else {
            return false
        }
        guard case let .window(token) = plan.subject else { return false }

        let transferSucceeded = transferWindowFromSourceEngine(
            token: token,
            from: plan.sourceWorkspaceId,
            to: targetWorkspaceId
        )
        guard transferSucceeded else { return false }

        controller.reassignManagedWindow(token, to: targetWorkspaceId)
        applySessionPatch(workspaceId: targetWorkspaceId, rememberedFocusToken: rememberedTargetFocusToken)

        guard plan.shouldCommitWorkspaceTransition else {
            if let sourceWorkspaceId = plan.sourceWorkspaceId {
                let sourceState = controller.workspaceManager.niriViewportState(for: sourceWorkspaceId)
                controller.recoverSourceFocusAfterMove(
                    in: sourceWorkspaceId,
                    preferredNodeId: sourceState.selectedNodeId
                )
            }
            return true
        }

        let sourcePreferredNodeId = plan.sourceWorkspaceId.map {
            controller.workspaceManager.niriViewportState(for: $0).selectedNodeId
        } ?? nil

        performTransferFocus(
            plan,
            targetFocusToken: rememberedTargetFocusToken,
            sourcePreferredNodeId: sourcePreferredNodeId,
            ensureTargetVisible: true,
            stopSourceScroll: stopSourceScroll,
            markTransferringWindow: markTransferringWindow
        )
        return true
    }

    private func executeColumnTransferPlan(
        _ plan: WorkspaceNavigationKernel.Plan,
        rememberedTargetFocusToken: WindowToken
    ) -> Bool {
        guard let controller,
              let engine = controller.niriEngine,
              let sourceWorkspaceId = plan.sourceWorkspaceId,
              let targetWorkspaceId = plan.targetWorkspaceId
        else {
            return false
        }
        guard case let .column(subjectToken) = plan.subject else { return false }

        var sourceState = controller.workspaceManager.niriViewportState(for: sourceWorkspaceId)
        var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)

        guard let windowNode = engine.findNode(for: subjectToken),
              let column = engine.findColumn(containing: windowNode, in: sourceWorkspaceId),
              let result = engine.moveColumnToWorkspace(
                  column,
                  from: sourceWorkspaceId,
                  to: targetWorkspaceId,
                  sourceState: &sourceState,
                  targetState: &targetState
              )
        else {
            return false
        }

        applySessionTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sourceState: sourceState,
            sourceFocusedToken: nil,
            targetWorkspaceId: targetWorkspaceId,
            targetState: targetState,
            targetFocusedToken: nil
        )

        for window in column.windowNodes {
            controller.reassignManagedWindow(window.token, to: targetWorkspaceId)
        }

        applySessionPatch(
            workspaceId: targetWorkspaceId,
            rememberedFocusToken: rememberedTargetFocusToken
        )

        performTransferFocus(
            plan,
            targetFocusToken: rememberedTargetFocusToken,
            sourcePreferredNodeId: result.newFocusNodeId,
            ensureTargetVisible: false,
            stopSourceScroll: false,
            markTransferringWindow: false
        )
        return true
    }

    func focusMonitorCyclic(previous: Bool) {
        guard let controller else { return }
        guard let plan = plan(
            .init(
                operation: .focusMonitorCyclic,
                direction: previous ? .left : .right,
                currentMonitorId: interactionMonitorId(for: controller)
            )
        ) else {
            return
        }
        applySwitchPlan(plan, hideReason: "focus monitor")
    }

    func focusLastMonitor() {
        guard let controller else { return }
        guard let plan = plan(
            .init(
                operation: .focusMonitorLast,
                currentMonitorId: interactionMonitorId(for: controller),
                previousMonitorId: controller.workspaceManager.previousInteractionMonitorId
            )
        ) else {
            return
        }
        applySwitchPlan(plan, hideReason: "focus last monitor")
    }

    func swapCurrentWorkspaceWithMonitor(direction: Direction) {
        guard let controller else { return }
        guard let plan = plan(
            .init(
                operation: .swapWorkspaceWithMonitor,
                direction: direction,
                currentWorkspaceId: controller.activeWorkspace()?.id,
                currentMonitorId: interactionMonitorId(for: controller)
            )
        ) else {
            return
        }

        guard plan.outcome == .execute,
              let sourceWorkspaceId = plan.sourceWorkspaceId,
              let targetWorkspaceId = plan.targetWorkspaceId,
              let sourceMonitorId = plan.sourceMonitorId,
              let targetMonitorId = plan.targetMonitorId
        else {
            return
        }

        saveWorkspaces(plan.saveWorkspaceIds)
        prepareSwapSelection(targetWorkspaceId: targetWorkspaceId)

        guard controller.workspaceManager.swapWorkspaces(
            sourceWorkspaceId,
            on: sourceMonitorId,
            with: targetWorkspaceId,
            on: targetMonitorId
        ) else {
            return
        }

        if plan.shouldSyncMonitorsToNiri {
            controller.syncMonitorsToNiriEngine()
        }
        commitFocusPlan(plan)
    }

    func switchWorkspace(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        switchWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func switchWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        guard let plan = plan(
            .init(
                operation: .switchWorkspaceExplicit,
                currentWorkspaceId: controller.activeWorkspace()?.id,
                targetWorkspaceId: controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
            )
        ) else {
            return
        }
        applySwitchPlan(plan, hideReason: "switch workspace")
    }

    func switchWorkspaceRelative(isNext: Bool, wrapAround: Bool = true) {
        guard let controller else { return }
        guard let plan = plan(
            .init(
                operation: .switchWorkspaceRelative,
                direction: isNext ? .right : .left,
                currentWorkspaceId: controller.activeWorkspace()?.id,
                currentMonitorId: interactionMonitorId(for: controller),
                wrapAround: wrapAround
            )
        ) else {
            return
        }
        applySwitchPlan(plan, hideReason: "switch workspace relative")
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
        guard let plan = plan(
            .init(
                operation: .focusWorkspaceAnywhere,
                currentWorkspaceId: controller.activeWorkspace()?.id,
                targetWorkspaceId: controller.workspaceManager.workspaceId(named: rawWorkspaceID),
                currentMonitorId: interactionMonitorId(for: controller)
            )
        ) else {
            return
        }
        applySwitchPlan(plan, hideReason: "focus workspace anywhere")
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        guard let plan = plan(
            .init(
                operation: .workspaceBackAndForth,
                currentWorkspaceId: controller.activeWorkspace()?.id,
                currentMonitorId: interactionMonitorId(for: controller)
            )
        ) else {
            return
        }
        applySwitchPlan(plan, hideReason: "workspace back and forth")
    }

    func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        let focusedToken = controller.workspaceManager.focusedToken
        guard let rawPlan = plan(
            .init(
                operation: .moveWindowAdjacent,
                direction: direction,
                sourceWorkspaceId: controller.activeWorkspace()?.id,
                currentMonitorId: interactionMonitorId(for: controller),
                focusedToken: focusedToken
            )
        ),
        let plan = materializeTargetWorkspaceIfNeeded(
            rawPlan
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds)
        _ = executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: focusedToken ?? .init(pid: 0, windowId: 0),
            stopSourceScroll: false,
            markTransferringWindow: false
        )
    }

    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let rawPlan = plan(
            .init(
                operation: .moveColumnAdjacent,
                direction: direction,
                sourceWorkspaceId: controller.activeWorkspace()?.id,
                currentMonitorId: interactionMonitorId(for: controller)
            )
        ),
        let plan = materializeTargetWorkspaceIfNeeded(
            rawPlan
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds)
        if case let .column(subjectToken) = plan.subject {
            _ = executeColumnTransferPlan(plan, rememberedTargetFocusToken: subjectToken)
        }
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveColumnToWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func moveColumnToWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        let sourceWorkspaceId = controller.activeWorkspace()?.id
        guard let rawPlan = plan(
            .init(
                operation: .moveColumnExplicit,
                sourceWorkspaceId: sourceWorkspaceId,
                targetWorkspaceId: controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
            )
        ),
        let plan = materializeTargetWorkspaceIfNeeded(
            rawPlan
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds)
        if case let .column(subjectToken) = plan.subject {
            _ = executeColumnTransferPlan(plan, rememberedTargetFocusToken: subjectToken)
        }
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
    }

    func moveFocusedWindow(toRawWorkspaceID rawWorkspaceID: String) {
        guard let controller else { return }
        let focusedToken = controller.workspaceManager.focusedToken
        guard let rawPlan = plan(
            .init(
                operation: .moveWindowExplicit,
                sourceWorkspaceId: focusedToken.flatMap { controller.workspaceManager.workspace(for: $0) },
                targetWorkspaceId: controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false),
                focusedToken: focusedToken,
                followFocus: controller.settings.focusFollowsWindowToMonitor
            )
        ),
        let plan = materializeTargetWorkspaceIfNeeded(
            rawPlan
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds)
        _ = executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: focusedToken ?? .init(pid: 0, windowId: 0),
            stopSourceScroll: true,
            markTransferringWindow: true
        )
    }

    @discardableResult
    func moveWindow(handle: WindowHandle, toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }
        guard let rawPlan = plan(
            .init(
                operation: .moveWindowHandle,
                sourceWorkspaceId: controller.workspaceManager.workspace(for: handle.id),
                targetWorkspaceId: targetWorkspaceId,
                subjectToken: handle.id
            )
        ),
        let plan = materializeTargetWorkspaceIfNeeded(
            rawPlan
        ) else {
            return false
        }
        saveWorkspaces(plan.saveWorkspaceIds)
        return executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: handle.id,
            stopSourceScroll: false,
            markTransferringWindow: false
        )
    }

    func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else { return }
        moveWindowToWorkspaceOnMonitor(rawWorkspaceID: rawWorkspaceID, monitorDirection: monitorDirection)
    }

    func moveWindowToWorkspaceOnMonitor(rawWorkspaceID: String, monitorDirection: Direction) {
        guard let controller else { return }
        let focusedToken = controller.workspaceManager.focusedToken
        guard let rawPlan = plan(
            .init(
                operation: .moveWindowToWorkspaceOnMonitor,
                direction: monitorDirection,
                sourceWorkspaceId: focusedToken.flatMap { controller.workspaceManager.workspace(for: $0) },
                targetWorkspaceId: controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false),
                currentMonitorId: interactionMonitorId(for: controller),
                focusedToken: focusedToken,
                followFocus: controller.settings.focusFollowsWindowToMonitor
            )
        ),
        let plan = materializeTargetWorkspaceIfNeeded(
            rawPlan
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds)
        _ = executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: focusedToken ?? .init(pid: 0, windowId: 0),
            stopSourceScroll: false,
            markTransferringWindow: false
        )
    }
}
