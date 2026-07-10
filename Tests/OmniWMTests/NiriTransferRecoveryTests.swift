// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

private struct NiriColumnCollisionFixture {
    let engine: NiriLayoutEngine
    let sourceWorkspace: WorkspaceDescriptor.ID
    let targetWorkspace: WorkspaceDescriptor.ID
    let sharedToken: WindowToken
    let sourceOnlyToken: WindowToken
    let targetOnlyToken: WindowToken
    let sourceSharedNode: NiriWindow
    let sourceOnlyNode: NiriWindow
    let staleSharedNode: NiriWindow
    let targetOnlyNode: NiriWindow
    let sourceColumn: NiriContainer
}

@MainActor
final class NiriTransferRecoveryTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testFailedScopedRekeyIsRepairedBySyncWithoutMutatingForeignWorkspace() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 947, windowId: 1)
        let newToken = WindowToken(pid: 947, windowId: 2)
        let foreignToken = WindowToken(pid: 947, windowId: 3)
        let oldNode = engine.addWindow(token: oldToken, to: workspaceA, afterSelection: nil)
        let foreignNode = engine.addWindow(token: foreignToken, to: workspaceB, afterSelection: nil)
        let foreignRoot = try XCTUnwrap(engine.root(for: workspaceB))

        XCTAssertFalse(engine.rekeyWindow(from: oldToken, to: newToken, in: workspaceB))
        XCTAssertTrue(engine.findNode(for: oldToken, in: workspaceA) === oldNode)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
        XCTAssertEqual(engine.syncWindows([newToken], in: workspaceA, selectedNodeId: nil), [oldToken])

        let repairedNode = try XCTUnwrap(engine.findNode(for: newToken, in: workspaceA))
        XCTAssertNil(engine.findNode(for: oldToken, in: workspaceA))
        XCTAssertNil(oldNode.parent)
        assertSingleIndexedOccurrence(newToken, is: repairedNode, in: workspaceA, engine: engine)
        XCTAssertTrue(engine.root(for: workspaceB) === foreignRoot)
        XCTAssertTrue(engine.findNode(for: foreignToken, in: workspaceB) === foreignNode)
        XCTAssertEqual(foreignRoot.allWindows.count, 1)
        XCTAssertTrue(foreignRoot.allWindows.first === foreignNode)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testWindowTransferPrunesTargetDuplicateAndMovesSourceIdentity() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 944, windowId: 1)
        let nodeInA = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let staleNodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)
        var sourceState = ViewportState()
        var targetState = ViewportState()
        sourceState.selectedNodeId = nodeInA.id
        targetState.selectedNodeId = staleNodeInB.id

        let result = engine.moveWindowToWorkspace(
            nodeInA,
            from: workspaceA,
            to: workspaceB,
            sourceState: &sourceState,
            targetState: &targetState
        )

        XCTAssertNotNil(result)
        XCTAssertNil(engine.findNode(for: token, in: workspaceA))
        XCTAssertTrue(engine.findNode(for: token, in: workspaceB) === nodeInA)
        XCTAssertNil(staleNodeInB.parent)
        XCTAssertNil(sourceState.selectedNodeId)
        XCTAssertEqual(targetState.selectedNodeId, nodeInA.id)
        assertSelectionValid(targetState.selectedNodeId, in: workspaceB, engine: engine)
        assertSingleIndexedOccurrence(token, is: nodeInA, in: workspaceB, engine: engine)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
        XCTAssertTrue(engine.syncWindows([token], in: workspaceB, selectedNodeId: targetState.selectedNodeId).isEmpty)

        let removal = removeWindow(token, from: engine, in: workspaceB, state: &targetState)
        XCTAssertEqual(removal.removedTokens, [token])
        XCTAssertNil(engine.findNode(for: token, in: workspaceB))
        XCTAssertTrue(engine.root(for: workspaceB)?.allWindows.isEmpty == true)
        assertSelectionValid(targetState.selectedNodeId, in: workspaceB, engine: engine)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testColumnTransferPrunesOverlappingTargetTokenAndPreservesOtherTargetWindow() throws {
        let fixture = try makeColumnCollisionFixture()
        var sourceState = ViewportState()
        var targetState = ViewportState()
        sourceState.selectedNodeId = fixture.sourceSharedNode.id
        targetState.selectedNodeId = fixture.targetOnlyNode.id

        let result = fixture.engine.moveColumnToWorkspace(
            fixture.sourceColumn,
            from: fixture.sourceWorkspace,
            to: fixture.targetWorkspace,
            sourceState: &sourceState,
            targetState: &targetState
        )

        XCTAssertNotNil(result)
        assertColumnTransfer(fixture, sourceState: sourceState, targetState: targetState)
        XCTAssertTrue(
            fixture.engine.syncWindows(
                [fixture.sharedToken, fixture.sourceOnlyToken, fixture.targetOnlyToken],
                in: fixture.targetWorkspace,
                selectedNodeId: targetState.selectedNodeId
            ).isEmpty
        )

        let removal = removeWindow(
            fixture.sharedToken,
            from: fixture.engine,
            in: fixture.targetWorkspace,
            state: &targetState
        )
        XCTAssertEqual(removal.removedTokens, [fixture.sharedToken])
        XCTAssertNil(fixture.engine.findNode(for: fixture.sharedToken, in: fixture.targetWorkspace))
        XCTAssertTrue(
            fixture.engine.findNode(for: fixture.sourceOnlyToken, in: fixture.targetWorkspace)
                === fixture.sourceOnlyNode
        )
        XCTAssertTrue(
            fixture.engine.findNode(for: fixture.targetOnlyToken, in: fixture.targetWorkspace)
                === fixture.targetOnlyNode
        )
        assertSelectionValid(targetState.selectedNodeId, in: fixture.targetWorkspace, engine: fixture.engine)
        assertIndexMatchesTree(fixture.engine, in: fixture.targetWorkspace)
    }

    func testRestoreDeduplicatesRepeatedTokenInputAndLeavesNoOrphan() throws {
        let engine = NiriLayoutEngine()
        let sourceWorkspace = WorkspaceDescriptor.ID()
        let restoredWorkspace = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 946, windowId: 1)
        let sourceNode = engine.addWindow(token: token, to: sourceWorkspace, afterSelection: nil)
        let placements = engine.persistedPlacements(in: sourceWorkspace)

        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [token, token], in: restoredWorkspace))

        let restoredNode = try XCTUnwrap(engine.findNode(for: token, in: restoredWorkspace))
        XCTAssertFalse(restoredNode === sourceNode)
        XCTAssertTrue(engine.findNode(for: token, in: sourceWorkspace) === sourceNode)
        assertSingleIndexedOccurrence(token, is: sourceNode, in: sourceWorkspace, engine: engine)
        assertSingleIndexedOccurrence(token, is: restoredNode, in: restoredWorkspace, engine: engine)
        assertIndexMatchesTree(engine, in: sourceWorkspace)
        assertIndexMatchesTree(engine, in: restoredWorkspace)

        var restoredState = ViewportState()
        restoredState.selectedNodeId = restoredNode.id
        XCTAssertTrue(
            engine.syncWindows([token], in: restoredWorkspace, selectedNodeId: restoredState.selectedNodeId).isEmpty
        )
        let removal = removeWindow(token, from: engine, in: restoredWorkspace, state: &restoredState)
        XCTAssertEqual(removal.removedTokens, [token])
        XCTAssertNil(engine.findNode(for: token, in: restoredWorkspace))
        XCTAssertTrue(engine.root(for: restoredWorkspace)?.allWindows.isEmpty == true)
        XCTAssertTrue(engine.findNode(for: token, in: sourceWorkspace) === sourceNode)
        assertSelectionValid(restoredState.selectedNodeId, in: restoredWorkspace, engine: engine)
        assertIndexMatchesTree(engine, in: sourceWorkspace)
        assertIndexMatchesTree(engine, in: restoredWorkspace)
    }

    private func makeColumnCollisionFixture() throws -> NiriColumnCollisionFixture {
        let engine = NiriLayoutEngine()
        let sourceWorkspace = WorkspaceDescriptor.ID()
        let targetWorkspace = WorkspaceDescriptor.ID()
        let sharedToken = WindowToken(pid: 945, windowId: 1)
        let sourceOnlyToken = WindowToken(pid: 945, windowId: 2)
        let targetOnlyToken = WindowToken(pid: 945, windowId: 3)
        let sourceSharedNode = engine.addWindow(token: sharedToken, to: sourceWorkspace, afterSelection: nil)
        let sourceOnlyNode = engine.addWindow(token: sourceOnlyToken, to: sourceWorkspace, afterSelection: nil)
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: sourceSharedNode, in: sourceWorkspace))
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                sourceOnlyNode,
                into: sourceColumn,
                enteringFrom: .down,
                in: sourceWorkspace,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: 0
            )
        )
        let staleSharedNode = engine.addWindow(token: sharedToken, to: targetWorkspace, afterSelection: nil)
        let targetOnlyNode = engine.addWindow(token: targetOnlyToken, to: targetWorkspace, afterSelection: nil)
        return NiriColumnCollisionFixture(
            engine: engine,
            sourceWorkspace: sourceWorkspace,
            targetWorkspace: targetWorkspace,
            sharedToken: sharedToken,
            sourceOnlyToken: sourceOnlyToken,
            targetOnlyToken: targetOnlyToken,
            sourceSharedNode: sourceSharedNode,
            sourceOnlyNode: sourceOnlyNode,
            staleSharedNode: staleSharedNode,
            targetOnlyNode: targetOnlyNode,
            sourceColumn: sourceColumn
        )
    }

    private func assertColumnTransfer(
        _ fixture: NiriColumnCollisionFixture,
        sourceState: ViewportState,
        targetState: ViewportState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let engine = fixture.engine
        XCTAssertNil(engine.findNode(for: fixture.sharedToken, in: fixture.sourceWorkspace), file: file, line: line)
        XCTAssertNil(engine.findNode(for: fixture.sourceOnlyToken, in: fixture.sourceWorkspace), file: file, line: line)
        XCTAssertTrue(
            engine.findNode(for: fixture.sharedToken, in: fixture.targetWorkspace) === fixture.sourceSharedNode,
            file: file,
            line: line
        )
        XCTAssertTrue(
            engine.findNode(for: fixture.sourceOnlyToken, in: fixture.targetWorkspace) === fixture.sourceOnlyNode,
            file: file,
            line: line
        )
        XCTAssertTrue(
            engine.findNode(for: fixture.targetOnlyToken, in: fixture.targetWorkspace) === fixture.targetOnlyNode,
            file: file,
            line: line
        )
        XCTAssertTrue(
            engine.findColumn(containing: fixture.sourceSharedNode, in: fixture.targetWorkspace)
                === fixture.sourceColumn,
            file: file,
            line: line
        )
        XCTAssertNil(fixture.staleSharedNode.parent, file: file, line: line)
        XCTAssertNil(sourceState.selectedNodeId, file: file, line: line)
        XCTAssertEqual(targetState.selectedNodeId, fixture.sourceSharedNode.id, file: file, line: line)
        assertSelectionValid(targetState.selectedNodeId, in: fixture.targetWorkspace, engine: engine)
        assertSingleIndexedOccurrence(
            fixture.sharedToken,
            is: fixture.sourceSharedNode,
            in: fixture.targetWorkspace,
            engine: engine
        )
        assertSingleIndexedOccurrence(
            fixture.sourceOnlyToken,
            is: fixture.sourceOnlyNode,
            in: fixture.targetWorkspace,
            engine: engine
        )
        assertSingleIndexedOccurrence(
            fixture.targetOnlyToken,
            is: fixture.targetOnlyNode,
            in: fixture.targetWorkspace,
            engine: engine
        )
        assertIndexMatchesTree(engine, in: fixture.sourceWorkspace)
        assertIndexMatchesTree(engine, in: fixture.targetWorkspace)
    }

    private func removeWindow(
        _ token: WindowToken,
        from engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriLayoutEngine.NiriRemovalResult {
        engine.removeWindows(
            [token],
            in: workspaceId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 0,
            selectedNodeId: state.selectedNodeId,
            removedNodeIds: []
        )
    }

    private func assertIndexMatchesTree(
        _ engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let state = engine.states[workspaceId] else {
            XCTFail("missing workspace state", file: file, line: line)
            return
        }
        let treeWindows = state.root.allWindows
        XCTAssertEqual(treeWindows.count, state.nodesByToken.count, file: file, line: line)
        XCTAssertEqual(Set(treeWindows.map(\.token)), Set(state.nodesByToken.keys), file: file, line: line)
        for window in treeWindows {
            XCTAssertTrue(state.nodesByToken[window.token] === window, file: file, line: line)
        }
    }

    private func assertSingleIndexedOccurrence(
        _ token: WindowToken,
        is expectedNode: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let state = engine.states[workspaceId] else {
            XCTFail("missing workspace state", file: file, line: line)
            return
        }
        let occurrences = state.root.allWindows.filter { $0.token == token }
        XCTAssertEqual(occurrences.count, 1, file: file, line: line)
        XCTAssertTrue(occurrences.first === expectedNode, file: file, line: line)
        XCTAssertTrue(state.nodesByToken[token] === expectedNode, file: file, line: line)
    }

    private func assertSelectionValid(
        _ nodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let nodeId else { return }
        XCTAssertNotNil(engine.findNode(by: nodeId, in: workspaceId), file: file, line: line)
    }
}
