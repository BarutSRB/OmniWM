// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class TabRailTests: XCTestCase {
    func testKeyIncludesLayoutOwnerAndWorkspace() {
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let niriInfo = TabRailInfo(
            workspaceId: workspaceId,
            owner: .niriColumn(NodeId()),
            plannedSeq: 1,
            tileFrame: frame,
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )
        let dwindleInfo = TabRailInfo(
            workspaceId: workspaceId,
            owner: .dwindleTile(UUID()),
            plannedSeq: 1,
            tileFrame: frame,
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )

        XCTAssertNotEqual(niriInfo.key, dwindleInfo.key)
        XCTAssertEqual(niriInfo.key.workspaceId, workspaceId)
        XCTAssertEqual(dwindleInfo.key.workspaceId, workspaceId)
    }

    func testDefaultTabsClampActiveSelection() {
        let info = TabRailInfo(
            workspaceId: WorkspaceDescriptor.ID(),
            owner: .dwindleTile(UUID()),
            plannedSeq: 1,
            tileFrame: .zero,
            tabCount: 3,
            activeVisualIndex: 8,
            activeWindowId: nil
        )

        XCTAssertEqual(info.tabs.map(\.visualIndex), [0, 1, 2])
        XCTAssertEqual(info.tabs.map(\.isActive), [false, false, true])
    }

    func testLayoutMaintainsVisualOrderWithinAvailableHeight() {
        let layout = TabRailLayout(tabCount: 4, bounds: CGRect(x: 0, y: 0, width: 20, height: 80))

        XCTAssertEqual(layout.items.map(\.visualIndex), [0, 1, 2, 3])
        XCTAssertTrue(zip(layout.items, layout.items.dropFirst()).allSatisfy { pair in
            pair.0.hitRect.minY > pair.1.hitRect.minY
        })
        XCTAssertTrue(layout.items.allSatisfy { layout.railRect.contains($0.hitRect) })
    }
}
