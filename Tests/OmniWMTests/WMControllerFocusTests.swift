import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private enum FocusOperationEvent: Equatable {
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
}

private func makeFocusTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.focus-order.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeFocusTestMonitor(
    displayId: CGDirectDisplayID = 1,
    name: String = "Main",
    x: CGFloat = 0,
    y: CGFloat = 0,
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

private func makeFocusTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private final class NotificationValueBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private func makeFocusTestController(
    windowFocusOperations: WindowFocusOperations
) -> (controller: WMController, workspaceId: WorkspaceDescriptor.ID, handle: WindowHandle) {
    let settings = SettingsStore(defaults: makeFocusTestDefaults())
    let controller = WMController(settings: settings, windowFocusOperations: windowFocusOperations)
    let monitor = makeFocusTestMonitor()
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])

    guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else {
        fatalError("Expected a visible workspace for focus test setup")
    }

    let window = makeFocusTestWindow()
    let handle = controller.workspaceManager.addWindow(window, pid: getpid(), windowId: window.windowId, to: workspaceId)
    return (controller, workspaceId, handle)
}

@MainActor
private func makeTwoMonitorFocusController(
    windowFocusOperations: WindowFocusOperations
) -> (
    controller: WMController,
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor,
    primaryWorkspaceId: WorkspaceDescriptor.ID,
    secondaryWorkspaceId: WorkspaceDescriptor.ID
) {
    let settings = SettingsStore(defaults: makeFocusTestDefaults())
    let controller = WMController(settings: settings, windowFocusOperations: windowFocusOperations)
    let primaryMonitor = makeFocusTestMonitor()
    let secondaryMonitor = makeFocusTestMonitor(displayId: 2, name: "Secondary", x: 1920)
    controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

    guard let primaryWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id,
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
    else {
        fatalError("Expected two-monitor focus test fixture")
    }

    controller.workspaceManager.assignWorkspaceToMonitor(secondaryWorkspaceId, monitorId: secondaryMonitor.id)
    _ = controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id)
    _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)

    return (controller, primaryMonitor, secondaryMonitor, primaryWorkspaceId, secondaryWorkspaceId)
}

@MainActor
private func waitForFocusRefresh(on controller: WMController) async {
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
}

