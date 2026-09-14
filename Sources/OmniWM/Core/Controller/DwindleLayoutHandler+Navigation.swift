// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func focusNeighbor(direction: Direction) -> Bool {
        guard let controller else { return false }
        var didMove = false
        withDwindleContext { engine, wsId in
            if focusGroupMember(
                direction: direction,
                wraps: false,
                engine: engine,
                workspaceId: wsId
            ) {
                didMove = true
                return
            }
            let previousSelection = engine.selectedNode(in: wsId)
            guard let token = engine.moveFocus(direction: direction, in: wsId) else { return }
            guard !controller.isManagedWindowSuppressedByMacOSHide(token) else {
                engine.setSelectedNode(previousSelection, in: wsId)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
                return
            }
            didMove = true
            if controller.workspaceManager.hiddenState(for: token) != nil {
                commitGroupSelection(token, workspaceId: wsId, focusAfterLayout: true)
                return
            }
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: nil,
                    rememberedFocusToken: token,
                    plannedSeq: controller.workspaceManager.worldSeq
                )
            )
            controller.focusWindow(token)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return didMove
    }

    func wrapGroupFocus(direction: Direction) -> Bool {
        var didMove = false
        withDwindleContext { engine, workspaceId in
            didMove = focusGroupMember(
                direction: direction,
                wraps: true,
                engine: engine,
                workspaceId: workspaceId
            )
        }
        return didMove
    }

    @discardableResult
    func activateWindow(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic,
        layoutRefresh: Bool = true,
        focusAfterLayout: Bool = true
    ) -> DwindleWindowActivationOutcome {
        guard let controller,
              let engine = controller.dwindleEngine,
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling,
              entry.layoutReason == .standard,
              !controller.isManagedWindowSuppressedByMacOSHide(token)
        else {
            return .missing
        }

        let outcome = controller.workspaceManager.withEngineMutationScope {
            engine.activateWindowOutcome(token, in: workspaceId)
        }
        guard outcome != .missing else { return .missing }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let requiresLayout = outcome == .activated || controller.workspaceManager.hiddenState(for: token) != nil
        if requiresLayout, layoutRefresh {
            let postLayout: LayoutRefreshController.PostLayoutAction = { [weak self] in
                self?.completeGroupSelectionAfterReveal(
                    token,
                    workspaceId: workspaceId,
                    focusAfterLayout: focusAfterLayout,
                    focusOrigin: origin
                )
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [workspaceId],
                postLayout: postLayout
            )
        } else {
            if focusAfterLayout {
                controller.focusWindow(token, origin: origin)
            }
            if layoutRefresh {
                controller.surfaceReconciler.noteWorldChanged()
            }
        }
        return outcome
    }
}
