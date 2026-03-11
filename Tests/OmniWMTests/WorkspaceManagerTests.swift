import ApplicationServices
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

private func makeWorkspaceManagerTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
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
        manager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(manager.setActiveWorkspace(ws2, on: oldRight.id))

        let newCenter = makeWorkspaceManagerTestMonitor(displayId: 30, name: "New Center", x: 1000, y: 0)
        let newFar = makeWorkspaceManagerTestMonitor(displayId: 40, name: "New Far", x: 3000, y: 0)
        manager.applyMonitorConfigurationChange([newCenter, newFar])

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
        manager.applyMonitorConfigurationChange([left, center, rightNear, rightFar])

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
        manager.applyMonitorConfigurationChange([left, center, right])

        #expect(manager.adjacentMonitor(from: right.id, direction: .right, wrapAround: false) == nil)
        #expect(manager.adjacentMonitor(from: right.id, direction: .right, wrapAround: true)?.id == left.id)
        #expect(manager.adjacentMonitor(from: left.id, direction: .left, wrapAround: true)?.id == right.id)
    }

    @Test @MainActor func setActiveWorkspaceTracksInteractionMonitorOwnership() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.interactionMonitorId == left.id)

        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws2)
    }

    @Test @MainActor func moveWorkspaceToMonitorUpdatesVisibleAndPreviousWorkspaceState() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))

        #expect(manager.moveWorkspaceToMonitor(ws1, to: right.id))
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws1)
        #expect(manager.previousWorkspace(on: right.id)?.id == ws2)
        #expect(manager.activeWorkspace(on: left.id)?.id != ws1)
    }

    @Test @MainActor func setManagedFocusAtomicallyUpdatesOwnerState() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.setInteractionMonitor(left.id))
        #expect(manager.enterNonManagedFocus(appFullscreen: true))

        let handle = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2101),
            pid: getpid(),
            windowId: 2101,
            to: ws2
        )

        #expect(manager.setManagedFocus(handle, in: ws2, onMonitor: right.id))
        #expect(manager.focusedHandle == handle)
        #expect(manager.lastFocusedHandle(in: ws2) == handle)
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.isNonManagedFocusActive == false)
        #expect(manager.isAppFullscreenActive == false)
    }

    @Test @MainActor func resolveWorkspaceFocusIgnoresDeadRememberedHandles() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let survivor = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2201),
            pid: 2201,
            windowId: 2201,
            to: workspaceId
        )
        let removed = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2202),
            pid: 2202,
            windowId: 2202,
            to: workspaceId
        )

        _ = manager.setManagedFocus(removed, in: workspaceId, onMonitor: monitor.id)
        _ = manager.removeWindow(pid: 2202, windowId: 2202)
        _ = manager.rememberFocus(removed, in: workspaceId)

        #expect(manager.resolveWorkspaceFocus(in: workspaceId) == survivor)
        #expect(manager.resolveAndSetWorkspaceFocus(in: workspaceId, onMonitor: monitor.id) == survivor)
        #expect(manager.focusedHandle == survivor)
    }

    @Test @MainActor func removeMissingClearsDeadFocusMemoryAndRecoverySelectsSurvivorAfterConsecutiveMisses() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let survivor = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2301),
            pid: 2301,
            windowId: 2301,
            to: workspaceId
        )
        let removed = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2302),
            pid: 2302,
            windowId: 2302,
            to: workspaceId
        )

        _ = manager.setManagedFocus(removed, in: workspaceId, onMonitor: monitor.id)

        manager.removeMissing(
            keys: Set([.init(pid: 2301, windowId: 2301)]),
            requiredConsecutiveMisses: 2
        )
        #expect(manager.entry(for: removed) != nil)
        #expect(manager.focusedHandle == removed)

        manager.removeMissing(
            keys: Set([.init(pid: 2301, windowId: 2301)]),
            requiredConsecutiveMisses: 2
        )

        #expect(manager.entry(for: removed) == nil)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: workspaceId) == nil)
        #expect(manager.resolveAndSetWorkspaceFocus(in: workspaceId, onMonitor: monitor.id) == survivor)
        #expect(manager.focusedHandle == survivor)
        #expect(manager.lastFocusedHandle(in: workspaceId) == survivor)
    }

    @Test @MainActor func removeWindowsForAppClearsFocusedAndRememberedHandles() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        let pid: pid_t = 3303
        let handle1 = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 3301),
            pid: pid,
            windowId: 3301,
            to: ws1
        )
        let handle2 = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 3302),
            pid: pid,
            windowId: 3302,
            to: ws2
        )

        _ = manager.rememberFocus(handle1, in: ws1)
        _ = manager.setManagedFocus(handle2, in: ws2, onMonitor: right.id)

        let affected = manager.removeWindowsForApp(pid: pid)

        #expect(affected == Set([ws1, ws2]))
        #expect(manager.entries(forPid: pid).isEmpty)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: ws1) == nil)
        #expect(manager.lastFocusedHandle(in: ws2) == nil)
        #expect(manager.resolveWorkspaceFocus(in: ws1) == nil)
        #expect(manager.resolveWorkspaceFocus(in: ws2) == nil)
    }

    @Test @MainActor func swapWorkspacesMovesVisibleAndAssignedWorkspaceStateTogether() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.swapWorkspaces(ws1, on: left.id, with: ws2, on: right.id))
        #expect(manager.activeWorkspace(on: left.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws1)
        #expect(manager.previousWorkspace(on: right.id)?.id == ws2)
        #expect(manager.monitorId(for: ws1) == right.id)
        #expect(manager.monitorId(for: ws2) == left.id)
    }

    @Test @MainActor func summonWorkspaceMovesVisibleOwnershipToTargetMonitor() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.setInteractionMonitor(left.id))
        #expect(manager.summonWorkspace(ws2, to: left.id))
        #expect(manager.activeWorkspace(on: left.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: left.id)?.id == ws1)
        #expect(manager.monitorId(for: ws2) == left.id)
        #expect(manager.interactionMonitorId == left.id)
        #expect(manager.activeWorkspace(on: right.id)?.id != ws2)
    }

    @Test @MainActor func viewportStatePersistsAcrossWorkspaceTransitions() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        var viewport = manager.niriViewportState(for: ws1)
        viewport.activeColumnIndex = 2
        manager.updateNiriViewportState(viewport, for: ws1)

        #expect(manager.setActiveWorkspace(ws1, on: monitor.id))
        #expect(manager.setActiveWorkspace(ws2, on: monitor.id))
        #expect(manager.setActiveWorkspace(ws1, on: monitor.id))
        #expect(manager.niriViewportState(for: ws1).activeColumnIndex == 2)
    }

    @Test @MainActor func applyMonitorConfigurationChangeKeepsForcedWorkspaceAuthoritativeAfterRestore() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "3", monitorAssignment: .numbered(2), isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let oldLeft = makeWorkspaceManagerTestMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeWorkspaceManagerTestMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws3 = manager.workspaceId(for: "3", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(manager.setActiveWorkspace(ws3, on: oldRight.id))

        let newLeft = makeWorkspaceManagerTestMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeWorkspaceManagerTestMonitor(displayId: 100, name: "L", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([newLeft, newRight])

        let sorted = Monitor.sortedByPosition(manager.monitors)
        guard let forcedTarget = MonitorDescription.sequenceNumber(2).resolveMonitor(sortedMonitors: sorted) else {
            Issue.record("Failed to resolve forced monitor target")
            return
        }

        #expect(forcedTarget.id == newRight.id)
        #expect(manager.activeWorkspace(on: forcedTarget.id)?.id == ws3)
        #expect(manager.activeWorkspace(on: newLeft.id)?.id != ws3)
    }

    @Test @MainActor func applyMonitorConfigurationChangePreservesViewportStateOnReconnect() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let oldLeft = makeWorkspaceManagerTestMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeWorkspaceManagerTestMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(manager.setActiveWorkspace(ws2, on: oldRight.id))

        let selectedNodeId = NodeId()
        manager.withNiriViewportState(for: ws2) { state in
            state.activeColumnIndex = 3
            state.selectedNodeId = selectedNodeId
        }

        let newLeft = makeWorkspaceManagerTestMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeWorkspaceManagerTestMonitor(displayId: 100, name: "L", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([newLeft, newRight])

        #expect(manager.activeWorkspace(on: newLeft.id)?.id == ws2)
        #expect(manager.niriViewportState(for: ws2).activeColumnIndex == 3)
        #expect(manager.niriViewportState(for: ws2).selectedNodeId == selectedNodeId)
    }

    @Test @MainActor func applyMonitorConfigurationChangeClearsInvalidPreviousInteractionMonitor() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.previousInteractionMonitorId == left.id)

        manager.applyMonitorConfigurationChange([right])

        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == nil)
    }

    @Test @MainActor func applyMonitorConfigurationChangeNormalizesInvalidInteractionMonitor() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .any, isPersistent: true),
            WorkspaceConfiguration(name: "2", monitorAssignment: .any, isPersistent: true)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        _ = manager.setInteractionMonitor(right.id, preservePrevious: false)
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == nil)

        manager.applyMonitorConfigurationChange([left])

        #expect(manager.interactionMonitorId == left.id)
        #expect(manager.previousInteractionMonitorId == nil)
    }
}
