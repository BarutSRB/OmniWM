// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutHandler {
    func focusPreviousInNiri(observation: CommandFocusObservation) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        let anchor = focusHistoryAnchor(
            controller: controller,
            engine: engine,
            fallbackWorkspaceId: wsId,
            observation: observation
        )
        if let anchor {
            _ = controller.workspaceManager.rememberFocus(
                anchor.token,
                in: anchor.workspaceId
            )
            if let nodeId = anchor.nodeId {
                controller.workspaceManager.withEngineMutationScope {
                    engine.updateFocusTimestamp(for: nodeId, in: anchor.workspaceId)
                }
            }
            if let target = controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: anchor.token),
               let targetWorkspaceId = controller.workspaceManager.entry(for: target)?.workspaceId,
               controller.windowActionHandler.navigateToWindowInternal(
                   token: target,
                   workspaceId: targetWorkspaceId
               )
            {
                return
            }
            if anchor.representsCurrentFocus {
                _ = focusGloballyPreviousNiriWindowIfNeeded(
                    controller: controller,
                    engine: engine,
                    anchor: anchor
                )
                return
            }
        }
        if focusGloballyPreviousNiriWindowIfNeeded(
            controller: controller,
            engine: engine,
            anchor: anchor
        ) {
            return
        }

        focusPreviousInCurrentNiriWorkspace(
            controller: controller,
            engine: engine,
            workspaceId: wsId
        )
    }

    private func focusPreviousInCurrentNiriWorkspace(
        controller: WMController,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
        let context = NiriInteractionContext(
            workspaceId: workspaceId,
            motion: motion,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        let previousWindow = controller.workspaceManager.withEngineMutationScope { () -> NiriWindow? in
            if let selected = engine.reconcileProjectedSelection(state: &state, in: workspaceId) {
                let currentId = selected.id
                engine.updateFocusTimestamp(for: currentId, in: workspaceId)
                engine.activateWindow(currentId, in: workspaceId)
            }

            return engine.focusPrevious(
                currentNodeId: state.selectedNodeId,
                context: context,
                state: &state,
                limitToWorkspace: true
            )
        }
        guard let previousWindow else { return }

        controller.niriLayoutHandler.activateNode(
            previousWindow, in: workspaceId, state: &state,
            options: .init(
                ensureVisible: false,
                updateTimestamp: false,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.niriLayoutHandler.focusSelectedWindowAndRequestRelayout(in: workspaceId)

        if controller.workspaceManager.animationDriver.hasMotion(in: workspaceId) {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private func focusGloballyPreviousNiriWindowIfNeeded(
        controller: WMController,
        engine: NiriLayoutEngine,
        anchor: FocusHistoryAnchor?
    ) -> Bool {
        guard let anchor,
              let nodeId = anchor.nodeId,
              !controller.workspaceManager.isAppHidden(anchor.token),
              let target = engine.findMostRecentlyFocusedWindow(excluding: nodeId, in: nil),
              let targetWorkspaceId = controller.workspaceManager.entry(for: target.token)?.workspaceId,
              targetWorkspaceId != anchor.workspaceId
        else {
            return false
        }

        controller.workspaceManager.withEngineMutationScope {
            engine.updateFocusTimestamp(for: nodeId, in: anchor.workspaceId)
            engine.activateWindow(nodeId, in: anchor.workspaceId)
        }
        controller.windowActionHandler.navigateToWindowInternal(
            token: target.token,
            workspaceId: targetWorkspaceId
        )
        return true
    }

    private func focusHistoryAnchor(
        controller: WMController,
        engine: NiriLayoutEngine,
        fallbackWorkspaceId: WorkspaceDescriptor.ID,
        observation: CommandFocusObservation
    ) -> FocusHistoryAnchor? {
        let frontmostPid = observation.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let observedToken = observation.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { controller.axEventHandler.focusedWindowToken(for: $0) }

        if let observedToken,
           let entry = controller.workspaceManager.entry(for: observedToken),
           !controller.workspaceManager.isAppHidden(pid: entry.pid)
        {
            return FocusHistoryAnchor(
                workspaceId: entry.workspaceId,
                token: observedToken,
                nodeId: engine.findNode(for: observedToken, in: entry.workspaceId)?.id,
                representsCurrentFocus: true
            )
        }

        if let token = controller.workspaceManager.selectedManagedToken,
           let entry = controller.workspaceManager.entry(for: token),
           !controller.workspaceManager.isAppHidden(pid: entry.pid)
        {
            return FocusHistoryAnchor(
                workspaceId: entry.workspaceId,
                token: token,
                nodeId: engine.findNode(for: token, in: entry.workspaceId)?.id,
                representsCurrentFocus: true
            )
        }

        let selectedNodeId = controller.workspaceManager
            .niriViewportState(for: fallbackWorkspaceId)
            .selectedNodeId
        guard let selectedNodeId,
              let node = engine.findNode(by: selectedNodeId, in: fallbackWorkspaceId) as? NiriWindow,
              !engine.isExcludedFromProjection(node.token, in: fallbackWorkspaceId)
        else {
            return nil
        }
        return FocusHistoryAnchor(
            workspaceId: fallbackWorkspaceId,
            token: node.token,
            nodeId: node.id,
            representsCurrentFocus: false
        )
    }

    private struct FocusHistoryAnchor {
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let nodeId: NodeId?
        let representsCurrentFocus: Bool
    }
}

@MainActor
struct CommandFocusObservation {
    let frontmostAppPidProvider: (() -> pid_t?)?
    let frontmostFocusedWindowTokenProvider: (() -> WindowToken?)?
}
