import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeLifecycleTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.lifecycle.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeLifecycleMonitor(
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

@Suite struct ServiceLifecycleManagerTests {
    @Test @MainActor func monitorChangeKeepsForcedWorkspaceAuthoritativeAfterRestore() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "3", monitorAssignment: .numbered(2), isPersistent: true)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        let oldLeft = makeLifecycleMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeLifecycleMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        controller.workspaceManager.updateMonitors([oldLeft, oldRight])
        controller.workspaceManager.reconcileAfterMonitorChange()

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws3 = controller.workspaceManager.workspaceId(for: "3", createIfMissing: true) else {
            Issue.record("Failed to create expected test workspaces")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(controller.workspaceManager.setActiveWorkspace(ws3, on: oldRight.id))

        let newLeft = makeLifecycleMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeLifecycleMonitor(displayId: 100, name: "L", x: 1920, y: 0)

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [newLeft, newRight],
            performPostUpdateActions: false
        )

        let sorted = Monitor.sortedByPosition(controller.workspaceManager.monitors)
        guard let forcedTarget = MonitorDescription.sequenceNumber(2).resolveMonitor(sortedMonitors: sorted) else {
            Issue.record("Failed to resolve forced monitor target")
            return
        }

        #expect(forcedTarget.id == newRight.id)
        #expect(controller.workspaceManager.activeWorkspace(on: forcedTarget.id)?.id == ws3)
        #expect(controller.workspaceManager.activeWorkspace(on: newLeft.id)?.id != ws3)
    }
}
