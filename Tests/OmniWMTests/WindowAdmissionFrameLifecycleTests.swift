// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionFrameLifecycleTests: XCTestCase {
    func testFrameLedgerEmitsTerminalSizeRefusalAfterSingleRetry() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_301
        let windowId = 467_401
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 0, y: 0, width: 1, height: 1)
        let failure = AXFrameWriteFailureReason.sizeWriteFailed(.attributeUnsupported)

        let firstRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(ledger, pid: pid, windowId: windowId, frame: target)
        )
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: firstRequest,
                observed: observed,
                failure: failure
            )
        ])
        XCTAssertEqual(firstOutcome.retries, [AXFrameRetryRequest(pid: pid, windowId: windowId, frame: target)])
        XCTAssertTrue(firstOutcome.terminalRefusals.isEmpty)

        let retryRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger, pid: pid, windowId: windowId, frame: target, isRetry: true
            )
        )
        let retryOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: retryRequest,
                observed: observed,
                failure: failure
            )
        ])

        XCTAssertEqual(
            retryOutcome.terminalRefusals,
            [
                AXFrameTerminalRefusal(
                    pid: pid,
                    windowId: windowId,
                    targetFrame: target,
                    observedFrame: observed,
                    failureReason: failure
                )
            ]
        )
        XCTAssertTrue(retryOutcome.retries.isEmpty)
    }

    func testFrameLedgerDoesNotAcceptStaleSuccessForQuarantineReset() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_302
        let windowId = 467_402
        let firstTarget = CGRect(x: 20, y: 30, width: 640, height: 480)
        let secondTarget = CGRect(x: 40, y: 50, width: 800, height: 600)
        let firstRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                frame: firstTarget,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        let secondRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                frame: secondTarget,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        var acceptedWindowIds: [Int] = []

        _ = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: firstRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertTrue(acceptedWindowIds.isEmpty)

        _ = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: secondRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertEqual(acceptedWindowIds, [windowId])
    }

    func testFrameLedgerRejectsOldIncarnationResultAfterStateRemoval() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_304
        let windowId = 467_404
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let oldRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        _ = ledger.removeWindowState(windowId: windowId)
        let newRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid + 1,
                windowId: windowId,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        var acceptedWindowIds: [Int] = []

        _ = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: oldRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertTrue(acceptedWindowIds.isEmpty)

        _ = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: newRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertEqual(acceptedWindowIds, [windowId])
    }

    func testRepeatedDegenerateTerminalRefusalRemovesAndQuarantinesIncarnation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_701
        let windowId = 467_801
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let proxyAXRef = AXWindowRef(element: AXUIElementCreateApplication(pid + 1), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [pid, pid + 1], axRefs: [axRef, proxyAXRef])
        ])
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let refusal = AXFrameTerminalRefusal(
            pid: pid,
            windowId: windowId,
            targetFrame: CGRect(x: 20, y: 30, width: 640, height: 480),
            observedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            failureReason: .sizeWriteFailed(.attributeUnsupported)
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertTrue(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: axRef))
        XCTAssertTrue(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: proxyAXRef))
        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertEqual(controller.workspaceManager.nonManagedFocusToken, token)

        let replacement = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 2),
            windowId: windowId
        )
        XCTAssertFalse(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: replacement))
    }

    func testBackgroundPendingFocusTerminalRefusalPreservesConfirmedFocus() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let refusedPID: pid_t = 467_711
        let focusedPID: pid_t = 467_712
        let refusedWindowId = 467_811
        let focusedWindowId = 467_812
        let refusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(refusedPID), windowId: refusedWindowId),
            pid: refusedPID,
            windowId: refusedWindowId,
            to: workspaceId
        )
        let focusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(focusedPID), windowId: focusedWindowId),
            pid: focusedPID,
            windowId: focusedWindowId,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                focusedToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(
            token: refusedToken,
            workspaceId: workspaceId
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            refusedToken,
            in: workspaceId,
            requestId: request.requestId
        )
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, refusedToken)
        let refusal = AXFrameTerminalRefusal(
            pid: refusedPID,
            windowId: refusedWindowId,
            targetFrame: CGRect(x: 20, y: 30, width: 640, height: 480),
            observedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            failureReason: .sizeWriteFailed(.attributeUnsupported)
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        controller.axEventHandler.handleTerminalFrameRefusal(refusal)

        XCTAssertNil(controller.workspaceManager.entry(for: refusedToken))
        XCTAssertEqual(controller.workspaceManager.focusedToken, focusedToken)
        XCTAssertEqual(controller.workspaceManager.renderableFocusToken, focusedToken)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
    }
}
