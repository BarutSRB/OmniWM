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
        rememberedFocusToken: WindowToken? = nil,
        source: WMEventSource = .command
    ) {
        guard let controller else { return }
        let patch = WorkspaceSessionPatch(
            workspaceId: workspaceId,
            viewportState: viewportState,
            rememberedFocusToken: rememberedFocusToken
        )
        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.applySessionPatch requires WMRuntime to be attached")
        }
        _ = runtime.applySessionPatch(patch, source: source)
    }

    private func applySessionTransfer(
        sourceWorkspaceId: WorkspaceDescriptor.ID?,
        sourceState: ViewportState?,
        sourceFocusedToken: WindowToken?,
        targetWorkspaceId: WorkspaceDescriptor.ID?,
        targetState: ViewportState?,
        targetFocusedToken: WindowToken?,
        source: WMEventSource = .command
    ) {
        guard let controller else { return }
        let transfer = WorkspaceSessionTransfer(
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
        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.applySessionTransfer requires WMRuntime to be attached")
        }
        _ = runtime.applySessionTransfer(transfer, source: source)
    }

    private func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        source: WMEventSource = .command
    ) {
        guard let controller else { return }
        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.commitWorkspaceSelection requires WMRuntime to be attached")
        }
        _ = runtime.commitWorkspaceSelection(
            nodeId: nodeId,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitorId,
            source: source
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

    private func commitWorkspaceTransition(
        _ plan: WorkspaceNavigationKernel.Plan,
        stopScrollAnimationOnTargetMonitor: Bool,
        source: WMEventSource = .command
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
                rememberedFocusToken: resolvedFocusToken,
                source: source
            )
        }
        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.commitWorkspaceTransition requires WMRuntime to be attached")
        }
        let postAction: WMEffect.PostWorkspaceTransitionAction
        if let resolvedFocusToken = plan.resolvedFocusToken {
            postAction = .focusWindow(resolvedFocusToken)
        } else if plan.focusAction == .clearManagedFocus {
            postAction = .clearManagedFocusAfterEmptyWorkspaceTransition
        } else {
            postAction = .none
        }
        _ = runtime.commitWorkspaceTransition(
            affectedWorkspaceIds: plan.affectedWorkspaceIds,
            postAction: postAction,
            source: source
        )
    }

    private func saveWorkspaces(_ workspaceIds: [WorkspaceDescriptor.ID]) {
        for workspaceId in workspaceIds {
            saveNiriViewportState(for: workspaceId)
        }
    }

    private func saveWorkspaces(
        _ workspaceIds: [WorkspaceDescriptor.ID],
        source: WMEventSource
    ) {
        for workspaceId in workspaceIds {
            saveNiriViewportState(for: workspaceId, source: source)
        }
    }

    private func materializeTargetWorkspaceIfNeeded(
        _ plan: WorkspaceNavigationKernel.Plan,
        source: WMEventSource = .command
    ) -> WorkspaceNavigationKernel.Plan? {
        guard let rawWorkspaceID = plan.materializeTargetWorkspaceRawID else {
            return plan
        }
        guard let controller,
              let targetMonitorId = plan.targetMonitorId
        else { return nil }
        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.materializeTargetWorkspace requires WMRuntime to be attached")
        }
        guard let targetWorkspaceId = runtime.materializeWorkspace(
            named: rawWorkspaceID,
            source: source
        ) else { return nil }

        runtime.assignWorkspaceToMonitor(
            targetWorkspaceId,
            monitorId: targetMonitorId,
            source: source
        )
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

    private func activateTargetWorkspaceIfNeeded(
        _ plan: WorkspaceNavigationKernel.Plan,
        source: WMEventSource = .command
    ) -> Bool {
        guard let controller,
              let targetWorkspaceId = plan.targetWorkspaceId,
              let targetMonitorId = plan.targetMonitorId
        else {
            return false
        }

        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.activateTargetWorkspaceIfNeeded requires WMRuntime to be attached")
        }
        guard plan.shouldActivateTargetWorkspace else {
            if plan.shouldSetInteractionMonitor {
                _ = runtime.setInteractionMonitor(targetMonitorId, source: source)
            }
            return true
        }
        return runtime.setActiveWorkspace(
            targetWorkspaceId,
            on: targetMonitorId,
            source: source
        )
    }

    private func commitFocusPlan(
        _ plan: WorkspaceNavigationKernel.Plan,
        source: WMEventSource = .command
    ) {
        guard plan.shouldCommitWorkspaceTransition else {
            return
        }

        switch plan.focusAction {
        case .workspaceHandoff:
            commitWorkspaceTransition(plan, stopScrollAnimationOnTargetMonitor: true, source: source)

        case .resolveTargetIfPresent:
            commitWorkspaceTransition(plan, stopScrollAnimationOnTargetMonitor: false, source: source)

        case .clearManagedFocus:
            commitWorkspaceTransition(plan, stopScrollAnimationOnTargetMonitor: false, source: source)

        case .subject, .recoverSource, .none:
            break
        }
    }

    private func applySwitchPlan(
        _ plan: WorkspaceNavigationKernel.Plan,
        hideReason: String,
        source: WMEventSource = .command
    ) {
        guard plan.outcome == .execute else { return }
        hideFocusBorderIfNeeded(plan, reason: hideReason)
        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        guard activateTargetWorkspaceIfNeeded(plan, source: source) else { return }
        if plan.shouldSyncMonitorsToNiri {
            controller?.syncMonitorsToNiriEngine()
        }
        commitFocusPlan(plan, source: source)
    }

    private func prepareSwapSelection(
        targetWorkspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
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
            in: targetWorkspaceId,
            source: source
        )
    }

    private func transferWindowFromSourceEngine(
        token: WindowToken,
        from sourceWorkspaceId: WorkspaceDescriptor.ID?,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
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

        if controller.workspaceManager.windowMode(for: token) == .floating {
            // Floating windows are graph-owned and may not have any layout-engine node.
            guard sourceWorkspaceId != targetWorkspaceId else { return false }
            controller.reassignManagedWindow(token, to: targetWorkspaceId, source: source)
            return true
        }

        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWorkspaceId,
           let engine = controller.niriEngine,
           let windowNode = engine.findNode(for: token),
           sourceWorkspaceId != targetWorkspaceId,
           engine.findColumn(containing: windowNode, in: sourceWorkspaceId) != nil
        {
            var sourceState = controller.workspaceManager.niriViewportState(for: sourceWorkspaceId)
            var targetState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)
            controller.reassignManagedWindow(token, to: targetWorkspaceId, source: source)
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
                    targetFocusedToken: nil,
                    source: source
                )
                movedWithNiri = true
            } else {
                controller.reassignManagedWindow(token, to: sourceWorkspaceId, source: source)
                return false
            }
        }

        if !movedWithNiri,
           !sourceIsDwindle,
           let sourceWorkspaceId
        {
            if targetIsDwindle {
                controller.reassignManagedWindow(token, to: targetWorkspaceId, source: source)
            }

            if let engine = controller.niriEngine {
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
                    targetFocusedToken: nil,
                    source: source
                )
            }
        } else if sourceIsDwindle,
                  let sourceWorkspaceId,
                  let dwindleEngine = controller.dwindleEngine
        {
            controller.reassignManagedWindow(token, to: targetWorkspaceId, source: source)
            dwindleEngine.removeWindow(token: token, from: sourceWorkspaceId)
        }

        if movedWithNiri {
            return true
        }
        if sourceWorkspaceId == nil {
            controller.reassignManagedWindow(token, to: targetWorkspaceId, source: source)
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
        markTransferringWindow: Bool,
        source: WMEventSource = .command
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
                guard let runtime = controller.runtime else {
                    preconditionFailure("WorkspaceNavigationHandler.moveColumnToWorkspace requires WMRuntime to be attached")
                }
                _ = runtime.setActiveWorkspace(
                    targetWorkspaceId,
                    on: targetMonitor.id,
                    source: source
                )
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
                rememberedFocusToken: targetFocusToken,
                source: source
            )

            if plan.shouldCommitWorkspaceTransition {
                guard let runtime = controller.runtime else {
                    preconditionFailure("WorkspaceNavigationHandler.moveColumnToWorkspace requires WMRuntime to be attached")
                }
                _ = runtime.commitWorkspaceTransition(
                    affectedWorkspaceIds: plan.affectedWorkspaceIds,
                    postAction: .focusWindow(targetFocusToken),
                    source: source
                )
            }

        case .recoverSource:
            if let sourceWorkspaceId = plan.sourceWorkspaceId {
                controller.recoverSourceFocusAfterMove(
                    in: sourceWorkspaceId,
                    preferredNodeId: sourcePreferredNodeId
                )
            }
            let focusToken = plan.sourceWorkspaceId.flatMap {
                controller.resolveAndSetWorkspaceFocusToken(for: $0, source: source)
            }

            if plan.shouldCommitWorkspaceTransition {
                guard let runtime = controller.runtime else {
                    preconditionFailure("WorkspaceNavigationHandler.moveColumnToWorkspace requires WMRuntime to be attached")
                }
                let postAction: WMEffect.PostWorkspaceTransitionAction
                if let focusToken {
                    postAction = .focusWindow(focusToken)
                } else {
                    postAction = .none
                }
                _ = runtime.commitWorkspaceTransition(
                    affectedWorkspaceIds: plan.affectedWorkspaceIds,
                    postAction: postAction,
                    source: source
                )
            }

        case .workspaceHandoff, .resolveTargetIfPresent, .clearManagedFocus, .none:
            break
        }
    }

    private func executeWindowTransferPlan(
        _ plan: WorkspaceNavigationKernel.Plan,
        rememberedTargetFocusToken: WindowToken,
        stopSourceScroll: Bool,
        markTransferringWindow: Bool,
        source: WMEventSource = .command
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
            to: targetWorkspaceId,
            source: source
        )
        guard transferSucceeded else { return false }

        applySessionPatch(
            workspaceId: targetWorkspaceId,
            rememberedFocusToken: rememberedTargetFocusToken,
            source: source
        )

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
            markTransferringWindow: markTransferringWindow,
            source: source
        )
        return true
    }

    private func executeColumnTransferPlan(
        _ plan: WorkspaceNavigationKernel.Plan,
        rememberedTargetFocusToken: WindowToken,
        source: WMEventSource = .command
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
              engine.columnIndex(of: column, in: sourceWorkspaceId) != nil,
              sourceWorkspaceId != targetWorkspaceId,
              !column.windowNodes.isEmpty
        else {
            return false
        }

        let movedWindowTokens = column.windowNodes.map(\.token)
        for token in movedWindowTokens {
            controller.reassignManagedWindow(token, to: targetWorkspaceId, source: source)
        }

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            for token in movedWindowTokens {
                controller.reassignManagedWindow(token, to: sourceWorkspaceId, source: source)
            }
            return false
        }

        applySessionTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sourceState: sourceState,
            sourceFocusedToken: nil,
            targetWorkspaceId: targetWorkspaceId,
            targetState: targetState,
            targetFocusedToken: nil,
            source: source
        )

        applySessionPatch(
            workspaceId: targetWorkspaceId,
            rememberedFocusToken: rememberedTargetFocusToken,
            source: source
        )

        performTransferFocus(
            plan,
            targetFocusToken: rememberedTargetFocusToken,
            sourcePreferredNodeId: result.newFocusNodeId,
            ensureTargetVisible: false,
            stopSourceScroll: false,
            markTransferringWindow: false,
            source: source
        )
        return true
    }

    func focusMonitorCyclic(
        previous: Bool,
        source: WMEventSource = .command
    ) {
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
        applySwitchPlan(plan, hideReason: "focus monitor", source: source)
    }

    func focusLastMonitor(source: WMEventSource = .command) {
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
        applySwitchPlan(plan, hideReason: "focus last monitor", source: source)
    }

    func swapCurrentWorkspaceWithMonitor(
        direction: Direction,
        source: WMEventSource = .command
    ) {
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

        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        prepareSwapSelection(targetWorkspaceId: targetWorkspaceId, source: source)

        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.swapCurrentWorkspaceWithMonitor requires WMRuntime to be attached")
        }
        let didSwap = runtime.swapWorkspaces(
            sourceWorkspaceId,
            on: sourceMonitorId,
            with: targetWorkspaceId,
            on: targetMonitorId,
            source: source
        )
        guard didSwap else {
            return
        }

        if plan.shouldSyncMonitorsToNiri {
            controller.syncMonitorsToNiriEngine()
        }
        commitFocusPlan(plan, source: source)
    }

    func switchWorkspace(
        index: Int,
        source: WMEventSource = .command
    ) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        switchWorkspace(rawWorkspaceID: rawWorkspaceID, source: source)
    }

    func switchWorkspace(
        rawWorkspaceID: String,
        source: WMEventSource = .command
    ) {
        guard let controller else { return }
        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.switchWorkspace requires WMRuntime to be attached")
        }
        let command: WMCommand.WorkspaceSwitchCommand = switch source {
        case .command:
            .explicit(rawWorkspaceID: rawWorkspaceID)
        default:
            .explicitFrom(rawWorkspaceID: rawWorkspaceID, source: source)
        }
        runtime.submit(
            command: .workspaceSwitch(command)
        )
    }

    func switchWorkspaceRelative(
        isNext: Bool,
        wrapAround: Bool = true,
        source: WMEventSource = .command
    ) {
        guard let controller else { return }
        guard let runtime = controller.runtime else {
            preconditionFailure("WorkspaceNavigationHandler.switchWorkspaceRelative requires WMRuntime to be attached")
        }
        let command: WMCommand.WorkspaceSwitchCommand = switch source {
        case .command:
            .relative(isNext: isNext, wrapAround: wrapAround)
        default:
            .relativeFrom(isNext: isNext, wrapAround: wrapAround, source: source)
        }
        runtime.submit(
            command: .workspaceSwitch(command)
        )
    }

    func saveNiriViewportState(
        for workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }

        if let focusedToken = controller.workspaceManager.focusedToken,
           controller.workspaceManager.workspace(for: focusedToken) == workspaceId,
           let focusedNode = engine.findNode(for: focusedToken)
        {
            commitWorkspaceSelection(
                nodeId: focusedNode.id,
                focusedToken: focusedToken,
                in: workspaceId,
                source: source
            )
        }
    }

    func focusWorkspaceAnywhere(index: Int, source: WMEventSource = .command) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID, source: source)
    }

    func focusWorkspaceAnywhere(
        rawWorkspaceID: String,
        source: WMEventSource = .command
    ) {
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
        applySwitchPlan(plan, hideReason: "focus workspace anywhere", source: source)
    }

    func workspaceBackAndForth(source: WMEventSource = .command) {
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
        applySwitchPlan(plan, hideReason: "workspace back and forth", source: source)
    }

    func moveWindowToAdjacentWorkspace(
        direction: Direction,
        source: WMEventSource = .command
    ) {
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
            rawPlan,
            source: source
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        _ = executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: focusedToken ?? .init(pid: 0, windowId: 0),
            stopSourceScroll: false,
            markTransferringWindow: false,
            source: source
        )
    }

    func moveColumnToAdjacentWorkspace(
        direction: Direction,
        source: WMEventSource = .command
    ) {
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
            rawPlan,
            source: source
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        if case let .column(subjectToken) = plan.subject {
            _ = executeColumnTransferPlan(
                plan,
                rememberedTargetFocusToken: subjectToken,
                source: source
            )
        }
    }

    func moveColumnToWorkspaceByIndex(
        index: Int,
        source: WMEventSource = .command
    ) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveColumnToWorkspace(rawWorkspaceID: rawWorkspaceID, source: source)
    }

    func moveColumnToWorkspace(
        rawWorkspaceID: String,
        source: WMEventSource = .command
    ) {
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
            rawPlan,
            source: source
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        if case let .column(subjectToken) = plan.subject {
            _ = executeColumnTransferPlan(
                plan,
                rememberedTargetFocusToken: subjectToken,
                source: source
            )
        }
    }

    func moveFocusedWindow(
        toWorkspaceIndex index: Int,
        source: WMEventSource = .command
    ) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID, source: source)
    }

    func moveFocusedWindow(
        toRawWorkspaceID rawWorkspaceID: String,
        source: WMEventSource = .command
    ) {
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
            rawPlan,
            source: source
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        _ = executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: focusedToken ?? .init(pid: 0, windowId: 0),
            stopSourceScroll: true,
            markTransferringWindow: true,
            source: source
        )
    }

    @discardableResult
    func moveWindow(
        handle: WindowHandle,
        toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) -> Bool {
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
            rawPlan,
            source: source
        ) else {
            return false
        }
        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        return executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: handle.id,
            stopSourceScroll: false,
            markTransferringWindow: false,
            source: source
        )
    }

    func moveWindowToWorkspaceOnMonitor(
        workspaceIndex: Int,
        monitorDirection: Direction,
        source: WMEventSource = .command
    ) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else { return }
        moveWindowToWorkspaceOnMonitor(
            rawWorkspaceID: rawWorkspaceID,
            monitorDirection: monitorDirection,
            source: source
        )
    }

    func moveWindowToWorkspaceOnMonitor(
        rawWorkspaceID: String,
        monitorDirection: Direction,
        source: WMEventSource = .command
    ) {
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
            rawPlan,
            source: source
        ) else {
            return
        }
        saveWorkspaces(plan.saveWorkspaceIds, source: source)
        _ = executeWindowTransferPlan(
            plan,
            rememberedTargetFocusToken: focusedToken ?? .init(pid: 0, windowId: 0),
            stopSourceScroll: false,
            markTransferringWindow: false,
            source: source
        )
    }
}
