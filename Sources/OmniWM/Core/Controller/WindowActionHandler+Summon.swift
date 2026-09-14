// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension WindowActionHandler {
    @discardableResult
    func summonWindowRight(handle: WindowHandle) -> Bool {
        guard let controller,
              let currentWorkspace = controller.activeWorkspace(),
              let focusedToken = controller.workspaceManager.selectedManagedToken,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              focusedEntry.workspaceId == currentWorkspace.id
        else {
            return false
        }

        return summonWindowRight(
            handle: handle,
            anchorToken: focusedToken,
            anchorWorkspaceId: currentWorkspace.id
        )
    }

    @discardableResult
    func summonWindowRight(
        handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let anchorEntry = controller.workspaceManager.entry(for: anchorToken),
              anchorEntry.workspaceId == anchorWorkspaceId,
              !controller.workspaceManager.isAppHidden(pid: anchorEntry.pid),
              let targetEntry = controller.workspaceManager.entry(for: handle),
              !controller.workspaceManager.isAppHidden(pid: targetEntry.pid)
        else {
            return false
        }

        let token = handle.id
        guard token != anchorToken else { return false }

        let targetWorkspaceId = anchorWorkspaceId
        switch layoutType(for: targetWorkspaceId) {
        case .dwindle:
            return summonWindowRightInDwindle(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        case .niri,
             .defaultLayout:
            return summonWindowRightInNiri(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        }
    }

    @discardableResult
    private func summonWindowRightInNiri(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) -> Bool {
        guard let controller,
              let handle = controller.workspaceManager.handle(for: token),
              let engine = controller.niriEngine,
              let focusedNode = engine.findNode(for: focusedToken, in: targetWorkspaceId),
              let focusedColumn = engine.findColumn(containing: focusedNode, in: targetWorkspaceId),
              let focusedColumnIndex = engine.columnIndex(of: focusedColumn, in: targetWorkspaceId)
        else {
            return false
        }

        let insertIndex = focusedColumnIndex + 1
        let sourceLayoutType = layoutType(for: sourceWorkspaceId)

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.niriLayoutHandler.insertWindowInNewColumn(
                handle: handle,
                insertIndex: insertIndex,
                in: targetWorkspaceId
            ) else {
                return false
            }
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
            return true
        }

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: handle,
            toWorkspaceId: targetWorkspaceId
        ).didMutate else {
            return false
        }

        if sourceLayoutType == .dwindle {
            commitSummonedWindowFocus(
                token: token,
                workspaceId: targetWorkspaceId,
                rememberedFocusToken: focusedToken,
                startNiriScrollAnimation: true
            )
            return true
        }

        guard controller.niriLayoutHandler.insertWindowInNewColumn(
            handle: handle,
            insertIndex: insertIndex,
            in: targetWorkspaceId,
            sizingPolicy: .inheritSource
        ) else {
            return false
        }
        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
        return true
    }

    @discardableResult
    private func summonWindowRightInDwindle(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) -> Bool {
        guard let controller,
              let engine = controller.dwindleEngine,
              let focusedNode = engine.findNode(for: focusedToken, in: targetWorkspaceId),
              focusedNode.isLeaf
        else {
            return false
        }

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.workspaceManager.withEngineMutationScope(label: "summon_window", {
                engine.summonWindowRight(token, beside: focusedToken, in: targetWorkspaceId)
            }) else {
                return false
            }
            controller.workspaceManager.recordLayoutOperation(.windowInserted(token: token), in: targetWorkspaceId)
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
            return true
        }

        _ = controller.dwindleLayoutHandler.activateWindow(
            focusedToken,
            in: targetWorkspaceId,
            layoutRefresh: false,
            focusAfterLayout: false
        )
        controller.workspaceManager.withEngineMutationScope {
            engine.setPreselection(.right, in: targetWorkspaceId)
        }

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ).didMutate else {
            return false
        }

        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
        return true
    }

    private func commitSummonedWindowFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken? = nil,
        startNiriScrollAnimation: Bool = false
    ) {
        guard let controller else { return }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: rememberedFocusToken ?? token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId]
        ) { [weak controller] in
            controller?.focusWindow(token)
        }
        if startNiriScrollAnimation {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private func layoutType(for workspaceId: WorkspaceDescriptor.ID) -> LayoutType {
        guard let controller,
              let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name
        else {
            return .defaultLayout
        }
        return controller.settings.workspaces.layoutType(for: workspaceName)
    }
}
