// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class PersistedRestoreCatalogBuilderTests: XCTestCase {
    func testInvalidKeysAreSkippedAndSameTitleLiveIdentitiesRemainDistinct() {
        let entries = [
            entry(windowId: 9, title: "Shared"),
            entry(windowId: 3, bundleId: nil),
            entry(windowId: 4, bundleId: " \n "),
            entry(windowId: 2, title: " Shared ")
        ]

        let catalog = PersistedWindowRestoreCatalogBuilder.build(from: .init(entries: entries))

        XCTAssertEqual(catalog.entries.compactMap { $0.identity?.windowId }, [2, 9])
        XCTAssertEqual(catalog.entries.map(\.key.title), ["Shared", "Shared"])
        XCTAssertEqual(catalog.entries.map(\.key.baseKey.bundleId), ["com.example.app", "com.example.app"])
        XCTAssertTrue(catalog.entries.allSatisfy { $0.restoreIntent.restoreToFloating })
        XCTAssertEqual(
            catalog.entries.map(\.restoreIntent.floatingFrame),
            [entries[3].floatingFrame, entries[0].floatingFrame]
        )
        XCTAssertEqual(
            catalog.entries.map(\.restoreIntent.dwindlePlacement),
            [entries[3].dwindlePlacement, entries[0].dwindlePlacement]
        )
    }

    func testCatalogKeepsWorkspaceBundleTitleAndIdentitySortPriority() {
        let entries = [
            entry(windowId: 9, title: "Same", pid: 41),
            entry(windowId: 8, title: "Same", workspace: "B"),
            entry(windowId: 7, title: "Same", bundleId: "com.z.app"),
            entry(windowId: 6, title: "Zebra"),
            entry(windowId: 5, title: "Same", pid: 42),
            entry(windowId: 4, title: "Same", pid: 41),
            entry(windowId: 3, title: nil)
        ]

        let catalog = PersistedWindowRestoreCatalogBuilder.build(from: .init(entries: entries))

        XCTAssertEqual(catalog.entries.compactMap { $0.identity?.windowId }, [3, 4, 9, 5, 6, 7, 8])
        XCTAssertEqual(catalog.entries.count, entries.count)
    }

    private func entry(
        windowId: Int,
        title: String? = "Window",
        workspace: String = "A",
        bundleId: String? = " COM.Example.App ",
        pid: Int32 = 41
    ) -> PersistedWindowRestoreCatalogBuildEntry {
        let frame = CGRect(x: windowId * 10, y: 30, width: 500, height: 400)
        let metadata = ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: WorkspaceDescriptor.ID(),
            mode: .floating,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: title,
            windowLevel: 0,
            parentWindowId: nil,
            frame: frame
        )
        return PersistedWindowRestoreCatalogBuildEntry(
            token: WindowToken(pid: pid, windowId: windowId),
            metadata: metadata,
            workspaceName: workspace,
            topologyProfile: TopologyProfile(monitors: []),
            preferredMonitor: nil,
            floatingFrame: frame,
            normalizedFloatingOrigin: CGPoint(x: 0.25, y: 0.5),
            restoreToFloating: true,
            rescueEligible: false,
            niriPlacement: nil,
            detachedNiriContainerSizingState: nil,
            dwindlePlacement: PersistedDwindlePlacement(
                steps: [.init(orientation: .horizontal, ratio: 0.4, childIndex: 1)],
                memberIndex: 2,
                isActiveMember: false
            )
        )
    }
}
