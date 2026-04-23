// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct RefreshRequestEvent: Equatable {
    var refresh: ScheduledRefresh
    var shouldDropWhileBusy: Bool
    var isIncrementalRefreshInProgress: Bool
    var isImmediateLayoutInProgress: Bool
    var hasActiveAnimationRefreshes: Bool
}

struct RefreshCompletionEvent: Equatable {
    var refresh: ScheduledRefresh
    var didComplete: Bool
    var didExecutePlan: Bool
}

struct ManagedFocusRequestEvent: Equatable {
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
}

enum ManagedActivationMatch: Equatable {
    case missingFocusedWindow(
        pid: pid_t,
        fallbackFullscreen: Bool
    )
    case managed(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        requiresNativeFullscreenRestoreRelayout: Bool
    )
    case unmanaged(
        pid: pid_t,
        token: WindowToken,
        appFullscreen: Bool,
        fallbackFullscreen: Bool
    )
    case ownedApplication(pid: pid_t)
}

struct ManagedActivationObservation: Equatable {
    var source: ActivationEventSource
    var origin: ActivationCallOrigin
    var match: ManagedActivationMatch
}

enum OrchestrationEvent: Equatable {
    case refreshRequested(RefreshRequestEvent)
    case refreshCompleted(RefreshCompletionEvent)
    case focusRequested(ManagedFocusRequestEvent)
    case activationObserved(ManagedActivationObservation)
}

extension RefreshRequestEvent {
    var summary: String {
        "refreshRequested \(refresh.summary) drop=\(orchestrationDebugFlag(shouldDropWhileBusy)) incremental=\(orchestrationDebugFlag(isIncrementalRefreshInProgress)) immediate=\(orchestrationDebugFlag(isImmediateLayoutInProgress)) animated=\(orchestrationDebugFlag(hasActiveAnimationRefreshes))"
    }
}

extension RefreshCompletionEvent {
    var summary: String {
        "refreshCompleted \(refresh.summary) complete=\(orchestrationDebugFlag(didComplete)) executed=\(orchestrationDebugFlag(didExecutePlan))"
    }
}

extension ManagedFocusRequestEvent {
    var summary: String {
        "focusRequested token=\(orchestrationDebugToken(token)) workspace=\(orchestrationDebugWorkspace(workspaceId))"
    }
}

extension ManagedActivationMatch {
    var summary: String {
        switch self {
        case let .missingFocusedWindow(pid, fallbackFullscreen):
            "missingFocusedWindow pid=\(pid) fallback_fullscreen=\(orchestrationDebugFlag(fallbackFullscreen))"
        case let .managed(token, workspaceId, monitorId, isWorkspaceActive, appFullscreen, requiresNativeFullscreenRestoreRelayout):
            "managed token=\(orchestrationDebugToken(token)) workspace=\(orchestrationDebugWorkspace(workspaceId)) monitor=\(orchestrationDebugMonitor(monitorId)) workspace_active=\(orchestrationDebugFlag(isWorkspaceActive)) fullscreen=\(orchestrationDebugFlag(appFullscreen)) restore_relayout=\(orchestrationDebugFlag(requiresNativeFullscreenRestoreRelayout))"
        case let .unmanaged(pid, token, appFullscreen, fallbackFullscreen):
            "unmanaged pid=\(pid) token=\(orchestrationDebugToken(token)) fullscreen=\(orchestrationDebugFlag(appFullscreen)) fallback_fullscreen=\(orchestrationDebugFlag(fallbackFullscreen))"
        case let .ownedApplication(pid):
            "ownedApplication pid=\(pid)"
        }
    }
}

extension ManagedActivationObservation {
    var summary: String {
        "activationObserved source=\(source.rawValue) origin=\(origin.rawValue) match={\(match.summary)}"
    }
}

extension OrchestrationEvent {
    var summary: String {
        switch self {
        case let .refreshRequested(event):
            event.summary
        case let .refreshCompleted(event):
            event.summary
        case let .focusRequested(event):
            event.summary
        case let .activationObserved(observation):
            observation.summary
        }
    }
}
