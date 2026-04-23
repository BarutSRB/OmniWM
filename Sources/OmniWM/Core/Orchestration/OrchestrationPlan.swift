// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

enum ScheduledRefreshKind: Int, Equatable {
    case relayout
    case immediateRelayout
    case visibilityRefresh
    case windowRemoval
    case fullRescan
}

struct WindowRemovalPayload: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let layoutType: LayoutType
    let removedNodeId: NodeId?
    let niriOldFrames: [WindowToken: CGRect]
    let shouldRecoverFocus: Bool
}

struct FollowUpRefresh: Equatable {
    var kind: ScheduledRefreshKind
    var reason: RefreshReason
    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
}

struct ScheduledRefresh: Equatable {
    var cycleId: RefreshCycleId
    var kind: ScheduledRefreshKind
    var reason: RefreshReason
    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    var postLayoutAttachmentIds: [RefreshAttachmentId] = []
    var windowRemovalPayloads: [WindowRemovalPayload] = []
    var followUpRefresh: FollowUpRefresh?
    var needsVisibilityReconciliation: Bool = false
    var visibilityReason: RefreshReason?

    init(
        cycleId: RefreshCycleId,
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayoutAttachmentIds: [RefreshAttachmentId] = [],
        windowRemovalPayload: WindowRemovalPayload? = nil
    ) {
        self.cycleId = cycleId
        self.kind = kind
        self.reason = reason
        self.affectedWorkspaceIds = affectedWorkspaceIds
        self.postLayoutAttachmentIds = postLayoutAttachmentIds
        if let windowRemovalPayload {
            windowRemovalPayloads = [windowRemovalPayload]
        }
    }
}

enum OrchestrationDecision: Equatable {
    case refreshDropped(reason: RefreshReason)
    case refreshQueued(cycleId: RefreshCycleId, kind: ScheduledRefreshKind)
    case refreshMerged(cycleId: RefreshCycleId, kind: ScheduledRefreshKind)
    case refreshSuperseded(activeCycleId: RefreshCycleId, pendingCycleId: RefreshCycleId)
    case refreshCompleted(cycleId: RefreshCycleId, didComplete: Bool)
    case focusRequestAccepted(requestId: UInt64, token: WindowToken)
    case focusRequestSuperseded(replacedRequestId: UInt64, requestId: UInt64, token: WindowToken)
    case focusRequestContinued(requestId: UInt64, reason: ActivationRetryReason)
    case focusRequestCancelled(requestId: UInt64, token: WindowToken?)
    case focusRequestIgnored(token: WindowToken)
    case managedActivationConfirmed(token: WindowToken)
    case managedActivationDeferred(requestId: UInt64, reason: ActivationRetryReason)
    case managedActivationFallback(pid: pid_t)
}

extension ScheduledRefreshKind {
    var summary: String {
        switch self {
        case .relayout:
            "relayout"
        case .immediateRelayout:
            "immediate_relayout"
        case .visibilityRefresh:
            "visibility_refresh"
        case .windowRemoval:
            "window_removal"
        case .fullRescan:
            "full_rescan"
        }
    }
}

extension FollowUpRefresh {
    var summary: String {
        "kind=\(kind.summary) reason=\(reason.rawValue) workspaces=\(affectedWorkspaceIds.count)"
    }
}

extension ScheduledRefresh {
    var summary: String {
        var components = [
            "cycle=\(cycleId)",
            "kind=\(kind.summary)",
            "reason=\(reason.rawValue)",
            "workspaces=\(affectedWorkspaceIds.count)",
            "attachments=\(postLayoutAttachmentIds.count)",
            "removals=\(windowRemovalPayloads.count)",
            "visibility=\(orchestrationDebugFlag(needsVisibilityReconciliation))",
        ]
        if let visibilityReason {
            components.append("visibility_reason=\(visibilityReason.rawValue)")
        }
        if let followUpRefresh {
            components.append("follow_up={\(followUpRefresh.summary)}")
        }
        return components.joined(separator: " ")
    }
}

extension OrchestrationDecision {
    var summary: String {
        switch self {
        case let .refreshDropped(reason):
            "refreshDropped reason=\(reason.rawValue)"
        case let .refreshQueued(cycleId, kind):
            "refreshQueued cycle=\(cycleId) kind=\(kind.summary)"
        case let .refreshMerged(cycleId, kind):
            "refreshMerged cycle=\(cycleId) kind=\(kind.summary)"
        case let .refreshSuperseded(activeCycleId, pendingCycleId):
            "refreshSuperseded active=\(activeCycleId) pending=\(pendingCycleId)"
        case let .refreshCompleted(cycleId, didComplete):
            "refreshCompleted cycle=\(cycleId) complete=\(orchestrationDebugFlag(didComplete))"
        case let .focusRequestAccepted(requestId, token):
            "focusRequestAccepted request=\(requestId) token=\(orchestrationDebugToken(token))"
        case let .focusRequestSuperseded(replacedRequestId, requestId, token):
            "focusRequestSuperseded replaced=\(replacedRequestId) request=\(requestId) token=\(orchestrationDebugToken(token))"
        case let .focusRequestContinued(requestId, reason):
            "focusRequestContinued request=\(requestId) reason=\(reason.rawValue)"
        case let .focusRequestCancelled(requestId, token):
            "focusRequestCancelled request=\(requestId) token=\(orchestrationDebugToken(token))"
        case let .focusRequestIgnored(token):
            "focusRequestIgnored token=\(orchestrationDebugToken(token))"
        case let .managedActivationConfirmed(token):
            "managedActivationConfirmed token=\(orchestrationDebugToken(token))"
        case let .managedActivationDeferred(requestId, reason):
            "managedActivationDeferred request=\(requestId) reason=\(reason.rawValue)"
        case let .managedActivationFallback(pid):
            "managedActivationFallback pid=\(pid)"
        }
    }
}

