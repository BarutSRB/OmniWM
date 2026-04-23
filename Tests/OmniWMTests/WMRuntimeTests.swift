// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

private enum RuntimeFocusOperationEvent: Equatable {
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
}

private final class RuntimeFocusOperationRecorder {
    var events: [RuntimeFocusOperationEvent] = []
}

@MainActor
private func makeRuntimeFocusOperations(
    recorder: RuntimeFocusOperationRecorder
) -> WindowFocusOperations {
    WindowFocusOperations(
        activateApp: { pid in
            recorder.events.append(.activate(pid))
        },
        focusSpecificWindow: { pid, windowId, _ in
            recorder.events.append(.focus(pid, windowId))
        },
        raiseWindow: { _ in
            recorder.events.append(.raise)
        }
    )
}

@MainActor
private func makeRuntimeTestSettings() -> SettingsStore {
    let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
    settings.workspaceConfigurations = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main)
    ]
    return settings
}

@Suite(.serialized) struct WMRuntimeTests {
    @Test @MainActor func runtimeOwnsFocusOrchestrationForControllerRequests() {
        resetSharedControllerStateForTests()
        let recorder = RuntimeFocusOperationRecorder()
        let runtime = WMRuntime(
            settings: makeRuntimeTestSettings(),
            windowFocusOperations: makeRuntimeFocusOperations(recorder: recorder)
        )
        let controller = runtime.controller
        let monitor = makeLayoutPlanTestMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false) else {
            Issue.record("Expected a visible workspace for runtime focus orchestration test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 321),
            pid: getpid(),
            windowId: 321,
            to: workspaceId
        )

        controller.focusWindow(token)

        #expect(runtime.orchestrationSnapshot.focus.activeManagedRequest?.token == token)
        #expect(controller.workspaceManager.pendingFocusedToken == token)
        #expect(recorder.events == [.activate(getpid()), .focus(getpid(), 321), .raise])
    }

    @Test @MainActor func runtimeTracksRefreshPlanningAndCompletion() async {
        resetSharedControllerStateForTests()
        let runtime = WMRuntime(settings: makeRuntimeTestSettings())
        let controller = runtime.controller
        controller.workspaceManager.applyMonitorConfigurationChange([makeLayoutPlanTestMonitor()])
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { _ in
            try? await Task.sleep(for: .milliseconds(25))
            return true
        }

        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)

        #expect(runtime.refreshSnapshot.activeRefresh?.kind == .visibilityRefresh)
        #expect(runtime.refreshSnapshot.activeRefresh?.reason == .appHidden)

        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(runtime.refreshSnapshot.activeRefresh == nil)
        #expect(runtime.refreshSnapshot.pendingRefresh == nil)
    }

    @Test @MainActor func runtimeOwnsAppliedConfigurationSnapshots() {
        resetSharedControllerStateForTests()
        let settings = makeRuntimeTestSettings()
        let runtime = WMRuntime(settings: settings)
        let controller = runtime.controller

        let originalValue = runtime.configuration.focusFollowsMouse
        let updatedValue = !originalValue

        settings.focusFollowsMouse = updatedValue

        #expect(runtime.configuration.focusFollowsMouse == originalValue)

        controller.setFocusFollowsMouse(updatedValue)

        #expect(runtime.configuration.focusFollowsMouse == updatedValue)
        #expect(controller.focusFollowsMouseEnabled == updatedValue)
    }
}
