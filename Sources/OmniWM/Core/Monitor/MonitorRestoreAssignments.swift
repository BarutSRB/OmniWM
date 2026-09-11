// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorRestoreKey: Hashable {
    let displayUUID: String?
    let displayId: CGDirectDisplayID
    let name: String
    let anchorPoint: CGPoint
    let frameSize: CGSize

    init(monitor: Monitor) {
        displayUUID = monitor.displayUUID
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
        frameSize = monitor.frame.size
    }

    static func == (lhs: MonitorRestoreKey, rhs: MonitorRestoreKey) -> Bool {
        if lhs.displayUUID != nil || rhs.displayUUID != nil {
            return lhs.displayUUID == rhs.displayUUID
        }
        return lhs.displayId == rhs.displayId &&
            lhs.name == rhs.name &&
            lhs.anchorPoint == rhs.anchorPoint &&
            lhs.frameSize == rhs.frameSize
    }

    func hash(into hasher: inout Hasher) {
        if let displayUUID {
            hasher.combine(displayUUID)
        } else {
            hasher.combine(displayId)
            hasher.combine(name)
            hasher.combine(anchorPoint)
            hasher.combine(frameSize)
        }
    }
}

struct MonitorRestoreOrder: Comparable {
    private let horizontal: CGFloat
    private let vertical: CGFloat
    private let displayId: CGDirectDisplayID

    init(monitor: Monitor) {
        horizontal = monitor.frame.minX
        vertical = -monitor.frame.maxY
        displayId = monitor.displayId
    }

    init(restoreKey: MonitorRestoreKey) {
        horizontal = restoreKey.anchorPoint.x
        vertical = -restoreKey.anchorPoint.y
        displayId = restoreKey.displayId
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.horizontal != rhs.horizontal {
            return lhs.horizontal < rhs.horizontal
        }
        if lhs.vertical != rhs.vertical {
            return lhs.vertical < rhs.vertical
        }
        return lhs.displayId < rhs.displayId
    }
}

struct WorkspaceRestoreSnapshot: Hashable {
    let monitor: MonitorRestoreKey
    let workspaceId: WorkspaceDescriptor.ID
}

private struct RestoreMatchingResult {
    var assignmentsBySnapshotIndex: [Int: Monitor.ID] = [:]
    var assignedCount = 0
    var totalNamePenalty = 0
    var totalGeometryDelta: CGFloat = 0

    func isPreferred(
        over rhs: RestoreMatchingResult,
        snapshotIndices: Range<Int>,
        monitorsById: [Monitor.ID: Monitor]
    ) -> Bool {
        if self.assignedCount != rhs.assignedCount {
            return self.assignedCount > rhs.assignedCount
        }
        if self.totalNamePenalty != rhs.totalNamePenalty {
            return self.totalNamePenalty < rhs.totalNamePenalty
        }
        if self.totalGeometryDelta != rhs.totalGeometryDelta {
            return self.totalGeometryDelta < rhs.totalGeometryDelta
        }

        for index in snapshotIndices {
            let lhsMonitorId = self.assignmentsBySnapshotIndex[index]
            let rhsMonitorId = rhs.assignmentsBySnapshotIndex[index]

            switch (lhsMonitorId, rhsMonitorId) {
            case (nil, nil):
                continue
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case let (.some(lhsMonitorId), .some(rhsMonitorId)):
                guard lhsMonitorId != rhsMonitorId else { continue }
                guard let lhsMonitor = monitorsById[lhsMonitorId],
                      let rhsMonitor = monitorsById[rhsMonitorId]
                else {
                    return lhsMonitorId.displayId < rhsMonitorId.displayId
                }
                return MonitorRestoreOrder(monitor: lhsMonitor) < MonitorRestoreOrder(monitor: rhsMonitor)
            }
        }

        return false
    }
}

private struct RestoreAssignmentAccumulator {
    private(set) var assignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    private var usedMonitorIds: Set<Monitor.ID> = []
    private var assignedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

    mutating func assignUniqueUUIDs(snapshots: [WorkspaceRestoreSnapshot], monitors: [Monitor]) {
        let snapshotUUIDCounts = snapshots.reduce(into: [String: Int]()) { counts, snapshot in
            guard let displayUUID = snapshot.monitor.displayUUID else { return }
            counts[displayUUID, default: 0] += 1
        }
        let monitorUUIDCounts = monitors.reduce(into: [String: Int]()) { counts, monitor in
            guard let displayUUID = monitor.displayUUID else { return }
            counts[displayUUID, default: 0] += 1
        }

        for snapshot in snapshots {
            guard let displayUUID = snapshot.monitor.displayUUID,
                  snapshotUUIDCounts[displayUUID] == 1,
                  monitorUUIDCounts[displayUUID] == 1,
                  let exactMonitor = monitors.first(where: { $0.displayUUID == displayUUID })
            else {
                continue
            }
            assign(snapshot, to: exactMonitor)
        }
    }

    mutating func assignLegacyDisplays(snapshots: [WorkspaceRestoreSnapshot], monitors: [Monitor]) {
        for snapshot in snapshots {
            guard snapshot.monitor.displayUUID == nil,
                  !assignedWorkspaceIds.contains(snapshot.workspaceId),
                  let exactMonitor = monitors.first(where: {
                      !usedMonitorIds.contains($0.id) &&
                          $0.displayId == snapshot.monitor.displayId &&
                          Monitor.namesMatch($0.name, snapshot.monitor.name)
                  })
            else {
                continue
            }
            assign(snapshot, to: exactMonitor)
        }
    }

