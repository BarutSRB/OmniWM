// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorTopologyRestoreInput {
    let snapshot: ReconcileSnapshot
    let previousMonitors: [Monitor]
    let newMonitors: [Monitor]
    let visibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]
    let disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID]
    let runtimeOverrideReconnectPreferences: [Monitor.ID: WorkspaceDescriptor.ID]
    let interactionMonitorId: Monitor.ID?
    let previousInteractionMonitorId: Monitor.ID?
    let workspaceExists: (WorkspaceDescriptor.ID) -> Bool
    let homeMonitorId: (WorkspaceDescriptor.ID, [Monitor]) -> Monitor.ID?
    let effectiveMonitorId: (WorkspaceDescriptor.ID, [Monitor]) -> Monitor.ID?
}

struct MonitorTopologyRestorePlan: Equatable {
    var previousMonitors: [Monitor] = []
    var newMonitors: [Monitor] = []
    var visibleAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
    var refreshRestoreIntents: Bool = false
    var notes: [String] = []
}

enum MonitorTopologyRestorePlanner {
    static func plan(_ input: MonitorTopologyRestoreInput) -> MonitorTopologyRestorePlan {
        let previousMonitorIds = Set(input.previousMonitors.map(\.id))
        let newMonitorIds = Set(input.newMonitors.map(\.id))
        let hasNewMonitor = !newMonitorIds.subtracting(previousMonitorIds).isEmpty
        var plan = MonitorTopologyRestorePlan()
        plan.previousMonitors = input.previousMonitors
        plan.newMonitors = input.newMonitors
        plan.refreshRestoreIntents = true
        plan.visibleAssignments = restoredVisibleAssignments(input)
        var disconnectedCache = input.disconnectedVisibleWorkspaceCache
        let migrations = disconnectedMigrations(input, cache: &disconnectedCache)
        if hasNewMonitor, !disconnectedCache.isEmpty {
            restoreReconnectedWorkspaces(input, cache: disconnectedCache, assignments: &plan.visibleAssignments)
        }
        assignFallbackMigrations(migrations, input: input, assignments: &plan.visibleAssignments)
        let prioritized = prioritizedAssignments(input, fallbackAssignments: plan.visibleAssignments)
        plan.visibleAssignments = prioritized.assignments
        disconnectedCache = disconnectedCache.filter { _, workspaceId in
            guard input.workspaceExists(workspaceId) else {
                return false
            }
            guard let homeMonitorId = input.homeMonitorId(workspaceId, input.newMonitors) else {
                return true
            }
            return plan.visibleAssignments[homeMonitorId] != workspaceId
        }
        plan.disconnectedVisibleWorkspaceCache = disconnectedCache

        let reconciled = reconcileInteractionMonitors(
            input: input,
            focus: prioritized.focus,
            visibleAssignments: plan.visibleAssignments
        )
        plan.interactionMonitorId = reconciled.interactionMonitorId
        plan.previousInteractionMonitorId = reconciled.previousInteractionMonitorId
        plan.notes = [
            "visible_assignments=\(plan.visibleAssignments.count)",
            "disconnected_cache=\(plan.disconnectedVisibleWorkspaceCache.count)"
        ]
        return plan
    }

