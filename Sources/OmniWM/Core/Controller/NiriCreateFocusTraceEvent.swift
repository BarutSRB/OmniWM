// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum ManagedBorderReapplyPhase: String, Equatable {
    case postLayout
    case animationSettled
    case retryExhaustedFallback
}

struct NiriCreateFocusTraceEvent: Equatable {
    enum Kind: Equatable {
        case createSeen(windowId: UInt32)
        case createRetryScheduled(
            windowId: UInt32,
            pid: pid_t?,
            reason: WindowAdmissionPendingReason,
            attempt: Int
        )
        case admissionRejected(windowId: UInt32, pid: pid_t?, reason: WindowAdmissionRejectionReason)
        case createPlacementResolved(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            rung: WorkspacePlacementRung,
            pendingWorkspaceId: WorkspaceDescriptor.ID?,
            pendingMonitorId: Monitor.ID?,
            focusedWorkspaceId: WorkspaceDescriptor.ID?,
            focusedMonitorId: Monitor.ID?,
            nativeSpaceMonitorId: Monitor.ID?,
            frameMonitorId: Monitor.ID?,
            interactionWorkspaceId: WorkspaceDescriptor.ID?,
            interactionMonitorId: Monitor.ID?,
            ruleSkipReason: WorkspaceRuleSkipReason?
        )
        case candidateTracked(token: WindowToken, axPid: pid_t?, workspaceId: WorkspaceDescriptor.ID)
        case relayoutActivatedWindow(token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case pendingFocusStarted(requestId: UInt64, token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case activationSourceObserved(pid: pid_t, source: ActivationEventSource)
        case activationDeferred(
            requestId: UInt64,
            token: WindowToken,
            source: ActivationEventSource,
            reason: ActivationRetryReason,
            attempt: Int
        )
        case focusConfirmed(token: WindowToken, workspaceId: WorkspaceDescriptor.ID, source: ActivationEventSource)
        case borderReapplied(token: WindowToken, phase: ManagedBorderReapplyPhase)
        case provisionalExternalFocusEntered(pid: pid_t, source: ActivationEventSource)
        case externalFocusFallbackEntered(pid: pid_t, source: ActivationEventSource)
    }

    let timestamp: Date
    let kind: Kind

    init(
        timestamp: Date = Date(),
        kind: Kind
    ) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

extension NiriCreateFocusTraceEvent: CustomStringConvertible {
    var description: String {
        switch kind {
        case let .createSeen(windowId):
            "create_seen window=\(windowId)"
        case let .createRetryScheduled(windowId, pid, reason, attempt):
            "create_retry_scheduled window=\(windowId) pid=\(pid.map(String.init) ?? "nil") reason=\(reason.rawValue) attempt=\(attempt)"
        case let .admissionRejected(windowId, pid, reason):
            "admission_rejected window=\(windowId) pid=\(pid.map(String.init) ?? "nil") reason=\(reason.rawValue)"
        case let .createPlacementResolved(
            token,
            workspaceId,
            rung,
            pendingWorkspaceId,
            pendingMonitorId,
            focusedWorkspaceId,
            focusedMonitorId,
            nativeSpaceMonitorId,
            frameMonitorId,
            interactionWorkspaceId,
            interactionMonitorId,
            ruleSkipReason
        ):
            "create_placement_resolved token=\(token) workspace=\(workspaceId.uuidString) rung=\(rung.rawValue) rule_skip=\(ruleSkipReason?.rawValue ?? "none") pending_workspace=\(pendingWorkspaceId?.uuidString ?? "nil") pending_monitor=\(String(describing: pendingMonitorId)) focused_workspace=\(focusedWorkspaceId?.uuidString ?? "nil") focused_monitor=\(String(describing: focusedMonitorId)) native_monitor=\(String(describing: nativeSpaceMonitorId)) frame_monitor=\(String(describing: frameMonitorId)) interaction_workspace=\(interactionWorkspaceId?.uuidString ?? "nil") interaction_monitor=\(String(describing: interactionMonitorId))"
        case let .candidateTracked(token, axPid, workspaceId):
            "candidate_tracked token=\(token) ax_pid=\(axPid.map(String.init) ?? "nil") workspace=\(workspaceId.uuidString)"
        case let .relayoutActivatedWindow(token, workspaceId):
            "relayout_activated_window token=\(token) workspace=\(workspaceId.uuidString)"
        case let .pendingFocusStarted(requestId, token, workspaceId):
            "pending_focus_started request=\(requestId) token=\(token) workspace=\(workspaceId.uuidString)"
        case let .activationSourceObserved(pid, source):
            "activation_source_observed pid=\(pid) source=\(source.rawValue)"
        case let .activationDeferred(requestId, token, source, reason, attempt):
            "activation_deferred request=\(requestId) token=\(token) source=\(source.rawValue) reason=\(reason.rawValue) attempt=\(attempt)"
        case let .focusConfirmed(token, workspaceId, source):
            "focus_confirmed token=\(token) workspace=\(workspaceId.uuidString) source=\(source.rawValue)"
        case let .borderReapplied(token, phase):
            "border_reapplied token=\(token) phase=\(phase.rawValue)"
        case let .provisionalExternalFocusEntered(pid, source):
            "provisional_external_focus_entered pid=\(pid) source=\(source.rawValue)"
        case let .externalFocusFallbackEntered(pid, source):
            "external_focus_fallback_entered pid=\(pid) source=\(source.rawValue)"
        }
    }
}
