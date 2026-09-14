// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func setInteractionMonitor(_ monitorId: Monitor.ID?, preservePrevious: Bool = true) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        return updateInteractionMonitor(normalizedMonitorId, preservePrevious: preservePrevious, notify: true)
    }

    @discardableResult
    func setManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        guard canConfirmManagedFocus(token, in: workspaceId, requestId: nil) else {
            return false
        }
        var changed = rememberFocus(token, in: workspaceId)
        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }
        changed = applyFocusReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                requestId: nil,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return changed
    }

    @discardableResult
    func confirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        activateWorkspaceOnMonitor: Bool,
        requestId: UInt64? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        guard canConfirmManagedFocus(token, in: workspaceId, requestId: requestId) else {
            return false
        }
        var changed = false

        if activateWorkspaceOnMonitor,
           let normalizedMonitorId,
           let monitor = monitor(byId: normalizedMonitorId)
        {
            changed = setActiveWorkspaceInternal(
                workspaceId,
                on: normalizedMonitorId,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            ) || changed
        }

        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }

        changed = rememberFocus(token, in: workspaceId) || changed
        changed = applyFocusReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                requestId: requestId,
                source: .workspaceManager
            )
        ) || changed

        if changed {
            notifySessionStateChanged()
        }

        drainPendingRuntimeMonitorOverrideClears()
        return changed
    }

    func canConfirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        requestId: UInt64?
    ) -> Bool {
        if let requestId {
            return pendingManagedFocusMatches(
                token: token,
                workspaceId: workspaceId,
                requestId: requestId
            )
        }
        let request = focusSessionSnapshot.pendingManagedFocus
        guard request != .empty else {
            return true
        }
        return request.requestId == nil
            && request.token == token
            && request.workspaceId == workspaceId
    }

    @discardableResult
    func cancelManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        requestId: UInt64?
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                requestId: requestId,
                source: .workspaceManager
            )
        )

        if changed {
            notifySessionStateChanged()
        }

        drainPendingRuntimeMonitorOverrideClears()
        return changed
    }

    @discardableResult
    func cancelCurrentManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> Bool {
        let request = focusSessionSnapshot.pendingManagedFocus
        let matchesToken = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesToken, matchesWorkspace, request != .empty else {
            return false
        }
        return cancelManagedFocusRequest(
            matching: token,
            workspaceId: workspaceId,
            requestId: request.requestId
        )
    }

    @discardableResult
    func clearNativeFocusOwner() -> Bool {
        let changed = applyFocusReconcileEvent(
            .nativeFocusOwnerChanged(
                owner: .none,
                preservePendingManagedFocus: false,
                source: .workspaceManager
            )
        )
        if changed {
            notifySessionStateChanged(surfaceScope: .border)
        }
        return changed
    }
}
