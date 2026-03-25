import ApplicationServices
import CoreGraphics
import Foundation

@testable import OmniWM

func makeLayoutPlanTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.layout-plan.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

func makeLayoutPlanTestMonitor(
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

func makeLayoutPlanTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

@MainActor
func installSynchronousFrameApplySuccessOverride(on controller: WMController) {
    controller.axManager.frameApplyOverrideForTests = { requests in
        requests.map { request in
            AXFrameApplyResult(
                pid: request.pid,
                windowId: request.windowId,
                targetFrame: request.frame,
                currentFrameHint: request.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    targetFrame: request.frame,
                    observedFrame: request.frame,
                    writeOrder: AXWindowService.frameWriteOrder(
                        currentFrame: request.currentFrameHint,
                        targetFrame: request.frame
                    ),
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            )
        }
    }
}

@MainActor
func makeLayoutPlanTestController(
    monitors: [Monitor] = [makeLayoutPlanTestMonitor()],
    workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
) -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
    settings.workspaceConfigurations = workspaceConfigurations
    let controller = WMController(
        settings: settings,
        windowFocusOperations: operations
    )
    installSynchronousFrameApplySuccessOverride(on: controller)
    controller.workspaceManager.applyMonitorConfigurationChange(monitors)
    return controller
}

@MainActor
func makeTwoMonitorLayoutPlanTestController() -> (
    controller: WMController,
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor,
    primaryWorkspaceId: WorkspaceDescriptor.ID,
    secondaryWorkspaceId: WorkspaceDescriptor.ID
) {
    makeTwoMonitorLayoutPlanTestController(
        primaryMonitor: makeLayoutPlanTestMonitor(
            displayId: 100,
            name: "Primary"
        ),
        secondaryMonitor: makeLayoutPlanTestMonitor(
            displayId: 200,
            name: "Secondary",
            x: 1920
        )
    )
}

@MainActor
func makeTwoMonitorLayoutPlanTestController(
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor
) -> (
    controller: WMController,
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor,
    primaryWorkspaceId: WorkspaceDescriptor.ID,
    secondaryWorkspaceId: WorkspaceDescriptor.ID
) {
    let controller = makeLayoutPlanTestController(
        monitors: [primaryMonitor, secondaryMonitor],
        workspaceConfigurations: [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
    )

    guard let primaryWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id,
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
    else {
        fatalError("Failed to create two-monitor layout plan fixture")
    }

    guard controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id) else {
        fatalError("Failed to activate secondary workspace on the secondary monitor")
    }
    _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)

    return (controller, primaryMonitor, secondaryMonitor, primaryWorkspaceId, secondaryWorkspaceId)
}

@MainActor
func waitForLayoutPlanRefreshWork(on controller: WMController) async {
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
}

@MainActor
@discardableResult
func addLayoutPlanTestWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int,
    pid: pid_t = getpid()
) -> WindowToken {
    controller.workspaceManager.addWindow(
        makeLayoutPlanTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId
    )
}

@MainActor
func setWorkspaceInactiveHiddenStateForLayoutPlanTests(
    on controller: WMController,
    token: WindowToken,
    monitor: Monitor,
    proportionalPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
) {
    controller.workspaceManager.setHiddenState(
        WindowModel.HiddenState(
            proportionalPosition: proportionalPosition,
            referenceMonitorId: monitor.id,
            workspaceInactive: true
        ),
        for: token
    )
}

@MainActor
func lastAppliedBorderWindowIdForLayoutPlanTests(on controller: WMController) -> Int? {
    controller.borderManager.lastAppliedFocusedWindowIdForTests
}

@MainActor
func lastAppliedBorderFrameForLayoutPlanTests(on controller: WMController) -> CGRect? {
    controller.borderManager.lastAppliedFocusedFrameForTests
}
