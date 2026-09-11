// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension IPCAutomationManifest {
    private static let directionArgument = IPCCommandArgumentDescriptor(
        kind: .direction,
        summary: "Direction argument."
    )
    private static let workspaceNumberArgument = IPCCommandArgumentDescriptor(
        kind: .workspaceNumber,
        summary: "Positive numeric workspace ID."
    )
    private static let slotNumberArgument = IPCCommandArgumentDescriptor(
        kind: .workspaceNumber,
        summary: "One-based position in the interaction monitor's ordered workspace list."
    )
    private static let columnIndexArgument = IPCCommandArgumentDescriptor(
        kind: .columnIndex,
        summary: "One-based column index."
    )
    private static let windowIndexArgument = IPCCommandArgumentDescriptor(
        kind: .windowIndex,
        summary: "One-based window index within the focused column."
    )
    private static let scratchpadIndexArgument = IPCCommandArgumentDescriptor(
        kind: .scratchpadIndex,
        summary: "Scratchpad slot from 1 to 10."
    )
    private static let layoutArgument = IPCCommandArgumentDescriptor(
        kind: .layout,
        summary: "Workspace layout selection."
    )
    private static let resizeAxisArgument = IPCCommandArgumentDescriptor(
        kind: .resizeAxis,
        summary: "Dwindle split axis."
    )
    private static let resizeOperationArgument = IPCCommandArgumentDescriptor(
        kind: .resizeOperation,
        summary: "Whether to grow or shrink."
    )
    private static let sizeChangeArgument = IPCCommandArgumentDescriptor(
        kind: .sizeChange,
        summary: "Size change such as 100, 50%, +10, or -10%."
    )

    private static func command(
        _ commandWords: [String],
        name: IPCCommandName,
        summary: String,
        arguments: [IPCCommandArgumentDescriptor] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) -> IPCCommandDescriptor {
        IPCCommandDescriptor(
            commandWords: commandWords,
            name: name,
            summary: summary,
            arguments: arguments,
            layoutCompatibility: layoutCompatibility
        )
    }

    public static let commandDescriptors: [IPCCommandDescriptor] = [
        command(
            ["focus"],
            name: .focus,
            summary: "Focus spatially; Dwindle Up/Down traverse grouped tabs before edge fallback.",
            arguments: [directionArgument]
        ),
        command(
            ["focus", "previous"],
            name: .focusPrevious,
            summary: "Focus the previously focused window."
        ),
        command(
            ["focus", "down-or-left"],
            name: .focusDownOrLeft,
            summary: "Traverse backward through the active Niri workspace.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus", "up-or-right"],
            name: .focusUpOrRight,
            summary: "Traverse forward through the active Niri workspace.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window-in-column"],
            name: .focusWindowInColumn,
            summary: "Focus a window in the focused Niri column by one-based index.",
            arguments: [windowIndexArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window", "top"],
            name: .focusWindowTop,
            summary: "Focus the top window in the focused Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window", "bottom"],
            name: .focusWindowBottom,
            summary: "Focus the bottom window in the focused Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window", "down-or-top"],
            name: .focusWindowDownOrTop,
            summary: "Focus the next window in the active Niri column or Dwindle group, wrapping to the top."
        ),
        command(
            ["focus-window", "up-or-bottom"],
            name: .focusWindowUpOrBottom,
            summary: "Focus the previous window in the active Niri column or Dwindle group, wrapping to the bottom."
        ),
        command(
            ["focus-window-or-workspace-down"],
            name: .focusWindowOrWorkspaceDown,
            summary: "Focus down using the active Niri orientation; if no target exists, switch without wrapping to the workspace below.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window-or-workspace-up"],
            name: .focusWindowOrWorkspaceUp,
            summary: "Focus up using the active Niri orientation; if no target exists, switch without wrapping to the workspace above.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-column"],
            name: .focusColumn,
            summary: "Focus a Niri column by one-based index.",
            arguments: [columnIndexArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["focus-column", "first"],
            name: .focusColumnFirst,
            summary: "Focus the first Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-column", "last"],
            name: .focusColumnLast,
            summary: "Focus the last Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["center-column"],
            name: .centerColumn,
            summary: "Center the focused Niri column without changing focus.",
            layoutCompatibility: .niri
        ),
        command(
            ["center-visible-columns"],
            name: .centerVisibleColumns,
            summary: "Center the current block of fully visible Niri columns in the viewport.",
            layoutCompatibility: .niri
        ),
        command(
            ["move"],
            name: .move,
            summary: "Move with layout-aware consume/expel or Dwindle join/extract behavior.",
            arguments: [directionArgument]
        ),
        command(
            ["move-window-down"],
            name: .moveWindowDown,
            summary: "Reorder the focused window down by one without wrapping within its Niri column or Dwindle group."
        ),
        command(
            ["move-window-up"],
            name: .moveWindowUp,
            summary: "Reorder the focused window up by one without wrapping within its Niri column or Dwindle group."
        ),
        command(
            ["move-window-down-or-to-workspace-down"],
            name: .moveWindowDownOrToWorkspaceDown,
            summary: "Move the focused Niri window down, or to the workspace below at the column edge.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-window-up-or-to-workspace-up"],
            name: .moveWindowUpOrToWorkspaceUp,
            summary: "Move the focused Niri window up, or to the workspace above at the column edge.",
            layoutCompatibility: .niri
        ),
        command(
            ["consume-or-expel-window-left"],
            name: .consumeOrExpelWindowLeft,
            summary: "Consume the focused Niri window into the column to the left, or expel it left from its column.",
            layoutCompatibility: .niri
        ),
        command(
            ["consume-or-expel-window-right"],
            name: .consumeOrExpelWindowRight,
            summary: "Consume the focused Niri window into the column to the right, or expel it right from its column.",
            layoutCompatibility: .niri
        ),
        command(
            ["consume-window-into-column"],
            name: .consumeWindowIntoColumn,
            summary: "Consume the top window from the next Niri column into the focused column.",
            layoutCompatibility: .niri
        ),
        command(
            ["expel-window-from-column"],
            name: .expelWindowFromColumn,
            summary: "Expel the bottom window from the focused Niri column into a new following column.",
            layoutCompatibility: .niri
        ),
        command(
            ["switch-workspace"],
            name: .switchWorkspace,
            summary: "Switch to a workspace on the interaction monitor by workspace ID.",
            arguments: [workspaceNumberArgument]
        ),
        command(
            ["switch-workspace", "next"],
            name: .switchWorkspaceNext,
            summary: "Switch to the next workspace on the current monitor."
        ),
        command(
            ["switch-workspace", "prev"],
            name: .switchWorkspacePrevious,
            summary: "Switch to the previous workspace on the current monitor."
        ),
        command(
            ["switch-workspace", "back-and-forth"],
            name: .switchWorkspaceBackAndForth,
            summary: "Switch to the previously active workspace on the current monitor."
        ),
        command(
            ["switch-workspace", "anywhere"],
            name: .switchWorkspaceAnywhere,
            summary: "Focus a workspace by workspace ID across all monitors.",
            arguments: [workspaceNumberArgument]
        ),
        command(
            ["switch-workspace", "slot"],
            name: .switchWorkspaceSlot,
            summary: "Switch to the workspace at a one-based position in the interaction monitor's workspace list.",
            arguments: [slotNumberArgument]
        ),
        command(
            ["move-to-workspace"],
            name: .moveToWorkspace,
            summary: "Move the focused window to a workspace by workspace ID.",
            arguments: [workspaceNumberArgument]
        ),
        command(
            ["move-to-workspace", "up"],
            name: .moveToWorkspaceUp,
            summary: "Move the focused window to the adjacent workspace above."
        ),
        command(
            ["move-to-workspace", "down"],
            name: .moveToWorkspaceDown,
            summary: "Move the focused window to the adjacent workspace below."
        ),
        command(
            ["move-to-workspace", "on-monitor"],
            name: .moveToWorkspaceOnMonitor,
            summary: "Move the focused window to a workspace already assigned to the requested adjacent monitor.",
            arguments: [workspaceNumberArgument, directionArgument]
        ),
        command(
            ["move-to-workspace", "slot"],
            name: .moveToWorkspaceSlot,
            summary: "Move the focused window to the workspace at a one-based position in the interaction monitor's workspace list.",
            arguments: [slotNumberArgument]
        ),
        command(
            ["move-to-monitor"],
            name: .moveToMonitor,
            summary: "Move the focused window to the active workspace on the adjacent monitor.",
            arguments: [directionArgument]
        ),
        command(
            ["focus-monitor", "prev"],
            name: .focusMonitorPrevious,
            summary: "Move interaction focus to the previous monitor."
        ),
        command(
            ["focus-monitor", "next"],
            name: .focusMonitorNext,
            summary: "Move interaction focus to the next monitor."
        ),
        command(
            ["focus-monitor", "last"],
            name: .focusMonitorLast,
            summary: "Move interaction focus back to the previous monitor."
        ),
        command(
            ["move-column"],
            name: .moveColumn,
            summary: "Move a Niri column horizontally or a complete Dwindle tile/group without monitor fallback.",
            arguments: [directionArgument]
        ),
        command(
            ["move-column-to-first"],
            name: .moveColumnToFirst,
            summary: "Move the focused Niri column to the first position.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-last"],
            name: .moveColumnToLast,
            summary: "Move the focused Niri column to the last position.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-index"],
            name: .moveColumnToIndex,
            summary: "Move the focused Niri column to a one-based index.",
            arguments: [columnIndexArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-workspace"],
            name: .moveColumnToWorkspace,
            summary: "Move the focused Niri column to a Niri workspace by workspace ID.",
            arguments: [workspaceNumberArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-workspace", "up"],
            name: .moveColumnToWorkspaceUp,
            summary: "Move the focused Niri column to the adjacent workspace above.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-workspace", "down"],
            name: .moveColumnToWorkspaceDown,
            summary: "Move the focused Niri column to the adjacent workspace below.",
            layoutCompatibility: .niri
        ),
        command(
            ["toggle-column-tabbed"],
            name: .toggleColumnTabbed,
            summary: "Toggle tabbed mode for the focused Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-size", "forward"],
            name: .cycleSizeForward,
            summary: "Cycle layout sizing presets forward."
        ),
        command(
            ["cycle-size", "backward"],
            name: .cycleSizeBackward,
            summary: "Cycle layout sizing presets backward."
        ),
        command(
            ["cycle-window-primary-span", "forward"],
            name: .cycleWindowPrimarySpanForward,
            summary: "Cycle Niri window primary-span presets forward.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-window-primary-span", "backward"],
            name: .cycleWindowPrimarySpanBackward,
            summary: "Cycle Niri window primary-span presets backward.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-window-secondary-span", "forward"],
            name: .cycleWindowSecondarySpanForward,
            summary: "Cycle Niri window secondary-span presets forward.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-window-secondary-span", "backward"],
            name: .cycleWindowSecondarySpanBackward,
            summary: "Cycle Niri window secondary-span presets backward.",
            layoutCompatibility: .niri
        ),
        command(
            ["toggle-container-full-primary-span"],
            name: .toggleContainerFullPrimarySpan,
            summary: "Toggle full-primary-span mode for the focused Niri container.",
            layoutCompatibility: .niri
        ),
        command(
            ["expand-container-to-available-primary-span"],
            name: .expandContainerToAvailablePrimarySpan,
            summary: "Expand the focused Niri container into available primary-axis space.",
            layoutCompatibility: .niri
        ),
        command(
            ["reset-window-secondary-span"],
            name: .resetWindowSecondarySpan,
            summary: "Reset the focused Niri window secondary span.",
            layoutCompatibility: .niri
        ),
        command(
            ["set-container-primary-span"],
            name: .setContainerPrimarySpan,
            summary: "Set or adjust the focused Niri container primary span.",
            arguments: [sizeChangeArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["set-window-primary-span"],
            name: .setWindowPrimarySpan,
            summary: "Set or adjust the focused Niri window primary span.",
            arguments: [sizeChangeArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["set-window-secondary-span"],
            name: .setWindowSecondarySpan,
            summary: "Set or adjust the focused Niri window secondary span.",
            arguments: [sizeChangeArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["swap-workspace-with-monitor"],
            name: .swapWorkspaceWithMonitor,
            summary: "Swap the active workspace with the active workspace on an adjacent monitor.",
            arguments: [directionArgument]
        ),
        command(["balance-sizes"], name: .balanceSizes, summary: "Balance layout sizes in the active workspace."),
        command(
            ["move-to-root"],
            name: .moveToRoot,
            summary: "Move the selected Dwindle window to the root split.",
            layoutCompatibility: .dwindle
        ),
        command(
            ["toggle-split"],
            name: .toggleSplit,
            summary: "Toggle the active Dwindle split orientation.",
            layoutCompatibility: .dwindle
        ),
        command(
            ["swap-split"],
            name: .swapSplit,
            summary: "Swap the active Dwindle split.",
            layoutCompatibility: .dwindle
        ),
        command(
            ["resize"],
            name: .resize,
            summary: "Resize the selected Dwindle window.",
            arguments: [resizeAxisArgument, resizeOperationArgument],
            layoutCompatibility: .dwindle
        ),
        command(
            ["resize-focused"],
            name: .resizeFocused,
            summary: "Grow or shrink the focused Dwindle window.",
            arguments: [resizeOperationArgument],
            layoutCompatibility: .dwindle
        ),
        command(
            ["preselect"],
            name: .preselect,
            summary: "Set the Dwindle preselection direction.",
            arguments: [directionArgument],
            layoutCompatibility: .dwindle
        ),
        command(
            ["preselect", "clear"],
            name: .preselectClear,
            summary: "Clear the Dwindle preselection.",
            layoutCompatibility: .dwindle
        ),
        command(["open-command-palette"], name: .openCommandPalette, summary: "Toggle the command palette."),
        command(
            ["raise-all-floating-windows"],
            name: .raiseAllFloatingWindows,
            summary: "Raise all visible floating windows."
        ),
        command(
            ["rescue-offscreen-windows"],
            name: .rescueOffscreenWindows,
            summary: "Clamp tracked floating windows back onto their visible monitors."
        ),
        command(
            ["toggle-focused-window-floating"],
            name: .toggleFocusedWindowFloating,
            summary: "Toggle the focused managed window between tiled and floating."
        ),
        command(
            ["close-focused-window"],
            name: .closeFocusedWindow,
            summary: "Close the focused managed window through its close button."
        ),
        command(
            ["scratchpad", "assign"],
            name: .scratchpadAssign,
            summary: "Assign the focused managed window to a scratchpad, or remove it when already there.",
            arguments: [scratchpadIndexArgument]
        ),
        command(
            ["scratchpad", "toggle"],
            name: .scratchpadToggle,
            summary: "Show or hide a scratchpad's windows.",
            arguments: [scratchpadIndexArgument]
        ),
        command(["open-menu-anywhere"], name: .openMenuAnywhere, summary: "Open the menu surface anywhere."),
        command(
            ["toggle-workspace-bar"],
            name: .toggleWorkspaceBar,
            summary: "Toggle runtime workspace bar visibility."
        ),
        command(["hidden-bar", "panel"], name: .hiddenBarPanel, summary: "Toggle the hidden-bar items panel."),
        command(
            ["toggle-quake-terminal"],
            name: .toggleQuakeTerminal,
            summary: "Toggle the configured Quake terminal."
        ),
        command(
            ["toggle-workspace-layout"],
            name: .toggleWorkspaceLayout,
            summary: "Toggle the current workspace between Niri and Dwindle."
        ),
        command(
            ["set-workspace-layout"],
            name: .setWorkspaceLayout,
            summary: "Set the current workspace layout explicitly.",
            arguments: [layoutArgument]
        ),
        command(["toggle-fullscreen"], name: .toggleFullscreen, summary: "Toggle OmniWM-managed fullscreen."),
        command(
            ["toggle-native-fullscreen"],
            name: .toggleNativeFullscreen,
            summary: "Toggle native macOS fullscreen."
        ),
        command(["toggle-overview"], name: .toggleOverview, summary: "Toggle the overview surface."),
        command(
            ["toggle-system-stats"],
            name: .toggleSystemStats,
            summary: "Toggle the system stats popup when a workspace-bar System Stats button is available."
        )
    ]

    public static func commandDescriptor(for name: IPCCommandName) -> IPCCommandDescriptor? {
        commandDescriptors.first { $0.name == name }
    }

    public static func commandDescriptors(matching commandWords: [String]) -> [IPCCommandDescriptor] {
        commandDescriptors
            .sorted {
                if $0.commandWords.count != $1.commandWords.count {
                    return $0.commandWords.count > $1.commandWords.count
                }
                return $0.path < $1.path
            }
            .filter { descriptor in
                guard commandWords.count >= descriptor.commandWords.count else { return false }
                return Array(commandWords.prefix(descriptor.commandWords.count)) == descriptor.commandWords
            }
    }
}
