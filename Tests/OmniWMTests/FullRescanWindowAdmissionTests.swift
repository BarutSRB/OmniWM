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

    func testFullRescanPreservesManagedStateUntilDestinationAXContextCanRebind() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalPID: pid_t = 467_937
        let helperPID: pid_t = 467_938
        let windowId = 467_939
        let logicalAXRef = AXWindowRef(element: AXUIElementCreateApplication(logicalPID), windowId: windowId)
        let helperAXRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let oldToken = controller.workspaceManager.addWindow(
            logicalAXRef,
            pid: logicalPID,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let observedAliases = FullRescanWindowIdentityAliases(
            pids: [logicalPID, helperPID],
            axRefs: [logicalAXRef, helperAXRef]
        )

        let resolution = controller.axEventHandler.resolveFullRescanIdentity(
            axRef: helperAXRef,
            pid: helperPID,
            windowId: windowId,
            observedAliases: observedAliases
        )

        guard case let .preserve(preservedToken) = resolution else {
            return XCTFail("Expected existing identity to remain authoritative until AX rebind")
        }
        XCTAssertEqual(preservedToken, oldToken)
        XCTAssertEqual(controller.workspaceManager.entry(for: oldToken)?.workspaceId, workspaceId)
        XCTAssertEqual(controller.workspaceManager.entry(for: oldToken)?.mode, .floating)
        let retryState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)]
        )
        guard case let .identityRebind(oldWindow, newWindow, _, _, _) = retryState.trigger else {
            return XCTFail("Expected an identity-rebind retry")
        }
        XCTAssertEqual(oldWindow.token, oldToken)
        XCTAssertEqual(newWindow.token, WindowToken(pid: helperPID, windowId: windowId))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: UInt32(windowId))
    }

    func testFailedExistingEndpointCannotBeRetiredByUnprovenCandidate() throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let existingPID: pid_t = 46_793
        let candidatePID: pid_t = 46_794
        let windowId = 46_795
        let existingAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(existingPID),
            windowId: windowId
        )
        let candidateAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(candidatePID),
            windowId: windowId
        )
        let existingToken = controller.workspaceManager.addWindow(
            existingAXRef,
            pid: existingPID,
            windowId: windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.niriEngine?.addWindow(token: existingToken, to: workspaceId, afterSelection: nil)
        }

        let resolution = controller.axEventHandler.resolveFullRescanIdentity(
            axRef: candidateAXRef,
            pid: candidatePID,
            windowId: windowId,
            observedAliases: .init(pids: [candidatePID], axRefs: [candidateAXRef]),
            failedPIDs: [existingPID]
        )

        guard case let .preserve(preservedToken) = resolution else {
            return XCTFail("Expected failed existing endpoint to remain authoritative")
        }
        XCTAssertEqual(preservedToken, existingToken)
        let retained = try XCTUnwrap(controller.workspaceManager.entry(for: existingToken))
        XCTAssertTrue(CFEqual(retained.axRef.element, existingAXRef.element))
        XCTAssertNotNil(controller.niriEngine?.findNode(for: existingToken, in: workspaceId))
        XCTAssertNil(controller.workspaceManager.entry(for: WindowToken(pid: candidatePID, windowId: windowId)))
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
