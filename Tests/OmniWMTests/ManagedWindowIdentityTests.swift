// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ManagedWindowIdentityTests: XCTestCase {
    func testWorkspaceManagerRejectsDuplicateWindowIdBeforeReconcileMutation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let firstWorkspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let secondWorkspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let windowId = 467_501
        let existingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_601), windowId: windowId),
            pid: 467_601,
            windowId: windowId,
            to: firstWorkspace
        )

        let returnedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_602), windowId: windowId),
            pid: 467_602,
            windowId: windowId,
            to: secondWorkspace,
            mode: .floating
        )

        XCTAssertEqual(returnedToken, existingToken)
        XCTAssertEqual(controller.workspaceManager.allEntries().map(\.token), [existingToken])
        XCTAssertEqual(controller.workspaceManager.entry(for: existingToken)?.workspaceId, firstWorkspace)
        XCTAssertEqual(controller.workspaceManager.entry(for: existingToken)?.mode, .tiling)
    }

    func testObservedAliasPIDUsesCanonicalManagedWindowToken() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let element = AXUIElementCreateApplication(467_921)
        let axRef = AXWindowRef(element: element, windowId: 467_923)
        let canonicalToken = controller.workspaceManager.addWindow(
            axRef,
            pid: 467_921,
            windowId: 467_923,
            to: workspaceId
        )

        XCTAssertEqual(
            controller.axEventHandler.canonicalObservedWindowToken(
                pid: 467_922,
                axRef: AXWindowRef(element: element, windowId: canonicalToken.windowId)
            ),
            canonicalToken
        )
    }

    func testKnownAlternateProxyElementCanonicalizesAcrossPartialScan() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalPID: pid_t = 467_930
        let helperPID: pid_t = 467_931
        let windowId = 467_932
        let logicalAXRef = AXWindowRef(element: AXUIElementCreateApplication(logicalPID), windowId: windowId)
        let helperAXRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            helperAXRef,
            pid: helperPID,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(
                pids: [logicalPID, helperPID],
                axRefs: [logicalAXRef, helperAXRef]
            )
        ])
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [helperPID], axRefs: [helperAXRef])
        ])

        let observedToken = controller.axEventHandler.canonicalObservedWindowToken(
            pid: logicalPID,
            axRef: logicalAXRef
        )

        XCTAssertEqual(observedToken, token)
        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: windowId)?.token, token)
    }

    func testStaleAXDestroyCannotRemoveReplacementIncarnation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId = 467_934
        let oldAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_935), windowId: windowId)
        let oldToken = controller.workspaceManager.addWindow(
            oldAXRef,
            pid: 467_935,
            windowId: windowId,
            to: workspaceId
        )
        let oldEntry = try XCTUnwrap(controller.workspaceManager.entry(for: oldToken))
        controller.axEventHandler.discardStaleManagedWindowIncarnation(oldEntry)
        let replacementAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(467_936),
            windowId: windowId
        )
        let replacementToken = controller.workspaceManager.addWindow(
            replacementAXRef,
            pid: 467_936,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.terminalFrameFailureStateByWindowId[windowId] = TerminalFrameFailureState(
            axRef: replacementAXRef,
            count: 1
        )

        controller.axEventHandler.handleRemoved(pid: oldToken.pid, winId: windowId, axRef: oldAXRef)

        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: windowId)?.token, replacementToken)
        XCTAssertEqual(controller.axEventHandler.terminalFrameFailureStateByWindowId[windowId]?.count, 1)
    }

    func testStaleAXDestroyCannotClearIdentitylessReplacementAdmission() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_940
        let replacementToken = WindowToken(pid: 467_941, windowId: Int(windowId))
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: replacementToken,
            axRef: nil,
            reason: .axWindowMissing,
            attempt: 1,
            generation: 1,
            trigger: .create,
            exhausted: false,
            task: nil
        )
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        let staleAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(467_942),
            windowId: Int(windowId)
        )

        controller.axEventHandler.handleRemoved(
            pid: 467_942,
            winId: Int(windowId),
            axRef: staleAXRef
        )

        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    func testKnownProxyCannotBypassAdmissionQuarantine() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId = 467_943
        let token = WindowToken(pid: 467_944, windowId: windowId)
        let refusedAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_944), windowId: windowId)
        let proxyAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_945), windowId: windowId)
        controller.axEventHandler.admissionQuarantineByWindowId[windowId] = AdmissionQuarantine(
            token: token,
            axRef: refusedAXRef
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(
                pids: [467_944, 467_945],
                axRefs: [refusedAXRef, proxyAXRef]
            )
        ])

        XCTAssertTrue(
            controller.axEventHandler.isAdmissionQuarantined(
                windowId: windowId,
                axRef: proxyAXRef
            )
        )
        XCTAssertNotNil(controller.axEventHandler.admissionQuarantineByWindowId[windowId])
    }

    func testChangedAXIncarnationCanReplaceExplicitlyRetiredWindowId() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId = 467_933
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_931), windowId: windowId),
            pid: 467_931,
            windowId: windowId,
            to: workspaceId
        )
        let oldEntry = try XCTUnwrap(controller.workspaceManager.entry(for: oldToken))

        controller.axEventHandler.discardStaleManagedWindowIncarnation(oldEntry)
        let replacementToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_932), windowId: windowId),
            pid: 467_932,
            windowId: windowId,
            to: workspaceId
        )

        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertEqual(replacementToken, WindowToken(pid: 467_932, windowId: windowId))
        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: windowId)?.token, replacementToken)
    }

    func testSuccessfulIdentityRebindConsumesPendingRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_973
        let token = WindowToken(pid: 467_974, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let identity = AXManagedWindowIdentity(token: token, axRef: axRef)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .identityRebind(
                    oldWindow: identity,
                    newWindow: identity,
                    managedReplacementMetadata: nil
                )
            )
        )

        let rebound = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: token,
            to: token,
            windowId: windowId,
            axRef: axRef
        )

        XCTAssertNotNil(rebound)
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }
}
