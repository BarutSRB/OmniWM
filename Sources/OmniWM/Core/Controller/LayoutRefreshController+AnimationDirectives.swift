// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func applySessionPatch(_ patch: WorkspaceSessionPatch) {
        controller?.workspaceManager.applySessionPatch(patch)
    }

    func applyAnimationDirectives(
        _ directives: [AnimationDirective],
        workspaceId: WorkspaceDescriptor.ID,
        focusSeqAccepted: Bool,
        suppressWindowActivation: Bool
    ) {
        guard let controller else { return }

        for directive in directives {
            switch directive {
            case .none:
                continue
            case let .startNiriScroll(workspaceId):
                startScrollAnimation(for: workspaceId)
            case let .startDwindleAnimation(workspaceId, monitorId):
                guard let monitor = controller.workspaceManager.monitor(byId: monitorId) else { continue }
                startDwindleAnimation(for: workspaceId, monitor: monitor)
            case let .activateWindow(token):
                guard !suppressWindowActivation,
                      !controller.shouldSuppressManagedFocusRecovery,
                      !controller.workspaceManager.hasPendingNativeFullscreenTransition(in: workspaceId),
                      focusSeqAccepted
                else { continue }
                if controller.workspaceManager.nativeManagedFocusToken == token,
                   controller.workspaceManager.pendingFocusedToken == nil,
                   controller.intentLedger.activeManagedRequest == nil
                {
                    continue
                }
                if let workspaceId = controller.workspaceManager.workspace(for: token) {
                    controller.recordNiriCreateFocusTrace(
                        .relayoutActivatedWindow(
                            token: token,
                            workspaceId: workspaceId
                        )
                    )
                }
                controller.focusWindow(token)
            }
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        niriHandler.cancelActiveAnimations(for: workspaceId)
    }
}
