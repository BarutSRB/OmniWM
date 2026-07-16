// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionPolicyTests: XCTestCase {
    func testMeaningfulAdmissionFrameRejectsOneByOneProxyGeometry() {
        XCTAssertFalse(WMController.isMeaningfulAdmissionFrame(CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertFalse(WMController.isMeaningfulAdmissionFrame(CGRect(x: 0, y: 0, width: 1, height: 400)))
        XCTAssertTrue(WMController.isMeaningfulAdmissionFrame(CGRect(x: 0, y: 0, width: 640, height: 480)))
    }

    func testExplicitUserRuleCannotBypassTilingManageability() {
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 467_101
        let windowId = 467_102
        let windowInfo = WindowServerInfo(
            id: UInt32(windowId),
            pid: pid,
            level: 0,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let evaluation = explicitProxyEvaluation(pid: pid, windowId: windowId, windowInfo: windowInfo)

        XCTAssertTrue(
            controller.shouldDeferTilingAdmission(
                evaluation: evaluation,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                windowInfo: windowInfo
            )
        )
    }

    func testManualTilePromotionDefersUnmanageableFloatingWindow() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_918
        let windowId = 467_919
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )

        XCTAssertEqual(controller.toggleFocusedWindowFloating(), .executed)

        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
        XCTAssertEqual(controller.workspaceManager.manualLayoutOverride(for: token), .forceTile)
        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)])

        XCTAssertEqual(controller.toggleFocusedWindowFloating(), .executed)

        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)])
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: UInt32(windowId), spaceId: 0))
    }
}

private func explicitProxyEvaluation(
    pid: pid_t,
    windowId: Int,
    windowInfo: WindowServerInfo
) -> WMController.WindowDecisionEvaluation {
    let facts = WindowRuleFacts(
        appName: "Proxy",
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Proxy",
            hasCloseButton: true,
            hasFullscreenButton: true,
            fullscreenButtonEnabled: true,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: "example.proxy",
            attributeFetchSucceeded: true
        ),
        sizeConstraints: nil,
        windowServer: windowInfo
    )
    return WMController.WindowDecisionEvaluation(
        token: WindowToken(pid: pid, windowId: windowId),
        facts: facts,
        decision: WindowDecision(
            disposition: .managed,
            source: .userRule(UUID()),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        ),
        appFullscreen: false,
        manualOverride: nil,
        admissionGeometry: WindowAdmissionGeometryEvidence(
            isSizeSettable: true,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    )
}
