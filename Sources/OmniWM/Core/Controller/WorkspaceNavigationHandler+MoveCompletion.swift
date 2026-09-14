// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    func finishWorkspaceMove(
        _ mutation: StructuralMutation,
        focusPolicy: WorkspaceMoveFocusPolicy = .configured
    ) {
        guard let controller else { return }
        let sourceWorkspaceId = mutation.sourceWorkspaceId

        if let sourceMonitor = controller.workspaceManager.monitor(for: sourceWorkspaceId) {
            controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
        }
        if focusPolicy == .retainCurrent {
            controller.layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: mutation.affectedWorkspaceIds,
                reason: .workspaceTransition
            )
            return
        }

        let completion = workspaceMoveFocusCompletion(mutation, focusPolicy: focusPolicy, controller: controller)
        let postLayout = completion.postLayout

        let newestFocusIntentId = controller.intentLedger.newestFocusIntentId()
        let focusEpochSeq = controller.workspaceManager.worldSeq
        let postLayoutIfFocusStillCurrent: LayoutRefreshController.PostLayoutAction = { [weak controller] in
            guard let controller,
                  controller.intentLedger.newestFocusIntentId() == newestFocusIntentId,
                  controller.workspaceManager.isSeqEpochCurrent(focusEpochSeq, domains: .focus)
            else {
                return
            }
            postLayout()
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: mutation.affectedWorkspaceIds,
            reason: .workspaceTransition,
            postLayoutGateWorkspaceIds: completion.gateWorkspaceIds,
            postLayout: postLayoutIfFocusStillCurrent,
            postLayoutInvalidated: postLayoutIfFocusStillCurrent
        )
    }

    func recoverSourceFocus(
        after transfer: WindowTransferResult,
        from workspaceId: WorkspaceDescriptor.ID
    ) {
        controller?.recoverSourceFocusAfterMove(
            in: workspaceId,
            preferredToken: transfer.newSourceFocusToken
        )
    }

    func restoreRememberedSelection(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let token = controller.workspaceManager.lastFocusedToken(in: workspaceId)
        else { return }

        switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            guard let node = controller.niriEngine?.findNode(for: token, in: workspaceId) else { return }
            commitWorkspaceSelection(nodeId: node.id, focusedToken: token, in: workspaceId)
        case .dwindle:
            guard let engine = controller.dwindleEngine,
                  engine.findNode(for: token, in: workspaceId) != nil
            else { return }
            _ = controller.dwindleLayoutHandler.activateWindow(
                token,
                in: workspaceId,
                layoutRefresh: false,
                focusAfterLayout: false
            )
        }
    }

    func transferredWindowNiriViewportState(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ViewportState? {
        guard let controller else { return nil }
        guard controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return nil }
        guard let engine = controller.niriEngine,
              let movedNode = engine.findNode(for: token, in: workspaceId),
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            return nil
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = movedNode.id
        let gap = controller.innerGap(for: monitor)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
        controller.workspaceManager.withEngineMutationScope {
            engine.activateWindow(movedNode.id, in: workspaceId)
            engine.ensureSelectionVisible(
                node: movedNode,
                context: .init(
                    workspaceId: workspaceId,
                    motion: controller.motionPolicy.snapshot(),
                    workingFrame: workingFrame,
                    gaps: gap,
                    orientation: orientation
                ),
                state: &state
            )
        }
        return state
    }

    private struct WorkspaceMoveFocusCompletion {
        let gateWorkspaceIds: Set<WorkspaceDescriptor.ID>
        let postLayout: LayoutRefreshController.PostLayoutAction
    }

    private func workspaceMoveFocusCompletion(
        _ mutation: StructuralMutation,
        focusPolicy: WorkspaceMoveFocusPolicy,
        controller: WMController
    ) -> WorkspaceMoveFocusCompletion {
        let sourceWorkspaceId = mutation.sourceWorkspaceId
        let destinationWorkspaceId = mutation.destinationWorkspaceId
        let gateWorkspaceIds: Set<WorkspaceDescriptor.ID>
        let postLayout: LayoutRefreshController.PostLayoutAction
        if focusPolicy == .alwaysFollow || controller.settings.focus.followsWindowToMonitor {
            controller.isTransferringWindow = true
            defer { controller.isTransferringWindow = false }

            if let targetMonitor = controller.workspaceManager.monitorForWorkspace(destinationWorkspaceId) {
                _ = controller.workspaceManager.setActiveWorkspace(
                    destinationWorkspaceId,
                    on: targetMonitor.id
                )
            }

            let focusToken = mutation.selectedHandle.id
            gateWorkspaceIds = [destinationWorkspaceId]
            postLayout = { [weak controller] in
                guard let controller,
                      controller.activeWorkspace()?.id == destinationWorkspaceId,
                      controller.workspaceManager.entry(for: focusToken)?.workspaceId == destinationWorkspaceId
                else {
                    return
                }
                controller.focusWindow(focusToken)
            }
        } else {
            gateWorkspaceIds = [sourceWorkspaceId]
            postLayout = { [weak self, weak controller] in
                guard let controller,
                      controller.activeWorkspace()?.id == sourceWorkspaceId
                else {
                    return
                }
                if let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: sourceWorkspaceId),
                   controller.workspaceManager.entry(for: focusToken)?.workspaceId == sourceWorkspaceId
                {
                    controller.focusWindow(focusToken)
                } else if controller.workspaceManager.entries(in: sourceWorkspaceId).isEmpty {
                    self?.clearManagedFocusAfterEmptyWorkspaceSwitch()
                }
            }
        }

        return WorkspaceMoveFocusCompletion(gateWorkspaceIds: gateWorkspaceIds, postLayout: postLayout)
    }
}
