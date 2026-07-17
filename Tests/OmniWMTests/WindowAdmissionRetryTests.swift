// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionRetryTests: XCTestCase {
    func testMissingWindowInfoRetryRecordsTypedReason() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_201
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        controller.axEventHandler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))

        let trace = controller.axEventHandler.createFocusTraceDump()
        XCTAssertTrue(trace.contains("window=\(windowId) pid=nil reason=window_info_missing attempt=1"))
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testRetryExhaustionSurvivesPIDAliasUntilAXIncarnationChanges() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_403
        let firstToken = WindowToken(pid: 467_303, windowId: Int(windowId))
        let firstAXRef = AXWindowRef(element: AXUIElementCreateApplication(firstToken.pid), windowId: Int(windowId))
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: firstToken,
            axRef: firstAXRef,
            reason: .degenerateGeometry,
            attempt: AXEventHandler.createdWindowRetryLimit,
            generation: 1,
            trigger: .candidate(token: firstToken, axRef: firstAXRef),
            exhausted: true,
            task: nil
        )

        let aliasToken = WindowToken(pid: firstToken.pid + 1, windowId: Int(windowId))
        XCTAssertFalse(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: aliasToken,
                axRef: firstAXRef,
                reason: .degenerateGeometry,
                trigger: .candidate(token: aliasToken, axRef: firstAXRef)
            )
        )
        XCTAssertEqual(
            controller.axEventHandler.admissionRetryStateByWindowId[windowId]?.attempt,
            AXEventHandler.createdWindowRetryLimit
        )

        let replacementAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(aliasToken.pid + 1),
            windowId: Int(windowId)
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: aliasToken,
                axRef: replacementAXRef,
                reason: .degenerateGeometry,
                trigger: .candidate(token: aliasToken, axRef: replacementAXRef)
            )
        )
        XCTAssertEqual(controller.axEventHandler.admissionRetryStateByWindowId[windowId]?.attempt, 1)
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testCreateRetryCannotReplaceConcreteCandidateTrigger() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_405
        let token = WindowToken(pid: 467_305, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        )

        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: nil,
                axRef: axRef,
                reason: .windowInfoMissing,
                trigger: .create
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(state.expectedToken, token)
        XCTAssertTrue(CFEqual(state.axRef?.element, axRef.element))
        guard case let .candidate(triggerToken, triggerAXRef) = state.trigger else {
            return XCTFail("Expected concrete candidate retry")
        }
        XCTAssertEqual(triggerToken, token)
        XCTAssertTrue(CFEqual(triggerAXRef.element, axRef.element))
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testCandidateRetryCannotReplaceFocusedRetrySemantics() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_406
        let token = WindowToken(pid: 467_306, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .focusedWindowChanged,
                    observationGeneration: 7,
                    callbackGeneration: nil
                )
            )
        )

        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        guard case let .focused(triggerToken, source, observationGeneration, _) = state.trigger else {
            return XCTFail("Expected focused retry")
        }
        XCTAssertEqual(triggerToken, token)
        XCTAssertEqual(source, .focusedWindowChanged)
        XCTAssertEqual(observationGeneration, 7)
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testSuccessfulLowerPriorityAdmissionConsumesFocusedRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_407
        let token = WindowToken(pid: 467_307, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .focusedWindowChanged,
                    observationGeneration: 7,
                    callbackGeneration: nil
                )
            )
        )
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )

        controller.axEventHandler.finishAdmissionRetryAfterTracking(windowId: windowId)

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    func testKnownProxyElementsShareRetryPriorityAndBudget() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_408
        let logicalToken = WindowToken(pid: 467_308, windowId: Int(windowId))
        let helperToken = WindowToken(pid: 467_309, windowId: Int(windowId))
        let logicalAXRef = WindowAdmissionTestSupport.axRef(for: logicalToken)
        let helperAXRef = WindowAdmissionTestSupport.axRef(for: helperToken)
        controller.axEventHandler.updateIdentityAliases([
            Int(windowId): .init(
                pids: [logicalToken.pid, helperToken.pid],
                axRefs: [logicalAXRef, helperAXRef]
            )
        ])
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: helperToken.pid,
                axRef: helperAXRef,
                reason: .degenerateGeometry
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: logicalToken,
                axRef: logicalAXRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: logicalToken,
                    source: .focusedWindowChanged,
                    observationGeneration: 9,
                    callbackGeneration: nil
                )
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: helperToken.pid,
                axRef: helperAXRef,
                reason: .degenerateGeometry
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(state.attempt, 1)
        guard case .focused = state.trigger else {
            return XCTFail("Expected focused retry")
        }
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testAppTerminationRetiresAdmissionRetryAndOnlyItsIdentityAliases() {
        let controller = WindowAdmissionTestSupport.controller()
        let terminatedPID: pid_t = 467_310
        let survivingPID: pid_t = 467_311
        let windowId: UInt32 = 467_409
        let token = WindowToken(pid: terminatedPID, windowId: Int(windowId))
        let terminatedAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(terminatedPID),
            windowId: token.windowId
        )
        let survivingAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(survivingPID),
            windowId: token.windowId
        )
        controller.axEventHandler.updateIdentityAliases([
            Int(windowId): .init(
                pids: [terminatedPID, survivingPID],
                axRefs: [terminatedAXRef, survivingAXRef]
            )
        ])
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: terminatedAXRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .focusedWindowChanged,
                    observationGeneration: 7,
                    callbackGeneration: nil
                )
            )
        )

        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: terminatedPID)

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(
            controller.axEventHandler.identityAliasesByWindowId[Int(windowId)]?.current?.pids,
            [survivingPID]
        )
        XCTAssertEqual(
            controller.axEventHandler.identityAliasesByWindowId[Int(windowId)]?.current?.axRefs.count,
            1
        )
    }
}