struct OrchestrationPlan: Equatable {
    enum Action: Equatable {
        case cancelActiveRefresh(cycleId: RefreshCycleId)
        case startRefresh(ScheduledRefresh)
        case runPostLayoutAttachments([RefreshAttachmentId])
        case discardPostLayoutAttachments([RefreshAttachmentId])
        case performVisibilitySideEffects
        case requestWorkspaceBarRefresh
        case beginManagedFocusRequest(
            requestId: UInt64,
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID
        )
        case frontManagedWindow(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID
        )
        case clearManagedFocusState(
            requestId: UInt64,
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID?
        )
        case continueManagedFocusRequest(
            requestId: UInt64,
            reason: ActivationRetryReason,
            source: ActivationEventSource,
            origin: ActivationCallOrigin
        )
        case confirmManagedActivation(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID?,
            isWorkspaceActive: Bool,
            appFullscreen: Bool,
            source: ActivationEventSource
        )
        case beginNativeFullscreenRestoreActivation(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID?,
            isWorkspaceActive: Bool,
            source: ActivationEventSource
        )
        case enterNonManagedFallback(
            pid: pid_t,
            token: WindowToken?,
            appFullscreen: Bool,
            source: ActivationEventSource
        )
        case cancelActivationRetry(requestId: UInt64?)
        case enterOwnedApplicationFallback(
            pid: pid_t,
            source: ActivationEventSource
        )
    }

    var actions: [Action] = []
}

extension OrchestrationPlan.Action {
    var summary: String {
        switch self {
        case let .cancelActiveRefresh(cycleId):
            "cancelActiveRefresh cycle=\(cycleId)"
        case let .startRefresh(refresh):
            "startRefresh \(refresh.summary)"
        case let .runPostLayoutAttachments(attachmentIds):
            "runPostLayoutAttachments count=\(attachmentIds.count)"
        case let .discardPostLayoutAttachments(attachmentIds):
            "discardPostLayoutAttachments count=\(attachmentIds.count)"
        case .performVisibilitySideEffects:
            "performVisibilitySideEffects"
        case .requestWorkspaceBarRefresh:
            "requestWorkspaceBarRefresh"
        case let .beginManagedFocusRequest(requestId, token, workspaceId):
            "beginManagedFocusRequest request=\(requestId) token=\(orchestrationDebugToken(token)) workspace=\(orchestrationDebugWorkspace(workspaceId))"
        case let .frontManagedWindow(token, workspaceId):
            "frontManagedWindow token=\(orchestrationDebugToken(token)) workspace=\(orchestrationDebugWorkspace(workspaceId))"
        case let .clearManagedFocusState(requestId, token, workspaceId):
            "clearManagedFocusState request=\(requestId) token=\(orchestrationDebugToken(token)) workspace=\(orchestrationDebugWorkspace(workspaceId))"
        case let .continueManagedFocusRequest(requestId, reason, source, origin):
            "continueManagedFocusRequest request=\(requestId) reason=\(reason.rawValue) source=\(source.rawValue) origin=\(origin.rawValue)"
        case let .confirmManagedActivation(token, workspaceId, monitorId, isWorkspaceActive, appFullscreen, source):
            "confirmManagedActivation token=\(orchestrationDebugToken(token)) workspace=\(orchestrationDebugWorkspace(workspaceId)) monitor=\(orchestrationDebugMonitor(monitorId)) workspace_active=\(orchestrationDebugFlag(isWorkspaceActive)) fullscreen=\(orchestrationDebugFlag(appFullscreen)) source=\(source.rawValue)"
        case let .beginNativeFullscreenRestoreActivation(token, workspaceId, monitorId, isWorkspaceActive, source):
            "beginNativeFullscreenRestoreActivation token=\(orchestrationDebugToken(token)) workspace=\(orchestrationDebugWorkspace(workspaceId)) monitor=\(orchestrationDebugMonitor(monitorId)) workspace_active=\(orchestrationDebugFlag(isWorkspaceActive)) source=\(source.rawValue)"
        case let .enterNonManagedFallback(pid, token, appFullscreen, source):
            "enterNonManagedFallback pid=\(pid) token=\(orchestrationDebugToken(token)) fullscreen=\(orchestrationDebugFlag(appFullscreen)) source=\(source.rawValue)"
        case let .cancelActivationRetry(requestId):
            "cancelActivationRetry request=\(requestId.map(String.init) ?? "nil")"
        case let .enterOwnedApplicationFallback(pid, source):
            "enterOwnedApplicationFallback pid=\(pid) source=\(source.rawValue)"
        }
    }
}

struct OrchestrationResult: Equatable {
    var snapshot: OrchestrationSnapshot
    var decision: OrchestrationDecision
    var plan: OrchestrationPlan
}

func orchestrationDebugFlag(_ value: Bool) -> Int {
    value ? 1 : 0
}

func orchestrationDebugWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> String {
    String(workspaceId.uuidString.prefix(8))
}

func orchestrationDebugWorkspace(_ workspaceId: WorkspaceDescriptor.ID?) -> String {
    guard let workspaceId else { return "nil" }
    return orchestrationDebugWorkspace(workspaceId)
}

func orchestrationDebugToken(_ token: WindowToken) -> String {
    "\(token.pid):\(token.windowId)"
}

func orchestrationDebugToken(_ token: WindowToken?) -> String {
    guard let token else { return "nil" }
    return orchestrationDebugToken(token)
}

func orchestrationDebugMonitor(_ monitorId: Monitor.ID?) -> String {
    guard let monitorId else { return "nil" }
    return String(monitorId.displayId)
}
