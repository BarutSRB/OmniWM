// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionRetryIdentityTests: XCTestCase {
    func testActiveIdentitylessRetryBindsConcreteIdentityWithoutRestarting() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_973
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: nil,
                reason: .windowInfoMissing,
                trigger: .create
            )
        )
        let initial = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        let token = WindowToken(pid: 467_974, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)

        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .factsDeferred
            )
        )

        let bound = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(bound.attempt, initial.attempt)
        XCTAssertEqual(bound.generation, initial.generation)
        XCTAssertEqual(bound.expectedToken, token)
        XCTAssertTrue(CFEqual(bound.axRef?.element, axRef.element))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testExhaustedIdentitylessRetryRestartsForConcreteIdentity() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_975
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: nil,
            axRef: nil,
            reason: .windowInfoMissing,
            attempt: AXEventHandler.createdWindowRetryLimit,
            generation: 77,
            trigger: .create,
            exhausted: true,
            task: nil
        )
        let token = WindowToken(pid: 467_976, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)

        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .factsDeferred
            )
        )

        let restarted = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(restarted.attempt, 1)
        XCTAssertNotEqual(restarted.generation, 77)
        XCTAssertFalse(restarted.exhausted)
        XCTAssertEqual(restarted.expectedToken, token)
        XCTAssertTrue(CFEqual(restarted.axRef?.element, axRef.element))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testLaterIdentitylessObservationDoesNotEraseConcreteIdentity() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_977
        let token = WindowToken(pid: 467_978, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .factsDeferred
            )
        )
        let concrete = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])

        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: nil,
                reason: .windowInfoMissing,
                trigger: .create
            )
        )

        let retained = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(retained.attempt, concrete.attempt)
        XCTAssertEqual(retained.generation, concrete.generation)
        XCTAssertEqual(retained.expectedToken, token)
        XCTAssertTrue(CFEqual(retained.axRef?.element, axRef.element))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testDistinctConcreteIdentityRestartsRetryBudget() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_979
        let oldToken = WindowToken(pid: 467_980, windowId: Int(windowId))
        let oldAXRef = AXWindowRef(element: AXUIElementCreateApplication(oldToken.pid), windowId: oldToken.windowId)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: oldToken,
            axRef: oldAXRef,
            reason: .factsDeferred,
            attempt: 4,
            generation: 81,
            trigger: .candidate(token: oldToken, axRef: oldAXRef),
            exhausted: false,
            task: nil
        )
        let replacementToken = WindowToken(pid: 467_981, windowId: Int(windowId))
        let replacementAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(replacementToken.pid),
            windowId: replacementToken.windowId
        )

        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: replacementToken.pid,
                axRef: replacementAXRef,
                reason: .degenerateGeometry
            )
        )

        let restarted = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(restarted.attempt, 1)
        XCTAssertNotEqual(restarted.generation, 81)
        XCTAssertEqual(restarted.expectedToken, replacementToken)
        XCTAssertTrue(CFEqual(restarted.axRef?.element, replacementAXRef.element))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }
}
