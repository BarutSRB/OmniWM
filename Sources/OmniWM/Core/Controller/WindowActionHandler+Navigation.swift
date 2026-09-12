// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension WindowActionHandler {
    @discardableResult
    func navigateToWindowInternal(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let handle = controller.workspaceManager.handle(for: token),
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              !controller.workspaceManager.isAppHidden(pid: entry.pid)
        else {
            return false
        }
        let targetLayoutKind = controller.workspaceManager.activeLayoutKind(for: workspaceId)
        if targetLayoutKind == .niri, controller.niriEngine == nil {
            return false
        }

        let currentWsId = controller.activeWorkspace()?.id

        if workspaceId != currentWsId {
            let wsName = controller.workspaceManager.descriptor(for: workspaceId)?.name ?? ""
            if let result = controller.workspaceManager.focusWorkspace(named: wsName) {
                _ = controller.workspaceManager.setInteractionMonitor(result.monitor.id)
                controller.syncMonitorsToNiriEngine()
            }
        }

        switch targetLayoutKind {
        case .dwindle:
            if !prepareDwindleNavigationTarget(token, workspaceId: workspaceId) {
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: workspaceId,
                        viewportState: nil,
                        rememberedFocusToken: token,
                        plannedSeq: controller.workspaceManager.worldSeq
                    )
                )
            }
        case .niri:
            guard let engine = controller.niriEngine else { return false }
            prepareNiriNavigationTarget(token, workspaceId: workspaceId, engine: engine, controller: controller)
        }
        commitWindowNavigation(handle: handle, workspaceId: workspaceId, controller: controller)
        return true
    }

    private func prepareNiriNavigationTarget(
        _ token: WindowToken, workspaceId: WorkspaceDescriptor.ID, engine: NiriLayoutEngine, controller: WMController
    ) {
        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let niriWindow = engine.findNode(for: token, in: workspaceId) {
            targetState.selectedNodeId = niriWindow.id

            if engine.findColumn(containing: niriWindow, in: workspaceId) != nil,
               let monitor = controller.workspaceManager.monitor(for: workspaceId)
            {
                let gap = controller.innerGap(for: monitor)
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
                controller.workspaceManager.withEngineMutationScope {
                    engine.activateWindow(niriWindow.id, in: workspaceId)
                    engine.resolvePrimaryContainerSpans(
                        in: workspaceId,
                        workingFrame: workingFrame,
                        gaps: gap,
                        orientation: orientation
                    )
                    engine.ensureProjectedSelectionVisible(
                        node: niriWindow,
                        context: .init(
                            workspaceId: workspaceId,
                            motion: .disabled,
                            workingFrame: workingFrame,
                            gaps: gap,
                            orientation: orientation
                        ),
                        state: &targetState,
                        animationConfig: nil,
                        fromContainerIndex: nil
                    )
                }
            }
        }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: targetState,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }

    private func commitWindowNavigation(
        handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID, controller: WMController
    ) {
        let newestFocusIntentId = controller.intentLedger.newestFocusIntentId()
        let focusTarget: LayoutRefreshController.PostLayoutAction = { [weak controller] in
            guard let controller,
                  controller.activeWorkspace()?.id == workspaceId,
                  controller.workspaceManager.handle(for: handle.id) === handle,
                  controller.workspaceManager.entry(for: handle)?.workspaceId == workspaceId
            else {
                return
            }
            controller.focusWindow(handle.id)
        }
        let focusTargetIfStillCurrent: LayoutRefreshController.PostLayoutAction = { [weak controller] in
            guard let controller,
                  controller.intentLedger.newestFocusIntentId() == newestFocusIntentId
            else {
                return
            }
            focusTarget()
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition,
            postLayoutGateWorkspaceIds: [workspaceId],
            postLayout: focusTarget,
            postLayoutInvalidated: focusTargetIfStillCurrent
        )
    }

    func prepareDwindleNavigationTarget(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling,
              entry.layoutReason == .standard,
              controller.dwindleEngine?.findNode(for: token, in: workspaceId) != nil
        else {
            return false
        }

        return controller.dwindleLayoutHandler.activateWindow(
            token,
            in: workspaceId,
            layoutRefresh: false,
            focusAfterLayout: false
        ) != .missing
    }
}
