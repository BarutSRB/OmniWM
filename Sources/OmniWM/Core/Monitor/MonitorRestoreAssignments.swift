import CoreGraphics
import Foundation

struct MonitorRestoreKey: Hashable {
    let displayId: CGDirectDisplayID
    let name: String
    let anchorPoint: CGPoint
    let frameSize: CGSize

    init(monitor: Monitor) {
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
        frameSize = monitor.frame.size
    }
}

struct WorkspaceRestoreSnapshot: Hashable {
    let monitor: MonitorRestoreKey
    let workspaceId: WorkspaceDescriptor.ID
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
        snapshotSortKey(lhs.monitor) < snapshotSortKey(rhs.monitor)
    }

    let sortedMonitors = monitors.sorted { lhs, rhs in
        monitorRestoreSortKey(lhs) < monitorRestoreSortKey(rhs)
    }

    var assignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    var usedMonitorIds: Set<Monitor.ID> = []

    for snapshot in filteredSnapshots {
        guard let exactMonitor = sortedMonitors.first(where: { $0.displayId == snapshot.monitor.displayId }) else {
            continue
        }
        guard usedMonitorIds.insert(exactMonitor.id).inserted else { continue }
        assignments[exactMonitor.id] = snapshot.workspaceId
    }

    for snapshot in filteredSnapshots where !assignments.values.contains(snapshot.workspaceId) {
        let remaining = sortedMonitors.filter { !usedMonitorIds.contains($0.id) }
        guard let best = remaining.min(by: { lhs, rhs in
            isBetterRestoreCandidate(lhs, than: rhs, for: snapshot.monitor)
        }) else {
            continue
        }

        usedMonitorIds.insert(best.id)
        assignments[best.id] = snapshot.workspaceId
    }

    return assignments
}

private func isBetterRestoreCandidate(_ lhs: Monitor, than rhs: Monitor, for snapshot: MonitorRestoreKey) -> Bool {
    let lhsScore = restoreMatchScore(snapshot: snapshot, monitor: lhs)
    let rhsScore = restoreMatchScore(snapshot: snapshot, monitor: rhs)

    if lhsScore.namePenalty != rhsScore.namePenalty {
        return lhsScore.namePenalty < rhsScore.namePenalty
    }
    if lhsScore.geometryDelta != rhsScore.geometryDelta {
        return lhsScore.geometryDelta < rhsScore.geometryDelta
    }
    return monitorRestoreSortKey(lhs) < monitorRestoreSortKey(rhs)
}

private func restoreMatchScore(snapshot: MonitorRestoreKey, monitor: Monitor) -> (namePenalty: Int, geometryDelta: CGFloat) {
    let namePenalty = snapshot.name.localizedCaseInsensitiveCompare(monitor.name) == .orderedSame ? 0 : 1
    let anchorDistance = snapshot.anchorPoint.distanceSquared(to: monitor.workspaceAnchorPoint)
    let widthDelta = abs(snapshot.frameSize.width - monitor.frame.width)
    let heightDelta = abs(snapshot.frameSize.height - monitor.frame.height)
    let geometryDelta = anchorDistance + widthDelta + heightDelta
    return (namePenalty, geometryDelta)
}

private func snapshotSortKey(_ snapshot: MonitorRestoreKey) -> (CGFloat, CGFloat, UInt32) {
    (snapshot.anchorPoint.x, -snapshot.anchorPoint.y, snapshot.displayId)
}

private func monitorRestoreSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
    (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
