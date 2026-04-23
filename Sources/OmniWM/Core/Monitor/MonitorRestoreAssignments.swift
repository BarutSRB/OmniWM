// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
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

    guard !filteredSnapshots.isEmpty else { return [:] }

    var snapshotInputs = ContiguousArray<omniwm_restore_snapshot>()
    snapshotInputs.reserveCapacity(filteredSnapshots.count)
    for snapshot in filteredSnapshots {
        snapshotInputs.append(
            omniwm_restore_snapshot(
                display_id: snapshot.monitor.displayId,
                anchor_x: snapshot.monitor.anchorPoint.x,
                anchor_y: snapshot.monitor.anchorPoint.y,
                frame_width: snapshot.monitor.frameSize.width,
                frame_height: snapshot.monitor.frameSize.height
            )
        )
    }

    var monitorInputs = ContiguousArray<omniwm_restore_monitor>()
    monitorInputs.reserveCapacity(monitors.count)
    for monitor in monitors {
        monitorInputs.append(
            omniwm_restore_monitor(
                display_id: monitor.displayId,
                frame_min_x: monitor.frame.minX,
                frame_max_y: monitor.frame.maxY,
                anchor_x: monitor.workspaceAnchorPoint.x,
                anchor_y: monitor.workspaceAnchorPoint.y,
                frame_width: monitor.frame.width,
                frame_height: monitor.frame.height
            )
        )
    }

    var namePenalties = ContiguousArray<UInt8>()
    namePenalties.reserveCapacity(filteredSnapshots.count * monitors.count)
    for snapshot in filteredSnapshots {
        for monitor in monitors {
            namePenalties.append(
                snapshot.monitor.name.localizedCaseInsensitiveCompare(monitor.name) == .orderedSame ? 0 : 1
            )
        }
    }

    var rawAssignments = ContiguousArray(
        repeating: omniwm_restore_assignment(snapshot_index: 0, monitor_index: 0),
        count: min(filteredSnapshots.count, monitors.count)
    )
    var rawAssignmentCount = 0

    let status = snapshotInputs.withUnsafeBufferPointer { snapshotBuffer in
        monitorInputs.withUnsafeBufferPointer { monitorBuffer in
            namePenalties.withUnsafeBufferPointer { penaltyBuffer in
                rawAssignments.withUnsafeMutableBufferPointer { assignmentBuffer in
                    omniwm_restore_resolve_assignments(
                        snapshotBuffer.baseAddress,
                        snapshotBuffer.count,
                        monitorBuffer.baseAddress,
                        monitorBuffer.count,
                        penaltyBuffer.baseAddress,
                        penaltyBuffer.count,
                        assignmentBuffer.baseAddress,
                        assignmentBuffer.count,
                        &rawAssignmentCount
                    )
                }
            }
        }
    }

    precondition(
        status == OMNIWM_KERNELS_STATUS_OK,
        "omniwm_restore_resolve_assignments returned \(status)"
    )

    var assignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    assignments.reserveCapacity(rawAssignmentCount)

    for assignment in rawAssignments.prefix(rawAssignmentCount) {
        assignments[monitors[Int(assignment.monitor_index)].id] =
            filteredSnapshots[Int(assignment.snapshot_index)].workspaceId
    }

    return assignments
}
