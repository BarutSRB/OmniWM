// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriFocusPreviousTests: XCTestCase {
    private struct EngineFixture {
        let engine: NiriLayoutEngine
        let workspaceA: WorkspaceDescriptor.ID
        let workspaceB: WorkspaceDescriptor.ID
        let windowA1: NiriWindow
        let windowA2: NiriWindow
        let windowB: NiriWindow
    }

    func testGlobalMRUFindsCrossWorkspaceWindow() {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)
        fixture.windowA2.lastFocusedTime = timestamp(2)
        fixture.windowB.lastFocusedTime = timestamp(3)

        let global = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: nil
        )
        let scoped = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: fixture.workspaceA
        )

        XCTAssertEqual(global?.token, fixture.windowB.token)
        XCTAssertEqual(scoped?.token, fixture.windowA2.token)
    }

    func testGlobalMRUPrefersNewerSameWorkspaceWindow() {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)
        fixture.windowB.lastFocusedTime = timestamp(2)
        fixture.windowA2.lastFocusedTime = timestamp(3)

        let global = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: nil
        )

        XCTAssertEqual(global?.token, fixture.windowA2.token)
    }

    func testUnstampedWindowsExcluded() {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)

        let onlyExcludedStamped = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: nil
        )
        let noExcludedWindow = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: nil,
            in: nil
        )

        XCTAssertNil(onlyExcludedStamped)
        XCTAssertEqual(noExcludedWindow?.token, fixture.windowA1.token)
    }

    func testToggleAlternatesAcrossWorkspaces() throws {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)
        fixture.windowB.lastFocusedTime = timestamp(2)

        let firstTarget = try XCTUnwrap(
            fixture.engine.findMostRecentlyFocusedWindow(
                excluding: fixture.windowB.id,
                in: nil
            )
        )
        fixture.windowB.lastFocusedTime = timestamp(3)
        firstTarget.lastFocusedTime = timestamp(4)

        let secondTarget = try XCTUnwrap(
            fixture.engine.findMostRecentlyFocusedWindow(
                excluding: firstTarget.id,
                in: nil
            )
        )

        XCTAssertEqual(firstTarget.token, fixture.windowA1.token)
        XCTAssertEqual(secondTarget.token, fixture.windowB.token)
    }

    func testEmptyCurrentWorkspaceFindsRemoteWindow() {
        let engine = NiriLayoutEngine()
        let emptyWorkspace = WorkspaceDescriptor.ID()
        let remoteWorkspace = WorkspaceDescriptor.ID()
        _ = engine.ensureRoot(for: emptyWorkspace)
        let remoteWindow = engine.addWindow(
            token: token(1),
            to: remoteWorkspace,
            afterSelection: nil
        )
        remoteWindow.lastFocusedTime = timestamp(1)

        let target = engine.findMostRecentlyFocusedWindow(excluding: nil, in: nil)

        XCTAssertEqual(target?.token, remoteWindow.token)
    }

    func testCommandFocusPreviousJumpsToWindowOnAnotherWorkspace() throws {
        let controller = makeController()
        let workspaceA = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let workspaceB = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "2")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokenA = addWindow(pid: 447_001, windowId: 447_101, to: workspaceA, controller: controller)
        let tokenB = addWindow(pid: 447_002, windowId: 447_102, to: workspaceB, controller: controller)
        let nodeA = engine.addWindow(token: tokenA, to: workspaceA, afterSelection: nil)
        let nodeB = engine.addWindow(token: tokenB, to: workspaceB, afterSelection: nil)
        nodeA.lastFocusedTime = timestamp(1)
        nodeB.lastFocusedTime = timestamp(2)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeB.id,
            focusedToken: tokenB,
            in: workspaceB,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceB)
        )

        let result = controller.commandHandler.handleHotkeyCommand(.focusPrevious)

        XCTAssertEqual(result, .executed)
        XCTAssertEqual(controller.activeWorkspace()?.id, workspaceA)
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceA).selectedNodeId, nodeA.id)
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceB).selectedNodeId, nodeB.id)
    }

    private func makeEngineFixture() -> EngineFixture {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let windowA1 = engine.addWindow(token: token(1), to: workspaceA, afterSelection: nil)
        let windowA2 = engine.addWindow(token: token(2), to: workspaceA, afterSelection: windowA1.id)
        let windowB = engine.addWindow(token: token(3), to: workspaceB, afterSelection: nil)
        return EngineFixture(
            engine: engine,
            workspaceA: workspaceA,
            workspaceB: workspaceB,
            windowA1: windowA1,
            windowA2: windowA2,
            windowB: windowB
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriFocusPreviousTests-\(UUID().uuidString)", isDirectory: true)
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

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func token(_ index: Int) -> WindowToken {
        WindowToken(pid: 447, windowId: index)
    }

    private func timestamp(_ order: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 447 + order)
    }
}
