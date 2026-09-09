// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public enum IPCCommandName: String, Codable, CaseIterable, Equatable, Sendable {
    case focus
    case focusPrevious = "focus-previous"
    case focusDownOrLeft = "focus-down-or-left"
    case focusUpOrRight = "focus-up-or-right"
    case focusWindowInColumn = "focus-window-in-column"
    case focusWindowTop = "focus-window-top"
    case focusWindowBottom = "focus-window-bottom"
    case focusWindowDownOrTop = "focus-window-down-or-top"
    case focusWindowUpOrBottom = "focus-window-up-or-bottom"
    case focusWindowOrWorkspaceDown = "focus-window-or-workspace-down"
    case focusWindowOrWorkspaceUp = "focus-window-or-workspace-up"
    case focusColumn = "focus-column"
    case focusColumnFirst = "focus-column-first"
    case focusColumnLast = "focus-column-last"
    case centerColumn = "center-column"
    case centerVisibleColumns = "center-visible-columns"
    case move
    case moveWindowDown = "move-window-down"
    case moveWindowUp = "move-window-up"
    case moveWindowDownOrToWorkspaceDown = "move-window-down-or-to-workspace-down"
    case moveWindowUpOrToWorkspaceUp = "move-window-up-or-to-workspace-up"
    case consumeOrExpelWindowLeft = "consume-or-expel-window-left"
    case consumeOrExpelWindowRight = "consume-or-expel-window-right"
    case consumeWindowIntoColumn = "consume-window-into-column"
    case expelWindowFromColumn = "expel-window-from-column"
    case switchWorkspace = "switch-workspace"
    case switchWorkspaceNext = "switch-workspace-next"
    case switchWorkspacePrevious = "switch-workspace-previous"
    case switchWorkspaceBackAndForth = "switch-workspace-back-and-forth"
    case switchWorkspaceAnywhere = "switch-workspace-anywhere"
    case switchWorkspaceSlot = "switch-workspace-slot"
    case moveToWorkspace = "move-to-workspace"
    case moveToWorkspaceUp = "move-to-workspace-up"
    case moveToWorkspaceDown = "move-to-workspace-down"
    case moveToWorkspaceOnMonitor = "move-to-workspace-on-monitor"
    case moveToWorkspaceSlot = "move-to-workspace-slot"
    case moveToMonitor = "move-to-monitor"
    case focusMonitorPrevious = "focus-monitor-previous"
    case focusMonitorNext = "focus-monitor-next"
    case focusMonitorLast = "focus-monitor-last"
    case moveColumn = "move-column"
    case moveColumnToFirst = "move-column-to-first"
    case moveColumnToLast = "move-column-to-last"
    case moveColumnToIndex = "move-column-to-index"
    case moveColumnToWorkspace = "move-column-to-workspace"
    case moveColumnToWorkspaceUp = "move-column-to-workspace-up"
    case moveColumnToWorkspaceDown = "move-column-to-workspace-down"
    case toggleColumnTabbed = "toggle-column-tabbed"
    case cycleSizeForward = "cycle-size-forward"
    case cycleSizeBackward = "cycle-size-backward"
    case cycleWindowPrimarySpanForward = "cycle-window-primary-span-forward"
    case cycleWindowPrimarySpanBackward = "cycle-window-primary-span-backward"
    case cycleWindowSecondarySpanForward = "cycle-window-secondary-span-forward"
    case cycleWindowSecondarySpanBackward = "cycle-window-secondary-span-backward"
    case toggleContainerFullPrimarySpan = "toggle-container-full-primary-span"
    case expandContainerToAvailablePrimarySpan = "expand-container-to-available-primary-span"
    case resetWindowSecondarySpan = "reset-window-secondary-span"
    case setContainerPrimarySpan = "set-container-primary-span"
    case setWindowPrimarySpan = "set-window-primary-span"
    case setWindowSecondarySpan = "set-window-secondary-span"
    case swapWorkspaceWithMonitor = "swap-workspace-with-monitor"
    case balanceSizes = "balance-sizes"
    case moveToRoot = "move-to-root"
    case toggleSplit = "toggle-split"
    case swapSplit = "swap-split"
    case resize
    case resizeFocused = "resize-focused"
    case preselect
    case preselectClear = "preselect-clear"
    case openCommandPalette = "open-command-palette"
    case raiseAllFloatingWindows = "raise-all-floating-windows"
    case rescueOffscreenWindows = "rescue-offscreen-windows"
    case toggleWorkspaceLayout = "toggle-workspace-layout"
    case setWorkspaceLayout = "set-workspace-layout"
    case toggleFullscreen = "toggle-fullscreen"
    case toggleNativeFullscreen = "toggle-native-fullscreen"
    case toggleOverview = "toggle-overview"
    case toggleSystemStats = "toggle-system-stats"
    case toggleQuakeTerminal = "toggle-quake-terminal"
    case toggleWorkspaceBar = "toggle-workspace-bar"
    case hiddenBarPanel = "hidden-bar-panel"
    case toggleFocusedWindowFloating = "toggle-focused-window-floating"
    case closeFocusedWindow = "close-focused-window"
    case scratchpadAssign = "scratchpad-assign"
    case scratchpadToggle = "scratchpad-toggle"
    case openMenuAnywhere = "open-menu-anywhere"
}

