// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ManagedFocusAliasAdmissionTests: XCTestCase {
    func testFullRescanObserverPIDAliasPreservesManagedFocusRequest() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let observerPID: pid_t = 467_927
        let helperPID: pid_t = 467_928
        let windowId = 467_929
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: helperPID,
            windowId: windowId,
            to: workspaceId
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [observerPID, helperPID], axRefs: [axRef])
        ])
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(pid: observerPID, source: .cgsFrontAppChanged)
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: observerPID,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 1,
                requestedAtSeq: controller.intentLedger.intent(id: request.requestId)?.issuedAtSeq ?? 0,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, token)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
    }

    func testMissingFocusedWindowFromObserverPIDAliasPreservesConfirmedManagedFocus() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let observerPID: pid_t = 467_946
        let helperPID: pid_t = 467_947
        let windowId = 467_948
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: helperPID,
            windowId: windowId,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [observerPID, helperPID], axRefs: [axRef])
        ])
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: observerPID, source: .focusedWindowChanged)

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: observerPID,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 1,
                requestedAtSeq: 0,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.focusedToken, token)
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
    }
}
