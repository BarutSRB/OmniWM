// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

struct TopologyMonitorSessionState: Equatable {
    var monitorId: Monitor.ID
    var visibleWorkspaceId: WorkspaceDescriptor.ID?
    var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
}

struct TopologyWorkspaceProjectionRecord: Equatable {
    var workspaceId: WorkspaceDescriptor.ID
    var projectedMonitorId: Monitor.ID?
    var homeMonitorId: Monitor.ID?
    var effectiveMonitorId: Monitor.ID?
}

struct TopologyTransitionPlan: Equatable {
    let previousMonitors: [Monitor]
    let newMonitors: [Monitor]
    var monitorStates: [TopologyMonitorSessionState]
    var workspaceProjections: [TopologyWorkspaceProjectionRecord]
    var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID]
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
    var refreshRestoreIntents: Bool
}

struct PersistedHydrationMutation: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let monitorId: Monitor.ID?
    let targetMode: TrackedWindowMode
    let floatingFrame: CGRect?
    let consumedKey: PersistedWindowRestoreKey
}

struct RestoreRefreshPlan: Equatable {
    var refreshRestoreIntents: Bool
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
}

struct ActionPlan: Equatable {
    var lifecyclePhase: WindowLifecyclePhase? = nil
    var observedState: ObservedWindowState? = nil
    var desiredState: DesiredWindowState? = nil
    var restoreIntent: RestoreIntent? = nil
    var replacementCorrelation: ReplacementCorrelation? = nil
    var focusSession: FocusSessionSnapshot? = nil
    var restoreRefresh: RestoreRefreshPlan? = nil
    var topologyTransition: TopologyTransitionPlan? = nil
    var persistedHydration: PersistedHydrationMutation? = nil
    var notes: [String] = []

    var isEmpty: Bool {
        lifecyclePhase == nil
            && observedState == nil
            && desiredState == nil
            && restoreIntent == nil
            && replacementCorrelation == nil
            && focusSession == nil
            && restoreRefresh == nil
            && topologyTransition == nil
            && persistedHydration == nil
            && notes.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if let lifecyclePhase {
            parts.append("phase=\(lifecyclePhase.rawValue)")
        }
        if let desiredState {
            parts.append("desired=\(desiredState.summary)")
        }
        if let replacementCorrelation {
            parts.append("replacement=\(replacementCorrelation.reason.rawValue)")
        }
        if let focusSession {
            parts.append("focus=\(describe(focusSession))")
        }
        if let restoreRefresh {
            if restoreRefresh.refreshRestoreIntents {
                parts.append("restore_refresh=true")
            }
            parts.append(
                "interaction=\(String(describing: restoreRefresh.interactionMonitorId))->\(String(describing: restoreRefresh.previousInteractionMonitorId))"
            )
        }
        if let topologyTransition {
            parts.append(
                "topology=\(topologyTransition.previousMonitors.count)->\(topologyTransition.newMonitors.count)"
            )
            parts.append(
                "visible_assignments=\(topologyTransition.monitorStates.filter { $0.visibleWorkspaceId != nil }.count)"
            )
        }
        if let persistedHydration {
            parts.append(
                "hydration=workspace=\(persistedHydration.workspaceId.uuidString),mode=\(persistedHydration.targetMode)"
            )
        }
        if !notes.isEmpty {
            parts.append(contentsOf: notes)
        }
        return parts.joined(separator: " ")
    }

    private func describe(_ focusSession: FocusSessionSnapshot) -> String {
        var parts: [String] = []
        parts.append("focused=\(focusSession.focusedToken.map(String.init(describing:)) ?? "nil")")
        parts.append("pending=\(focusSession.pendingManagedFocus.token.map(String.init(describing:)) ?? "nil")")
        if let leaseOwner = focusSession.focusLease?.owner.rawValue {
            parts.append("lease=\(leaseOwner)")
        }
        if focusSession.isNonManagedFocusActive {
            parts.append("non_managed=true")
        }
        if focusSession.isAppFullscreenActive {
            parts.append("app_fullscreen=true")
        }
        return parts.joined(separator: ",")
    }
}
