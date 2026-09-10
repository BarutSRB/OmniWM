// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension IPCCommandRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    private struct IPCDirectionArguments: Codable, Equatable, Sendable {
        let direction: IPCDirection
    }

    private struct IPCWorkspaceNumberArguments: Codable, Equatable, Sendable {
        let workspaceNumber: Int
    }

    private struct IPCSlotNumberArguments: Codable, Equatable, Sendable {
        let slotNumber: Int
    }

    private struct IPCColumnIndexArguments: Codable, Equatable, Sendable {
        let columnIndex: Int
    }

    private struct IPCScratchpadIndexArguments: Codable, Equatable, Sendable {
        let scratchpadIndex: Int
    }

    private struct IPCWindowIndexArguments: Codable, Equatable, Sendable {
        let windowIndex: Int
    }

    private struct IPCWorkspaceOnMonitorArguments: Codable, Equatable, Sendable {
        let workspaceNumber: Int
        let direction: IPCDirection
    }

    private struct IPCLayoutArguments: Codable, Equatable, Sendable {
        let layout: IPCWorkspaceLayout
    }

    private struct IPCResizeArguments: Codable, Equatable, Sendable {
        let axis: IPCResizeAxis
        let operation: IPCResizeOperation
    }

    private struct IPCResizeOperationArguments: Codable, Equatable, Sendable {
        let operation: IPCResizeOperation
    }

    private struct IPCSizeChangeArguments: Codable, Equatable, Sendable {
        let change: IPCSizeChange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(IPCCommandName.self, forKey: .name)

        switch name {
        case .focus:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .focus(direction: arguments.direction)
        case .focusPrevious:
            self = .focusPrevious
        case .focusDownOrLeft:
            self = .focusDownOrLeft
        case .focusUpOrRight:
            self = .focusUpOrRight
        case .focusWindowInColumn:
            let arguments = try container.decode(IPCWindowIndexArguments.self, forKey: .arguments)
            self = .focusWindowInColumn(windowIndex: arguments.windowIndex)
        case .focusWindowTop:
            self = .focusWindowTop
        case .focusWindowBottom:
            self = .focusWindowBottom
        case .focusWindowDownOrTop:
            self = .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            self = .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            self = .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            self = .focusWindowOrWorkspaceUp
        case .focusColumn:
            let arguments = try container.decode(IPCColumnIndexArguments.self, forKey: .arguments)
            self = .focusColumn(columnIndex: arguments.columnIndex)
        case .focusColumnFirst:
            self = .focusColumnFirst
        case .focusColumnLast:
            self = .focusColumnLast
        case .centerColumn:
            self = .centerColumn
        case .centerVisibleColumns:
            self = .centerVisibleColumns
        case .move:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .move(direction: arguments.direction)
        case .moveWindowDown:
            self = .moveWindowDown
        case .moveWindowUp:
            self = .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            self = .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            self = .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            self = .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            self = .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            self = .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            self = .expelWindowFromColumn
        case .switchWorkspace:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .switchWorkspace(workspaceNumber: arguments.workspaceNumber)
        case .switchWorkspaceNext:
            self = .switchWorkspaceNext
        case .switchWorkspacePrevious:
            self = .switchWorkspacePrevious
        case .switchWorkspaceBackAndForth:
            self = .switchWorkspaceBackAndForth
        case .switchWorkspaceAnywhere:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .switchWorkspaceAnywhere(workspaceNumber: arguments.workspaceNumber)
        case .switchWorkspaceSlot:
            let arguments = try container.decode(IPCSlotNumberArguments.self, forKey: .arguments)
            self = .switchWorkspaceSlot(slotNumber: arguments.slotNumber)
        case .moveToWorkspaceSlot:
            let arguments = try container.decode(IPCSlotNumberArguments.self, forKey: .arguments)
            self = .moveToWorkspaceSlot(slotNumber: arguments.slotNumber)
        case .moveToWorkspace:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .moveToWorkspace(workspaceNumber: arguments.workspaceNumber)
        case .moveToWorkspaceUp:
            self = .moveToWorkspaceUp
        case .moveToWorkspaceDown:
            self = .moveToWorkspaceDown
        case .moveToWorkspaceOnMonitor:
            let arguments = try container.decode(IPCWorkspaceOnMonitorArguments.self, forKey: .arguments)
            self = .moveToWorkspaceOnMonitor(workspaceNumber: arguments.workspaceNumber, direction: arguments.direction)
        case .moveToMonitor:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .moveToMonitor(direction: arguments.direction)
        case .focusMonitorPrevious:
            self = .focusMonitorPrevious
        case .focusMonitorNext:
            self = .focusMonitorNext
        case .focusMonitorLast:
            self = .focusMonitorLast
        case .moveColumn:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .moveColumn(direction: arguments.direction)
        case .moveColumnToFirst:
            self = .moveColumnToFirst
        case .moveColumnToLast:
            self = .moveColumnToLast
        case .moveColumnToIndex:
            let arguments = try container.decode(IPCColumnIndexArguments.self, forKey: .arguments)
            self = .moveColumnToIndex(columnIndex: arguments.columnIndex)
        case .moveColumnToWorkspace:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .moveColumnToWorkspace(workspaceNumber: arguments.workspaceNumber)
        case .moveColumnToWorkspaceUp:
            self = .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            self = .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            self = .toggleColumnTabbed
        case .cycleSizeForward:
            self = .cycleSizeForward
        case .cycleSizeBackward:
            self = .cycleSizeBackward
        case .cycleWindowPrimarySpanForward:
            self = .cycleWindowPrimarySpanForward
        case .cycleWindowPrimarySpanBackward:
            self = .cycleWindowPrimarySpanBackward
        case .cycleWindowSecondarySpanForward:
            self = .cycleWindowSecondarySpanForward
        case .cycleWindowSecondarySpanBackward:
            self = .cycleWindowSecondarySpanBackward
        case .toggleContainerFullPrimarySpan:
            self = .toggleContainerFullPrimarySpan
        case .expandContainerToAvailablePrimarySpan:
            self = .expandContainerToAvailablePrimarySpan
        case .resetWindowSecondarySpan:
            self = .resetWindowSecondarySpan
        case .setContainerPrimarySpan:
            let arguments = try container.decode(IPCSizeChangeArguments.self, forKey: .arguments)
            self = .setContainerPrimarySpan(change: arguments.change)
        case .setWindowPrimarySpan:
            let arguments = try container.decode(IPCSizeChangeArguments.self, forKey: .arguments)
            self = .setWindowPrimarySpan(change: arguments.change)
        case .setWindowSecondarySpan:
            let arguments = try container.decode(IPCSizeChangeArguments.self, forKey: .arguments)
            self = .setWindowSecondarySpan(change: arguments.change)
        case .swapWorkspaceWithMonitor:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .swapWorkspaceWithMonitor(direction: arguments.direction)
        case .balanceSizes:
            self = .balanceSizes
        case .moveToRoot:
            self = .moveToRoot
        case .toggleSplit:
            self = .toggleSplit
        case .swapSplit:
            self = .swapSplit
        case .resize:
            let arguments = try container.decode(IPCResizeArguments.self, forKey: .arguments)
            self = .resize(axis: arguments.axis, operation: arguments.operation)
        case .resizeFocused:
            let arguments = try container.decode(IPCResizeOperationArguments.self, forKey: .arguments)
            self = .resizeFocused(operation: arguments.operation)
        case .preselect:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .preselect(direction: arguments.direction)
        case .preselectClear:
            self = .preselectClear
        case .openCommandPalette:
            self = .openCommandPalette
        case .raiseAllFloatingWindows:
            self = .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            self = .rescueOffscreenWindows
        case .toggleWorkspaceLayout:
            self = .toggleWorkspaceLayout
        case .setWorkspaceLayout:
            let arguments = try container.decode(IPCLayoutArguments.self, forKey: .arguments)
            self = .setWorkspaceLayout(layout: arguments.layout)
        case .toggleFullscreen:
            self = .toggleFullscreen
        case .toggleNativeFullscreen:
            self = .toggleNativeFullscreen
        case .toggleOverview:
            self = .toggleOverview
        case .toggleSystemStats:
            self = .toggleSystemStats
        case .toggleQuakeTerminal:
            self = .toggleQuakeTerminal
        case .toggleWorkspaceBar:
            self = .toggleWorkspaceBar
        case .hiddenBarPanel:
            self = .hiddenBarPanel
        case .toggleFocusedWindowFloating:
            self = .toggleFocusedWindowFloating
        case .closeFocusedWindow:
            self = .closeFocusedWindow
        case .scratchpadAssign:
            let arguments = try container.decode(IPCScratchpadIndexArguments.self, forKey: .arguments)
            self = .scratchpadAssign(index: arguments.scratchpadIndex)
        case .scratchpadToggle:
            let arguments = try container.decode(IPCScratchpadIndexArguments.self, forKey: .arguments)
            self = .scratchpadToggle(index: arguments.scratchpadIndex)
        case .openMenuAnywhere:
            self = .openMenuAnywhere
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        switch self {
        case let .focus(direction),
             let .move(direction),
             let .moveToMonitor(direction),
             let .moveColumn(direction),
             let .swapWorkspaceWithMonitor(direction),
             let .preselect(direction):
            try container.encode(IPCDirectionArguments(direction: direction), forKey: .arguments)
        case .focusPrevious,
             .focusDownOrLeft,
             .focusUpOrRight,
             .focusWindowTop,
             .focusWindowBottom,
             .focusWindowDownOrTop,
             .focusWindowUpOrBottom,
             .focusWindowOrWorkspaceDown,
             .focusWindowOrWorkspaceUp,
             .focusColumnFirst,
             .focusColumnLast,
             .centerColumn,
             .centerVisibleColumns,
             .moveWindowDown,
             .moveWindowUp,
             .moveWindowDownOrToWorkspaceDown,
             .moveWindowUpOrToWorkspaceUp,
             .consumeOrExpelWindowLeft,
             .consumeOrExpelWindowRight,
             .consumeWindowIntoColumn,
             .expelWindowFromColumn,
             .switchWorkspaceNext,
             .switchWorkspacePrevious,
             .switchWorkspaceBackAndForth,
             .moveToWorkspaceUp,
             .moveToWorkspaceDown,
             .focusMonitorPrevious,
             .focusMonitorNext,
             .focusMonitorLast,
             .moveColumnToFirst,
             .moveColumnToLast,
             .moveColumnToWorkspaceUp,
             .moveColumnToWorkspaceDown,
             .toggleColumnTabbed,
             .cycleSizeForward,
             .cycleSizeBackward,
             .cycleWindowPrimarySpanForward,
             .cycleWindowPrimarySpanBackward,
             .cycleWindowSecondarySpanForward,
             .cycleWindowSecondarySpanBackward,
             .toggleContainerFullPrimarySpan,
             .expandContainerToAvailablePrimarySpan,
             .resetWindowSecondarySpan,
             .balanceSizes,
             .moveToRoot,
             .toggleSplit,
             .swapSplit,
             .preselectClear,
             .openCommandPalette,
             .raiseAllFloatingWindows,
             .rescueOffscreenWindows,
             .toggleWorkspaceLayout,
             .toggleFullscreen,
             .toggleNativeFullscreen,
             .toggleOverview,
             .toggleSystemStats,
             .toggleQuakeTerminal,
             .toggleWorkspaceBar,
             .hiddenBarPanel,
             .toggleFocusedWindowFloating,
             .closeFocusedWindow,
             .openMenuAnywhere:
            break
        case let .focusWindowInColumn(windowIndex):
            try container.encode(IPCWindowIndexArguments(windowIndex: windowIndex), forKey: .arguments)
        case let .focusColumn(columnIndex),
             let .moveColumnToIndex(columnIndex):
            try container.encode(IPCColumnIndexArguments(columnIndex: columnIndex), forKey: .arguments)
        case let .switchWorkspace(workspaceNumber),
             let .switchWorkspaceAnywhere(workspaceNumber),
             let .moveToWorkspace(workspaceNumber),
             let .moveColumnToWorkspace(workspaceNumber):
            try container.encode(IPCWorkspaceNumberArguments(workspaceNumber: workspaceNumber), forKey: .arguments)
        case let .switchWorkspaceSlot(slotNumber),
             let .moveToWorkspaceSlot(slotNumber):
            try container.encode(IPCSlotNumberArguments(slotNumber: slotNumber), forKey: .arguments)
        case let .moveToWorkspaceOnMonitor(workspaceNumber, direction):
            try container.encode(
                IPCWorkspaceOnMonitorArguments(workspaceNumber: workspaceNumber, direction: direction),
                forKey: .arguments
            )
        case let .setContainerPrimarySpan(change),
             let .setWindowPrimarySpan(change),
             let .setWindowSecondarySpan(change):
            try container.encode(IPCSizeChangeArguments(change: change), forKey: .arguments)
        case let .resize(axis, operation):
            try container.encode(
                IPCResizeArguments(axis: axis, operation: operation),
                forKey: .arguments
            )
        case let .resizeFocused(operation):
            try container.encode(IPCResizeOperationArguments(operation: operation), forKey: .arguments)
        case let .setWorkspaceLayout(layout):
            try container.encode(IPCLayoutArguments(layout: layout), forKey: .arguments)
        case let .scratchpadAssign(index),
             let .scratchpadToggle(index):
            try container.encode(IPCScratchpadIndexArguments(scratchpadIndex: index), forKey: .arguments)
        }
    }
}
