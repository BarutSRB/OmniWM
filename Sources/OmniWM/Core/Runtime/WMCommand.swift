// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum WMCommand: Equatable {
    case workspaceSwitch(WorkspaceSwitchCommand)
    case controllerAction(ControllerActionCommand)
    case focusAction(FocusActionCommand)
    case windowMoveAction(WindowMoveActionCommand)
    case layoutMutationAction(LayoutMutationActionCommand)
    case workspaceNavigationAction(WorkspaceNavigationActionCommand)
    case uiAction(UIActionCommand)
}

extension WMCommand {
    enum WorkspaceSwitchCommand: Equatable {
        case explicit(rawWorkspaceID: String)
        case explicitFrom(rawWorkspaceID: String, source: WMEventSource)
        case relative(isNext: Bool, wrapAround: Bool)
        case relativeFrom(isNext: Bool, wrapAround: Bool, source: WMEventSource)
    }

    enum ControllerActionCommand: Equatable {
        case focusWorkspaceAnywhere(rawWorkspaceID: String, source: WMEventSource)
        case moveFocusedWindow(rawWorkspaceID: String, source: WMEventSource)
        case moveFocusedWindowOnMonitor(
            rawWorkspaceID: String,
            monitorDirection: Direction,
            source: WMEventSource
        )
        case setWorkspaceLayout(LayoutType, source: WMEventSource)
        case rescueOffscreenWindows(source: WMEventSource)
        case focusWorkspace(named: String, source: WMEventSource)
        case focusWindow(WindowToken, source: WMEventSource)
        case navigateToWindow(WindowHandle, source: WMEventSource)
        case summonWindowRight(WindowHandle, source: WMEventSource)
    }

    enum FocusActionCommand: Equatable {
        case focusNeighbor(Direction, source: WMEventSource)
        case focusPrevious(source: WMEventSource)
        case focusDownOrLeft(source: WMEventSource)
        case focusUpOrRight(source: WMEventSource)
        case focusColumnFirst(source: WMEventSource)
        case focusColumnLast(source: WMEventSource)
        case focusColumn(Int, source: WMEventSource)
        case focusMonitorPrevious(source: WMEventSource)
        case focusMonitorNext(source: WMEventSource)
        case focusMonitorLast(source: WMEventSource)
    }

    enum WindowMoveActionCommand: Equatable {
        case moveWindow(Direction, source: WMEventSource)
        case moveColumn(Direction, source: WMEventSource)
        case moveWindowToWorkspaceUp(source: WMEventSource)
        case moveWindowToWorkspaceDown(source: WMEventSource)
        case moveColumnToWorkspace(Int, source: WMEventSource)
        case moveColumnToWorkspaceUp(source: WMEventSource)
        case moveColumnToWorkspaceDown(source: WMEventSource)
    }

    enum LayoutMutationActionCommand: Equatable {
        case toggleFullscreen(source: WMEventSource)
        case toggleNativeFullscreen(source: WMEventSource)
        case toggleColumnTabbed(source: WMEventSource)
        case toggleColumnFullWidth(source: WMEventSource)
        case cycleColumnWidthForward(source: WMEventSource)
        case cycleColumnWidthBackward(source: WMEventSource)
        case swapWorkspaceWithMonitor(Direction, source: WMEventSource)
        case cycleMonitors(source: WMEventSource)
        case balanceSizes(source: WMEventSource)
        case moveToRoot(source: WMEventSource)
        case toggleSplit(source: WMEventSource)
        case swapSplit(source: WMEventSource)
        case resizeInDirection(Direction, grow: Bool, source: WMEventSource)
        case preselect(Direction, source: WMEventSource)
        case preselectClear(source: WMEventSource)
        case toggleWorkspaceLayout(source: WMEventSource)
        case raiseAllFloatingWindows(source: WMEventSource)
        case toggleFocusedWindowFloating(source: WMEventSource)
        case assignFocusedWindowToScratchpad(source: WMEventSource)
        case toggleScratchpadWindow(source: WMEventSource)
    }

