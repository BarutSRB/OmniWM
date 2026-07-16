// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FullRescanWindowAdmissionTests: XCTestCase {
    func testFullRescanProbesRegularAppsWithoutVisibleProcessEvidence() {
        XCTAssertTrue(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .regular,
                hasDiscoveryEvidence: false
            )
        )
        XCTAssertTrue(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: true
            )
        )
        XCTAssertFalse(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false
            )
        )
        XCTAssertFalse(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .prohibited,
                hasDiscoveryEvidence: true
            )
        )
    }

    func testFullRescanPrefersPreservedLogicalPIDOverWindowServerOwner() {
        let windowId = 467_001
        let preservedPID: pid_t = 467_002
        let ownerPID: pid_t = 467_003
        let preserved = candidate(pid: preservedPID, windowId: windowId)
        let owner = candidate(pid: ownerPID, windowId: windowId)

        XCTAssertTrue(
            AXManager.shouldPreferFullRescanCandidate(
                preserved,
                over: owner,
                activationPolicyByPID: [preservedPID: .regular, ownerPID: .regular],
                ownerPID: ownerPID,
                existingPID: preservedPID
            )
        )
    }

    private func candidate(pid: pid_t, windowId: Int) -> FullRescanWindowCandidate {
        FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: CGRect(x: 0, y: 0, width: 640, height: 480)
                )
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: .persistent
        )
    }
}