    private static func restoredVisibleAssignments(
        _ input: MonitorTopologyRestoreInput
    ) -> [Monitor.ID: WorkspaceDescriptor.ID] {
        let visibleSnapshots = input.visibleWorkspaceMap
            .compactMap { monitorId, workspaceId -> WorkspaceRestoreSnapshot? in
                guard let monitor = input.previousMonitors.first(where: { $0.id == monitorId }) else {
                    return nil
                }
                return WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: monitor),
                    workspaceId: workspaceId
                )
            }

        let restoredAssignments = resolveWorkspaceRestoreAssignments(
            snapshots: visibleSnapshots,
            monitors: input.newMonitors,
            workspaceExists: input.workspaceExists
        )

        var assignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        for monitor in Monitor.sortedByPosition(input.newMonitors) {
            guard let workspaceId = restoredAssignments[monitor.id] else { continue }
            guard input.effectiveMonitorId(workspaceId, input.newMonitors) == monitor.id else { continue }
            assignments[monitor.id] = workspaceId
        }

        return assignments
    }

    private static func disconnectedMigrations(
        _ input: MonitorTopologyRestoreInput,
        cache disconnectedCache: inout [MonitorRestoreKey: WorkspaceDescriptor.ID]
    ) -> [(removedMonitor: Monitor, workspaceId: WorkspaceDescriptor.ID)] {
        let survivingIds = Set(input.newMonitors.map(\.id))
        var migrations: [(removedMonitor: Monitor, workspaceId: WorkspaceDescriptor.ID)] = []

        for monitor in input.previousMonitors where !survivingIds.contains(monitor.id) {
            guard let workspaceId = input.visibleWorkspaceMap[monitor.id],
                  input.workspaceExists(workspaceId)
            else {
                continue
            }
            disconnectedCache[MonitorRestoreKey(monitor: monitor)] = workspaceId
            migrations.append((monitor, workspaceId))
        }

        migrations.sort { lhs, rhs in
            MonitorRestoreOrder(monitor: lhs.removedMonitor) < MonitorRestoreOrder(monitor: rhs.removedMonitor)
        }

        return migrations
    }

    private static func restoreReconnectedWorkspaces(
        _ input: MonitorTopologyRestoreInput,
        cache disconnectedCache: [MonitorRestoreKey: WorkspaceDescriptor.ID],
        assignments: inout [Monitor.ID: WorkspaceDescriptor.ID]
    ) {
        let sortedCacheEntries = disconnectedCache.sorted { lhs, rhs in
            MonitorRestoreOrder(restoreKey: lhs.key) < MonitorRestoreOrder(restoreKey: rhs.key)
        }

        for (_, workspaceId) in sortedCacheEntries {
            guard input.workspaceExists(workspaceId),
                  let homeMonitorId = input.homeMonitorId(workspaceId, input.newMonitors),
                  assignments[homeMonitorId] == nil
            else {
                continue
            }
            assignments[homeMonitorId] = workspaceId
        }
    }

    private static func assignFallbackMigrations(
        _ migrations: [(removedMonitor: Monitor, workspaceId: WorkspaceDescriptor.ID)],
        input: MonitorTopologyRestoreInput,
        assignments: inout [Monitor.ID: WorkspaceDescriptor.ID]
    ) {
        var winnerByFallbackMonitorId: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        for migration in migrations {
            guard input.workspaceExists(migration.workspaceId),
                  let fallbackMonitorId = input.effectiveMonitorId(migration.workspaceId, input.newMonitors),
                  winnerByFallbackMonitorId[fallbackMonitorId] == nil
            else {
                continue
            }
            winnerByFallbackMonitorId[fallbackMonitorId] = migration.workspaceId
        }

        for monitor in Monitor.sortedByPosition(input.newMonitors) {
            guard let workspaceId = winnerByFallbackMonitorId[monitor.id] else { continue }
            assignments[monitor.id] = workspaceId
        }
    }

    private static func prioritizedAssignments(
        _ input: MonitorTopologyRestoreInput,
        fallbackAssignments: [Monitor.ID: WorkspaceDescriptor.ID]
    ) -> (assignments: [Monitor.ID: WorkspaceDescriptor.ID], focus: MonitorRestoreFocusPriority) {
        let sortedNewMonitors = Monitor.sortedByPosition(input.newMonitors)
        let validMonitorIds = Set(sortedNewMonitors.map(\.id))
        let focus = MonitorRestoreFocusPriority(snapshot: input.snapshot)
        var reservations = MonitorWorkspaceReservations(validMonitorIds: validMonitorIds)
        reservations.reserve(
            focus.confirmedFocusWorkspaceId,
            on: focus.confirmedFocusWorkspaceId.flatMap {
                input.effectiveMonitorId($0, input.newMonitors)
            },
            workspaceExists: input.workspaceExists
        )
        reservations.reserve(
            focus.pendingFocusWorkspaceId,
            on: focus.pendingFocusWorkspaceId.flatMap {
                input.effectiveMonitorId($0, input.newMonitors)
            },
            workspaceExists: input.workspaceExists
        )
        for monitor in sortedNewMonitors {
            reservations.reserve(
                input.runtimeOverrideReconnectPreferences[monitor.id],
                on: monitor.id,
                workspaceExists: input.workspaceExists
            )
        }
        reservations.assignFallbacks(fallbackAssignments, input: input, monitors: sortedNewMonitors)
        return (reservations.assignments, focus)
    }

    private static func reconcileInteractionMonitors(
        input: MonitorTopologyRestoreInput,
        focus: MonitorRestoreFocusPriority,
        visibleAssignments: [Monitor.ID: WorkspaceDescriptor.ID]
    ) -> (interactionMonitorId: Monitor.ID?, previousInteractionMonitorId: Monitor.ID?) {
        let sortedMonitors = Monitor.sortedByPosition(input.newMonitors)
        let validMonitorIds = Set(sortedMonitors.map(\.id))
        let confirmedFocusMonitorId = focus.confirmedFocusWorkspaceId.flatMap { workspaceId in
            sortedMonitors.first(where: { visibleAssignments[$0.id] == workspaceId })?.id
        }
        let pendingFocusMonitorId = focus.pendingFocusWorkspaceId.flatMap { workspaceId in
            sortedMonitors.first(where: { visibleAssignments[$0.id] == workspaceId })?.id
        }
        let connectedInteractionMonitorId = input.interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }
        let firstAssignedMonitorId = sortedMonitors.first(where: {
            visibleAssignments[$0.id] != nil
        })?.id
        let resolvedInteractionMonitorId = focus.prioritizesInteractionMonitor
            ? connectedInteractionMonitorId
            ?? pendingFocusMonitorId
            ?? firstAssignedMonitorId
            ?? sortedMonitors.first?.id
            : confirmedFocusMonitorId
            ?? pendingFocusMonitorId
            ?? connectedInteractionMonitorId
            ?? firstAssignedMonitorId
            ?? sortedMonitors.first?.id

        let resolvedPreviousInteractionMonitorId: Monitor.ID?
        if let connectedInteractionMonitorId,
           connectedInteractionMonitorId != resolvedInteractionMonitorId
        {
            resolvedPreviousInteractionMonitorId = connectedInteractionMonitorId
        } else {
            resolvedPreviousInteractionMonitorId = input.previousInteractionMonitorId.flatMap {
                validMonitorIds.contains($0) && $0 != resolvedInteractionMonitorId ? $0 : nil
            }
        }

        return (resolvedInteractionMonitorId, resolvedPreviousInteractionMonitorId)
    }
}

