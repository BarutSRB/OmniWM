// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

final class NiriSingleWindowOverrideRemovalTests: NiriInteractionTestCase {
    func testSpanSetBesideNeighborYieldsToFillAfterNeighborIsRemoved() throws {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = .fullScreen
        let workspaceId = WorkspaceDescriptor.ID()
        let survivor = addWindow(engine, pid: 6_681, to: workspaceId)
        let neighbor = addWindow(engine, pid: 6_682, to: workspaceId, after: survivor)
        let column = try XCTUnwrap(engine.findColumn(containing: survivor, in: workspaceId))
        var state = ViewportState()

        engine.setContainerPrimarySpan(
            column,
            change: .adjustProportion(10),
            context: interactionContext(for: workspaceId),
            state: &state
        )
        XCTAssertTrue(column.hasManualSingleWindowWidthOverride)

        _ = removeWindows([neighbor.token], from: engine, in: workspaceId)

        let expectedFrame = try fillFrame()
        XCTAssertFalse(column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(layout(engine, in: workspaceId)[survivor.token], expectedFrame)
    }

    func testMiddleColumnYieldsToFillAfterBothSideColumnsAreRemoved() throws {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = .fullScreen
        let workspaceId = WorkspaceDescriptor.ID()
        let left = addWindow(engine, pid: 6_683, to: workspaceId)
        let middle = addWindow(engine, pid: 6_684, to: workspaceId, after: left)
        let right = addWindow(engine, pid: 6_685, to: workspaceId, after: middle)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 3)
        let middleColumn = try XCTUnwrap(engine.findColumn(containing: middle, in: workspaceId))
        var state = ViewportState()

        engine.toggleContainerPrimarySpan(
            middleColumn,
            forwards: true,
            context: interactionContext(for: workspaceId),
            state: &state
        )
        XCTAssertTrue(middleColumn.hasManualSingleWindowWidthOverride)

        _ = removeWindows([left.token], from: engine, in: workspaceId)
        XCTAssertTrue(middleColumn.hasManualSingleWindowWidthOverride)

        _ = removeWindows([right.token], from: engine, in: workspaceId)

        let expectedFrame = try fillFrame()
        XCTAssertFalse(middleColumn.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(layout(engine, in: workspaceId)[middle.token], expectedFrame)
    }

    private func interactionContext(for workspaceId: WorkspaceDescriptor.ID) -> NiriInteractionContext {
        .init(
            workspaceId: workspaceId,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 0,
            orientation: .horizontal
        )
    }

    private func fillFrame() throws -> CGRect {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = .fullScreen
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 6_680, to: workspaceId)
        return try XCTUnwrap(layout(engine, in: workspaceId)[window.token])
    }
}

@MainActor
final class NiriSingleWindowOverrideCloseTests: XCTestCase {
    func testSpanCommandBesideNeighborYieldsToFillAfterNeighborWindowIsRemoved() throws {
        let controller = makeController()
        controller.settings.niriSingleWindowFit = .fullScreen
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let survivorToken = addWindow(pid: 891_021, windowId: 891_121, to: workspaceId, controller: controller)
        let closingToken = addWindow(pid: 891_022, windowId: 891_122, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let survivorNode = engine.addWindow(token: survivorToken, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(
            token: closingToken,
            to: workspaceId,
            afterSelection: survivorNode.id,
            focusedToken: survivorToken
        )

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = survivorNode.id
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: survivorToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        XCTAssertEqual(
            controller.commandHandler.performCommand(.setContainerPrimarySpan(.adjustProportion(10))),
            .executed
        )
        let column = try XCTUnwrap(engine.findColumn(containing: survivorNode, in: workspaceId))
        XCTAssertTrue(column.hasManualSingleWindowWidthOverride)

        _ = controller.workspaceManager.removeWindow(pid: closingToken.pid, windowId: closingToken.windowId)

        XCTAssertNil(engine.findNode(for: closingToken, in: workspaceId))
        XCTAssertFalse(column.hasManualSingleWindowWidthOverride)

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let plan = try XCTUnwrap(
            controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(
                    activeWorkspaces: [workspaceId],
                    useScrollAnimationPath: true
                ).first
            }
        )
        let frameChange = try XCTUnwrap(plan.diff.frameChanges.first { $0.token == survivorToken })
        XCTAssertEqual(frameChange.frame, controller.borderSafeFillFrame(for: monitor))
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriSingleWindowOverrideCloseTests-\(UUID().uuidString)", isDirectory: true)
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
}
