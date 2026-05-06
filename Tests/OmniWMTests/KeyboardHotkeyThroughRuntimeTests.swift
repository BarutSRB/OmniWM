// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) struct KeyboardHotkeyThroughRuntimeTests {
    @Test @MainActor func keyboardHotkeyTagsSourceAsCommandAndStampsEpoch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let result = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .command)
        )

        #expect(result.transactionEpoch.isValid)
        #expect(result.transaction.effects.count == 1)
        if case let .uiActionDispatch(kindForLog, source, _) = result.transaction.effects[0] {
            #expect(kindForLog == "toggle_overview")
            #expect(source == .command)
        } else {
            Issue.record("expected uiActionDispatch effect, got \(result.transaction.effects[0])")
        }
        #expect(result.transaction.transactionEpoch == result.transactionEpoch)
        #expect(result.transaction.transactionEpoch == result.transactionEpoch)
    }

    @Test @MainActor func dispatchHotkeyDefaultsToKeyboardSource() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let result = runtime.dispatchHotkey(.toggleOverview)

        #expect(result == .executed)
        #expect(platform.events == [
            .performUIAction(kindForLog: "toggle_overview", source: .keyboard)
        ])
    }

    @Test @MainActor func keyboardAndIPCHotkeySourcesAreDistinguishable() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let keyboard = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .command)
        )
        let ipc = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .ipc)
        )

        if case let .uiActionDispatch(_, source, _) = keyboard.transaction.effects[0] {
            #expect(source == .command)
        }
        if case let .uiActionDispatch(_, source, _) = ipc.transaction.effects[0] {
            #expect(source == .ipc)
        }
        #expect(keyboard.transactionEpoch < ipc.transactionEpoch)
    }

    @Test @MainActor func focusHotkeyPromotesToTypedFocusActionDispatch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let result = runtime.submit(
            command: WMRuntime.typedCommand(for: .focus(.right), source: .command)
        )

        #expect(result.transaction.effects.count == 1)
        if case let .focusActionDispatch(kindForLog, source, _) = result.transaction.effects[0] {
            #expect(kindForLog == "focus")
            #expect(source == .command)
        } else {
            Issue.record("expected focusActionDispatch effect, got \(result.transaction.effects[0])")
        }
        #expect(platform.events == [
            .performFocusAction(kindForLog: "focus", source: .command)
        ])
    }

    @Test @MainActor func directFocusActionAndMonitorFocusBothPromote() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let direct = runtime.submit(
            command: .focusAction(.focusColumn(3, source: .ipc))
        )
        let monitor = runtime.submit(
            command: WMRuntime.typedCommand(for: .focusMonitorLast, source: .command)
        )

        if case let .focusActionDispatch(kindForLog, source, _) = direct.transaction.effects[0] {
            #expect(kindForLog == "focus_column")
            #expect(source == .ipc)
        } else {
            Issue.record("expected focusActionDispatch on direct submit")
        }
        if case let .focusActionDispatch(kindForLog, source, _) = monitor.transaction.effects[0] {
            #expect(kindForLog == "focus_monitor_last")
            #expect(source == .command)
        } else {
            Issue.record("expected focusActionDispatch on monitor focus")
        }
        #expect(platform.events == [
            .performFocusAction(kindForLog: "focus_column", source: .ipc),
            .performFocusAction(kindForLog: "focus_monitor_last", source: .command)
        ])
    }

    @Test @MainActor func sliceCHotkeysPromoteToTypedDispatch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let layout = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleNativeFullscreen, source: .command)
        )
        let monitorCycle = runtime.submit(
            command: WMRuntime.typedCommand(for: .cycleMonitors, source: .ipc)
        )
        let nav = runtime.submit(
            command: WMRuntime.typedCommand(for: .workspaceBackAndForth, source: .ipc)
        )
        let ui = runtime.submit(
            command: WMRuntime.typedCommand(for: .toggleOverview, source: .command)
        )

        if case let .layoutMutationActionDispatch(kindForLog, source, _) = layout.transaction.effects[0] {
            #expect(kindForLog == "toggle_native_fullscreen")
            #expect(source == .command)
        } else {
            Issue.record("expected layoutMutationActionDispatch")
        }
        if case let .layoutMutationActionDispatch(kindForLog, source, _) = monitorCycle.transaction.effects[0] {
            #expect(kindForLog == "cycle_monitors")
            #expect(source == .ipc)
        } else {
            Issue.record("expected layoutMutationActionDispatch")
        }
        if case let .workspaceNavigationActionDispatch(kindForLog, source, _) = nav.transaction.effects[0] {
            #expect(kindForLog == "workspace_back_and_forth")
            #expect(source == .ipc)
        } else {
            Issue.record("expected workspaceNavigationActionDispatch")
        }
        if case let .uiActionDispatch(kindForLog, source, _) = ui.transaction.effects[0] {
            #expect(kindForLog == "toggle_overview")
            #expect(source == .command)
        } else {
            Issue.record("expected uiActionDispatch")
        }
        #expect(platform.events == [
            .performLayoutMutationAction(kindForLog: "toggle_native_fullscreen", source: .command),
            .performLayoutMutationAction(kindForLog: "cycle_monitors", source: .ipc),
            .performWorkspaceNavigationAction(kindForLog: "workspace_back_and_forth", source: .ipc),
            .performUIAction(kindForLog: "toggle_overview", source: .command)
        ])
    }

    @Test @MainActor func windowMoveHotkeyPromotesToTypedWindowMoveActionDispatch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeTransactionTestRuntime(platform: platform)

        let move = runtime.submit(
            command: WMRuntime.typedCommand(for: .move(.up), source: .command)
        )
        let columnUp = runtime.submit(
            command: WMRuntime.typedCommand(for: .moveColumnToWorkspaceUp, source: .ipc)
        )
        let columnIndex = runtime.submit(
            command: WMRuntime.typedCommand(for: .moveColumnToWorkspace(2), source: .ipc)
        )

        if case let .windowMoveActionDispatch(kindForLog, source, _) = move.transaction.effects[0] {
            #expect(kindForLog == "move")
            #expect(source == .command)
        } else {
            Issue.record("expected windowMoveActionDispatch for .move")
        }
        if case let .windowMoveActionDispatch(kindForLog, source, _) = columnUp.transaction.effects[0] {
            #expect(kindForLog == "move_column_to_workspace_up")
            #expect(source == .ipc)
        } else {
            Issue.record("expected windowMoveActionDispatch for .moveColumnToWorkspaceUp")
        }
        if case let .windowMoveActionDispatch(kindForLog, source, _) = columnIndex.transaction.effects[0] {
            #expect(kindForLog == "move_column_to_workspace")
            #expect(source == .ipc)
        } else {
            Issue.record("expected windowMoveActionDispatch for .moveColumnToWorkspace")
        }
        #expect(platform.events == [
            .performWindowMoveAction(kindForLog: "move", source: .command),
            .performWindowMoveAction(kindForLog: "move_column_to_workspace_up", source: .ipc),
            .performWindowMoveAction(kindForLog: "move_column_to_workspace", source: .ipc)
        ])
    }
}
