// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceDeletionEngineCleanupTests: XCTestCase {
    func testDeletingEmptiedWorkspaceRemovesNiriEngineState() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let workspaceId = try makeTransientWorkspace(named: "97", controller: controller)
        let token = WindowToken(pid: 900, windowId: 1)
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 900),
            displayId: 900,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Cleanup"
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            engine.syncWorkspaceAssignments([(workspaceId: workspaceId, monitor: monitor)])
        }
        let niriMonitor = try XCTUnwrap(engine.monitor(for: monitor.id))
        XCTAssertNotNil(engine.root(for: workspaceId))
        XCTAssertTrue(niriMonitor.containsWorkspace(workspaceId))

        removeTransientWorkspace(named: "97", controller: controller)

        XCTAssertNil(controller.workspaceManager.workspaceId(named: "97"))
        XCTAssertNil(engine.root(for: workspaceId))
        XCTAssertNil(engine.findNode(for: token, in: workspaceId))
        XCTAssertFalse(niriMonitor.containsWorkspace(workspaceId))
    }

    func testDeletingEmptiedWorkspaceRemovesDwindleEngineState() throws {
        let controller = makeController()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "98", controller: controller)
        let token = WindowToken(pid: 901, windowId: 1)
        controller.workspaceManager.withEngineMutationScope {
            engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
        }
        XCTAssertNotNil(engine.root(for: workspaceId))

        removeTransientWorkspace(named: "98", controller: controller)

        XCTAssertNil(controller.workspaceManager.workspaceId(named: "98"))
        XCTAssertNil(engine.root(for: workspaceId))
        XCTAssertNil(engine.findNode(for: token, in: workspaceId))
        XCTAssertNil(engine.selectedNode(in: workspaceId))
        XCTAssertEqual(engine.windowCount(in: workspaceId), 0)
    }

    func testDwindleRemoveWindowWithMismatchedWorkspaceLeavesTreesIntact() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let tokenA1 = WindowToken(pid: 902, windowId: 1)
        let tokenA2 = WindowToken(pid: 902, windowId: 2)
        let tokenB = WindowToken(pid: 903, windowId: 1)
        engine.addWindow(token: tokenA1, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: tokenA2, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: tokenB, to: workspaceB, activeWindowFrame: nil)
        let selectionA = engine.selectedNode(in: workspaceA)?.id
        let selectionB = engine.selectedNode(in: workspaceB)?.id

        engine.removeWindow(token: tokenA1, from: workspaceB)

        XCTAssertTrue(engine.containsWindow(tokenA1, in: workspaceA))
        XCTAssertNotNil(engine.findNode(for: tokenA1, in: workspaceA))
        XCTAssertEqual(engine.windowCount(in: workspaceA), 2)
        XCTAssertEqual(engine.windowCount(in: workspaceB), 1)
        XCTAssertEqual(engine.selectedNode(in: workspaceA)?.id, selectionA)
        XCTAssertEqual(engine.selectedNode(in: workspaceB)?.id, selectionB)
    }

    func testDwindleRemoveLayoutPreservesOtherWorkspaceIndexForStaleToken() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 904, windowId: 1)
        let minSize = CGSize(width: 200, height: 150)
        engine.addWindow(token: token, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: token, to: workspaceB, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: token,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )

        engine.removeLayout(for: workspaceA)

        XCTAssertNil(engine.root(for: workspaceA))
        XCTAssertNotNil(engine.findNode(for: token, in: workspaceB))
        XCTAssertTrue(engine.containsWindow(token, in: workspaceB))
        XCTAssertEqual(engine.constraints(for: token).minSize, minSize)
    }

    func testDwindleRemoveLayoutKeepsDuplicateTokenIsolatedInSurvivingWorkspace() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 907, windowId: 1)
        let minSize = CGSize(width: 240, height: 180)
        let leafInA = engine.addWindow(token: token, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: token, to: workspaceB, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: token,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )

        engine.removeLayout(for: workspaceB)

        XCTAssertNil(engine.root(for: workspaceB))
        XCTAssertTrue(engine.findNode(for: token, in: workspaceA) === leafInA)
        XCTAssertTrue(engine.containsWindow(token, in: workspaceA))
        XCTAssertEqual(engine.windowCount(in: workspaceA), 1)
        XCTAssertEqual(engine.constraints(for: token).minSize, minSize)
    }

    func testDwindleSyncPrunesStaleDuplicateLeafWithoutTouchingIndexedRoot() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 908, windowId: 1)
        let minSize = CGSize(width: 220, height: 160)
        engine.addWindow(token: token, to: workspaceA, activeWindowFrame: nil)
        let leafInB = engine.addWindow(token: token, to: workspaceB, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: token,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )

        let removed = engine.syncWindows([], in: workspaceA, focusedToken: nil)

        XCTAssertEqual(removed, [token])
        XCTAssertFalse(engine.containsWindow(token, in: workspaceA))
        XCTAssertEqual(engine.windowCount(in: workspaceA), 0)
        XCTAssertTrue(engine.findNode(for: token, in: workspaceB) === leafInB)
        XCTAssertTrue(engine.containsWindow(token, in: workspaceB))
        XCTAssertEqual(engine.constraints(for: token).minSize, minSize)
    }

    func testDwindleSyncRemovalKeepsDuplicateTokenIsolatedInOtherWorkspace() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 909, windowId: 1)
        let minSize = CGSize(width: 260, height: 170)
        let leafInA = engine.addWindow(token: token, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: token, to: workspaceB, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: token,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )

        let removed = engine.syncWindows([], in: workspaceB, focusedToken: nil)

        XCTAssertEqual(removed, [token])
        XCTAssertFalse(engine.containsWindow(token, in: workspaceB))
        XCTAssertTrue(engine.findNode(for: token, in: workspaceA) === leafInA)
        XCTAssertTrue(engine.containsWindow(token, in: workspaceA))
        XCTAssertEqual(engine.constraints(for: token).minSize, minSize)
    }

    func testDwindleSiblingPromotionLeavesOtherWorkspaceTreeIsolated() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 913, windowId: 1)
        let neighborToken = WindowToken(pid: 913, windowId: 2)
        let minSize = CGSize(width: 230, height: 150)
        engine.addWindow(token: token, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: neighborToken, to: workspaceA, activeWindowFrame: nil)
        let leafInB = engine.addWindow(token: token, to: workspaceB, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: token,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )

        engine.removeWindow(token: neighborToken, from: workspaceA)

        XCTAssertTrue(engine.findNode(for: token, in: workspaceB) === leafInB)
        XCTAssertNotNil(engine.findNode(for: token, in: workspaceA))
        XCTAssertTrue(engine.containsWindow(token, in: workspaceA))
        XCTAssertTrue(engine.containsWindow(token, in: workspaceB))
        XCTAssertEqual(engine.windowCount(in: workspaceA), 1)
        XCTAssertEqual(engine.constraints(for: token).minSize, minSize)
    }

    func testDwindleRekeyInRequestedWorkspaceLeavesDuplicateInOtherWorkspace() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 914, windowId: 1)
        let newToken = WindowToken(pid: 914, windowId: 2)
        let minSize = CGSize(width: 250, height: 155)
        engine.addWindow(token: oldToken, to: workspaceA, activeWindowFrame: nil)
        let leafInB = engine.addWindow(token: oldToken, to: workspaceB, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: oldToken,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )

        XCTAssertTrue(engine.rekeyWindow(from: oldToken, to: newToken, in: workspaceA))

        XCTAssertTrue(engine.findNode(for: oldToken, in: workspaceB) === leafInB)
        XCTAssertTrue(engine.containsWindow(newToken, in: workspaceA))
        XCTAssertFalse(engine.containsWindow(oldToken, in: workspaceA))
        XCTAssertEqual(engine.constraints(for: oldToken).minSize, minSize)
        XCTAssertEqual(engine.constraints(for: newToken).minSize, minSize)
    }

    func testDwindleRekeyMovesOnlyLocalLeafAndKeepsOtherWorkspaceToken() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 915, windowId: 1)
        let newToken = WindowToken(pid: 915, windowId: 2)
        let minSize = CGSize(width: 270, height: 165)
        let leafInB = engine.addWindow(token: oldToken, to: workspaceB, activeWindowFrame: nil)
        let leafInA = engine.addWindow(token: oldToken, to: workspaceA, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: oldToken,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )
        XCTAssertTrue(engine.findNode(for: oldToken, in: workspaceA) === leafInA)

        XCTAssertTrue(engine.rekeyWindow(from: oldToken, to: newToken, in: workspaceA))

        XCTAssertNil(engine.findNode(for: oldToken, in: workspaceA))
        XCTAssertTrue(engine.findNode(for: oldToken, in: workspaceB) === leafInB)
        XCTAssertTrue(engine.findNode(for: newToken, in: workspaceA) === leafInA)
        XCTAssertTrue(engine.containsWindow(oldToken, in: workspaceB))
        XCTAssertEqual(engine.constraints(for: oldToken).minSize, minSize)
        XCTAssertEqual(engine.constraints(for: newToken).minSize, minSize)
    }

    func testDwindleSingleRootRekeyMovesIndexAndConstraints() {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 916, windowId: 1)
        let newToken = WindowToken(pid: 916, windowId: 2)
        let minSize = CGSize(width: 205, height: 145)
        let leaf = engine.addWindow(token: oldToken, to: workspace, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: oldToken,
            constraints: WindowSizeConstraints(minSize: minSize, maxSize: .zero, isFixed: false)
        )

        XCTAssertTrue(engine.rekeyWindow(from: oldToken, to: newToken, in: workspace))

        XCTAssertNil(engine.findNode(for: oldToken, in: workspace))
        XCTAssertEqual(engine.constraints(for: oldToken), .unconstrained)
        XCTAssertTrue(engine.findNode(for: newToken, in: workspace) === leaf)
        XCTAssertEqual(engine.constraints(for: newToken).minSize, minSize)
    }

    func testDwindleSingleRootRemovalDropsIndexAndConstraintsAndFallsBackSelection() {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let keptToken = WindowToken(pid: 910, windowId: 1)
        let removedToken = WindowToken(pid: 910, windowId: 2)
        engine.addWindow(token: keptToken, to: workspace, activeWindowFrame: nil)
        engine.addWindow(token: removedToken, to: workspace, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: removedToken,
            constraints: WindowSizeConstraints(minSize: CGSize(width: 210, height: 140), maxSize: .zero, isFixed: false)
        )

        engine.removeWindow(token: removedToken, from: workspace)

        XCTAssertNil(engine.findNode(for: removedToken, in: workspace))
        XCTAssertEqual(engine.constraints(for: removedToken), .unconstrained)
        XCTAssertFalse(engine.containsWindow(removedToken, in: workspace))
        XCTAssertEqual(engine.windowCount(in: workspace), 1)
        XCTAssertEqual(engine.selectedNode(in: workspace)?.windowToken, keptToken)
    }

    func testDwindleSplitOfStaleDuplicateLeafDoesNotStealForeignIndex() throws {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let sharedToken = WindowToken(pid: 918, windowId: 1)
        let newToken = WindowToken(pid: 918, windowId: 2)
        engine.addWindow(token: sharedToken, to: workspaceA, activeWindowFrame: nil)
        let leafInB = engine.addWindow(token: sharedToken, to: workspaceB, activeWindowFrame: nil)

        let newLeaf = engine.addWindow(token: newToken, to: workspaceA, activeWindowFrame: nil)

        XCTAssertTrue(engine.findNode(for: sharedToken, in: workspaceB) === leafInB)
        XCTAssertTrue(engine.root(for: workspaceB) === leafInB)
        XCTAssertTrue(leafInB.isLeaf)
        XCTAssertEqual(leafInB.windowToken, sharedToken)
        XCTAssertEqual(engine.windowCount(in: workspaceB), 1)
        let relocatedLeafInA = try XCTUnwrap(engine.findNode(for: sharedToken, in: workspaceA))
        XCTAssertFalse(relocatedLeafInA === leafInB)
        XCTAssertEqual(relocatedLeafInA.windowToken, sharedToken)
        XCTAssertTrue(engine.findNode(for: newToken, in: workspaceA) === newLeaf)
        XCTAssertEqual(engine.windowCount(in: workspaceA), 2)
    }

    func testDwindleSwapResolvesNeighborLocallyAndLeavesForeignTreeUntouched() throws {
        let engine = DwindleLayoutEngine()
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let sharedToken = WindowToken(pid: 919, windowId: 1)
        let localToken = WindowToken(pid: 919, windowId: 2)
        engine.addWindow(token: sharedToken, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: localToken, to: workspaceA, activeWindowFrame: nil)
        let leafInB = engine.addWindow(token: sharedToken, to: workspaceB, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceA, screen: screen)
        _ = engine.calculateLayout(for: workspaceB, screen: screen)
        let sharedLeafInA = try XCTUnwrap(engine.findNode(for: sharedToken, in: workspaceA))
        let localLeafInA = try XCTUnwrap(engine.findNode(for: localToken, in: workspaceA))
        let frameInB = leafInB.cachedFrame

        let outcome = engine.swapWindowOutcome(direction: .left, in: workspaceA)

        XCTAssertEqual(outcome, .movedWithinWorkspace)
        XCTAssertTrue(engine.findNode(for: sharedToken, in: workspaceA) === localLeafInA)
        XCTAssertTrue(engine.findNode(for: localToken, in: workspaceA) === sharedLeafInA)
        XCTAssertEqual(engine.selectedNode(in: workspaceA)?.windowToken, localToken)
        XCTAssertTrue(engine.findNode(for: sharedToken, in: workspaceB) === leafInB)
        XCTAssertTrue(engine.root(for: workspaceB) === leafInB)
        XCTAssertTrue(leafInB.isLeaf)
        XCTAssertEqual(leafInB.windowToken, sharedToken)
        XCTAssertFalse(leafInB.isFullscreen)
        XCTAssertEqual(leafInB.cachedFrame, frameInB)
        XCTAssertEqual(engine.windowCount(in: workspaceB), 1)
    }

    func testDwindleFullscreenQueryIsScopedToWorkspaceTree() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 905, windowId: 1)
        let tokenB = WindowToken(pid: 905, windowId: 2)
        engine.addWindow(token: token, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: tokenB, to: workspaceB, activeWindowFrame: nil)
        XCTAssertEqual(engine.toggleFullscreen(in: workspaceA), token)

        XCTAssertTrue(engine.isWindowFullscreen(token, in: workspaceA))
        XCTAssertFalse(engine.isWindowFullscreen(token, in: workspaceB))
    }

    func testNiriFullscreenQueryIsScopedToWorkspaceTree() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 906, windowId: 1)
        let tokenB = WindowToken(pid: 906, windowId: 2)
        let node = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        _ = engine.addWindow(token: tokenB, to: workspaceB, afterSelection: nil)
        node.sizingMode = .fullscreen

        XCTAssertTrue(engine.isWindowFullscreen(token, in: workspaceA))
        XCTAssertFalse(engine.isWindowFullscreen(token, in: workspaceB))
    }

    func testWorldViewFullscreenQueryIgnoresDormantEngineState() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let niriWorkspaceId = try makeTransientWorkspace(named: "95", layoutType: .niri, controller: controller)
        let dwindleWorkspaceId = try makeTransientWorkspace(named: "96", layoutType: .dwindle, controller: controller)
        let quietDwindleWorkspaceId = try makeTransientWorkspace(
            named: "94",
            layoutType: .dwindle,
            controller: controller
        )
        let niriToken = addManagedWindow(pid: 911, windowId: 1, to: niriWorkspaceId, controller: controller)
        let dwindleToken = addManagedWindow(pid: 912, windowId: 2, to: dwindleWorkspaceId, controller: controller)
        let quietToken = addManagedWindow(pid: 917, windowId: 3, to: quietDwindleWorkspaceId, controller: controller)

        controller.workspaceManager.withEngineMutationScope {
            _ = niriEngine.addWindow(token: niriToken, to: niriWorkspaceId, afterSelection: nil)
            dwindleEngine.addWindow(token: niriToken, to: niriWorkspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.toggleFullscreen(in: niriWorkspaceId)
            dwindleEngine.addWindow(token: dwindleToken, to: dwindleWorkspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.toggleFullscreen(in: dwindleWorkspaceId)
            _ = niriEngine.addWindow(token: dwindleToken, to: dwindleWorkspaceId, afterSelection: nil)
            dwindleEngine.addWindow(token: quietToken, to: quietDwindleWorkspaceId, activeWindowFrame: nil)
            let staleNiriNode = niriEngine.addWindow(
                token: quietToken,
                to: quietDwindleWorkspaceId,
                afterSelection: nil
            )
            staleNiriNode.sizingMode = .fullscreen
        }

        let world = WorldView(controller: controller)
        XCTAssertTrue(dwindleEngine.isWindowFullscreen(niriToken, in: niriWorkspaceId))
        XCTAssertFalse(niriEngine.isWindowFullscreen(niriToken, in: niriWorkspaceId))
        XCTAssertFalse(world.isWindowFullscreenInLayout(niriToken))
        XCTAssertTrue(dwindleEngine.isWindowFullscreen(dwindleToken, in: dwindleWorkspaceId))
        XCTAssertFalse(niriEngine.isWindowFullscreen(dwindleToken, in: dwindleWorkspaceId))
        XCTAssertTrue(world.isWindowFullscreenInLayout(dwindleToken))
        XCTAssertTrue(niriEngine.isWindowFullscreen(quietToken, in: quietDwindleWorkspaceId))
        XCTAssertFalse(dwindleEngine.isWindowFullscreen(quietToken, in: quietDwindleWorkspaceId))
        XCTAssertFalse(world.isWindowFullscreenInLayout(quietToken))
    }

    func testDwindleFailedScopedRekeyIsRepairedByNextSync() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 920, windowId: 1)
        let newToken = WindowToken(pid: 920, windowId: 2)
        let tokenB = WindowToken(pid: 920, windowId: 3)
        engine.addWindow(token: oldToken, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: tokenB, to: workspaceB, activeWindowFrame: nil)

        XCTAssertFalse(engine.rekeyWindow(from: oldToken, to: newToken, in: workspaceB))
        XCTAssertTrue(engine.containsWindow(oldToken, in: workspaceA))
        XCTAssertFalse(engine.containsWindow(newToken, in: workspaceA))

        let removed = engine.syncWindows([newToken], in: workspaceA, focusedToken: nil)

        XCTAssertEqual(removed, [oldToken])
        XCTAssertFalse(engine.containsWindow(oldToken, in: workspaceA))
        XCTAssertTrue(engine.containsWindow(newToken, in: workspaceA))
        XCTAssertEqual(engine.windowCount(in: workspaceA), 1)
        XCTAssertTrue(engine.containsWindow(tokenB, in: workspaceB))
    }

    func testDwindleFullscreenTopologyAvailableBeforeFirstLayoutCalculation() throws {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let fullscreenToken = WindowToken(pid: 921, windowId: 1)
        let plainToken = WindowToken(pid: 921, windowId: 2)
        engine.addWindow(token: fullscreenToken, to: workspace, activeWindowFrame: nil)
        engine.addWindow(token: plainToken, to: workspace, activeWindowFrame: nil)
        let fullscreenNode = try XCTUnwrap(engine.findNode(for: fullscreenToken, in: workspace))
        engine.setSelectedNode(fullscreenNode, in: workspace)
        XCTAssertEqual(engine.toggleFullscreen(in: workspace), fullscreenToken)

        XCTAssertTrue(engine.currentFrames(in: workspace).isEmpty)
        XCTAssertEqual(engine.fullscreenTokens(in: workspace), [fullscreenToken])
    }

    func testDwindleRemoveLayoutDuringResizePermitsResizeInAnotherWorkspace() {
        let engine = DwindleLayoutEngine()
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let tokenA1 = WindowToken(pid: 922, windowId: 1)
        let tokenA2 = WindowToken(pid: 922, windowId: 2)
        let tokenB1 = WindowToken(pid: 923, windowId: 1)
        let tokenB2 = WindowToken(pid: 923, windowId: 2)
        engine.addWindow(token: tokenA1, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: tokenA2, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: tokenB1, to: workspaceB, activeWindowFrame: nil)
        engine.addWindow(token: tokenB2, to: workspaceB, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceA, screen: screen)
        _ = engine.calculateLayout(for: workspaceB, screen: screen)
        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: tokenA1,
                edges: .right,
                startLocation: .zero,
                in: workspaceA,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertFalse(
            engine.interactiveResizeBegin(
                token: tokenB1,
                edges: .right,
                startLocation: .zero,
                in: workspaceB,
                innerGap: engine.settings.innerGap
            )
        )

        engine.removeLayout(for: workspaceA)

        XCTAssertNil(engine.interactiveResize)
        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: tokenB1,
                edges: .right,
                startLocation: .zero,
                in: workspaceB,
                innerGap: engine.settings.innerGap
            )
        )
    }

    func testDwindleSelectionSetterRejectsForeignNode() {
        let engine = DwindleLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let tokenA = WindowToken(pid: 924, windowId: 1)
        let tokenB1 = WindowToken(pid: 924, windowId: 2)
        let tokenB2 = WindowToken(pid: 924, windowId: 3)
        let foreignNode = engine.addWindow(token: tokenA, to: workspaceA, activeWindowFrame: nil)
        engine.addWindow(token: tokenB1, to: workspaceB, activeWindowFrame: nil)
        let localNode = engine.addWindow(token: tokenB2, to: workspaceB, activeWindowFrame: nil)

        engine.setSelectedNode(foreignNode, in: workspaceB)

        XCTAssertEqual(engine.selectedNode(in: workspaceB)?.id, localNode.id)
    }

    func testDwindleLastWindowRemovalClearsSelection() {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 925, windowId: 1)
        engine.addWindow(token: token, to: workspace, activeWindowFrame: nil)
        XCTAssertNotNil(engine.selectedNode(in: workspace))

        engine.removeWindow(token: token, from: workspace)

        XCTAssertNil(engine.selectedNode(in: workspace))
        XCTAssertEqual(engine.windowCount(in: workspace), 0)
    }

    private func makeTransientWorkspace(
        named name: String,
        layoutType: LayoutType = .defaultLayout,
        controller: WMController
    ) throws -> WorkspaceDescriptor.ID {
        controller.settings.workspaceConfigurations.append(WorkspaceConfiguration(name: name, layoutType: layoutType))
        controller.workspaceManager.applySettings()
        return try XCTUnwrap(controller.workspaceManager.workspaceId(named: name))
    }

    private func addManagedWindow(
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

    private func removeTransientWorkspace(named name: String, controller: WMController) {
        controller.settings.workspaceConfigurations.removeAll { $0.name == name }
        controller.workspaceManager.applySettings()
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceDeletionTests-\(UUID().uuidString)", isDirectory: true)
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
