// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OmniWMIPC
import Testing

@testable import OmniWM

@Suite(.serialized) struct IPCThroughRuntimeTransactionTests {
    @Test @MainActor func ipcHotkeyTagsSourceAsIPCAndStampsEpoch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let result = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .ipc)
        )

        #expect(result.transactionEpoch.isValid)
        #expect(!result.transaction.hasNoEffects)
        #expect(result.transaction.effects.count == 1)
        if case let .uiActionDispatch(kindForLog, source, _) = result.transaction.effects[0] {
            #expect(kindForLog == "toggle_overview")
            #expect(source == .ipc)
        } else {
            Issue.record("expected uiActionDispatch effect, got \(result.transaction.effects[0])")
        }
        #expect(result.transaction.transactionEpoch == result.transactionEpoch)
        #expect(result.externalCommandResult != nil)
    }

    @Test @MainActor func ipcHotkeySourceForLogReflectsIPCOrigin() {
        let ipcCommand = WMRuntime.typedCommand(for: .focusPrevious, source: .ipc)
        let commandSource = WMRuntime.typedCommand(for: .focusPrevious, source: .command)

        #expect(ipcCommand.sourceForLog == .ipc)
        #expect(commandSource.sourceForLog == .command)
    }

    @Test @MainActor func typedHotkeyKindForLogIsPayloadFreeAndStable() {
        let cases: [(InputBindingTrigger, String)] = [
            (.focus(.left), "focus_action:focus"),
            (.switchWorkspace(7), "workspace_switch_explicit"),
            (.openCommandPalette, "ui_action:open_command_palette")
        ]
        for (hotkey, expected) in cases {
            let command = WMRuntime.typedCommand(for: hotkey, source: .ipc)
            #expect(command.kindForLog == expected)
            #expect(!command.kindForLog.contains("7"))
            #expect(!command.kindForLog.contains("left"))
        }
    }

    @Test @MainActor func consecutiveHotkeysAdvanceTransactionEpoch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let first = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .ipc)
        )
        let second = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .ipc)
        )

        #expect(first.transactionEpoch < second.transactionEpoch)
    }

    @Test @MainActor func typedHotkeyPlanAdvancesEffectRunnerWatermark() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let typed = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "2"))
        )
        let ui = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .ipc)
        )

        #expect(typed.transactionEpoch < ui.transactionEpoch)
        #expect(ui.transaction.effects.count == 1)
        #expect(ui.transaction.transactionEpoch == ui.transactionEpoch)
    }

    @Test @MainActor func ipcWorkspaceSwitchCommandKeepsIPCProvenance() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let result = runtime.submit(
            command: .workspaceSwitch(.explicitFrom(rawWorkspaceID: "2", source: .ipc))
        )

        #expect(result.transactionEpoch.isValid)
        #expect(result.transaction.event == .commandIntent(kindForLog: "workspace_switch_explicit", source: .ipc))
        let activationSources = result.transaction.effects.compactMap { effect -> WMEventSource? in
            if case let .activateTargetWorkspace(_, _, source, _) = effect {
                source
            } else {
                nil
            }
        }
        #expect(activationSources == [.ipc])
    }

    @Test @MainActor func ipcWorkspaceSwitchConfirmationRecordsIPCSource() {
        resetSharedControllerStateForTests()
        let runtime = WMRuntime(settings: makeTransactionTestRuntimeSettings())
        runtime.controller.workspaceManager.applyMonitorConfigurationChange([
            makeLayoutPlanTestMonitor()
        ])
        let monitorId = runtime.controller.workspaceManager.monitors.first!.id
        let workspaceOne = runtime.controller.workspaceManager.workspaceId(
            for: "1",
            createIfMissing: false
        )!
        _ = runtime.controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitorId)

        let result = runtime.submit(
            command: .workspaceSwitch(.explicitFrom(rawWorkspaceID: "2", source: .ipc))
        )

        #expect(runtime.controller.workspaceManager.lastRecordedTransaction == result.transaction)
        guard case let .commandIntent(kindForLog, source) =
            runtime.controller.workspaceManager.lastRecordedTransaction?.event
        else {
            Issue.record("expected workspace-switch command transaction")
            return
        }
        #expect(kindForLog == "workspace_switch_explicit")
        #expect(source == .ipc)
    }

    @Test @MainActor func ipcWorkspaceSwitchHotkeyUsesWorkspaceSwitchCommand() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let result = runtime.submit(
            command: WMRuntime.typedCommand(for: .switchWorkspace(1), source: .ipc)
        )

        #expect(result.transactionEpoch.isValid)
        #expect(result.externalCommandResult == .executed)
        #expect(result.transaction.event == .commandIntent(kindForLog: "workspace_switch_explicit", source: .ipc))
    }

    @Test @MainActor func ipcMoveWindowHotkeyRecordsNestedIPCSource() {
        resetSharedControllerStateForTests()
        let runtime = WMRuntime(settings: makeTransactionTestRuntimeSettings())
        let controller = runtime.controller
        controller.workspaceManager.applyMonitorConfigurationChange([
            makeLayoutPlanTestMonitor()
        ])
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let monitorId = controller.workspaceManager.monitors.first?.id
        else {
            Issue.record("expected transaction test workspace fixture")
            return
        }
        controller.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        _ = controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitorId)
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceOne,
            windowId: 12_345
        )
        _ = runtime.observeExternalManagedFocusSet(token, in: workspaceOne, onMonitor: monitorId, source: .command)
        if let engine = controller.niriEngine {
            let handles = controller.workspaceManager.entries(in: workspaceOne).map(\.handle)
            let selectedNodeId = controller.workspaceManager.niriViewportState(for: workspaceOne).selectedNodeId
            let focusedHandle = controller.workspaceManager.lastFocusedHandle(in: workspaceOne)
            _ = engine.syncWindows(
                handles,
                in: workspaceOne,
                selectedNodeId: selectedNodeId,
                focusedHandle: focusedHandle
            )
        }

        _ = runtime.submit(
            command: WMRuntime.typedCommand(for: .moveToWorkspace(1), source: .ipc)
        )

        #expect(controller.workspaceManager.workspace(for: token) == workspaceTwo)
        guard case let .commandIntent(_, source) =
            controller.workspaceManager.lastRecordedTransaction?.event
        else {
            Issue.record("expected nested move transaction")
            return
        }
        #expect(source == .ipc)
    }

    @Test @MainActor func ipcMoveWindowHotkeyMovesFocusedFloatingWindow() throws {
        resetSharedControllerStateForTests()
        let runtime = WMRuntime(settings: makeTransactionTestRuntimeSettings())
        let controller = runtime.controller
        controller.workspaceManager.applyMonitorConfigurationChange([
            makeLayoutPlanTestMonitor()
        ])
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let monitorId = controller.workspaceManager.monitors.first?.id
        else {
            Issue.record("expected transaction test workspace fixture")
            return
        }
        controller.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        _ = controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitorId)
        let floatingWindow = addFloatingLayoutPlanTestWindow(
            to: controller,
            workspaceId: workspaceOne,
            referenceMonitorId: monitorId,
            windowId: 12_346,
            frame: CGRect(x: 160, y: 140, width: 500, height: 340),
            normalizedOrigin: CGPoint(x: 0.16, y: 0.24)
        )
        _ = runtime.observeExternalManagedFocusSet(
            floatingWindow.token,
            in: workspaceOne,
            onMonitor: monitorId,
            source: .command
        )

        let result = runtime.submit(
            command: WMRuntime.typedCommand(for: .moveToWorkspace(1), source: .ipc)
        )

        let graph = controller.workspaceManager.workspaceGraphSnapshot()
        #expect(result.externalCommandResult == .executed)
        #expect(controller.workspaceManager.workspace(for: floatingWindow.token) == workspaceTwo)
        #expect(controller.workspaceManager.windowMode(for: floatingWindow.token) == .floating)
        #expect(controller.workspaceManager.floatingState(for: floatingWindow.token) == floatingWindow.floatingState)
        #expect(!graph.floatingMembership(in: workspaceOne).contains { $0.logicalId == floatingWindow.logicalId })
        #expect(graph.floatingMembership(in: workspaceTwo).contains { $0.logicalId == floatingWindow.logicalId })
        guard case let .commandIntent(_, source) =
            controller.workspaceManager.lastRecordedTransaction?.event
        else {
            Issue.record("expected nested move transaction")
            return
        }
        #expect(source == .ipc)
    }
}
