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
    @Test func parseMainAndSecondaryCaseInsensitive() {
        let parsedMain = parseMonitorDescription("Main")
        let parsedSecondary = parseMonitorDescription("SECONDARY")

        if case let .success(desc) = parsedMain {
            #expect(desc == .main)
        } else {
            Issue.record("Expected case-insensitive parse of 'Main'")
        }

        if case let .success(desc) = parsedSecondary {
            #expect(desc == .secondary)
        } else {
            Issue.record("Expected case-insensitive parse of 'SECONDARY'")
        }
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
}
