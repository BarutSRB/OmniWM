// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func selectGroupMember(
        info: TabRailInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              case let .dwindleTile(tileId) = info.owner,
              controller.workspaceManager.activeLayoutKind(for: info.workspaceId) == .dwindle,
              controller.workspaceManager.isSeqCurrent(
                  info.plannedSeq,
                  for: info.workspaceId,
                  domains: .layoutCommit
              ),
              info.tabs.indices.contains(visualIndex),
              let token = expectedToken ?? info.tabs[visualIndex].token,
              let snapshot = engine.tileSnapshot(for: token, in: info.workspaceId),
              snapshot.id == tileId,
              snapshot.members.contains(where: { $0.token == token }),
              groupMemberActivationIsAllowed(token, workspaceId: info.workspaceId)
        else {
            return
        }

        let outcome = controller.workspaceManager.withEngineMutationScope {
            engine.activateWindowOutcome(token, in: info.workspaceId)
        }
        guard outcome != .missing else { return }
        if outcome == .activated {
            recordLayoutOperation(.tabActivated(token: token), in: info.workspaceId, source: .mouse)
            commitGroupSelection(
                token,
                workspaceId: info.workspaceId,
                focusAfterLayout: true,
                focusOrigin: .pointerHover
            )
        } else {
            updateRememberedGroupMember(token, workspaceId: info.workspaceId)
            controller.focusWindow(token, origin: .pointerHover)
            controller.surfaceReconciler.noteWorldChanged()
        }
    }

    func groupMembershipMutationIsAllowed(
        for token: WindowToken,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        requiresAllMembers: Bool = true
    ) -> Bool {
        guard let snapshot = engine.tileSnapshot(for: token, in: workspaceId)
        else {
            return false
        }
        guard requiresAllMembers else {
            return groupMemberActivationIsAllowed(token, workspaceId: workspaceId)
        }
        return snapshot.members.allSatisfy { member in
            groupMemberActivationIsAllowed(member.token, workspaceId: workspaceId)
        }
    }

    func groupMemberActivationIsAllowed(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return false
        }
        return entry.workspaceId == workspaceId
            && entry.mode == .tiling
            && entry.layoutReason == .standard
            && !controller.isManagedWindowSuppressedByMacOSHide(token)
            && !controller.isManagedWindowSuspendedForNativeFullscreen(token)
    }

    func commitGroupSelection(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        focusAfterLayout: Bool,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) {
        guard let controller else { return }
        updateRememberedGroupMember(token, workspaceId: workspaceId)
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId]
        ) { [weak self] in
            self?.completeGroupSelectionAfterReveal(
                token,
                workspaceId: workspaceId,
                focusAfterLayout: focusAfterLayout,
                focusOrigin: focusOrigin
            )
        }
    }

    func completeGroupSelectionAfterReveal(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        focusAfterLayout: Bool,
        focusOrigin: ManagedFocusOrigin
    ) {
        guard let controller else { return }
        if groupReveals.deferGroupSelectionCompletion(
            token,
            workspaceId: workspaceId,
            focusAfterReveal: focusAfterLayout,
            focusOrigin: focusOrigin
        ) {
            return
        }
        guard controller.dwindleEngine?.tileSnapshot(for: token, in: workspaceId)?.activeToken == token
        else {
            return
        }
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: [workspaceId],
            selectedToken: token
        )
        if focusAfterLayout {
            controller.focusWindow(token, origin: focusOrigin)
        }
    }

    func updateRememberedGroupMember(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }
}
