// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriVisibleColumnsTests: XCTestCase {
    private func proportion(of column: NiriContainer) -> CGFloat? {
        if case let .proportion(value) = column.width { return value }
        return nil
    }

    private func makeEngineWithColumns(_ count: Int) -> (NiriLayoutEngine, WorkspaceDescriptor.ID) {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        for index in 1 ... count {
            _ = engine.addWindow(
                token: WindowToken(pid: 1, windowId: index),
                to: workspaceId,
                afterSelection: nil
            )
        }
        return (engine, workspaceId)
    }

    func testBalanceSizesReTilesExistingColumnsToOneOverN() throws {
        let (engine, workspaceId) = makeEngineWithColumns(3)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 3)
        for column in engine.columns(in: workspaceId) {
            XCTAssertEqual(try XCTUnwrap(proportion(of: column)), 0.5, accuracy: 0.0001)
        }

        engine.maxVisibleColumns = 3
        engine.defaultColumnWidth = nil

        let didChange = engine.balanceSizes(
            in: workspaceId,
            motion: .disabled,
            workingAreaWidth: 1200,
            gaps: 12
        )

        XCTAssertTrue(didChange)
        for column in engine.columns(in: workspaceId) {
            XCTAssertEqual(try XCTUnwrap(proportion(of: column)), 1.0 / 3.0, accuracy: 0.0001)
        }
    }

    func testBalanceSizesReturnsFalseForEmptyWorkspace() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()

        let didChange = engine.balanceSizes(
            in: workspaceId,
            motion: .disabled,
            workingAreaWidth: 1200,
            gaps: 12
        )

        XCTAssertFalse(didChange)
    }

    func testResolvedColumnResetWidthDerivesFromVisibleColumnsWhenAuto() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        engine.maxVisibleColumns = 3
        engine.defaultColumnWidth = nil

        XCTAssertEqual(
            engine.resolvedColumnResetWidth(in: workspaceId).proportion,
            1.0 / 3.0,
            accuracy: 0.0001
        )
    }

    func testResolvedColumnResetWidthHonorsExplicitDefaultWidth() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        engine.maxVisibleColumns = 3
        engine.defaultColumnWidth = 0.5

        XCTAssertEqual(
            engine.resolvedColumnResetWidth(in: workspaceId).proportion,
            0.5,
            accuracy: 0.0001
        )
    }
}
