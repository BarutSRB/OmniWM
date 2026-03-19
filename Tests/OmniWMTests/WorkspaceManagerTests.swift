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

@MainActor
private func addWorkspaceManagerTestHandle(
    manager: WorkspaceManager,
    windowId: Int,
    pid: pid_t = getpid(),
    workspaceId: WorkspaceDescriptor.ID
) -> WindowHandle {
    let token = manager.addWindow(
        makeWorkspaceManagerTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId
    )
    guard let handle = manager.handle(for: token) else {
        fatalError("Expected bridge handle for workspace manager test")
    }
    return handle
}

private func workspaceConfigurations(
    _ assignments: [(String, MonitorAssignment)]
) -> [WorkspaceConfiguration] {
    assignments.map { name, assignment in
        WorkspaceConfiguration(name: name, monitorAssignment: assignment)
    }
}

@Suite struct WorkspaceManagerTests {
    @Test @MainActor func equalDistanceRemapUsesDeterministicTieBreak() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

    @Test @MainActor func workspaceIdsOutsideConfiguredSetAreNotSynthesized() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        #expect(manager.workspaceId(for: "1", createIfMissing: true) != nil)
        #expect(manager.workspaceId(for: "2", createIfMissing: true) == nil)
        #expect(manager.workspaceId(for: "10", createIfMissing: true) == nil)
    }

    @Test @MainActor func specificDisplayWorkspaceMigratesToFallbackSessionAndReturnsWhenTargetReappears() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .specificDisplay(OutputId(displayId: 300, name: "Detached")))
        ])

        let manager = WorkspaceManager(settings: settings)
        let main = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        let side = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Side", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([main, side])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.activeWorkspace(on: side.id) == nil)
        #expect(manager.monitorId(for: ws2) == main.id)
        #expect(manager.workspaces(on: main.id).map(\.id) == [ws1, ws2])

        let detached = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Detached", x: 3840, y: 0)
        manager.applyMonitorConfigurationChange([main, side, detached])

        #expect(manager.activeWorkspace(on: detached.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == detached.id)

        manager.applyMonitorConfigurationChange([main, side])

        #expect(manager.activeWorkspace(on: main.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: side.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: side.id)?.id == nil)
        #expect(manager.monitorId(for: ws2) == side.id)

        let restoredDetached = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Detached", x: 3840, y: 0)
        manager.applyMonitorConfigurationChange([main, side, restoredDetached])

        #expect(manager.activeWorkspace(on: main.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: side.id) == nil)
        #expect(manager.activeWorkspace(on: restoredDetached.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == restoredDetached.id)
    }

    @Test @MainActor func secondaryWorkspacesCollapseOntoRemainingMonitorAndReturnWhenSecondaryReappears() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))

        manager.applyMonitorConfigurationChange([left])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: left.id)?.id == ws1)
        #expect(manager.monitorId(for: ws2) == left.id)
        #expect(manager.workspaces(on: left.id).map(\.id) == [ws1, ws2])

        let restoredRight = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Restored", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, restoredRight])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: restoredRight.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == restoredRight.id)
    }

    @Test @MainActor func setActiveWorkspaceTracksInteractionMonitorOwnership() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

    @Test @MainActor func moveWorkspaceToForeignMonitorIsRejectedWhenHomeMonitorDiffers() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

        #expect(manager.moveWorkspaceToMonitor(ws1, to: right.id) == false)
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: right.id)?.id == nil)
    }

    @Test @MainActor func beginManagedFocusRequestOnlyMutatesPendingState() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2101, workspaceId: ws2)

        #expect(manager.beginManagedFocusRequest(handle, in: ws2, onMonitor: right.id))
        #expect(manager.pendingFocusedHandle == handle)
        #expect(manager.pendingFocusedWorkspaceId == ws2)
        #expect(manager.pendingFocusedMonitorId == right.id)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: ws2) == handle)
        #expect(manager.interactionMonitorId == left.id)
        #expect(manager.isNonManagedFocusActive == true)
        #expect(manager.isAppFullscreenActive == true)
    }

    @Test @MainActor func confirmManagedFocusAtomicallyCommitsOwnerState() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2111, workspaceId: ws2)

        #expect(manager.beginManagedFocusRequest(handle, in: ws2, onMonitor: right.id))
        #expect(manager.confirmManagedFocus(
            handle,
            in: ws2,
            onMonitor: right.id,
            appFullscreen: false,
            activateWorkspaceOnMonitor: true
        ))

        #expect(manager.pendingFocusedHandle == nil)
        #expect(manager.focusedHandle == handle)
        #expect(manager.lastFocusedHandle(in: ws2) == handle)
        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.previousInteractionMonitorId == left.id)
        #expect(manager.isNonManagedFocusActive == false)
        #expect(manager.isAppFullscreenActive == false)
    }

    @Test @MainActor func confirmManagedFocusClearsStalePendingRequestForDifferentWindow() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        #expect(manager.setActiveWorkspace(workspaceId, on: monitor.id))

        let confirmedHandle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2121, workspaceId: workspaceId)
        let pendingHandle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2122, workspaceId: workspaceId)

        #expect(manager.beginManagedFocusRequest(pendingHandle, in: workspaceId, onMonitor: monitor.id))
        #expect(manager.confirmManagedFocus(
            confirmedHandle,
            in: workspaceId,
            onMonitor: monitor.id,
            appFullscreen: false,
            activateWorkspaceOnMonitor: true
        ))

        #expect(manager.pendingFocusedHandle == nil)
        #expect(manager.focusedHandle == confirmedHandle)
        #expect(manager.lastFocusedHandle(in: workspaceId) == confirmedHandle)
        #expect(manager.preferredFocusHandle(in: workspaceId) == confirmedHandle)
    }

    @Test @MainActor func stableTokenFocusBridgeReusesHandleAcrossReupsert() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let token1 = manager.addWindow(makeWorkspaceManagerTestWindow(windowId: 2191), pid: getpid(), windowId: 2191, to: workspaceId)
        guard let handle1 = manager.handle(for: token1) else {
            Issue.record("Missing initial bridge handle")
            return
        }
        _ = manager.setManagedFocus(token1, in: workspaceId, onMonitor: monitor.id)

        let token2 = manager.addWindow(makeWorkspaceManagerTestWindow(windowId: 2191), pid: getpid(), windowId: 2191, to: workspaceId)
        guard let handle2 = manager.handle(for: token2) else {
            Issue.record("Missing refreshed bridge handle")
            return
        }

        #expect(token1 == token2)
        #expect(handle1 === handle2)
        #expect(manager.focusedToken == token1)
        #expect(manager.focusedHandle === handle1)
        #expect(manager.lastFocusedToken(in: workspaceId) == token1)
        #expect(manager.lastFocusedHandle(in: workspaceId) === handle1)
    }

    @Test @MainActor func rekeyWindowPreservesHandleAndFocusState() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 11, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let handle = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 2192,
            pid: 2192,
            workspaceId: workspaceId
        )
        let oldToken = handle.id
        let hiddenState = WindowModel.HiddenState(
            proportionalPosition: CGPoint(x: 0.25, y: 0.75),
            referenceMonitorId: monitor.id,
            workspaceInactive: true,
            offscreenSide: .left
        )
        let floatingState = WindowModel.FloatingState(
            lastFrame: CGRect(x: 100, y: 120, width: 500, height: 380),
            normalizedOrigin: CGPoint(x: 0.2, y: 0.3),
            referenceMonitorId: monitor.id,
            restoreToFloating: true
        )
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 320, height: 240),
            maxSize: CGSize(width: 960, height: 720),
            isFixed: false
        )

        _ = manager.setManagedFocus(handle, in: workspaceId, onMonitor: monitor.id)
        _ = manager.beginManagedFocusRequest(handle, in: workspaceId, onMonitor: monitor.id)
        _ = manager.rememberFocus(handle, in: workspaceId)
        manager.setHiddenState(hiddenState, for: handle)
        manager.setFloatingState(floatingState, for: handle.id)
        manager.setManualLayoutOverride(.forceFloat, for: handle.id)
        manager.setLayoutReason(.macosHiddenApp, for: handle)
        manager.setCachedConstraints(constraints, for: handle.id)

        let newToken = WindowToken(pid: oldToken.pid, windowId: 2193)
        let newAXRef = makeWorkspaceManagerTestWindow(windowId: 2193)
        guard let rekeyedEntry = manager.rekeyWindow(from: oldToken, to: newToken, newAXRef: newAXRef) else {
            Issue.record("Failed to rekey window")
            return
        }

        #expect(rekeyedEntry.handle === handle)
        #expect(handle.id == newToken)
        #expect(rekeyedEntry.token == newToken)
        #expect(rekeyedEntry.axRef.windowId == 2193)
        #expect(rekeyedEntry.workspaceId == workspaceId)
        #expect(manager.entry(for: oldToken) == nil)
        #expect(manager.entry(for: newToken) === rekeyedEntry)
        #expect(manager.focusedHandle === handle)
        #expect(manager.focusedToken == newToken)
        #expect(manager.pendingFocusedHandle === handle)
        #expect(manager.pendingFocusedToken == newToken)
        #expect(manager.lastFocusedHandle(in: workspaceId) === handle)

        guard let rekeyedHiddenState = manager.hiddenState(for: newToken) else {
            Issue.record("Missing hidden state after rekey")
            return
        }
        #expect(rekeyedHiddenState.proportionalPosition == hiddenState.proportionalPosition)
        #expect(rekeyedHiddenState.referenceMonitorId == hiddenState.referenceMonitorId)
        #expect(rekeyedHiddenState.workspaceInactive == hiddenState.workspaceInactive)
        #expect(rekeyedHiddenState.offscreenSide == hiddenState.offscreenSide)
        #expect(manager.floatingState(for: newToken) == floatingState)
        #expect(manager.manualLayoutOverride(for: newToken) == .forceFloat)
        #expect(manager.layoutReason(for: newToken) == .macosHiddenApp)
        #expect(manager.cachedConstraints(for: newToken) == constraints)
    }

    @Test @MainActor func floatingFocusDoesNotPoisonTiledPreferredFocus() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 12, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let tiledToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2201),
            pid: 2201,
            windowId: 2201,
            to: workspaceId
        )
        let floatingToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2202),
            pid: 2202,
            windowId: 2202,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.setManagedFocus(tiledToken, in: workspaceId, onMonitor: monitor.id)
        _ = manager.setManagedFocus(floatingToken, in: workspaceId, onMonitor: monitor.id)

        #expect(manager.lastFocusedToken(in: workspaceId) == tiledToken)
        #expect(manager.lastFloatingFocusedToken(in: workspaceId) == floatingToken)
        #expect(manager.preferredFocusToken(in: workspaceId) == tiledToken)
        #expect(manager.resolveWorkspaceFocusToken(in: workspaceId) == tiledToken)
    }

    @Test @MainActor func resolveWorkspaceFocusFallsBackToFloatingWhenNoTiledWindowExists() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 13, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let floatingToken = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2203),
            pid: 2203,
            windowId: 2203,
            to: workspaceId,
            mode: .floating
        )
        _ = manager.setManagedFocus(floatingToken, in: workspaceId, onMonitor: monitor.id)

        #expect(manager.preferredFocusToken(in: workspaceId) == nil)
        #expect(manager.resolveWorkspaceFocusToken(in: workspaceId) == floatingToken)
    }

    @Test @MainActor func resolvedFloatingFrameUsesNormalizedOriginOnMonitorChange() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 14, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 15, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let token = manager.addWindow(
            makeWorkspaceManagerTestWindow(windowId: 2204),
            pid: 2204,
            windowId: 2204,
            to: workspaceId,
            mode: .floating
        )
        manager.setFloatingState(
            .init(
                lastFrame: CGRect(x: 200, y: 150, width: 400, height: 300),
                normalizedOrigin: CGPoint(x: 0.75, y: 0.5),
                referenceMonitorId: left.id,
                restoreToFloating: true
            ),
            for: token
        )

        let resolved = manager.resolvedFloatingFrame(for: token, preferredMonitor: right)

        #expect(resolved == CGRect(x: 3060, y: 390, width: 400, height: 300))
    }

    @Test @MainActor func resolveWorkspaceFocusIgnoresDeadRememberedHandles() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let survivor = addWorkspaceManagerTestHandle(manager: manager, windowId: 2201, pid: 2201, workspaceId: workspaceId)
        let removed = addWorkspaceManagerTestHandle(manager: manager, windowId: 2202, pid: 2202, workspaceId: workspaceId)

        _ = manager.setManagedFocus(removed, in: workspaceId, onMonitor: monitor.id)
        _ = manager.removeWindow(pid: 2202, windowId: 2202)
        _ = manager.rememberFocus(removed, in: workspaceId)

        #expect(manager.resolveWorkspaceFocus(in: workspaceId) == survivor)
        #expect(manager.resolveAndSetWorkspaceFocus(in: workspaceId, onMonitor: monitor.id) == survivor)
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: workspaceId) == survivor)
    }

    @Test @MainActor func removeMissingClearsDeadFocusMemoryAndRecoverySelectsSurvivorAfterConsecutiveMisses() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let survivor = addWorkspaceManagerTestHandle(manager: manager, windowId: 2301, pid: 2301, workspaceId: workspaceId)
        let removed = addWorkspaceManagerTestHandle(manager: manager, windowId: 2302, pid: 2302, workspaceId: workspaceId)

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
        #expect(manager.focusedHandle == nil)
        #expect(manager.lastFocusedHandle(in: workspaceId) == survivor)
    }

    @Test @MainActor func removeMissingDoesNotEvictNativeFullscreenSuspendedWindow() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 31, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let suspended = addWorkspaceManagerTestHandle(manager: manager, windowId: 2311, pid: 2311, workspaceId: workspaceId)
        manager.setLayoutReason(.nativeFullscreen, for: suspended)

        manager.removeMissing(keys: [], requiredConsecutiveMisses: 2)
        manager.removeMissing(keys: [], requiredConsecutiveMisses: 2)

        #expect(manager.entry(for: suspended) != nil)
        #expect(manager.layoutReason(for: suspended) == .nativeFullscreen)
    }

    @Test @MainActor func nativeFullscreenRestoreOnlyClearsTargetRecordWhenSamePidHasMultipleSuspendedWindows() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 10, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 20, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create workspaces")
            return
        }

        let pid: pid_t = 4601
        let token1 = manager.addWindow(makeWorkspaceManagerTestWindow(windowId: 2321), pid: pid, windowId: 2321, to: ws1)
        let token2 = manager.addWindow(makeWorkspaceManagerTestWindow(windowId: 2322), pid: pid, windowId: 2322, to: ws2)

        _ = manager.requestNativeFullscreenEnter(token1, in: ws1)
        _ = manager.markNativeFullscreenSuspended(token1)
        _ = manager.requestNativeFullscreenEnter(token2, in: ws2)
        _ = manager.markNativeFullscreenSuspended(token2)
        _ = manager.requestNativeFullscreenExit(token2, initiatedByCommand: true)
        _ = manager.restoreNativeFullscreenRecord(for: token2)

        #expect(manager.nativeFullscreenRecord(for: token2) == nil)
        #expect(manager.layoutReason(for: token2) == .standard)
        #expect(manager.layoutReason(for: token1) == .nativeFullscreen)
        #expect(manager.nativeFullscreenCommandTarget(frontmostToken: token1) == token1)
    }

    @Test @MainActor func monitorReconnectPrefersFocusedWorkspaceMonitorForInteractionState() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 2401, workspaceId: ws2)
        #expect(manager.setManagedFocus(handle, in: ws2, onMonitor: right.id))

        let replacement = makeWorkspaceManagerTestMonitor(displayId: 30, name: "Replacement", x: -1920, y: 0)
        manager.applyMonitorConfigurationChange([replacement, right])

        #expect(manager.interactionMonitorId == right.id)
        #expect(manager.focusedHandle == handle)
    }

    @Test @MainActor func removeWindowsForAppClearsFocusedAndRememberedHandles() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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
        let handle1 = addWorkspaceManagerTestHandle(manager: manager, windowId: 3301, pid: pid, workspaceId: ws1)
        let handle2 = addWorkspaceManagerTestHandle(manager: manager, windowId: 3302, pid: pid, workspaceId: ws2)

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

    @Test @MainActor func swapWorkspacesAcrossHomeMonitorsIsRejected() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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
        #expect(manager.swapWorkspaces(ws1, on: left.id, with: ws2, on: right.id) == false)
        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.previousWorkspace(on: left.id)?.id == nil)
        #expect(manager.activeWorkspace(on: right.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: right.id)?.id == nil)
        #expect(manager.monitorId(for: ws1) == left.id)
        #expect(manager.monitorId(for: ws2) == right.id)
    }

    @Test @MainActor func viewportStatePersistsAcrossWorkspaceTransitions() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
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
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("3", .secondary)
        ])

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
        guard let forcedTarget = MonitorDescription.secondary.resolveMonitor(sortedMonitors: sorted) else {
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
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

        manager.applyMonitorConfigurationChange([oldLeft])

        #expect(manager.activeWorkspace(on: oldLeft.id)?.id == ws2)
        #expect(manager.previousWorkspace(on: oldLeft.id)?.id == ws1)
        #expect(manager.monitorId(for: ws2) == oldLeft.id)
        #expect(manager.niriViewportState(for: ws2).activeColumnIndex == 3)
        #expect(manager.niriViewportState(for: ws2).selectedNodeId == selectedNodeId)

        let restoredRight = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Replacement", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([oldLeft, restoredRight])

        #expect(manager.activeWorkspace(on: oldLeft.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: restoredRight.id)?.id == ws2)
        #expect(manager.monitorId(for: ws2) == restoredRight.id)
        #expect(manager.niriViewportState(for: ws2).activeColumnIndex == 3)
        #expect(manager.niriViewportState(for: ws2).selectedNodeId == selectedNodeId)
    }

    @Test @MainActor func reconnectRestoresPreviouslyVisibleWorkspaceWhenMonitorOwnsMultipleWorkspaces() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary),
            ("3", .secondary)
        ])

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 200, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = manager.workspaceId(for: "2", createIfMissing: true),
              let ws3 = manager.workspaceId(for: "3", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.setActiveWorkspace(ws1, on: left.id))
        #expect(manager.setActiveWorkspace(ws2, on: right.id))
        #expect(manager.setActiveWorkspace(ws3, on: right.id))

        let selectedNodeId = NodeId()
        manager.withNiriViewportState(for: ws3) { state in
            state.activeColumnIndex = 4
            state.selectedNodeId = selectedNodeId
        }

        manager.applyMonitorConfigurationChange([left])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws3)
        #expect(manager.previousWorkspace(on: left.id)?.id == ws1)
        #expect(manager.monitorId(for: ws2) == left.id)
        #expect(manager.monitorId(for: ws3) == left.id)
        #expect(manager.workspaces(on: left.id).map(\.id) == [ws1, ws2, ws3])

        let restoredRight = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Replacement", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, restoredRight])

        #expect(manager.activeWorkspace(on: left.id)?.id == ws1)
        #expect(manager.activeWorkspace(on: restoredRight.id)?.id == ws3)
        #expect(manager.monitorId(for: ws2) == restoredRight.id)
        #expect(manager.monitorId(for: ws3) == restoredRight.id)
        #expect(manager.niriViewportState(for: ws3).activeColumnIndex == 4)
        #expect(manager.niriViewportState(for: ws3).selectedNodeId == selectedNodeId)
    }

    @Test @MainActor func applyMonitorConfigurationChangeClearsInvalidPreviousInteractionMonitor() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("2", .secondary)
        ])

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

    @Test @MainActor func removingVisibleWorkspaceFallsBackToLowestAssignedIdOnMonitor() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = workspaceConfigurations([
            ("1", .main),
            ("3", .main)
        ])

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 100, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = manager.workspaceId(for: "1", createIfMissing: true),
              let ws3 = manager.workspaceId(for: "3", createIfMissing: true)
        else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(manager.activeWorkspace(on: monitor.id)?.id == ws1)
        #expect(manager.setActiveWorkspace(ws3, on: monitor.id))
        #expect(manager.activeWorkspace(on: monitor.id)?.id == ws3)

        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]
        manager.applySettings()

        #expect(manager.activeWorkspace(on: monitor.id)?.id == ws1)
        #expect(manager.workspaceId(named: "3") == nil)
    }

    @Test @MainActor func applySessionPatchCommitsViewportAndRememberedFocusAtomically() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 300, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 3201, workspaceId: workspaceId)
        let selectedNodeId = NodeId()
        var viewportState = manager.niriViewportState(for: workspaceId)
        viewportState.selectedNodeId = selectedNodeId
        viewportState.activeColumnIndex = 2

        #expect(
            manager.applySessionPatch(
                .init(
                    workspaceId: workspaceId,
                    viewportState: viewportState,
                    rememberedFocusToken: handle.id
                )
            )
        )
        #expect(manager.niriViewportState(for: workspaceId).selectedNodeId == selectedNodeId)
        #expect(manager.niriViewportState(for: workspaceId).activeColumnIndex == 2)
        #expect(manager.lastFocusedToken(in: workspaceId) == handle.id)
    }

    @Test @MainActor func applySessionTransferMovesViewportAndFocusMemoryTogether() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let left = makeWorkspaceManagerTestMonitor(displayId: 310, name: "Left", x: 0, y: 0)
        let right = makeWorkspaceManagerTestMonitor(displayId: 320, name: "Right", x: 1920, y: 0)
        manager.applyMonitorConfigurationChange([left, right])

        guard let sourceWorkspaceId = manager.workspaceId(for: "1", createIfMissing: true),
              let targetWorkspaceId = manager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create workspaces")
            return
        }

        let sourceHandle = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 3301,
            workspaceId: sourceWorkspaceId
        )
        let targetHandle = addWorkspaceManagerTestHandle(
            manager: manager,
            windowId: 3302,
            workspaceId: targetWorkspaceId
        )

        var sourceState = manager.niriViewportState(for: sourceWorkspaceId)
        sourceState.selectedNodeId = NodeId()
        var targetState = manager.niriViewportState(for: targetWorkspaceId)
        targetState.selectedNodeId = NodeId()

        #expect(
            manager.applySessionTransfer(
                .init(
                    sourcePatch: .init(
                        workspaceId: sourceWorkspaceId,
                        viewportState: sourceState,
                        rememberedFocusToken: sourceHandle.id
                    ),
                    targetPatch: .init(
                        workspaceId: targetWorkspaceId,
                        viewportState: targetState,
                        rememberedFocusToken: targetHandle.id
                    )
                )
            )
        )
        #expect(manager.niriViewportState(for: sourceWorkspaceId).selectedNodeId == sourceState.selectedNodeId)
        #expect(manager.niriViewportState(for: targetWorkspaceId).selectedNodeId == targetState.selectedNodeId)
        #expect(manager.lastFocusedToken(in: sourceWorkspaceId) == sourceHandle.id)
        #expect(manager.lastFocusedToken(in: targetWorkspaceId) == targetHandle.id)
    }

    @Test @MainActor func commitWorkspaceSelectionUpdatesSelectedNodeAndRememberedFocusAtomically() {
        let defaults = makeWorkspaceManagerTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let manager = WorkspaceManager(settings: settings)
        let monitor = makeWorkspaceManagerTestMonitor(displayId: 330, name: "Main", x: 0, y: 0)
        manager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = manager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create workspace")
            return
        }

        let handle = addWorkspaceManagerTestHandle(manager: manager, windowId: 3401, workspaceId: workspaceId)
        let selectedNodeId = NodeId()

        #expect(
            manager.commitWorkspaceSelection(
                nodeId: selectedNodeId,
                focusedToken: handle.id,
                in: workspaceId,
                onMonitor: monitor.id
            )
        )
        #expect(manager.niriViewportState(for: workspaceId).selectedNodeId == selectedNodeId)
        #expect(manager.lastFocusedToken(in: workspaceId) == handle.id)
    }
}
