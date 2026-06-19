// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class GapSettingsTests: XCTestCase {
    func testNormalizedTopStrutMeasuresFromPhysicalTop() {
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 33, reservedTopInset: 0), 13)
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 0, reservedTopInset: 0), 46)
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 24, reservedTopInset: 0), 22)
        XCTAssertEqual(normalizedTopStrut(top: 10, menuBarInset: 24, reservedTopInset: 0), 0)
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 33, reservedTopInset: 28), 41)
    }

    func testNormalizedTopStrutKeepsTopGapConsistentAcrossDisplays() {
        let frameMaxY: CGFloat = 1000
        let top: CGFloat = 46

        for inset: CGFloat in [0, 24, 33] {
            let visibleFrameMaxY = frameMaxY - inset
            let windowTop = visibleFrameMaxY - normalizedTopStrut(top: top, menuBarInset: inset, reservedTopInset: 0)
            XCTAssertEqual(frameMaxY - windowTop, top)
        }
    }

    func testNormalizedTopStrutNeverPlacesWindowAboveVisibleFrame() {
        for inset: CGFloat in [0, 24, 33, 50] {
            XCTAssertGreaterThanOrEqual(normalizedTopStrut(top: 8, menuBarInset: inset, reservedTopInset: 0), 0)
        }
    }

    func testMonitorGapSettingsDecodePartialLeavesOthersNil() throws {
        let json = Data(#"{"id":"\#(UUID().uuidString)","monitorName":"Built-in","outerGapTop":20}"#.utf8)
        let decoded = try JSONDecoder().decode(MonitorGapSettings.self, from: json)
        XCTAssertEqual(decoded.outerGapTop, 20)
        XCTAssertNil(decoded.outerGapLeft)
        XCTAssertNil(decoded.outerGapRight)
        XCTAssertNil(decoded.outerGapBottom)
    }

    func testMonitorGapSettingsRoundTrips() throws {
        let original = MonitorGapSettings(
            monitorName: "Built-in",
            monitorDisplayId: 7,
            outerGapTop: 20,
            outerGapBottom: 12
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitorGapSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMonitorSettingsStoreMatchesByDisplayIdThenName() {
        let byId = MonitorGapSettings(monitorName: "Whatever", monitorDisplayId: 42, outerGapTop: 5)
        let byName = MonitorGapSettings(monitorName: "External", monitorDisplayId: nil, outerGapTop: 9)
        let overrides = [byId, byName]

        let idMonitor = makeMonitor(displayId: 42, name: "Renamed")
        XCTAssertEqual(MonitorSettingsStore.get(for: idMonitor, in: overrides)?.outerGapTop, 5)

        let nameMonitor = makeMonitor(displayId: 99, name: "External")
        XCTAssertEqual(MonitorSettingsStore.get(for: nameMonitor, in: overrides)?.outerGapTop, 9)

        let unknownMonitor = makeMonitor(displayId: 100, name: "Unknown")
        XCTAssertNil(MonitorSettingsStore.get(for: unknownMonitor, in: overrides))
    }

    @MainActor
    func testResolvedGapSettingsFallsBackToGlobalThenOverride() {
        let settings = makeSettingsStore()
        settings.outerGapLeft = 12
        settings.outerGapRight = 12
        settings.outerGapTop = 46
        settings.outerGapBottom = 12

        let monitor = makeMonitor(displayId: 1, name: "Built-in")

        let globalOnly = settings.resolvedGapSettings(for: monitor)
        XCTAssertEqual(globalOnly.outerGapTop, 46)
        XCTAssertEqual(globalOnly.outerGapLeft, 12)

        settings.updateGapSettings(
            MonitorGapSettings(monitorName: "Built-in", monitorDisplayId: 1, outerGapTop: 20)
        )

        let resolved = settings.resolvedGapSettings(for: monitor)
        XCTAssertEqual(resolved.outerGapTop, 20)
        XCTAssertEqual(resolved.outerGapLeft, 12)
        XCTAssertEqual(resolved.outerGapBottom, 12)
    }

    func testDwindleApplyGapsEdgesAreFlush() {
        var settings = DwindleSettings()
        settings.innerGap = 8
        let tilingArea = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        let fullEdge = DwindleGapCalculator.applyGaps(nodeRect: tilingArea, tilingArea: tilingArea, settings: settings)
        XCTAssertEqual(fullEdge, tilingArea)

        let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let result = DwindleGapCalculator.applyGaps(nodeRect: leftHalf, tilingArea: tilingArea, settings: settings)
        XCTAssertEqual(result.minX, 0)
        XCTAssertEqual(result.width, 500 - settings.innerGap / 2)
        XCTAssertEqual(result.height, 1000)
    }

    @MainActor
    func testFullscreenLayoutFrameIgnoresOuterGapsButKeepsWorkspaceBarReserve() {
        let settings = makeSettingsStore()
        settings.outerGapLeft = 12
        settings.outerGapRight = 12
        settings.outerGapTop = 46
        settings.outerGapBottom = 14
        settings.workspaceBarReserveLayoutSpace = true
        settings.workspaceBarHeight = 24
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )

        XCTAssertEqual(
            controller.insetWorkingFrame(for: monitor),
            CGRect(x: 12, y: 14, width: 1416, height: 816)
        )
        XCTAssertEqual(
            controller.fullscreenLayoutFrame(for: monitor),
            CGRect(x: 0, y: 0, width: 1440, height: 836)
        )
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: name
        )
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMGapTests-\(UUID().uuidString)", isDirectory: true)
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
}