@Suite struct WMControllerFocusTests {
    @Test @MainActor func focusWindowPerformsActivatePrivateFocusAndRaiseInOrder() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)

        controller.focusWindow(handle)

        #expect(events == [
            .activate(getpid()),
            .focus(getpid(), 101),
            .raise
        ])
    }

    @Test @MainActor func focusWindowClearsNonManagedFocusAndRecordsWorkspaceMemory() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)

        controller.focusWindow(handle)

        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == handle)
    }

    @Test @MainActor func focusWindowClearsFullscreenSessionWithoutBorderRefresh() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        controller.focusWindow(handle)

        #expect(controller.workspaceManager.isAppFullscreenActive == false)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
    }

    @Test @MainActor func workspaceManagerOwnsDurableControllerFocusState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        let monitorId = controller.workspaceManager.monitorId(for: workspaceId)

        _ = controller.workspaceManager.setManagedFocus(handle, in: workspaceId, onMonitor: monitorId)

        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == handle)
        #expect(controller.workspaceManager.interactionMonitorId == monitorId)
    }

    @Test @MainActor func focusNotificationsTrackWorkspaceManagerOwnedState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        let secondaryMonitor = makeFocusTestMonitor(
            displayId: 2,
            name: "Secondary",
            x: 1920
        )
        controller.workspaceManager.applyMonitorConfigurationChange([
            makeFocusTestMonitor(),
            secondaryMonitor
        ])

        guard let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create secondary workspace")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(workspace2, on: secondaryMonitor.id))

        let window2 = makeFocusTestWindow(windowId: 202)
        let handle2 = controller.workspaceManager.addWindow(
            window2,
            pid: getpid(),
            windowId: window2.windowId,
            to: workspace2
        )

        let focusHandleId = NotificationValueBox<UUID?>(nil)
        let workspaceIdBox = NotificationValueBox<WorkspaceDescriptor.ID?>(nil)
        let monitorDisplayIdBox = NotificationValueBox<CGDirectDisplayID?>(nil)

        let center = NotificationCenter.default
        let focusObserver = center.addObserver(
            forName: .omniwmFocusChanged,
            object: controller,
            queue: nil
        ) { notification in
            focusHandleId.value = notification.userInfo?[OmniWMFocusNotificationKey.newHandleId] as? UUID
        }
        let workspaceObserver = center.addObserver(
            forName: .omniwmFocusedWorkspaceChanged,
            object: controller,
            queue: nil
        ) { notification in
            workspaceIdBox.value = notification.userInfo?[OmniWMFocusNotificationKey.newWorkspaceId] as? WorkspaceDescriptor.ID
        }
        let monitorObserver = center.addObserver(
            forName: .omniwmFocusedMonitorChanged,
            object: controller,
            queue: nil
        ) { notification in
            monitorDisplayIdBox.value = notification.userInfo?[OmniWMFocusNotificationKey.newMonitorIndex] as? CGDirectDisplayID
        }

        defer {
            center.removeObserver(focusObserver)
            center.removeObserver(workspaceObserver)
            center.removeObserver(monitorObserver)
        }

        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.setManagedFocus(
            handle2,
            in: workspace2,
            onMonitor: secondaryMonitor.id
        )

        #expect(focusHandleId.value == handle2.id)
        #expect(workspaceIdBox.value == workspace2)
        #expect(monitorDisplayIdBox.value == secondaryMonitor.displayId)
    }

    @Test @MainActor func unmanagedAppActivationClearsManagedFocusState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        controller.hasStartedServices = true
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.handleAppActivation(pid: 999_999)

        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == handle)
    }

    @Test @MainActor func focusLastMonitorRestoresPreviousMonitorFocusOwnerState() async {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let fixture = makeTwoMonitorFocusController(windowFocusOperations: operations)
        let primaryHandle = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 301),
            pid: getpid(),
            windowId: 301,
            to: fixture.primaryWorkspaceId
        )
        let secondaryHandle = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 302),
            pid: getpid(),
            windowId: 302,
            to: fixture.secondaryWorkspaceId
        )

        _ = fixture.controller.workspaceManager.setManagedFocus(
            primaryHandle,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )
        _ = fixture.controller.workspaceManager.setManagedFocus(
            secondaryHandle,
            in: fixture.secondaryWorkspaceId,
            onMonitor: fixture.secondaryMonitor.id
        )

        fixture.controller.workspaceNavigationHandler.focusLastMonitor()
        await waitForFocusRefresh(on: fixture.controller)

        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.primaryMonitor.id)
        #expect(fixture.controller.workspaceManager.previousInteractionMonitorId == fixture.secondaryMonitor.id)
        #expect(fixture.controller.workspaceManager.focusedHandle == primaryHandle)
    }

    @Test @MainActor func managedActivationPublishesCoherentCrossMonitorNotifications() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let fixture = makeTwoMonitorFocusController(windowFocusOperations: operations)
        let primaryHandle = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 401),
            pid: getpid(),
            windowId: 401,
            to: fixture.primaryWorkspaceId
        )
        let secondaryHandle = fixture.controller.workspaceManager.addWindow(
            makeFocusTestWindow(windowId: 402),
            pid: getpid(),
            windowId: 402,
            to: fixture.secondaryWorkspaceId
        )
        _ = fixture.controller.workspaceManager.setManagedFocus(
            primaryHandle,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        let focusInfo = NotificationValueBox<[AnyHashable: Any]?>(nil)
        let workspaceInfo = NotificationValueBox<[AnyHashable: Any]?>(nil)
        let monitorInfo = NotificationValueBox<[AnyHashable: Any]?>(nil)

        let center = NotificationCenter.default
        let focusObserver = center.addObserver(
            forName: .omniwmFocusChanged,
            object: fixture.controller,
            queue: nil
        ) { notification in
            focusInfo.value = notification.userInfo
        }
        let workspaceObserver = center.addObserver(
            forName: .omniwmFocusedWorkspaceChanged,
            object: fixture.controller,
            queue: nil
        ) { notification in
            workspaceInfo.value = notification.userInfo
        }
        let monitorObserver = center.addObserver(
            forName: .omniwmFocusedMonitorChanged,
            object: fixture.controller,
            queue: nil
        ) { notification in
            monitorInfo.value = notification.userInfo
        }

        defer {
            center.removeObserver(focusObserver)
            center.removeObserver(workspaceObserver)
            center.removeObserver(monitorObserver)
        }

        guard let entry = fixture.controller.workspaceManager.entry(for: secondaryHandle) else {
            Issue.record("Missing secondary entry")
            return
        }

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        #expect(fixture.controller.workspaceManager.focusedHandle == secondaryHandle)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.secondaryMonitor.id)
        #expect(focusInfo.value?[OmniWMFocusNotificationKey.newHandleId] as? UUID == secondaryHandle.id)
        #expect(workspaceInfo.value?[OmniWMFocusNotificationKey.oldWorkspaceId] as? WorkspaceDescriptor.ID == fixture.primaryWorkspaceId)
        #expect(workspaceInfo.value?[OmniWMFocusNotificationKey.newWorkspaceId] as? WorkspaceDescriptor.ID == fixture.secondaryWorkspaceId)
        #expect(monitorInfo.value?[OmniWMFocusNotificationKey.oldMonitorIndex] as? CGDirectDisplayID == fixture.primaryMonitor.displayId)
        #expect(monitorInfo.value?[OmniWMFocusNotificationKey.newMonitorIndex] as? CGDirectDisplayID == fixture.secondaryMonitor.displayId)
    }

    @Test @MainActor func removingFocusedWindowRecoversFocusToRemainingWindow() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, survivor) = makeFocusTestController(windowFocusOperations: operations)
        let removedWindow = makeFocusTestWindow(windowId: 502)
        let removedHandle = controller.workspaceManager.addWindow(
            removedWindow,
            pid: getpid(),
            windowId: removedWindow.windowId,
            to: workspaceId
        )

        _ = controller.workspaceManager.setManagedFocus(
            removedHandle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        controller.axEventHandler.handleRemoved(pid: getpid(), winId: removedWindow.windowId)

        #expect(controller.workspaceManager.entry(for: removedHandle) == nil)
        #expect(controller.workspaceManager.focusedHandle == survivor)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == survivor)
    }
}
