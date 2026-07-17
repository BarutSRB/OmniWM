// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ManagedFocusAdmissionTests: XCTestCase {
    func testUnexpectedActivationClearsManagedCommandTargetBeforeFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_211), windowId: 467_221),
            pid: 467_211,
            windowId: 467_221,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(pid: 467_212, source: .cgsFrontAppChanged)

        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.focusedToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testConflictingExternalActivationCancelsPendingCommandTargetBeforeFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_901), windowId: 467_902),
            pid: 467_901,
            windowId: 467_902,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(pid: token.pid + 1, source: .cgsFrontAppChanged)

        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.focusedToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testKnownAXPidAliasPreservesPendingCommandTargetBeforeFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalPID: pid_t = 467_903
        let axPID: pid_t = 467_904
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(axPID), windowId: 467_905),
            pid: logicalPID,
            windowId: 467_905,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(pid: axPID, source: .cgsFrontAppChanged)

        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, token)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
    }

    func testSupersededActivationFactsCannotRestoreStaleCommandTarget() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let managedPID: pid_t = 467_911
        let externalPID: pid_t = 467_912
        let windowId = 467_913
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(managedPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: managedPID,
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
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: managedPID, source: .cgsFrontAppChanged)
        controller.axEventHandler.handleAppActivation(pid: externalPID, source: .cgsFrontAppChanged)

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: managedPID,
                source: .cgsFrontAppChanged,
                origin: .external,
                observationGeneration: 1,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.focusedToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testStaleFocusedRetryCannotSupersedeNewerExternalActivation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let firstPID: pid_t = 467_914
        let secondPID: pid_t = 467_915
        let firstToken = WindowToken(pid: firstPID, windowId: 467_916)
        let secondToken = WindowToken(pid: secondPID, windowId: 467_917)
        _ = WindowAdmissionTestSupport.track(firstToken, in: workspaceId, controller: controller)
        let secondAXRef = WindowAdmissionTestSupport.track(secondToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                firstToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: firstPID, source: .cgsFrontAppChanged)
        controller.axEventHandler.handleAppActivation(pid: secondPID, source: .cgsFrontAppChanged)

        controller.axEventHandler.handleAppActivation(
            pid: firstPID,
            source: .focusedWindowChanged,
            origin: .retry,
            causalObservationGeneration: 1
        )
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: secondPID,
                source: .cgsFrontAppChanged,
                origin: .external,
                observationGeneration: 2,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: secondAXRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertEqual(controller.workspaceManager.focusedToken, secondToken)
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
    }

    func testStaleFocusedRetryRetiresBeforeFocusPolicySuppression() {
        let controller = WindowAdmissionTestSupport.controller()
        let stalePID: pid_t = 467_920
        let currentPID: pid_t = 467_921
        let windowId: UInt32 = 467_922
        let token = WindowToken(pid: stalePID, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(stalePID), windowId: token.windowId)
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: stalePID, source: .focusedWindowChanged)
        controller.axEventHandler.handleAppActivation(pid: currentPID, source: .focusedWindowChanged)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .workspaceDidActivateApplication,
                    observationGeneration: 1,
                    callbackGeneration: nil
                )
            )
        )
        controller.focusPolicyEngine.beginLease(
            owner: .nativeMenu,
            reason: "test",
            duration: nil
        )

        controller.axEventHandler.handleAppActivation(
            pid: stalePID,
            source: .workspaceDidActivateApplication,
            origin: .retry,
            causalObservationGeneration: 1
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }
}
