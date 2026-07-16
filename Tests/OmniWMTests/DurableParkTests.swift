// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DurableParkTests: XCTestCase {
    func testAnimationTickParkStaysPendingUntilConfirmed() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(951_001), windowId: 951_101),
            pid: 951_001, windowId: 951_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)

        let onscreenFrame = CGRect(x: 100, y: 16, width: 800, height: 600)
        var physicalFrame = onscreenFrame
        controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
            queriedToken == token ? physicalFrame : nil
        }

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        let parkOrigin = try XCTUnwrap(controller.axManager.skyLightLivePosition(for: token.windowId))

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertNil(controller.axManager.skyLightLivePosition(for: token.windowId))

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertNotNil(controller.axManager.skyLightLivePosition(for: token.windowId))

        physicalFrame = CGRect(origin: parkOrigin, size: onscreenFrame.size)
        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertNotNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testShowClearsPendingPark() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(952_001), windowId: 952_101),
            pid: 952_001, windowId: 952_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.axManager.confirmFrameWrite(
            for: token.windowId,
            frame: CGRect(x: 100, y: 16, width: 800, height: 600)
        )

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))

        var showDiff = WorkspaceLayoutDiff()
        showDiff.visibilityChanges.append(.show(token))
        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.plan(workspaceId: workspaceId, monitor: monitor, diff: showDiff)
            )
        )
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCompletedWriteOnParkedWindowRemarksPending() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(954_001), windowId: 954_101),
            pid: 954_001, windowId: 954_101, to: workspaceId
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.right)
            ),
            for: token
        )
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))

        let stragglerFrame = CGRect(x: -857, y: 16, width: 1256, height: 1378)
        controller.axManager.handleFrameApplyResults([
            AXFrameApplyResult(
                pid: token.pid,
                windowId: token.windowId,
                targetFrame: stragglerFrame,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    targetFrame: stragglerFrame,
                    observedFrame: stragglerFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            )
        ])
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))

        controller.workspaceManager.setHiddenState(nil, for: token)
        controller.axManager.clearParkPending(for: token.windowId, pid: token.pid, reason: "test")
        controller.axManager.handleFrameApplyResults([
            AXFrameApplyResult(
                pid: token.pid,
                windowId: token.windowId,
                targetFrame: stragglerFrame,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    targetFrame: stragglerFrame,
                    observedFrame: stragglerFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            )
        ])
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
    }

    func testStragglerLandingAfterParkBlocksClearUntilSettle() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(955_001), windowId: 955_101),
            pid: 955_001, windowId: 955_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)

        let onscreenFrame = CGRect(x: 100, y: 16, width: 800, height: 600)
        var physicalFrame = onscreenFrame
        controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
            queriedToken == token ? physicalFrame : nil
        }

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        let parkOrigin = try XCTUnwrap(controller.axManager.skyLightLivePosition(for: token.windowId))
        physicalFrame = CGRect(origin: parkOrigin, size: onscreenFrame.size)

        let stragglerFrame = CGRect(x: -202, y: 16, width: 800, height: 600)
        controller.axManager.handleFrameApplyResults([
            AXFrameApplyResult(
                pid: token.pid,
                windowId: token.windowId,
                targetFrame: stragglerFrame,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    targetFrame: stragglerFrame,
                    observedFrame: stragglerFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            )
        ])

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token, isAnimationTick: false)
            )
        )
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testFrameChangedSkipsWindowServerQueryWhileScrollAnimating() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(956_001), windowId: 956_101),
            pid: 956_001, windowId: 956_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)

        var providerCalls = 0
        controller.axEventHandler.windowInfoProvider = { _ in
            providerCalls += 1
            return nil
        }

        controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] = workspaceId
        controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
        XCTAssertEqual(providerCalls, 0)

        controller.niriLayoutHandler.scrollAnimationByDisplay.removeAll()
        controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
        XCTAssertGreaterThan(providerCalls, 0)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testRemovingWindowClearsParkPendingBookkeeping() {
        let controller = Self.controller()
        let axManager = controller.axManager

        axManager.markParkPending(for: 42, pid: 953_001)
        XCTAssertTrue(axManager.pendingParkWindowIds.contains(42))

        axManager.removeWindowState(pid: 953_001, windowId: 42)
        XCTAssertFalse(axManager.pendingParkWindowIds.contains(42))
    }

    private static func hidePlan(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        token: WindowToken,
        isAnimationTick: Bool = true
    ) -> WorkspaceLayoutPlan {
        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges.append(.hide(token, side: .right))
        return plan(workspaceId: workspaceId, monitor: monitor, diff: diff, isAnimationTick: isAnimationTick)
    }

    private static func plan(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        diff: WorkspaceLayoutDiff,
        isAnimationTick: Bool = true
    ) -> WorkspaceLayoutPlan {
        WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: LayoutMonitorSnapshot(
                monitorId: monitor.id,
                displayId: monitor.displayId,
                frame: monitor.frame,
                visibleFrame: monitor.visibleFrame,
                workingFrame: monitor.visibleFrame,
                fullscreenLayoutFrame: monitor.visibleFrame,
                scale: 1,
                orientation: monitor.autoOrientation
            ),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId, viewportState: nil),
            diff: diff,
            isAnimationTick: isAnimationTick
        )
    }

    private static func monitor() -> Monitor {
        Monitor(
            id: .init(displayId: 77),
            displayId: 77,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
            hasNotch: false,
            name: "DurablePark"
        )
    }

    private static func controller() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDurableParkTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }
}
