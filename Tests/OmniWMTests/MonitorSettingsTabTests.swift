// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeMonitorTabTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func makeMonitorTabTestDefaults() -> UserDefaults {
    UserDefaults(suiteName: "com.omniwm.monitor-tab-test.\(UUID().uuidString)")!
}

@Suite struct MonitorSettingsTabTests {
    @Test func normalizedSelectionFallsBackToFirstEffectiveOrderEntryWhenSelectionIsMissing() {
        let right = makeMonitorTabTestMonitor(displayId: 2, name: "Right", x: 1920, y: 0)
        let left = makeMonitorTabTestMonitor(displayId: 1, name: "Left", x: 0, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [right, left],
            orderedMonitorIds: [right.id, left.id]
        )

        let selection = MonitorSettingsTabModel.normalizedSelection(nil, entries: entries)

        #expect(selection == right.id)
    }

    @Test func normalizedSelectionClearsWhenNoMonitorsRemain() {
        let missing = Monitor.ID(displayId: 42)

        let selection = MonitorSettingsTabModel.normalizedSelection(
            missing,
            entries: [MonitorOrderEntry]()
        )

        #expect(selection == nil)
    }

    @Test func displayLabelsDisambiguateDuplicateMonitorNamesByPhysicalOrder() {
        let first = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let second = makeMonitorTabTestMonitor(displayId: 2, name: "Studio Display", x: 1920, y: 0)
        let labels = MonitorSettingsTabModel.displayLabels(for: [second, first])

        #expect(labels[first.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 1))
        #expect(labels[second.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 2))
    }

    @Test func displayLabelsDisambiguateDuplicateMonitorNamesByVerticalOrder() {
        let bottom = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let top = makeMonitorTabTestMonitor(displayId: 2, name: "Studio Display", x: 320, y: 1080)
        let labels = MonitorSettingsTabModel.displayLabels(for: [bottom, top], axis: .vertical)

        #expect(labels[top.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 1))
        #expect(labels[bottom.id] == MonitorDisplayLabel(name: "Studio Display", duplicateIndex: 2))
    }

    @Test func canMoveDisablesLeftAndRightAtSequenceEdges() {
        let left = makeMonitorTabTestMonitor(displayId: 1, name: "Left", x: 0, y: 0)
        let center = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 1920, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [left, center],
            orderedMonitorIds: [left.id, center.id]
        )

        #expect(MonitorSettingsTabModel.canMove(entries: entries, moving: left.id, direction: .left) == false)
        #expect(MonitorSettingsTabModel.canMove(entries: entries, moving: center.id, direction: .right) == false)
        #expect(MonitorSettingsTabModel.canMove(entries: entries, moving: center.id, direction: .left))
    }

    @Test func reorderedMonitorIdsMoveSelectedMonitorLeftAndRight() {
        let left = makeMonitorTabTestMonitor(displayId: 1, name: "Left", x: 0, y: 0)
        let center = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 1920, y: 0)
        let right = makeMonitorTabTestMonitor(displayId: 3, name: "Right", x: 3840, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [left, center, right],
            orderedMonitorIds: [left.id, center.id, right.id]
        )

        let movedLeft = MonitorSettingsTabModel.reorderedMonitorIds(
            entries: entries,
            moving: center.id,
            direction: .left
        )
        let movedRight = MonitorSettingsTabModel.reorderedMonitorIds(
            entries: entries,
            moving: center.id,
            direction: .right
        )

        #expect(movedLeft == [center.id, left.id, right.id])
        #expect(movedRight == [left.id, right.id, center.id])
    }

    @Test func duplicateNamedEntriesStayDistinctWhenReorderingByMonitorId() {
        let first = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let middle = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 1920, y: 0)
        let second = makeMonitorTabTestMonitor(displayId: 3, name: "Studio Display", x: 3840, y: 0)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [first, middle, second],
            orderedMonitorIds: [first.id, middle.id, second.id]
        )

        #expect(entries.map(\.id) == [first.id, middle.id, second.id])
        #expect(entries.first?.displayLabel.duplicateIndex == 1)
        #expect(entries.last?.displayLabel.duplicateIndex == 2)

        let reordered = MonitorSettingsTabModel.reorderedMonitorIds(
            entries: entries,
            moving: second.id,
            direction: .left
        )

        #expect(reordered == [first.id, second.id, middle.id])
    }

    @Test @MainActor func applyReorderCommitsThroughSettingsStoreWhilePreservingDisconnectedEntries() {
        let defaults = makeMonitorTabTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let first = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let second = makeMonitorTabTestMonitor(displayId: 2, name: "Studio Display", x: 1920, y: 0)
        let disconnected = OutputId(displayId: 999, name: "Detached")

        settings.mouseWarpMonitorOrder = [
            OutputId(from: first),
            disconnected,
            OutputId(from: second)
        ]

        let entries = MonitorSettingsTabModel.orderEntries(
            for: [first, second],
            orderedMonitorIds: settings.effectiveMouseWarpMonitorOrder(for: [first, second])
        )

        let didApply = MonitorSettingsTabModel.applyReorder(
            entries: entries,
            moving: second.id,
            direction: .left,
            settings: settings,
            connectedMonitors: [first, second]
        )

        #expect(didApply)
        #expect(settings.mouseWarpMonitorOrder == [
            OutputId(from: second),
            disconnected,
            OutputId(from: first)
        ])
    }

    @Test func orderEntriesUseVerticalAxisForDuplicateNameResolution() {
        let bottom = makeMonitorTabTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let center = makeMonitorTabTestMonitor(displayId: 2, name: "Center", x: 0, y: 1080)
        let top = makeMonitorTabTestMonitor(displayId: 3, name: "Studio Display", x: 320, y: 2160)
        let entries = MonitorSettingsTabModel.orderEntries(
            for: [bottom, center, top],
            orderedMonitorIds: [top.id, center.id, bottom.id],
            axis: .vertical
        )

        #expect(entries.map(\.id) == [top.id, center.id, bottom.id])
        #expect(entries.first?.displayLabel.duplicateIndex == 1)
        #expect(entries.last?.displayLabel.duplicateIndex == 2)
    }
}