    enum WorkspaceNavigationActionCommand: Equatable {
        case workspaceBackAndForth(source: WMEventSource)
    }

    enum UIActionCommand: Equatable {
        case openCommandPalette(source: WMEventSource)
        case openMenuAnywhere(source: WMEventSource)
        case toggleWorkspaceBarVisibility(source: WMEventSource)
        case toggleHiddenBar(source: WMEventSource)
        case toggleQuakeTerminal(source: WMEventSource)
        case toggleOverview(source: WMEventSource)
    }
}

extension WMCommand {
    var summary: String {
        switch self {
        case let .workspaceSwitch(.explicit(rawId)):
            "workspace_switch_explicit raw=\(rawId)"
        case let .workspaceSwitch(.explicitFrom(rawId, source)):
            "workspace_switch_explicit raw=\(rawId) source=\(source.rawValue)"
        case let .workspaceSwitch(.relative(isNext, wrapAround)):
            "workspace_switch_relative next=\(isNext) wrap=\(wrapAround)"
        case let .workspaceSwitch(.relativeFrom(isNext, wrapAround, source)):
            "workspace_switch_relative next=\(isNext) wrap=\(wrapAround) source=\(source.rawValue)"
        case let .controllerAction(action):
            "controller_action kind=\(action.kindForLog) source=\(action.source.rawValue)"
        case let .focusAction(action):
            "focus_action kind=\(action.kindForLog) source=\(action.source.rawValue)"
        case let .windowMoveAction(action):
            "window_move_action kind=\(action.kindForLog) source=\(action.source.rawValue)"
        case let .layoutMutationAction(action):
            "layout_mutation_action kind=\(action.kindForLog) source=\(action.source.rawValue)"
        case let .workspaceNavigationAction(action):
            "workspace_navigation_action kind=\(action.kindForLog) source=\(action.source.rawValue)"
        case let .uiAction(action):
            "ui_action kind=\(action.kindForLog) source=\(action.source.rawValue)"
        }
    }

    var kindForLog: String {
        switch self {
        case .workspaceSwitch(.explicit), .workspaceSwitch(.explicitFrom):
            "workspace_switch_explicit"
        case .workspaceSwitch(.relative), .workspaceSwitch(.relativeFrom):
            "workspace_switch_relative"
        case let .controllerAction(action):
            "controller_action:\(action.kindForLog)"
        case let .focusAction(action):
            "focus_action:\(action.kindForLog)"
        case let .windowMoveAction(action):
            "window_move_action:\(action.kindForLog)"
        case let .layoutMutationAction(action):
            "layout_mutation_action:\(action.kindForLog)"
        case let .workspaceNavigationAction(action):
            "workspace_navigation_action:\(action.kindForLog)"
        case let .uiAction(action):
            "ui_action:\(action.kindForLog)"
        }
    }

    var sourceForLog: WMEventSource {
        switch self {
        case .workspaceSwitch(.explicit), .workspaceSwitch(.relative):
            .command
        case let .workspaceSwitch(.explicitFrom(_, source)),
             let .workspaceSwitch(.relativeFrom(_, _, source)):
            source
        case let .controllerAction(action):
            action.source
        case let .focusAction(action):
            action.source
        case let .windowMoveAction(action):
            action.source
        case let .layoutMutationAction(action):
            action.source
        case let .workspaceNavigationAction(action):
            action.source
        case let .uiAction(action):
            action.source
        }
    }

    var layoutCompatibility: LayoutCompatibility {
        switch self {
        case .workspaceSwitch, .controllerAction, .workspaceNavigationAction, .uiAction:
            .shared
        case let .focusAction(action):
            action.layoutCompatibility
        case let .windowMoveAction(action):
            action.layoutCompatibility
        case let .layoutMutationAction(action):
            action.layoutCompatibility
        }
    }

    var allowsOverviewOpen: Bool {
        if case .uiAction(.toggleOverview) = self {
            return true
        }
        return false
    }
}

