import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

@Suite struct MonitorRestoreAssignmentsTests {
    @Test func resolvesByDisplayIdWhenAvailable() {
        let left = makeMonitor(displayId: 100, name: "Dell", x: 0, y: 0)
        let right = makeMonitor(displayId: 200, name: "LG", x: 1920, y: 0)
        let wsLeft = WorkspaceDescriptor.ID()
        let wsRight = WorkspaceDescriptor.ID()

        let snapshots = [
            WorkspaceRestoreSnapshot(monitor: .init(monitor: left), workspaceId: wsLeft),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: right), workspaceId: wsRight)
        ]

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: [left, right],
            workspaceExists: { _ in true }
        )

        #expect(assignments[left.id] == wsLeft)
        #expect(assignments[right.id] == wsRight)
    }

    @Test func resolvesDuplicateMonitorNamesByGeometryFallback() {
        let oldLeft = makeMonitor(displayId: 10, name: "Studio Display", x: 0, y: 0)
        let oldRight = makeMonitor(displayId: 20, name: "Studio Display", x: 1920, y: 0)

        let newLeft = makeMonitor(displayId: 30, name: "Studio Display", x: 0, y: 0)
        let newRight = makeMonitor(displayId: 40, name: "Studio Display", x: 1920, y: 0)

        let wsLeft = WorkspaceDescriptor.ID()
        let wsRight = WorkspaceDescriptor.ID()

        let snapshots = [
            WorkspaceRestoreSnapshot(monitor: .init(monitor: oldRight), workspaceId: wsRight),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: oldLeft), workspaceId: wsLeft)
        ]

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: [newLeft, newRight],
            workspaceExists: { _ in true }
        )

        #expect(assignments[newLeft.id] == wsLeft)
        #expect(assignments[newRight.id] == wsRight)
    }

    @Test func filtersUnknownWorkspacesAndDuplicateWorkspaceSnapshots() {
        let left = makeMonitor(displayId: 500, name: "Left", x: 0, y: 0)
        let right = makeMonitor(displayId: 600, name: "Right", x: 1920, y: 0)
        let keptWorkspace = WorkspaceDescriptor.ID()
        let missingWorkspace = WorkspaceDescriptor.ID()

        let snapshots = [
            WorkspaceRestoreSnapshot(monitor: .init(monitor: left), workspaceId: keptWorkspace),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: right), workspaceId: keptWorkspace),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: right), workspaceId: missingWorkspace)
        ]

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: [left, right],
            workspaceExists: { $0 == keptWorkspace }
        )

        #expect(assignments.count == 1)
        #expect(assignments[left.id] == keptWorkspace)
        #expect(!assignments.values.contains(missingWorkspace))
    }

    @Test func assignmentCountIsBoundedWhenSnapshotsOutnumberMonitors() {
        let monitor1 = makeMonitor(displayId: 700, name: "M1", x: 0, y: 0)
        let monitor2 = makeMonitor(displayId: 800, name: "M2", x: 1920, y: 0)
        let oldExtra = makeMonitor(displayId: 900, name: "M3", x: 3840, y: 0)
        let ws1 = WorkspaceDescriptor.ID()
        let ws2 = WorkspaceDescriptor.ID()
        let ws3 = WorkspaceDescriptor.ID()

        let snapshots = [
            WorkspaceRestoreSnapshot(monitor: .init(monitor: monitor1), workspaceId: ws1),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: monitor2), workspaceId: ws2),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: oldExtra), workspaceId: ws3)
        ]

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: [monitor1, monitor2],
            workspaceExists: { _ in true }
        )

        #expect(assignments.count == 2)
        #expect(assignments[monitor1.id] == ws1)
        #expect(assignments[monitor2.id] == ws2)
        #expect(!assignments.values.contains(ws3))
    }
}
