// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeMonitorDescriptionTestMonitor(
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

@Suite struct MonitorDescriptionTests {
    @Test func sortedByPositionUsesDisplayIdForIdenticalOrigins() {
        let highDisplay = makeMonitorDescriptionTestMonitor(displayId: 200, name: "High", x: 0, y: 0)
        let lowDisplay = makeMonitorDescriptionTestMonitor(displayId: 100, name: "Low", x: 0, y: 0)

        let sorted = Monitor.sortedByPosition([highDisplay, lowDisplay])

        #expect(sorted.map(\.displayId) == [100, 200])
    }

    @Test func outputResolvesByExactDisplayId() {
        let mainMonitor = makeMonitorDescriptionTestMonitor(displayId: 100, name: "Main", x: 0, y: 0)
        let second = makeMonitorDescriptionTestMonitor(displayId: 200, name: "Second", x: 1920, y: 0)
        let sorted = Monitor.sortedByPosition([mainMonitor, second])

        let resolved = MonitorDescription.output(OutputId(displayId: 200, name: "Second"))
            .resolveMonitor(sortedMonitors: sorted)

        #expect(resolved?.id == second.id)
    }

    @Test func secondaryResolvesWithThreeMonitors() {
        let mainMonitor = makeMonitorDescriptionTestMonitor(
            displayId: CGMainDisplayID(),
            name: "Main",
            x: 0,
            y: 0
        )
        let second = makeMonitorDescriptionTestMonitor(displayId: 200, name: "Second", x: 1920, y: 0)
        let third = makeMonitorDescriptionTestMonitor(displayId: 300, name: "Third", x: 3840, y: 0)
        let sorted = Monitor.sortedByPosition([mainMonitor, second, third])

        let resolved = MonitorDescription.secondary.resolveMonitor(sortedMonitors: sorted)
        #expect(resolved?.id == second.id)
    }

    @Test func outputRequiresExactDisplayId() {
        let mainMonitor = makeMonitorDescriptionTestMonitor(displayId: 100, name: "Studio Display", x: 0, y: 0)
        let sorted = Monitor.sortedByPosition([mainMonitor])

        let resolved = MonitorDescription.output(OutputId(displayId: 999, name: "Studio Display"))
            .resolveMonitor(sortedMonitors: sorted)

        #expect(resolved == nil)
    }
}
