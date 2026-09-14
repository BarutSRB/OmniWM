// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorldTransactionClockTests: XCTestCase {
    func testClockReentrancyRecordsNestedCommitFirstAndReleasesMutationSanction() throws {
        weak var currentWorld: WorldStore?
        var clockReads = 0
        var phases: [String] = []
        let nestedEvent = WMEvent.userCommand(workspaceId: nil, label: "nested-clock", source: .command)
        let outerEvent = WMEvent.userCommand(workspaceId: nil, label: "outer-clock", source: .command)
        let snapshot = ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(),
            windows: []
        )
        let world = WorldStore {
            clockReads += 1
            let timestamp = Date(timeIntervalSince1970: Double(clockReads))
            guard let world = currentWorld else {
                XCTFail("Clock must only run after WorldStore initialization")
                return timestamp
            }
            XCTAssertTrue(world.isEngineMutationSanctioned)
            phases.append("clock:\(clockReads)")
            if clockReads == 1 {
                _ = world.commit(nestedEvent, monitors: [], snapshot: { snapshot }, resolvePlan: { plan, _, _ in
                    phases.append("resolve:nested")
                    return plan
                })
            }
            return timestamp
        }
        currentWorld = world
        XCTAssertEqual(clockReads, 0)
        let transaction = world.commit(outerEvent, monitors: [], snapshot: { snapshot }, resolvePlan: { plan, _, _ in
            phases.append("resolve:outer")
            return plan
        })

        XCTAssertEqual(phases, ["resolve:outer", "clock:1", "resolve:nested", "clock:2"])
        XCTAssertEqual(transaction.timestamp, Date(timeIntervalSince1970: 1))
        let records = world.traceRecords()
        XCTAssertEqual(records.map(\.event), [nestedEvent, outerEvent])
        XCTAssertEqual(records.map(\.sequence), [1, 2])
        XCTAssertEqual(records.map(\.timestamp), [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 1)])
        XCTAssertTrue(records.allSatisfy { $0.invariantViolations.isEmpty })
        XCTAssertEqual(world.invariantViolationCountsDump(), "clean")
        XCTAssertEqual(world.seq, 2)
        XCTAssertFalse(world.isEngineMutationSanctioned)
    }
}
