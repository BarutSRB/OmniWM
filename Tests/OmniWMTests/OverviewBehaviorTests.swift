// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class OverviewBehaviorTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testRevealPreservesAlreadyVisibleOffset() {
        let layout = makeGeometryLayout()

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: 200, width: 300, height: 200),
            currentOffset: -50,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -50)
    }

    func testRevealChoosesNearestEdgeAboveAndBelow() {
        let layout = makeGeometryLayout()

        let below = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: -200, width: 300, height: 100),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )
        let above = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: 150, width: 300, height: 100),
            currentOffset: -600,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(below, -216)
        XCTAssertEqual(above, -434)
    }

    func testRevealBoundsPaddingForNearlyViewportSizedCard() {
        let layout = makeGeometryLayout()
        let target = CGRect(x: 0, y: -100, width: 900, height: 694)

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: target,
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -103)
        assertVisible(target, in: layout, offset: offset)
    }

    func testRevealAlignsOversizedCardToContentTop() {
        let layout = makeGeometryLayout()
        let target = CGRect(x: 0, y: -500, width: 900, height: 800)

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: target,
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -400)
        let viewport = OverviewLayoutCalculator.visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: offset
        )
        XCTAssertEqual(target.maxY, viewport.maxY)
    }

    func testRevealClampsAtBothScrollBounds() {
        let layout = makeGeometryLayout()

        let bottom = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: -2200, width: 200, height: 100),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )
        let top = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: 1200, width: 200, height: 100),
            currentOffset: -600,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(bottom, -1300)
        XCTAssertEqual(top, 0)
    }

    func testRevealPreservesFractionalCoordinates() {
        let layout = makeGeometryLayout()

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: -10.25, width: 200, height: 99.5),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -26.25, accuracy: 0.0001)
    }

    func testRevealAtEverySupportedZoomStepRemainsBoundedAndVisible() {
        for percentage in stride(from: 50, through: 150, by: 5) {
            let scale = CGFloat(percentage) / 100
            let layout = makeGeometryLayout(scale: scale)
            let target = CGRect(x: 0, y: -250, width: 300, height: 80)

            let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
                targetFrame: target,
                currentOffset: 0,
                layout: layout,
                screenFrame: screenFrame
            )

            XCTAssertTrue(
                OverviewLayoutCalculator.scrollOffsetBounds(layout: layout, screenFrame: screenFrame)
                    .contains(offset),
                "zoom \(percentage)%"
            )
            assertVisible(target, in: layout, offset: offset, message: "zoom \(percentage)%")
        }
    }

    func testNavigationRevealsThirdWorkspaceAndWrapsHorizontally() throws {
        let fixture = makeProjectionFixture()
        var layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let first = try XCTUnwrap(layout.allWindows.first?.handle)
        layout.setSelected(handle: first)

        let second = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: first, direction: .down)
        )
        layout.setSelected(handle: second)
        let third = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: second, direction: .down)
        )
        layout.setSelected(handle: third)
        let thirdWindow = try XCTUnwrap(layout.window(for: third))
        layout.scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: thirdWindow.overviewFrame,
            currentOffset: layout.scrollOffset,
            layout: layout,
            screenFrame: screenFrame
        )

        assertVisible(thirdWindow.overviewFrame, in: layout, offset: layout.scrollOffset)
        XCTAssertTrue(layout.scrollOffset < 0)
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: third, direction: .right),
            first
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: first, direction: .left),
            third
        )
    }

    func testZoomPreservesSelectedMidpointsIndependentlyUntilClamped() throws {
        let fixture = makeProjectionFixture()
        var firstMonitor = projectedLayout(fixture: fixture, scale: 1, query: "")
        var secondMonitor = firstMonitor
        let selected = try XCTUnwrap(firstMonitor.allWindows.last?.handle)
        firstMonitor.setSelected(handle: selected)
        secondMonitor.setSelected(handle: selected)
        firstMonitor.scrollOffset = -500
        secondMonitor.scrollOffset = -700
        let firstMidpoint = try XCTUnwrap(firstMonitor.window(for: selected)).overviewFrame.midY
            - firstMonitor.scrollOffset
        let secondMidpoint = try XCTUnwrap(secondMonitor.window(for: selected)).overviewFrame.midY
            - secondMonitor.scrollOffset

        var zoomedFirst = projectedLayout(fixture: fixture, scale: 1.5, query: "")
        var zoomedSecond = zoomedFirst
        zoomedFirst.setSelected(handle: selected)
        zoomedSecond.setSelected(handle: selected)
        let zoomedWindow = try XCTUnwrap(zoomedFirst.window(for: selected))
        let firstDesiredOffset = zoomedWindow.overviewFrame.midY - firstMidpoint
        let secondDesiredOffset = zoomedWindow.overviewFrame.midY - secondMidpoint
        zoomedFirst.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            firstDesiredOffset,
            layout: zoomedFirst,
            screenFrame: screenFrame
        )
        zoomedSecond.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            secondDesiredOffset,
            layout: zoomedSecond,
            screenFrame: screenFrame
        )

        XCTAssertNotEqual(zoomedFirst.scrollOffset, zoomedSecond.scrollOffset)
        XCTAssertEqual(
            zoomedWindow.overviewFrame.midY - zoomedFirst.scrollOffset,
            firstMidpoint,
            accuracy: 0.0001
        )
        XCTAssertFalse(
            OverviewLayoutCalculator.scrollOffsetBounds(layout: zoomedSecond, screenFrame: screenFrame)
                .contains(secondDesiredOffset)
        )
        XCTAssertEqual(
            zoomedSecond.scrollOffset,
            OverviewLayoutCalculator.clampedScrollOffset(
                secondDesiredOffset,
                layout: zoomedSecond,
                screenFrame: screenFrame
            )
        )
    }

    func testSelectionSearchZoomRemovalSequenceMaintainsViewportInvariants() throws {
        var fixture = makeProjectionFixture()
        var layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let first = try XCTUnwrap(layout.allWindows.first?.handle)
        layout.setSelected(handle: first)
        assertViewportInvariant(layout)

        let second = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: first, direction: .down)
        )
        let third = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: second, direction: .down)
        )
        layout.setSelected(handle: third)
        revealSelection(in: &layout)
        assertViewportInvariant(layout)

        let previousOffset = layout.scrollOffset
        layout = projectedLayout(fixture: fixture, scale: 1, query: "third")
        layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            previousOffset,
            layout: layout,
            screenFrame: screenFrame
        )
        layout.setSelected(handle: third)
        revealSelection(in: &layout)
        assertViewportInvariant(layout)

        let midpoint = try XCTUnwrap(layout.window(for: third)).overviewFrame.midY - layout.scrollOffset
        layout = projectedLayout(fixture: fixture, scale: 1.5, query: "third")
        layout.setSelected(handle: third)
        let zoomedWindow = try XCTUnwrap(layout.window(for: third))
        layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            zoomedWindow.overviewFrame.midY - midpoint,
            layout: layout,
            screenFrame: screenFrame
        )
        revealSelection(in: &layout)
        assertViewportInvariant(layout)

        fixture.windows.removeValue(forKey: third)
        layout = projectedLayout(fixture: fixture, scale: 1.5, query: "")
        layout.setSelected(handle: layout.allWindows.first?.handle)
        revealSelection(in: &layout)
        assertViewportInvariant(layout)
    }

    func testActivationAndDismissalDoNotRepeatWhileNavigationDoes() {
        let repeatedReturn = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [],
            charactersIgnoringModifiers: "\r",
            searchQuery: "",
            isRepeat: true
        )
        let repeatedEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "query",
            isRepeat: true
        )
        let repeatedArrow = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_DownArrow),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "",
            isRepeat: true
        )
        let repeatedTab = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Tab),
            modifierFlags: .shift,
            charactersIgnoringModifiers: "\t",
            searchQuery: "",
            isRepeat: true
        )

        XCTAssertEqual(repeatedReturn.action, .consume)
        XCTAssertTrue(repeatedReturn.shouldConsume)
        XCTAssertEqual(repeatedEscape.action, .consume)
        XCTAssertTrue(repeatedEscape.shouldConsume)
        XCTAssertEqual(repeatedArrow.action, .navigate(.down))
        XCTAssertEqual(repeatedTab.action, .navigate(.left))
    }

    func testFirstEscapeClearsSearchBeforeRepeatedEscapeIsIgnored() {
        let firstEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "query",
            isRepeat: false
        )
        let repeatedEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "",
            isRepeat: true
        )

        XCTAssertEqual(firstEscape.action, .clearSearchOrDismiss)
        XCTAssertEqual(repeatedEscape.action, .consume)
    }

    private func makeGeometryLayout(scale: CGFloat = 1) -> OverviewLayout {
        var layout = OverviewLayout()
        layout.scale = scale
        layout.searchBarFrame = CGRect(x: 250, y: 720, width: 500, height: 44)
        layout.totalContentHeight = 2000
        return layout
    }

    private struct ProjectionFixture {
        var workspaces: [OverviewWorkspaceLayoutItem]
        var windows: [WindowHandle: OverviewWindowLayoutData]
    }

    private func makeProjectionFixture() -> ProjectionFixture {
        let descriptors = ["First", "Second", "Third"].map { WorkspaceDescriptor(name: $0) }
        let workspaces = descriptors.enumerated().map { index, descriptor in
            (id: descriptor.id, name: descriptor.name, isActive: index == 0)
        }
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        for (index, descriptor) in descriptors.enumerated() {
            let token = WindowToken(pid: pid_t(index + 1), windowId: index + 1)
            let handle = WindowHandle(id: token)
            windows[handle] = (
                token: token,
                workspaceId: descriptor.id,
                title: descriptor.name.lowercased(),
                appName: "App \(index + 1)",
                appIcon: nil,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 700)
            )
        }
        return ProjectionFixture(workspaces: workspaces, windows: windows)
    }

    private func projectedLayout(
        fixture: ProjectionFixture,
        scale: CGFloat,
        query: String
    ) -> OverviewLayout {
        OverviewLayoutCalculator.calculateLayout(
            workspaces: fixture.workspaces,
            windows: fixture.windows,
            screenFrame: screenFrame,
            searchQuery: query,
            scale: scale
        )
    }

    private func revealSelection(in layout: inout OverviewLayout) {
        guard let selected = layout.selectedWindow() else { return }
        layout.scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: selected.overviewFrame,
            currentOffset: layout.scrollOffset,
            layout: layout,
            screenFrame: screenFrame
        )
    }

    private func assertViewportInvariant(_ layout: OverviewLayout, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(layout: layout, screenFrame: screenFrame)
        XCTAssertTrue(bounds.contains(layout.scrollOffset), file: file, line: line)
        if let selected = layout.selectedWindow(), selected.matchesSearch {
            assertVisible(selected.overviewFrame, in: layout, offset: layout.scrollOffset, file: file, line: line)
        }
    }

    private func assertVisible(
        _ target: CGRect,
        in layout: OverviewLayout,
        offset: CGFloat,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = OverviewLayoutCalculator.visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: offset
        )
        guard target.height <= viewport.height else { return }
        let padding = min(
            OverviewLayoutMetrics.windowSpacing * OverviewLayoutCalculator.clampedScale(layout.scale),
            max(0, (viewport.height - target.height) / 2)
        )
        let paddedViewport = viewport.insetBy(dx: 0, dy: padding)
        XCTAssertGreaterThanOrEqual(target.minY + 0.0001, paddedViewport.minY, message, file: file, line: line)
        XCTAssertLessThanOrEqual(target.maxY - 0.0001, paddedViewport.maxY, message, file: file, line: line)
    }
}
