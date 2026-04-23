// SPDX-License-Identifier: GPL-2.0-only
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
    @Test func emptyInputsProduceNoAssignments() {
        let workspaceId = WorkspaceDescriptor.ID()

        #expect(
            resolveWorkspaceRestoreAssignments(
                snapshots: [],
                monitors: [makeMonitor(displayId: 1000, name: "Solo", x: 0, y: 0)],
                workspaceExists: { $0 == workspaceId }
            )
                .isEmpty
        )

        #expect(
            resolveWorkspaceRestoreAssignments(
                snapshots: [
                    WorkspaceRestoreSnapshot(
                        monitor: .init(monitor: makeMonitor(displayId: 1001, name: "Solo", x: 0, y: 0)),
                        workspaceId: workspaceId
                    )
                ],
                monitors: [],
                workspaceExists: { $0 == workspaceId }
            )
                .isEmpty
        )
    }

    @Test func filteringAwayAllSnapshotsProducesNoAssignments() {
        let monitor = makeMonitor(displayId: 100, name: "Solo", x: 0, y: 0)
        let workspaceId = WorkspaceDescriptor.ID()

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(monitor: .init(monitor: monitor), workspaceId: workspaceId)
            ],
            monitors: [monitor],
            workspaceExists: { _ in false }
        )

        #expect(assignments.isEmpty)
    }

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

    @Test func exactDisplayIdTakesPrecedenceOverCloserFallbackGeometry() {
        let exactButFar = makeMonitor(displayId: 300, name: "Studio", x: 5000, y: 0)
        let closerButInexact = makeMonitor(displayId: 400, name: "Studio", x: 0, y: 0)
        let snapshotMonitor = makeMonitor(displayId: 300, name: "Studio", x: 0, y: 0)
        let workspaceId = WorkspaceDescriptor.ID()

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(monitor: .init(monitor: snapshotMonitor), workspaceId: workspaceId)
            ],
            monitors: [closerButInexact, exactButFar],
            workspaceExists: { $0 == workspaceId }
        )

        #expect(assignments[exactButFar.id] == workspaceId)
        #expect(assignments[closerButInexact.id] == nil)
    }

    @Test func exactDisplayIdMatchTakesPrecedenceOverCloserGeometry() {
        let oldMonitor = makeMonitor(displayId: 100, name: "Center", x: 1000, y: 0)
        let exactButFar = makeMonitor(displayId: 100, name: "Center", x: 4000, y: 0)
        let closerButDifferentId = makeMonitor(displayId: 200, name: "Center", x: 1000, y: 0)
        let workspaceId = WorkspaceDescriptor.ID()

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(monitor: .init(monitor: oldMonitor), workspaceId: workspaceId)
            ],
            monitors: [closerButDifferentId, exactButFar],
            workspaceExists: { _ in true }
        )

        #expect(assignments[exactButFar.id] == workspaceId)
        #expect(assignments[closerButDifferentId.id] == nil)
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

    @Test func lowerNamePenaltyWinsBeforeGeometryDelta() {
        let snapshot = makeMonitor(displayId: 500, name: "Studio Display", x: 0, y: 0)
        let geometryMatchWrongName = makeMonitor(displayId: 510, name: "Other", x: 0, y: 0)
        let fartherNameMatch = makeMonitor(displayId: 520, name: "Studio Display", x: 300, y: 0)
        let workspaceId = WorkspaceDescriptor.ID()

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(monitor: .init(monitor: snapshot), workspaceId: workspaceId)
            ],
            monitors: [geometryMatchWrongName, fartherNameMatch],
            workspaceExists: { $0 == workspaceId }
        )

        #expect(assignments[fartherNameMatch.id] == workspaceId)
        #expect(assignments[geometryMatchWrongName.id] == nil)
    }

    @Test func lowerGeometryDeltaWinsWhenNamePenaltyTies() {
        let snapshot = makeMonitor(displayId: 530, name: "Dell", x: 0, y: 0)
        let farther = makeMonitor(displayId: 540, name: "Dell", x: 3000, y: 0)
        let nearer = makeMonitor(displayId: 550, name: "Dell", x: 200, y: 0)
        let workspaceId = WorkspaceDescriptor.ID()

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(monitor: .init(monitor: snapshot), workspaceId: workspaceId)
            ],
            monitors: [farther, nearer],
            workspaceExists: { $0 == workspaceId }
        )

        #expect(assignments[nearer.id] == workspaceId)
        #expect(assignments[farther.id] == nil)
    }

    @Test func higherAssignedCountWinsBeforeLowerPenaltyOrGeometry() {
        let snapshot1 = makeMonitor(displayId: 600, name: "Matched", x: 0, y: 0)
        let snapshot2 = makeMonitor(displayId: 610, name: "Second", x: 2000, y: 0)
        let firstMonitor = makeMonitor(displayId: 700, name: "Matched", x: 0, y: 0)
        let secondMonitor = makeMonitor(displayId: 710, name: "Other", x: 2000, y: 0)
        let workspace1 = WorkspaceDescriptor.ID()
        let workspace2 = WorkspaceDescriptor.ID()

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(monitor: .init(monitor: snapshot1), workspaceId: workspace1),
                WorkspaceRestoreSnapshot(monitor: .init(monitor: snapshot2), workspaceId: workspace2)
            ],
            monitors: [firstMonitor, secondMonitor],
            workspaceExists: { _ in true }
        )

        #expect(assignments.count == 2)
        #expect(assignments[firstMonitor.id] == workspace1)
        #expect(assignments[secondMonitor.id] == workspace2)
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

    @Test func equalGeometryTiesResolveUsingStableSnapshotOrder() {
        let oldLeft = makeMonitor(displayId: 10, name: "Old Left", x: 0, y: 0)
        let oldRight = makeMonitor(displayId: 20, name: "Old Right", x: 2000, y: 0)

        let newCenter = makeMonitor(displayId: 30, name: "New Center", x: 1000, y: 0)
        let newFar = makeMonitor(displayId: 40, name: "New Far", x: 3000, y: 0)

        let wsLeft = WorkspaceDescriptor.ID()
        let wsRight = WorkspaceDescriptor.ID()

        let snapshots = [
            WorkspaceRestoreSnapshot(monitor: .init(monitor: oldRight), workspaceId: wsRight),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: oldLeft), workspaceId: wsLeft)
        ]

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: [newCenter, newFar],
            workspaceExists: { _ in true }
        )

        #expect(assignments[newCenter.id] == wsLeft)
        #expect(assignments[newFar.id] == wsRight)
    }

    @Test func insertedMonitorDoesNotStealLaterExactGeometryMatch() {
        let oldCenter = makeMonitor(displayId: 10, name: "Center", x: 1000, y: 0)
        let oldRight = makeMonitor(displayId: 20, name: "Right", x: 3000, y: 0)
        let wsCenter = WorkspaceDescriptor.ID()
        let wsRight = WorkspaceDescriptor.ID()

        let snapshots = [
            WorkspaceRestoreSnapshot(monitor: .init(monitor: oldRight), workspaceId: wsRight),
            WorkspaceRestoreSnapshot(monitor: .init(monitor: oldCenter), workspaceId: wsCenter)
        ]

        let newLeft = makeMonitor(displayId: 30, name: "Left", x: 0, y: 0)
        let newCenter = makeMonitor(displayId: 40, name: "Center", x: 1000, y: 0)
        let newRight = makeMonitor(displayId: 50, name: "Right", x: 3000, y: 0)

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: snapshots,
            monitors: [newLeft, newCenter, newRight],
            workspaceExists: { _ in true }
        )

        #expect(assignments[newLeft.id] == nil)
        #expect(assignments[newCenter.id] == wsCenter)
        #expect(assignments[newRight.id] == wsRight)
    }
}

@Suite struct MonitorGeometryTests {
    @Test func sharedCornerUsesHalfOpenBoundsForFallbackMonitorApproximation() {
        let left = makeMonitor(displayId: 10, name: "Left", x: 0, y: 0, width: 100, height: 100)
        let right = makeMonitor(displayId: 20, name: "Right", x: 100, y: 0, width: 100, height: 100)

        let point = CGPoint(x: 100, y: 100)
        let approximated = point.monitorApproximation(in: [left, right])

        #expect(approximated?.id == right.id)
    }
}
