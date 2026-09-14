// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct WorkspaceDescriptor: Identifiable, Hashable {
    typealias ID = UUID
    let id: ID
    var name: String
    var assignedMonitorPoint: CGPoint?
    var runtimeMonitorOverride: OutputId?

    init(name: String, assignedMonitorPoint: CGPoint? = nil) {
        id = UUID()
        self.name = name
        self.assignedMonitorPoint = assignedMonitorPoint
        runtimeMonitorOverride = nil
    }
}

struct WorkspaceFloatingRelocation: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let token: WindowToken
    let frame: CGRect
}

struct WorkspaceMonitorRelocation {
    let workspaceId: WorkspaceDescriptor.ID
    let targetMonitor: Monitor
    let floatingStates: [WindowToken: FloatingState]
}

struct WorkspaceMonitorMoveVisibility {
    let sourceWasVisible: Bool
    let destinationWorkspaceId: WorkspaceDescriptor.ID?
    let sourceReplacementWorkspaceId: WorkspaceDescriptor.ID?
    let makesMovedWorkspaceVisible: Bool
    let transfersManagedFocus: Bool
}

struct WorkspaceMonitorMoveOutcome: Equatable {
    enum Status: Equatable {
        case executed
        case conflict
        case notFound
        case stateConflict
    }

    let status: Status
    let affectedWorkspaces: Set<WorkspaceDescriptor.ID>
    let floatingRelocations: [WorkspaceFloatingRelocation]
}

enum WorkspaceNativeFullscreenTransition: Equatable {
    case enterRequested
    case suspended
    case exitRequested
}

struct WorkspaceNativeFullscreenRecord: Equatable {
    let originalToken: WindowToken
    var currentToken: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var transition: WorkspaceNativeFullscreenTransition
    var transitionGeneration: Int = 0
}

extension WorkspaceMonitorMoveOutcome {
    init(unchanged status: Status) {
        self.init(status: status, affectedWorkspaces: [], floatingRelocations: [])
    }
}

extension WorkspaceFloatingRelocation {
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.token.pid != rhs.token.pid {
            return lhs.token.pid < rhs.token.pid
        }
        return lhs.token.windowId < rhs.token.windowId
    }
}

extension WorkspaceManager {
    struct MonitorResolutionContext {
        let monitors: [Monitor]
        let sortedMonitors: [Monitor]
        let topologyProfile: TopologyProfile
        let configuredWorkspaceNames: Set<String>
        let monitorDescriptionByWorkspaceName: [String: MonitorDescription]
    }
}
