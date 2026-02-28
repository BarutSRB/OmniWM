import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeWorkspaceManagerTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.workspace-manager.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeWorkspaceManagerTestMonitor(
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

@Suite struct WorkspaceManagerTests {
    @Test @MainActor func equalDistanceRemapUsesDeterministicTieBreak() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)

        let oldLeft = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Old Left", x: 0, y: 0)
        let oldRight = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Old Right", x: 2000, y: 0)
        manager.updateMonitors([oldLeft, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(manager.setActiveWorkspace(ws2, on: oldRight.id))

        let newCenter = makeWorkspaceManagerTestMonitor(displayId: 30, name: "New Center", x: 1000, y: 0)
        let newFar = makeWorkspaceManagerTestMonitor(displayId: 40, name: "New Far", x: 3000, y: 0)
        manager.updateMonitors([newCenter, newFar])

        #expect(manager.activeWorkspace(on: newCenter.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: newFar.id)?.id == ws2)
    }

    @Test @MainActor func adjacentMonitorPrefersClosestDirectionalCandidate() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let manager = WorkspaceManager(settings: settings)

        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: -1400, y: 0)
        let center = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Center", x: 0, y: 0)
        let rightNear = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Right Near", x: 1100, y: 350)
        let rightFar = makeWorkspaceManagerTestMonitor(displayId: 40, name: "Right Far", x: 1800, y: 0)
        manager.updateMonitors([left, center, rightNear, rightFar])

        #expect(manager.adjacentMonitor(from: center.id, direction: .right)?.id == rightNear.id)
        #expect(manager.adjacentMonitor(from: center.id, direction: .left)?.id == left.id)
    }

    @Test @MainActor func adjacentMonitorWrapsToOppositeExtremeWhenNoDirectionalCandidate() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let manager = WorkspaceManager(settings: settings)

        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: -2000, y: 0)
        let center = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Center", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Right", x: 2000, y: 0)
        manager.updateMonitors([left, center, right])

        #expect(manager.adjacentMonitor(from: right.id, direction: .right, wrapAround: false) == nil)
        #expect(manager.adjacentMonitor(from: right.id, direction: .right, wrapAround: true)?.id == left.id)
        #expect(manager.adjacentMonitor(from: left.id, direction: .left, wrapAround: true)?.id == right.id)
    }
}
