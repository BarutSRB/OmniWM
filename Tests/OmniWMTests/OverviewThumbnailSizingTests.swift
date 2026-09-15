// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class OverviewThumbnailSizingTests: XCTestCase {
    func testVisibleCardsShareOneCaptureAtLargestDisplaySize() {
        let handle = WindowHandle(id: WindowToken(pid: 1, windowId: 1))
        let first = projection(handle: handle, frame: CGRect(x: 20, y: 20, width: 100.25, height: 80.25), scale: 1)
        let second = projection(handle: handle, frame: CGRect(x: 20, y: 20, width: 100.25, height: 80.25), scale: 2)

        let requests = OverviewThumbnailSizing.captureRequests(projections: [first, second])

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.handle, handle)
        XCTAssertEqual(requests.first?.pixelWidth, 201)
        XCTAssertEqual(requests.first?.pixelHeight, 161)
    }

    func testScrollingStartsOnlyCardsIntersectingTheViewport() {
        let handle = WindowHandle(id: WindowToken(pid: 1, windowId: 1))
        let hidden = projection(handle: handle, frame: CGRect(x: 20, y: -300, width: 100, height: 80))
        var scrolledLayout = hidden.layout
        scrolledLayout.scrollOffset = -350
        let scrolled = OverviewPreviewProjection(
            layout: scrolledLayout,
            viewportFrame: hidden.viewportFrame,
            backingScaleFactor: 1
        )

        XCTAssertTrue(OverviewThumbnailSizing.captureRequests(projections: [hidden]).isEmpty)
        XCTAssertEqual(OverviewThumbnailSizing.captureRequests(projections: [scrolled]).first?.handle, handle)
    }

    func testCaptureSizeUsesSettledCardGeometryDuringAnimation() {
        let handle = WindowHandle(id: WindowToken(pid: 1, windowId: 1))
        let projection = projection(handle: handle, frame: CGRect(x: 20, y: 20, width: 100, height: 80))

        let requests = OverviewThumbnailSizing.captureRequests(projections: [projection])

        XCTAssertEqual(requests.first?.pixelWidth, 100)
        XCTAssertEqual(requests.first?.pixelHeight, 80)
        XCTAssertEqual(projection.layout.window(for: handle)?.originalFrame.width, 1200)
    }

    private func projection(handle: WindowHandle, frame: CGRect, scale: CGFloat = 1) -> OverviewPreviewProjection {
        let workspaceId = UUID()
        let window = OverviewWindowItem(
            handle: handle,
            windowId: handle.windowId,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: nil,
            originalFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            overviewFrame: frame,
            matchesSearch: true
        )
        var layout = OverviewLayout()
        layout.replaceWorkspaceSections([OverviewWorkspaceSection(
            workspaceId: workspaceId,
            name: "Workspace",
            windows: [window],
            sectionFrame: frame,
            labelFrame: .zero,
            gridFrame: frame,
            isActive: true
        )])
        return OverviewPreviewProjection(
            layout: layout,
            viewportFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            backingScaleFactor: scale
        )
    }
}
