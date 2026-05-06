// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum LayoutCompatibility: String {
    case shared = "Shared"
    case niri = "Niri"
    case dwindle = "Dwindle"
}

/// Identifies which input binding (keyboard chord or IPC request) was
/// triggered. Intentionally NOT the semantic command — that role belongs
/// to `WMCommand` in `Sources/OmniWM/Core/Runtime/WMCommand.swift`.
///
/// `InputBindingTrigger` is a *trigger payload*: "the user pressed the
/// chord bound to `.focus(.left)`" or "an IPC client requested
/// `.toggleFullscreen`". It carries no execution semantics. The dispatcher
/// (`WMRuntime.typedCommand(for:source:)`) promotes each trigger into a
/// typed `WMCommand` that the rest of the runtime can reason about with
/// epoch stamping, supersession, and effect-plan construction.
///
/// History: this type was originally named `HotkeyCommand`, which
/// conflated the input mechanism (hotkey) with the semantic action
/// (command). The rename to `InputBindingTrigger` finalizes ExecPlan 03
/// TX-CMD-01 by making the layer's purpose obvious from the name. Hotkey-
/// adjacent identifiers (`HotkeyCenter`, `HotkeyBinding`, `HotkeyCategory`,
/// `dispatchHotkey`, `setHotkeysEnabled`, etc.) intentionally keep the
/// "hotkey" prefix because they describe the input *mechanism* (keyboard
/// chord registration / event-tap delivery), which is a separate concept
/// from the binding's trigger payload.
///
/// Wire-format note: Codable-encoded values use the case names (`focus`,
/// `move`, `toggleOverview`, …), not the enum type name, so the rename
/// does not break TOML configuration files or IPC requests.
enum InputBindingTrigger: Codable, Equatable, Hashable {
    case focus(Direction)
    case focusPrevious
    case move(Direction)
    case moveToWorkspace(Int)
    case moveWindowToWorkspaceUp
    case moveWindowToWorkspaceDown
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case switchWorkspace(Int)
    case switchWorkspaceNext
    case switchWorkspacePrevious
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case toggleFullscreen
    case toggleNativeFullscreen
    case moveColumn(Direction)
    case toggleColumnTabbed

    case focusDownOrLeft
    case focusUpOrRight
    case focusColumnFirst
    case focusColumnLast
    case focusColumn(Int)
    case cycleColumnWidthForward
    case cycleColumnWidthBackward
    case toggleColumnFullWidth

    case swapWorkspaceWithMonitor(Direction)
    case cycleMonitors

    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resizeInDirection(Direction, Bool)
    case preselect(Direction)
    case preselectClear

    case workspaceBackAndForth
    case focusWorkspaceAnywhere(Int)
    case moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction)

    case openCommandPalette

    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case toggleFocusedWindowFloating
    case assignFocusedWindowToScratchpad
    case toggleScratchpadWindow

    case openMenuAnywhere

    case toggleWorkspaceBarVisibility
    case toggleHiddenBar
    case toggleQuakeTerminal
    case toggleWorkspaceLayout
    case toggleOverview

    var displayName: String {
        ActionCatalog.title(for: self) ?? String(describing: self)
    }

    var layoutCompatibility: LayoutCompatibility {
        ActionCatalog.layoutCompatibility(for: self) ?? .shared
    }

    var kindForLog: String {
        switch self {
        case .focus: "focus"
        case .focusPrevious: "focus_previous"
        case .move: "move"
        case .moveToWorkspace: "move_to_workspace"
        case .moveWindowToWorkspaceUp: "move_window_to_workspace_up"
        case .moveWindowToWorkspaceDown: "move_window_to_workspace_down"
        case .moveColumnToWorkspace: "move_column_to_workspace"
        case .moveColumnToWorkspaceUp: "move_column_to_workspace_up"
        case .moveColumnToWorkspaceDown: "move_column_to_workspace_down"
        case .switchWorkspace: "switch_workspace"
        case .switchWorkspaceNext: "switch_workspace_next"
        case .switchWorkspacePrevious: "switch_workspace_previous"
        case .focusMonitorPrevious: "focus_monitor_previous"
        case .focusMonitorNext: "focus_monitor_next"
        case .focusMonitorLast: "focus_monitor_last"
        case .toggleFullscreen: "toggle_fullscreen"
        case .toggleNativeFullscreen: "toggle_native_fullscreen"
        case .moveColumn: "move_column"
        case .toggleColumnTabbed: "toggle_column_tabbed"
        case .focusDownOrLeft: "focus_down_or_left"
        case .focusUpOrRight: "focus_up_or_right"
        case .focusColumnFirst: "focus_column_first"
        case .focusColumnLast: "focus_column_last"
        case .focusColumn: "focus_column"
        case .cycleColumnWidthForward: "cycle_column_width_forward"
        case .cycleColumnWidthBackward: "cycle_column_width_backward"
        case .toggleColumnFullWidth: "toggle_column_full_width"
        case .swapWorkspaceWithMonitor: "swap_workspace_with_monitor"
        case .cycleMonitors: "cycle_monitors"
        case .balanceSizes: "balance_sizes"
        case .moveToRoot: "move_to_root"
        case .toggleSplit: "toggle_split"
        case .swapSplit: "swap_split"
        case .resizeInDirection: "resize_in_direction"
        case .preselect: "preselect"
        case .preselectClear: "preselect_clear"
        case .workspaceBackAndForth: "workspace_back_and_forth"
        case .focusWorkspaceAnywhere: "focus_workspace_anywhere"
        case .moveWindowToWorkspaceOnMonitor: "move_window_to_workspace_on_monitor"
        case .openCommandPalette: "open_command_palette"
        case .raiseAllFloatingWindows: "raise_all_floating_windows"
        case .rescueOffscreenWindows: "rescue_offscreen_windows"
        case .toggleFocusedWindowFloating: "toggle_focused_window_floating"
        case .assignFocusedWindowToScratchpad: "assign_focused_window_to_scratchpad"
        case .toggleScratchpadWindow: "toggle_scratchpad_window"
        case .openMenuAnywhere: "open_menu_anywhere"
        case .toggleWorkspaceBarVisibility: "toggle_workspace_bar_visibility"
        case .toggleHiddenBar: "toggle_hidden_bar"
        case .toggleQuakeTerminal: "toggle_quake_terminal"
        case .toggleWorkspaceLayout: "toggle_workspace_layout"
        case .toggleOverview: "toggle_overview"
        }
    }
}
