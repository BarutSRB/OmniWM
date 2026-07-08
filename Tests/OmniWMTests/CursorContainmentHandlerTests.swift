// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class CursorContainmentHandlerTests: XCTestCase {
    private struct Fixture {
        let settings: SettingsStore
        let controller: WMController
        let handler: MouseWarpHandler
        let bottom: Monitor
        let top: Monitor
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCursorContainmentTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
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
    }

    private func makeMonitor(_ displayId: CGDirectDisplayID, _ name: String, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func routing(
        _ displayId: CGDirectDisplayID,
        _ name: String,
        _ column: Int,
        _ row: Int
    ) -> MonitorRoutingSettings {
        MonitorRoutingSettings(monitorName: name, monitorDisplayId: displayId, gridColumn: column, gridRow: row)
    }

    private func makeFixture(verticalRouting: Bool = false, margin: Int = 1) -> Fixture {
        let settings = makeSettings()
        settings.mouseWarpEnabled = true
        settings.cursorContainmentEnabled = true
        settings.monitorRoutingMode = .custom
        settings.mouseWarpMargin = margin

        let bottom = makeMonitor(1, "Bottom", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let top = makeMonitor(2, "Top", CGRect(x: 0, y: 1080, width: 1920, height: 1080))
        settings.monitorRoutingSettings = verticalRouting
            ? [routing(2, "Top", 0, 0), routing(1, "Bottom", 0, 1)]
            : [routing(1, "Bottom", 0, 0), routing(2, "Top", 1, 0)]

        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([bottom, top])
        let handler = controller.mouseWarpHandler
        return Fixture(settings: settings, controller: controller, handler: handler, bottom: bottom, top: top)
    }

    func testWallFiresAfterFreshSourceSampleInsideForbiddenMonitor() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)

        XCTAssertEqual(warped.count, 1)
        assertPoint(
            warped[0],
            ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: 960, y: 1078))
        )
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.bottom.id)
    }

    func testAllowedPhysicalCrossingInDestinationEntryBandConsumesSample() {
        let fixture = makeFixture(verticalRouting: true, margin: 4)
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: CGPoint(x: 960, y: fixture.top.frame.minY + 1))

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testRoutedSameMonitorEdgeTeleportStillWorksWithContainmentEnabled() {
        let fixture = makeFixture(margin: 2)
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        let edgeLocation = CGPoint(x: fixture.bottom.frame.maxX - 1, y: fixture.bottom.frame.midY)
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: edgeLocation)

        let crossing = MouseWarpGeometry.crossing(location: edgeLocation, frame: fixture.bottom.frame, margin: 2)
        let destination = MouseWarpGeometry.destinationPoint(
            on: fixture.top.frame,
            entryEdge: crossing?.entryEdge ?? .left,
            ratio: crossing?.ratio ?? 0,
            margin: 2
        )
        XCTAssertEqual(warped.count, 1)
        assertPoint(warped[0], ScreenCoordinateSpace.toWindowServer(point: destination))
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testCooldownExpiryRecheckWallsParkedForbiddenCursor() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        fixture.controller.currentMouseLocation = { fixture.top.frame.center }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertEqual(warped.count, 1)

        fixture.handler.handleCooldownExpiry()

        XCTAssertEqual(warped.count, 2)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.bottom.id)
    }

    func testProgrammaticCursorMoveWhitelistsStalePreWarpSample() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.noteProgrammaticCursorMove(to: fixture.top.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testStaleBaselineAdoptsDestinationWithoutWalling() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.state.lastSampleAt = Date(timeIntervalSinceNow: -2)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testContainmentGatesDoNotWall() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.settings.cursorContainmentEnabled = false
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertTrue(warped.isEmpty)

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.settings.cursorContainmentEnabled = true
        fixture.settings.monitorRoutingMode = .macOS
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertTrue(warped.isEmpty)

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.settings.monitorRoutingMode = .custom
        fixture.settings.mouseWarpEnabled = false
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertTrue(warped.isEmpty)
    }

    func testOuterBoundaryLocationOnNoMonitorDoesNotWall() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = { warped.append($0) }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        fixture.handler.handleMouseWarpMoved(at: CGPoint(x: fixture.top.frame.midX, y: fixture.top.frame.maxY))

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testResetTransientStateClearsContainmentState() {
        let fixture = makeFixture()
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)

        fixture.handler.resetTransientState()

        XCTAssertNil(fixture.handler.state.lastMonitorId)
        XCTAssertNil(fixture.handler.state.lastSampleAt)
        XCTAssertFalse(fixture.handler.state.isWarping)
    }

    private func assertPoint(
        _ point: CGPoint,
        _ expected: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(point.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 0.0001, file: file, line: line)
    }
}
