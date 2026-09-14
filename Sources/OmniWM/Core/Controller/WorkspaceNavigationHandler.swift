// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceNavigationHandler {
    weak var controller: WMController?

    enum WorkspaceMoveFocusPolicy {
        case configured
        case alwaysFollow
        case retainCurrent
    }

    init(controller: WMController) {
        self.controller = controller
    }

    func applySessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        viewportState: ViewportState? = nil,
        rememberedFocusToken: WindowToken? = nil
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: viewportState,
                rememberedFocusToken: rememberedFocusToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }

    func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId)
    }

    func commitWorkspaceSelection(
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

    func interactionMonitorId(for controller: WMController) -> Monitor.ID? {
        controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
    }
}