    mutating func assignRemaining(snapshots: [WorkspaceRestoreSnapshot], monitors: [Monitor]) {
        let remainingSnapshots = snapshots.filter {
            !assignedWorkspaceIds.contains($0.workspaceId)
        }
        let remainingMonitors = monitors.filter {
            !usedMonitorIds.contains($0.id)
        }
        let remainingAssignments = resolveBestRestoreMatches(
            snapshots: remainingSnapshots,
            monitors: remainingMonitors
        )
        for (snapshotIndex, monitorId) in remainingAssignments {
            assignments[monitorId] = remainingSnapshots[snapshotIndex].workspaceId
        }
    }

    private mutating func assign(_ snapshot: WorkspaceRestoreSnapshot, to monitor: Monitor) {
        guard usedMonitorIds.insert(monitor.id).inserted else { return }
        assignments[monitor.id] = snapshot.workspaceId
        assignedWorkspaceIds.insert(snapshot.workspaceId)
    }
}

func resolveWorkspaceRestoreAssignments(
    snapshots: [WorkspaceRestoreSnapshot],
    monitors: [Monitor],
    workspaceExists: (WorkspaceDescriptor.ID) -> Bool
) -> [Monitor.ID: WorkspaceDescriptor.ID] {
    guard !snapshots.isEmpty, !monitors.isEmpty else { return [:] }

    var filteredSnapshots: [WorkspaceRestoreSnapshot] = []
    var seenWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    filteredSnapshots.reserveCapacity(snapshots.count)

    for snapshot in snapshots {
        guard workspaceExists(snapshot.workspaceId) else { continue }
        guard seenWorkspaceIds.insert(snapshot.workspaceId).inserted else { continue }
        filteredSnapshots.append(snapshot)
    }

    filteredSnapshots.sort { lhs, rhs in
        MonitorRestoreOrder(restoreKey: lhs.monitor) < MonitorRestoreOrder(restoreKey: rhs.monitor)
    }

    let sortedMonitors = monitors.sorted { lhs, rhs in
        MonitorRestoreOrder(monitor: lhs) < MonitorRestoreOrder(monitor: rhs)
    }

    var result = RestoreAssignmentAccumulator()
    result.assignUniqueUUIDs(snapshots: filteredSnapshots, monitors: sortedMonitors)
    result.assignLegacyDisplays(snapshots: filteredSnapshots, monitors: sortedMonitors)
    result.assignRemaining(snapshots: filteredSnapshots, monitors: sortedMonitors)
    return result.assignments
}

private func resolveBestRestoreMatches(
    snapshots: [WorkspaceRestoreSnapshot],
    monitors: [Monitor]
) -> [Int: Monitor.ID] {
    guard !snapshots.isEmpty, !monitors.isEmpty else { return [:] }

    let monitorsById = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })

    func search(snapshotIndex: Int, availableMonitors: [Monitor]) -> RestoreMatchingResult {
        guard snapshotIndex < snapshots.count, !availableMonitors.isEmpty else {
            return RestoreMatchingResult()
        }

        let currentSnapshot = snapshots[snapshotIndex]
        // Monitor counts are small, so an exact search keeps restore matching
        // stable when a newly inserted display collides with a later exact fit.
        var bestResult = search(
            snapshotIndex: snapshotIndex + 1,
            availableMonitors: availableMonitors
        )

        for (monitorIndex, monitor) in availableMonitors.enumerated() {
            var nextMonitors = availableMonitors
            nextMonitors.remove(at: monitorIndex)

            let score = restoreMatchScore(snapshot: currentSnapshot.monitor, monitor: monitor)
            var candidate = search(
                snapshotIndex: snapshotIndex + 1,
                availableMonitors: nextMonitors
            )
            candidate.assignmentsBySnapshotIndex[snapshotIndex] = monitor.id
            candidate.assignedCount += 1
            candidate.totalNamePenalty += score.namePenalty
            candidate.totalGeometryDelta += score.geometryDelta

            if candidate.isPreferred(over: bestResult, snapshotIndices: snapshots.indices, monitorsById: monitorsById) {
                bestResult = candidate
            }
        }

        return bestResult
    }

    return search(snapshotIndex: 0, availableMonitors: monitors).assignmentsBySnapshotIndex
}

private func restoreMatchScore(
    snapshot: MonitorRestoreKey,
    monitor: Monitor
) -> (namePenalty: Int, geometryDelta: CGFloat) {
    let namePenalty = snapshot.name.localizedCaseInsensitiveCompare(monitor.name) == .orderedSame ? 0 : 1
    let anchorDistance = snapshot.anchorPoint.distanceSquared(to: monitor.workspaceAnchorPoint)
    let widthDelta = abs(snapshot.frameSize.width - monitor.frame.width)
    let heightDelta = abs(snapshot.frameSize.height - monitor.frame.height)
    let geometryDelta = anchorDistance + widthDelta + heightDelta
    return (namePenalty, geometryDelta)
}