public enum IPCSizeChangeKind: String, Codable, Equatable, Sendable {
    case setFixed = "set-fixed"
    case setProportion = "set-proportion"
    case adjustFixed = "adjust-fixed"
    case adjustProportion = "adjust-proportion"
}

public struct IPCSizeChange: Codable, Equatable, Sendable {
    public let kind: IPCSizeChangeKind
    public let value: Double

    public init(kind: IPCSizeChangeKind, value: Double) {
        self.kind = kind
        self.value = value
    }

    public static func setFixed(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .setFixed, value: value)
    }

    public static func setProportion(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .setProportion, value: value)
    }

    public static func adjustFixed(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .adjustFixed, value: value)
    }

    public static func adjustProportion(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .adjustProportion, value: value)
    }
}

public enum IPCCommandArgumentValue: Equatable, Sendable {
    case direction(IPCDirection)
    case integer(Int)
    case layout(IPCWorkspaceLayout)
    case resizeAxis(IPCResizeAxis)
    case resizeOperation(IPCResizeOperation)
    case sizeChange(IPCSizeChange)
}

public enum IPCCommandRequestConstructionError: Error, Equatable, Sendable {
    case invalidArgumentCount
    case invalidArgumentType
}

public enum IPCCommandRequest: Equatable, Sendable {
    case focus(direction: IPCDirection)
    case focusPrevious
    case focusDownOrLeft
    case focusUpOrRight
    case focusWindowInColumn(windowIndex: Int)
    case focusWindowTop
    case focusWindowBottom
    case focusWindowDownOrTop
    case focusWindowUpOrBottom
    case focusWindowOrWorkspaceDown
    case focusWindowOrWorkspaceUp
    case focusColumn(columnIndex: Int)
    case focusColumnFirst
    case focusColumnLast
    case centerColumn
    case centerVisibleColumns
    case move(direction: IPCDirection)
    case moveWindowDown
    case moveWindowUp
    case moveWindowDownOrToWorkspaceDown
    case moveWindowUpOrToWorkspaceUp
    case consumeOrExpelWindowLeft
    case consumeOrExpelWindowRight
    case consumeWindowIntoColumn
    case expelWindowFromColumn
    case switchWorkspace(workspaceNumber: Int)
    case switchWorkspaceNext
    case switchWorkspacePrevious
    case switchWorkspaceBackAndForth
    case switchWorkspaceAnywhere(workspaceNumber: Int)
    case switchWorkspaceSlot(slotNumber: Int)
    case moveToWorkspace(workspaceNumber: Int)
    case moveToWorkspaceUp
    case moveToWorkspaceDown
    case moveToWorkspaceOnMonitor(workspaceNumber: Int, direction: IPCDirection)
    case moveToWorkspaceSlot(slotNumber: Int)
    case moveToMonitor(direction: IPCDirection)
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case moveColumn(direction: IPCDirection)
    case moveColumnToFirst
    case moveColumnToLast
    case moveColumnToIndex(columnIndex: Int)
    case moveColumnToWorkspace(workspaceNumber: Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case toggleColumnTabbed
    case cycleSizeForward
    case cycleSizeBackward
    case cycleWindowPrimarySpanForward
    case cycleWindowPrimarySpanBackward
    case cycleWindowSecondarySpanForward
    case cycleWindowSecondarySpanBackward
    case toggleContainerFullPrimarySpan
    case expandContainerToAvailablePrimarySpan
    case resetWindowSecondarySpan
    case setContainerPrimarySpan(change: IPCSizeChange)
    case setWindowPrimarySpan(change: IPCSizeChange)
    case setWindowSecondarySpan(change: IPCSizeChange)
    case swapWorkspaceWithMonitor(direction: IPCDirection)
    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resize(axis: IPCResizeAxis, operation: IPCResizeOperation)
    case resizeFocused(operation: IPCResizeOperation)
    case preselect(direction: IPCDirection)
    case preselectClear
    case openCommandPalette
    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case toggleWorkspaceLayout
    case setWorkspaceLayout(layout: IPCWorkspaceLayout)
    case toggleFullscreen
    case toggleNativeFullscreen
    case toggleOverview
    case toggleSystemStats
    case toggleQuakeTerminal
    case toggleWorkspaceBar
    case hiddenBarPanel
    case toggleFocusedWindowFloating
    case closeFocusedWindow
    case scratchpadAssign(index: Int)
    case scratchpadToggle(index: Int)
    case openMenuAnywhere

    public var name: IPCCommandName {
        switch self {
        case .focus:
            .focus
        case .focusPrevious:
            .focusPrevious
        case .focusDownOrLeft:
            .focusDownOrLeft
        case .focusUpOrRight:
            .focusUpOrRight
        case .focusWindowInColumn:
            .focusWindowInColumn
        case .focusWindowTop:
            .focusWindowTop
        case .focusWindowBottom:
            .focusWindowBottom
        case .focusWindowDownOrTop:
            .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            .focusWindowOrWorkspaceUp
        case .focusColumn:
            .focusColumn
        case .focusColumnFirst:
            .focusColumnFirst
        case .focusColumnLast:
            .focusColumnLast
        case .centerColumn:
            .centerColumn
        case .centerVisibleColumns:
            .centerVisibleColumns
        case .move:
            .move
        case .moveWindowDown:
            .moveWindowDown
        case .moveWindowUp:
            .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            .expelWindowFromColumn
        case .switchWorkspace:
            .switchWorkspace
        case .switchWorkspaceNext:
            .switchWorkspaceNext
        case .switchWorkspacePrevious:
            .switchWorkspacePrevious
        case .switchWorkspaceBackAndForth:
            .switchWorkspaceBackAndForth
        case .switchWorkspaceAnywhere:
            .switchWorkspaceAnywhere
        case .switchWorkspaceSlot:
            .switchWorkspaceSlot
        case .moveToWorkspace:
            .moveToWorkspace
        case .moveToWorkspaceUp:
            .moveToWorkspaceUp
        case .moveToWorkspaceDown:
            .moveToWorkspaceDown
        case .moveToWorkspaceOnMonitor:
            .moveToWorkspaceOnMonitor
        case .moveToWorkspaceSlot:
            .moveToWorkspaceSlot
        case .moveToMonitor:
            .moveToMonitor
        case .focusMonitorPrevious:
            .focusMonitorPrevious
        case .focusMonitorNext:
            .focusMonitorNext
        case .focusMonitorLast:
            .focusMonitorLast
        case .moveColumn:
            .moveColumn
        case .moveColumnToFirst:
            .moveColumnToFirst
        case .moveColumnToLast:
            .moveColumnToLast
        case .moveColumnToIndex:
            .moveColumnToIndex
        case .moveColumnToWorkspace:
            .moveColumnToWorkspace
        case .moveColumnToWorkspaceUp:
            .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            .toggleColumnTabbed
        case .cycleSizeForward:
            .cycleSizeForward
        case .cycleSizeBackward:
            .cycleSizeBackward
        case .cycleWindowPrimarySpanForward:
            .cycleWindowPrimarySpanForward
        case .cycleWindowPrimarySpanBackward:
            .cycleWindowPrimarySpanBackward
        case .cycleWindowSecondarySpanForward:
            .cycleWindowSecondarySpanForward
        case .cycleWindowSecondarySpanBackward:
            .cycleWindowSecondarySpanBackward
        case .toggleContainerFullPrimarySpan:
            .toggleContainerFullPrimarySpan
        case .expandContainerToAvailablePrimarySpan:
            .expandContainerToAvailablePrimarySpan
        case .resetWindowSecondarySpan:
            .resetWindowSecondarySpan
        case .setContainerPrimarySpan:
            .setContainerPrimarySpan
        case .setWindowPrimarySpan:
            .setWindowPrimarySpan
        case .setWindowSecondarySpan:
            .setWindowSecondarySpan
        case .swapWorkspaceWithMonitor:
            .swapWorkspaceWithMonitor
        case .balanceSizes:
            .balanceSizes
        case .moveToRoot:
            .moveToRoot
        case .toggleSplit:
            .toggleSplit
        case .swapSplit:
            .swapSplit
        case .resize:
            .resize
        case .resizeFocused:
            .resizeFocused
        case .preselect:
            .preselect
        case .preselectClear:
            .preselectClear
        case .openCommandPalette:
            .openCommandPalette
        case .raiseAllFloatingWindows:
            .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            .rescueOffscreenWindows
        case .toggleWorkspaceLayout:
            .toggleWorkspaceLayout
        case .setWorkspaceLayout:
            .setWorkspaceLayout
        case .toggleFullscreen:
            .toggleFullscreen
        case .toggleNativeFullscreen:
            .toggleNativeFullscreen
        case .toggleOverview:
            .toggleOverview
        case .toggleSystemStats:
            .toggleSystemStats
        case .toggleQuakeTerminal:
            .toggleQuakeTerminal
        case .toggleWorkspaceBar:
            .toggleWorkspaceBar
        case .hiddenBarPanel:
            .hiddenBarPanel
        case .toggleFocusedWindowFloating:
            .toggleFocusedWindowFloating
        case .closeFocusedWindow:
            .closeFocusedWindow
        case .scratchpadAssign:
            .scratchpadAssign
        case .scratchpadToggle:
            .scratchpadToggle
        case .openMenuAnywhere:
            .openMenuAnywhere
        }
    }
}
