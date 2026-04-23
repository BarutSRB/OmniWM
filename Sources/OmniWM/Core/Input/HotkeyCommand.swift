// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum LayoutCompatibility: String {
    case shared = "Shared"
    case niri = "Niri"
    case dwindle = "Dwindle"
}

enum HotkeyCommand: Codable, Equatable, Hashable {
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
}
