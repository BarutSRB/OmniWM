// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewLayoutCalculatorTests: XCTestCase {
    func testGenericFallbackPreservesTranslatedWindowGeometryAndSectionSpacing() throws {
        let (layout, handles) = makeMixedLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first)

        XCTAssertEqual(layout.searchBarFrame, CGRect(x: 50, y: 620, width: 500, height: 55))
        XCTAssertEqual(section.name, "Generic")
        XCTAssertTrue(section.isActive)
        XCTAssertEqual(section.labelFrame, CGRect(x: -170, y: 555, width: 940, height: 40))
        XCTAssertEqual(section.gridFrame, CGRect(x: -150, y: 235, width: 900, height: 300))
        XCTAssertEqual(section.sectionFrame, CGRect(x: -200, y: 235, width: 1000, height: 340))
        XCTAssertEqual(section.windows.map(\.handle), Array(handles.prefix(2)))
        XCTAssertEqual(section.windows.map(\.overviewFrame), [
            CGRect(x: -150, y: 235, width: 450, height: 300),
            CGRect(x: 300, y: 235, width: 450, height: 300)
        ])
        XCTAssertEqual(section.windows.first?.originalFrame, CGRect(x: -640.25, y: 25.5, width: 300, height: 200))
    }

    func testNiriWeightedColumnsKeepTileSpacingAndDropZoneCoordinates() throws {
        let (layout, handles) = makeMixedLayout()
        let section = try XCTUnwrap(layout.workspaceSections.last)
        let columns = try XCTUnwrap(layout.niriColumnsByWorkspace[section.workspaceId])
        let dropZones = try XCTUnwrap(layout.niriColumnDropZonesByWorkspace[section.workspaceId])

        XCTAssertEqual(section.name, "Niri")
        XCTAssertFalse(section.isActive)
        XCTAssertEqual(section.labelFrame, CGRect(x: -170, y: 175, width: 940, height: 40))
        XCTAssertEqual(section.gridFrame, CGRect(x: -20, y: -265, width: 640, height: 420))
        XCTAssertEqual(section.sectionFrame, CGRect(x: -200, y: -265, width: 1000, height: 460))
        XCTAssertEqual(columns.map(\.columnIndex), [3, 8])
        XCTAssertEqual(columns.map(\.frame), [
            CGRect(x: -20, y: -265, width: 400, height: 420),
            CGRect(x: 400, y: -265, width: 200, height: 200)
        ])
        XCTAssertEqual(columns.map(\.windowHandles), [[handles[2], handles[3]], [handles[4]]])
        XCTAssertEqual(section.windows.map(\.overviewFrame), [
            CGRect(x: -20, y: -35, width: 400, height: 190),
            CGRect(x: -20, y: -245, width: 400, height: 190),
            CGRect(x: 400, y: -265, width: 200, height: 200)
        ])
        XCTAssertEqual(dropZones.map(\.insertIndex), [0, 1, 2])
        XCTAssertEqual(dropZones.map(\.frame), [
            CGRect(x: -40, y: -265, width: 20, height: 420),
            CGRect(x: 380, y: -265, width: 20, height: 420),
            CGRect(x: 620, y: -265, width: 20, height: 420)
        ])
    }

    func testMixedProjectionPreservesHandleIdentitySearchAndContentBounds() {
        let (layout, handles) = makeMixedLayout()

        XCTAssertEqual(layout.workspaceSections.count, 2)
        XCTAssertEqual(layout.scale, 1.25)
        XCTAssertEqual(layout.totalContentHeight, 910)
        XCTAssertEqual(layout.allWindows.map(\.matchesSearch), [false, true, true, false, false])
        for (window, handle) in zip(layout.allWindows, handles) {
            XCTAssertTrue(window.handle === handle)
        }
        XCTAssertEqual(
            OverviewLayoutCalculator.scrollOffsetBounds(
                layout: layout,
                screenFrame: CGRect(x: -200, y: -100, width: 1000, height: 800)
            ),
            -215 ... 0
        )
    }

    private func makeMixedLayout() -> (OverviewLayout, [WindowHandle]) {
        let generic = WorkspaceDescriptor.ID()
        let niri = WorkspaceDescriptor.ID()
        let handles = (1 ... 5).map { WindowHandle(id: WindowToken(pid: 7, windowId: $0)) }
        let frames = [
            CGRect(x: -640.25, y: 25.5, width: 300, height: 200),
            CGRect(x: -340.25, y: 25.5, width: 300, height: 200),
            CGRect(x: 0, y: 0, width: 200, height: 95),
            CGRect(x: 0, y: 0, width: 200, height: 95),
            CGRect(x: 0, y: 0, width: 100, height: 100)
        ]
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        for (index, handle) in handles.enumerated() {
            windows[handle] = OverviewWindowLayoutData(
                token: handle.id,
                workspaceId: index < 2 ? generic : niri,
                title: index == 1 ? "TERMINAL" : "Window \(index)",
                appName: index == 2 ? "Terminal" : "Editor",
                appIcon: nil,
                frame: frames[index]
            )
        }
        let snapshot = NiriOverviewWorkspaceSnapshot(workspaceId: niri, columns: [
            NiriOverviewColumnSnapshot(index: 3, widthWeight: 4, preferredWidth: 200, tiles: [
                NiriOverviewTileSnapshot(token: handles[2].id, preferredHeight: 95),
                NiriOverviewTileSnapshot(token: handles[3].id, preferredHeight: 95)
            ]),
            NiriOverviewColumnSnapshot(index: 8, widthWeight: 1, preferredWidth: nil, tiles: [
                NiriOverviewTileSnapshot(token: handles[4].id, preferredHeight: 100)
            ])
        ])
        let layout = OverviewLayoutCalculator(
            screenFrame: CGRect(x: -200, y: -100, width: 1000, height: 800),
            scale: 1.25
        ).calculateLayout(
            workspaces: [
                OverviewWorkspaceLayoutItem(id: generic, name: "Generic", isActive: true),
                OverviewWorkspaceLayoutItem(id: niri, name: "Niri", isActive: false),
                OverviewWorkspaceLayoutItem(id: WorkspaceDescriptor.ID(), name: "Empty", isActive: false)
            ],
            windows: windows,
            niriSnapshotsByWorkspace: [
                generic: NiriOverviewWorkspaceSnapshot(workspaceId: generic, columns: []),
                niri: snapshot
            ],
            searchQuery: "terminal"
        )
        return (layout, handles)
    }
}
