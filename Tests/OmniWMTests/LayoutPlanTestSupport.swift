// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import CoreGraphics
import Foundation

@testable import OmniWM

func makeLayoutPlanTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.layout-plan.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

func layoutPlanTestMainDisplayId() -> CGDirectDisplayID {
    let mainDisplayId = CGMainDisplayID()
    return mainDisplayId == 0 ? 1 : mainDisplayId
}

func layoutPlanTestSyntheticDisplayId(_ slot: Int) -> CGDirectDisplayID {
    precondition(slot >= 1, "Synthetic display slots start at 1")

    let mainDisplayId = layoutPlanTestMainDisplayId()
    var candidate = CGDirectDisplayID(10_000 + slot)
    if candidate == mainDisplayId {
        candidate = CGDirectDisplayID(20_000 + slot)
    }
    return candidate
}

func makeLayoutPlanTestMonitor(
    displayId: CGDirectDisplayID = layoutPlanTestMainDisplayId(),
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

func makeLayoutPlanPrimaryTestMonitor(
    name: String = "Main",
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    makeLayoutPlanTestMonitor(
        displayId: layoutPlanTestMainDisplayId(),
        name: name,
        x: x,
        y: y,
        width: width,
        height: height
    )
}

func makeLayoutPlanSecondaryTestMonitor(
    slot: Int = 1,
    name: String = "Secondary",
    x: CGFloat = 1920,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    makeLayoutPlanTestMonitor(
        displayId: layoutPlanTestSyntheticDisplayId(slot),
        name: name,
        x: x,
        y: y,
        width: width,
        height: height
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
                requestId: request.requestId,
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
func installAsynchronousFrameApplyContextForLayoutPlanTests(
    on controller: WMController,
    entry: WindowModel.Entry
) async throws -> AppAXContext? {
    controller.axManager.frameApplyOverrideForTests = nil

    guard let context = await AppAXContext.makeForTests(processIdentifier: entry.pid) else {
        return nil
    }

    AppAXContext.contexts[entry.pid] = context
    try await context.installWindowsForTests([entry.axRef])
    return context
}

@MainActor
func makeLayoutPlanTestController(
    monitors: [Monitor] = [makeLayoutPlanTestMonitor()],
    workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ],
    windowFocusOperations: WindowFocusOperations? = nil
) -> WMController {
    resetSharedControllerStateForTests()
    let operations = windowFocusOperations ?? WindowFocusOperations(
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


    controller.setAnimationsEnabled(true, persist: false)
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
        primaryMonitor: makeLayoutPlanPrimaryTestMonitor(
            name: "Primary"
        ),
        secondaryMonitor: makeLayoutPlanSecondaryTestMonitor(
            name: "Secondary",
            x: 1920
        ),
        windowFocusOperations: nil
    )
}

@MainActor
func makeTwoMonitorLayoutPlanTestController(
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor,
    windowFocusOperations: WindowFocusOperations? = nil
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
        ],
        windowFocusOperations: windowFocusOperations
    )

    guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
    else {
        fatalError("Failed to create two-monitor layout plan fixture")
    }

    guard controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id) else {
        fatalError("Failed to activate primary workspace on the primary monitor")
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
func waitForConditionForTests(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    until condition: @MainActor @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
    repeat {
        await Task.yield()
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    } while Date() < deadline

    await Task.yield()
    return condition()
}

func waitForSemaphoreForTests(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
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
