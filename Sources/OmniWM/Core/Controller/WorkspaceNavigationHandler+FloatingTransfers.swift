// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    @discardableResult
    func rebindFloatingWindow(
        handle: WindowHandle,
        toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID,
        onMonitor targetMonitor: Monitor
    ) -> Bool {
        guard let controller else { return false }
        let workspaceManager = controller.workspaceManager
        let token = handle.id
        guard let entry = floatingTransferEntry(
            handle,
            targetWorkspaceId: targetWorkspaceId,
            targetMonitor: targetMonitor,
            controller: controller
        ) else { return false }

        let sourceWorkspaceId = entry.workspaceId
        let activeRequest = controller.intentLedger.activeManagedRequest
        let matchingRequest = activeRequest?.token == token ? activeRequest : nil
        let hasNewerUnrelatedRequest = activeRequest.map { $0.token != token } ?? false
        let hasUnrelatedPendingFocus = workspaceManager.pendingFocusedToken.map { $0 != token } ?? false
        let shouldRehomeFocusedWindow = workspaceManager.selectedManagedToken == token
            && !hasNewerUnrelatedRequest
            && !hasUnrelatedPendingFocus

        controller.reassignManagedWindow(token, to: targetWorkspaceId)
        guard workspaceManager.workspace(for: token) == targetWorkspaceId else { return false }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: sourceWorkspaceId)

        retargetFloatingTransferFocus(
            token,
            workspaceId: targetWorkspaceId,
            monitorId: targetMonitor.id,
            matchingRequest: matchingRequest,
            shouldRehomeFocusedWindow: shouldRehomeFocusedWindow
        )

        return true
    }

    private func floatingTransferEntry(
        _ handle: WindowHandle,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        targetMonitor: Monitor,
        controller: WMController
    ) -> WindowState? {
        let workspaceManager = controller.workspaceManager
        let token = handle.id
        guard let entry = workspaceManager.entry(for: token),
              workspaceManager.handle(for: token) === handle,
              !workspaceManager.isAppHidden(pid: entry.pid),
              entry.mode == .floating,
              entry.workspaceId != targetWorkspaceId,
              workspaceManager.descriptor(for: targetWorkspaceId) != nil,
              workspaceManager.monitor(byId: targetMonitor.id) != nil,
              workspaceManager.monitorId(for: entry.workspaceId) != targetMonitor.id,
              workspaceManager.monitorId(for: targetWorkspaceId) == targetMonitor.id,
              workspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id)?.id == targetWorkspaceId
        else {
            return nil
        }

        return entry
    }

    private func retargetFloatingTransferFocus(
        _ token: WindowToken,
        workspaceId targetWorkspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        matchingRequest: ManagedFocusRequest?,
        shouldRehomeFocusedWindow: Bool
    ) {
        guard let controller else { return }
        let workspaceManager = controller.workspaceManager
        if let matchingRequest {
            guard let retargetedRequest = controller.intentLedger.retargetManagedRequest(
                requestId: matchingRequest.requestId,
                token: token,
                to: targetWorkspaceId
            ) else {
                return
            }
            if shouldRehomeFocusedWindow {
                _ = workspaceManager.rehomeManagedFocusRequest(
                    token,
                    in: targetWorkspaceId,
                    onMonitor: monitorId,
                    requestId: retargetedRequest.requestId
                )
            } else {
                _ = workspaceManager.beginManagedFocusRequest(
                    token,
                    in: targetWorkspaceId,
                    onMonitor: monitorId,
                    requestId: retargetedRequest.requestId
                )
            }
        } else if shouldRehomeFocusedWindow {
            _ = workspaceManager.setManagedFocus(
                token,
                in: targetWorkspaceId,
                onMonitor: monitorId
            )
        }
    }
}