extension WMCommand.ControllerActionCommand {
    var kindForLog: String {
        switch self {
        case .focusWorkspaceAnywhere:
            "focus_workspace_anywhere"
        case .moveFocusedWindow:
            "move_focused_window"
        case .moveFocusedWindowOnMonitor:
            "move_focused_window_on_monitor"
        case .setWorkspaceLayout:
            "set_workspace_layout"
        case .rescueOffscreenWindows:
            "rescue_offscreen_windows"
        case .focusWorkspace:
            "focus_workspace"
        case .focusWindow:
            "focus_window"
        case .navigateToWindow:
            "navigate_to_window"
        case .summonWindowRight:
            "summon_window_right"
        }
    }

    var source: WMEventSource {
        switch self {
        case let .focusWorkspaceAnywhere(_, source),
             let .moveFocusedWindow(_, source),
             let .moveFocusedWindowOnMonitor(_, _, source),
             let .setWorkspaceLayout(_, source),
             let .rescueOffscreenWindows(source),
             let .focusWorkspace(_, source),
             let .focusWindow(_, source),
             let .navigateToWindow(_, source),
             let .summonWindowRight(_, source):
            source
        }
    }
}

extension WMCommand.FocusActionCommand {
    var kindForLog: String {
        switch self {
        case .focusNeighbor: "focus"
        case .focusPrevious: "focus_previous"
        case .focusDownOrLeft: "focus_down_or_left"
        case .focusUpOrRight: "focus_up_or_right"
        case .focusColumnFirst: "focus_column_first"
        case .focusColumnLast: "focus_column_last"
        case .focusColumn: "focus_column"
        case .focusMonitorPrevious: "focus_monitor_previous"
        case .focusMonitorNext: "focus_monitor_next"
        case .focusMonitorLast: "focus_monitor_last"
        }
    }

    var source: WMEventSource {
        switch self {
        case let .focusNeighbor(_, source),
             let .focusPrevious(source),
             let .focusDownOrLeft(source),
             let .focusUpOrRight(source),
             let .focusColumnFirst(source),
             let .focusColumnLast(source),
             let .focusColumn(_, source),
             let .focusMonitorPrevious(source),
             let .focusMonitorNext(source),
             let .focusMonitorLast(source):
            source
        }
    }

    var layoutCompatibility: LayoutCompatibility {
        switch self {
        case .focusPrevious,
             .focusDownOrLeft,
             .focusUpOrRight,
             .focusColumnFirst,
             .focusColumnLast,
             .focusColumn:
            .niri
        case .focusNeighbor,
             .focusMonitorPrevious,
             .focusMonitorNext,
             .focusMonitorLast:
            .shared
        }
    }
}

extension WMCommand.WindowMoveActionCommand {
    var kindForLog: String {
        switch self {
        case .moveWindow: "move"
        case .moveColumn: "move_column"
        case .moveWindowToWorkspaceUp: "move_window_to_workspace_up"
        case .moveWindowToWorkspaceDown: "move_window_to_workspace_down"
        case .moveColumnToWorkspace: "move_column_to_workspace"
        case .moveColumnToWorkspaceUp: "move_column_to_workspace_up"
        case .moveColumnToWorkspaceDown: "move_column_to_workspace_down"
        }
    }

    var source: WMEventSource {
        switch self {
        case let .moveWindow(_, source),
             let .moveColumn(_, source),
             let .moveWindowToWorkspaceUp(source),
             let .moveWindowToWorkspaceDown(source),
             let .moveColumnToWorkspace(_, source),
             let .moveColumnToWorkspaceUp(source),
             let .moveColumnToWorkspaceDown(source):
            source
        }
    }

    var layoutCompatibility: LayoutCompatibility {
        switch self {
        case .moveColumn,
             .moveColumnToWorkspace,
             .moveColumnToWorkspaceUp,
             .moveColumnToWorkspaceDown:
            .niri
        case .moveWindow,
             .moveWindowToWorkspaceUp,
             .moveWindowToWorkspaceDown:
            .shared
        }
    }
}