private struct MonitorRestoreFocusPriority {
    let confirmedFocusWorkspaceId: WorkspaceDescriptor.ID?
    let prioritizesInteractionMonitor: Bool
    let pendingFocusWorkspaceId: WorkspaceDescriptor.ID?

    init(snapshot: borrowing ReconcileSnapshot) {
        switch snapshot.focusSession.nativeFocusOwner {
        case let .managed(token):
            confirmedFocusWorkspaceId = snapshot.windows.first(where: { $0.token == token })?.workspaceId
        case .external,
             .ownedSurface,
             .none:
            confirmedFocusWorkspaceId = nil
        }
        switch snapshot.focusSession.nativeFocusOwner {
        case .external,
             .ownedSurface:
            prioritizesInteractionMonitor = true
        case .managed,
             .none:
            prioritizesInteractionMonitor = false
        }
        pendingFocusWorkspaceId = snapshot.focusSession.pendingManagedFocus.workspaceId
    }
}

private struct MonitorWorkspaceReservations {
    let validMonitorIds: Set<Monitor.ID>
    private(set) var assignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    private var workspaceIds: Set<WorkspaceDescriptor.ID> = []

    init(validMonitorIds: Set<Monitor.ID>) {
        self.validMonitorIds = validMonitorIds
    }

    mutating func reserve(
        _ workspaceId: WorkspaceDescriptor.ID?,
        on monitorId: Monitor.ID?,
        workspaceExists: (WorkspaceDescriptor.ID) -> Bool
    ) {
        guard let workspaceId,
              let monitorId,
              workspaceExists(workspaceId),
              validMonitorIds.contains(monitorId),
              workspaceIds.insert(workspaceId).inserted
        else {
            return
        }
        guard assignments[monitorId] == nil else { return }
        assignments[monitorId] = workspaceId
    }

    mutating func assignFallbacks(
        _ fallbackAssignments: [Monitor.ID: WorkspaceDescriptor.ID],
        input: MonitorTopologyRestoreInput,
        monitors: [Monitor]
    ) {
        for monitor in monitors {
            guard assignments[monitor.id] == nil,
                  let workspaceId = fallbackAssignments[monitor.id],
                  input.workspaceExists(workspaceId),
                  input.effectiveMonitorId(workspaceId, input.newMonitors) == monitor.id,
                  workspaceIds.insert(workspaceId).inserted
            else {
                continue
            }
            assignments[monitor.id] = workspaceId
        }
    }
}
