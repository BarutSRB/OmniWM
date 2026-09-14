// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarInstanceTests: XCTestCase {
    private final class MeasurementView: NSHostingView<WorkspaceBarMeasurementView> {
        var measurementCount = 0

        override var fittingSize: NSSize {
            measurementCount += 1
            return NSSize(width: 120, height: 24)
        }
    }

    private struct Fixture {
        let instance: WorkspaceBarInstance
        let measurementView: MeasurementView
    }

    func testRepeatedSnapshotReusesMeasurementAndChangedSnapshotInvalidatesIt() {
        let fixture = makeFixture()
        let instance = fixture.instance
        let snapshot = instance.model.snapshot
        defer { instance.primary.panel.close() }

        XCTAssertEqual(instance.measuredWidth(for: snapshot, slice: .all, showsSystemStatsButton: false), 120)
        XCTAssertEqual(fixture.measurementView.measurementCount, 1)
        instance.updateSnapshot(snapshot)
        XCTAssertEqual(instance.measuredWidth(for: snapshot, slice: .all, showsSystemStatsButton: false), 120)
        XCTAssertEqual(fixture.measurementView.measurementCount, 1)

        let changed = snapshot.replacingScratchpads([
            WorkspaceBarScratchpadItem(index: 1, label: "Terminal", windows: [], isVisible: false)
        ])
        instance.updateSnapshot(changed)
        XCTAssertEqual(instance.measuredWidth(for: changed, slice: .all, showsSystemStatsButton: false), 120)
        XCTAssertEqual(fixture.measurementView.measurementCount, 2)
        XCTAssertEqual(instance.model.snapshot, changed)
    }

    func testMissingScreenRejectsUpdateWithoutChangingExistingMonitorOrPanels() {
        let fixture = makeFixture(screenDisplayId: 1)
        let instance = fixture.instance
        let originalMonitor = instance.monitor
        let panel = instance.primary.panel
        defer { panel.close() }

        XCTAssertFalse(instance.updateMonitor(makeMonitor(width: 800), screen: nil))
        XCTAssertEqual(instance.monitor.frame, originalMonitor.frame)
        XCTAssertEqual(instance.screenDisplayId, 1)
        XCTAssertTrue(instance.primary.panel === panel)
    }

    func testHeadlessMonitorUpdateRetainsPanelAndModelIdentity() {
        let fixture = makeFixture()
        let instance = fixture.instance
        let panel = instance.primary.panel
        let model = instance.model
        let updated = makeMonitor(width: 800)
        defer { panel.close() }

        XCTAssertTrue(instance.updateMonitor(updated, screen: nil))
        XCTAssertEqual(instance.monitor.frame, updated.frame)
        XCTAssertNil(instance.screenDisplayId)
        XCTAssertTrue(instance.primary.panel === panel)
        XCTAssertTrue(instance.model === model)
    }

    func testRepeatedFrameDoesNotApplyAgainAndRetargetingUsesSamePanel() {
        let fixture = makeFixture()
        var island = fixture.instance.primary
        let panel = island.panel
        let initial = NSRect(x: 100, y: 740, width: 120, height: 24)
        let retargeted = initial.offsetBy(dx: 80, dy: 0)
        var appliedFrames: [NSRect] = []
        let apply: (WorkspaceBarPanel, NSRect) -> Void = { target, frame in
            XCTAssertTrue(target === panel)
            appliedFrames.append(frame)
        }
        defer { panel.close() }

        island.applyFrame(initial, using: apply)
        island.applyFrame(initial, using: apply)
        island.applyFrame(retargeted, using: apply)
        XCTAssertEqual(appliedFrames, [initial, retargeted])
        XCTAssertEqual(island.lastAppliedFrame, retargeted)
    }

    private func makeFixture(screenDisplayId: CGDirectDisplayID? = nil) -> Fixture {
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.1,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
        let model = WorkspaceBarModel(snapshot: snapshot)
        let measurementView = MeasurementView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
        let primary = WorkspaceBarIslandPanel(
            panel: WorkspaceBarPanel.defaultPanel(),
            rootView: WorkspaceBarView(
                model: model,
                motionPolicy: MotionPolicy(animationsEnabled: false),
                onFocusWorkspace: { _ in },
                onFocusWindow: { _ in },
                onActivateScratchpad: { _ in }
            ),
            resolved: makeResolved()
        )
        return Fixture(
            instance: WorkspaceBarInstance(
                monitor: makeMonitor(),
                primary: primary,
                measurementView: measurementView,
                model: model,
                screenDisplayId: screenDisplayId
            ),
            measurementView: measurementView
        )
    }

    private func makeMonitor(width: CGFloat = 1200) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: width, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: 772),
            hasNotch: false,
            name: "Test"
        )
    }

    private func makeResolved() -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: .off,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            position: .overlappingMenuBar,
            windowLevel: .popup,
            height: 24,
            backgroundOpacity: 0.1,
            xOffset: 0,
            yOffset: 0,
            accentColor: nil,
            textColor: nil
        )
    }
}
