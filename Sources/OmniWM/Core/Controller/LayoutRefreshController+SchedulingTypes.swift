// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    enum ScheduledRefreshKind: Int {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
        case fullRescan
    }

    struct WindowRemovalPayload {
        var workspaceId: WorkspaceDescriptor.ID
        let layoutType: LayoutType
        let removedNodeId: NodeId?
        let removedNiriColumn: Bool
        let niriOldFrames: [WindowToken: CGRect]
        let shouldRecoverFocus: Bool
        let allowsPreferredRecoveryToken: Bool
    }

    struct FollowUpRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var additionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var workspaceMonitorRelocations: [WindowToken: ScheduledWorkspaceMonitorRelocation] = [:]
        var reconcilesWorkspaceMonitorState = false
        var suppressesWindowActivation = false
    }

    struct WorkspaceRefreshScope {
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        var additionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    }

    struct ScheduledRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
        var rescanScope: RescanScope
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var additionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var postLayoutActions: [RefreshPostLayoutAction] = []
        var windowRemovalPayloads: [WindowRemovalPayload] = []
        var workspaceMonitorRelocations: [WindowToken: ScheduledWorkspaceMonitorRelocation] = [:]
        var followUpRefresh: FollowUpRefresh?
        var subsumesRelayout = false
        var reconcilesWorkspaceMonitorState: Bool
        var suppressesWindowActivation: Bool
        var needsVisibilityReconciliation: Bool = false
        var visibilityReason: RefreshReason?

        init(
            kind: ScheduledRefreshKind,
            reason: RefreshReason,
            rescanScope: RescanScope = .all,
            affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
            postLayout: RefreshPostLayoutAction? = nil,
            windowRemovalPayload: WindowRemovalPayload? = nil,
            workspaceMonitorRelocations: [ScheduledWorkspaceMonitorRelocation] = [],
            reconcilesWorkspaceMonitorState: Bool? = nil,
            suppressesWindowActivation: Bool = false
        ) {
            self.kind = kind
            self.reason = reason
            self.rescanScope = rescanScope
            self.affectedWorkspaceIds = affectedWorkspaceIds
            self.workspaceMonitorRelocations = Dictionary(
                workspaceMonitorRelocations.map { ($0.token, $0) },
                uniquingKeysWith: { _, incoming in incoming }
            )
            self.reconcilesWorkspaceMonitorState = reconcilesWorkspaceMonitorState
                ?? (
                    reason == .workspaceConfigChanged
                        || reason == .monitorConfigurationChanged
                )
            self.suppressesWindowActivation = suppressesWindowActivation || reason == .overviewMutation
            if let postLayout {
                postLayoutActions = [postLayout]
            }
            if let windowRemovalPayload {
                windowRemovalPayloads = [windowRemovalPayload]
            }
        }
    }

    struct NativeSpaceRescanEvidence {
        var resolvedPIDs: Set<pid_t> = []
        var windowIds: Set<Int> = []
        var windowServerInfoByWindowId: [Int: WindowServerInfo] = [:]
    }
}