extension WMCommand.LayoutMutationActionCommand {
    var kindForLog: String {
        switch self {
        case .toggleFullscreen: "toggle_fullscreen"
        case .toggleNativeFullscreen: "toggle_native_fullscreen"
        case .toggleColumnTabbed: "toggle_column_tabbed"
        case .toggleColumnFullWidth: "toggle_column_full_width"
        case .cycleColumnWidthForward: "cycle_column_width_forward"
        case .cycleColumnWidthBackward: "cycle_column_width_backward"
        case .swapWorkspaceWithMonitor: "swap_workspace_with_monitor"
        case .cycleMonitors: "cycle_monitors"
        case .balanceSizes: "balance_sizes"
        case .moveToRoot: "move_to_root"
        case .toggleSplit: "toggle_split"
        case .swapSplit: "swap_split"
        case .resizeInDirection: "resize_in_direction"
        case .preselect: "preselect"
        case .preselectClear: "preselect_clear"
        case .toggleWorkspaceLayout: "toggle_workspace_layout"
        case .raiseAllFloatingWindows: "raise_all_floating_windows"
        case .toggleFocusedWindowFloating: "toggle_focused_window_floating"
        case .assignFocusedWindowToScratchpad: "assign_focused_window_to_scratchpad"
        case .toggleScratchpadWindow: "toggle_scratchpad_window"
        }
    }

    var source: WMEventSource {
        switch self {
        case let .toggleFullscreen(source),
             let .toggleNativeFullscreen(source),
             let .toggleColumnTabbed(source),
             let .toggleColumnFullWidth(source),
             let .cycleColumnWidthForward(source),
             let .cycleColumnWidthBackward(source),
             let .swapWorkspaceWithMonitor(_, source),
             let .cycleMonitors(source),
             let .balanceSizes(source),
             let .moveToRoot(source),
             let .toggleSplit(source),
             let .swapSplit(source),
             let .resizeInDirection(_, _, source),
             let .preselect(_, source),
             let .preselectClear(source),
             let .toggleWorkspaceLayout(source),
             let .raiseAllFloatingWindows(source),
             let .toggleFocusedWindowFloating(source),
             let .assignFocusedWindowToScratchpad(source),
             let .toggleScratchpadWindow(source):
            source
        }
    }

    var layoutCompatibility: LayoutCompatibility {
        switch self {
        case .toggleColumnTabbed,
             .toggleColumnFullWidth:
            .niri
        case .moveToRoot,
             .toggleSplit,
             .swapSplit,
             .resizeInDirection,
             .preselect,
             .preselectClear:
            .dwindle
        case .toggleFullscreen,
             .toggleNativeFullscreen,
             .cycleColumnWidthForward,
             .cycleColumnWidthBackward,
             .swapWorkspaceWithMonitor,
             .cycleMonitors,
             .balanceSizes,
             .toggleWorkspaceLayout,
             .raiseAllFloatingWindows,
             .toggleFocusedWindowFloating,
             .assignFocusedWindowToScratchpad,
             .toggleScratchpadWindow:
            .shared
        }
    }
}

extension WMCommand.WorkspaceNavigationActionCommand {
    var kindForLog: String {
        switch self {
        case .workspaceBackAndForth: "workspace_back_and_forth"
        }
    }

    var source: WMEventSource {
        switch self {
        case let .workspaceBackAndForth(source): source
        }
    }
}

extension WMCommand.UIActionCommand {
    var kindForLog: String {
        switch self {
        case .openCommandPalette: "open_command_palette"
        case .openMenuAnywhere: "open_menu_anywhere"
        case .toggleWorkspaceBarVisibility: "toggle_workspace_bar_visibility"
        case .toggleHiddenBar: "toggle_hidden_bar"
        case .toggleQuakeTerminal: "toggle_quake_terminal"
        case .toggleOverview: "toggle_overview"
        }
    }

    var source: WMEventSource {
        switch self {
        case let .openCommandPalette(source),
             let .openMenuAnywhere(source),
             let .toggleWorkspaceBarVisibility(source),
             let .toggleHiddenBar(source),
             let .toggleQuakeTerminal(source),
             let .toggleOverview(source):
            source
        }
    }
}
