// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension IPCCommandRequest {
    public init(name: IPCCommandName, argumentValues: [IPCCommandArgumentValue] = []) throws {
        func requireNoArguments() throws {
            guard argumentValues.isEmpty else {
                throw IPCCommandRequestConstructionError.invalidArgumentCount
            }
        }

        func requireDirection() throws -> IPCDirection {
            guard argumentValues.count == 1, case let .direction(direction) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return direction
        }

        func requireInteger() throws -> Int {
            guard argumentValues.count == 1, case let .integer(value) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        }

        func requireLayout() throws -> IPCWorkspaceLayout {
            guard argumentValues.count == 1, case let .layout(layout) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return layout
        }

        func requireSizeChange() throws -> IPCSizeChange {
            guard argumentValues.count == 1, case let .sizeChange(change) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return change
        }

        func requireResizeArguments() throws -> (axis: IPCResizeAxis, operation: IPCResizeOperation) {
            guard argumentValues.count == 2,
                  case let .resizeAxis(axis) = argumentValues[0],
                  case let .resizeOperation(operation) = argumentValues[1]
            else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return (axis, operation)
        }

        func requireResizeOperation() throws -> IPCResizeOperation {
            guard argumentValues.count == 1, case let .resizeOperation(operation) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return operation
        }

        func requireWorkspaceAndDirection() throws -> (workspaceNumber: Int, direction: IPCDirection) {
            guard argumentValues.count == 2,
                  case let .integer(workspaceNumber) = argumentValues[0],
                  case let .direction(direction) = argumentValues[1]
            else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return (workspaceNumber, direction)
        }

        switch name {
        case .focus:
            self = .focus(direction: try requireDirection())
        case .focusPrevious:
            try requireNoArguments()
            self = .focusPrevious
        case .focusDownOrLeft:
            try requireNoArguments()
            self = .focusDownOrLeft
        case .focusUpOrRight:
            try requireNoArguments()
            self = .focusUpOrRight
        case .focusWindowInColumn:
            self = .focusWindowInColumn(windowIndex: try requireInteger())
        case .focusWindowTop:
            try requireNoArguments()
            self = .focusWindowTop
        case .focusWindowBottom:
            try requireNoArguments()
            self = .focusWindowBottom
        case .focusWindowDownOrTop:
            try requireNoArguments()
            self = .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            try requireNoArguments()
            self = .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            try requireNoArguments()
            self = .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            try requireNoArguments()
            self = .focusWindowOrWorkspaceUp
        case .focusColumn:
            self = .focusColumn(columnIndex: try requireInteger())
        case .focusColumnFirst:
            try requireNoArguments()
            self = .focusColumnFirst
        case .focusColumnLast:
            try requireNoArguments()
            self = .focusColumnLast
        case .centerColumn:
            try requireNoArguments()
            self = .centerColumn
        case .centerVisibleColumns:
            try requireNoArguments()
            self = .centerVisibleColumns
        case .move:
            self = .move(direction: try requireDirection())
        case .moveWindowDown:
            try requireNoArguments()
            self = .moveWindowDown
        case .moveWindowUp:
            try requireNoArguments()
            self = .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            try requireNoArguments()
            self = .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            try requireNoArguments()
            self = .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            try requireNoArguments()
            self = .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            try requireNoArguments()
            self = .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            try requireNoArguments()
            self = .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            try requireNoArguments()
            self = .expelWindowFromColumn
        case .switchWorkspace:
            self = .switchWorkspace(workspaceNumber: try requireInteger())
        case .switchWorkspaceNext:
            try requireNoArguments()
            self = .switchWorkspaceNext
        case .switchWorkspacePrevious:
            try requireNoArguments()
            self = .switchWorkspacePrevious
        case .switchWorkspaceBackAndForth:
            try requireNoArguments()
            self = .switchWorkspaceBackAndForth
        case .switchWorkspaceAnywhere:
            self = .switchWorkspaceAnywhere(workspaceNumber: try requireInteger())
        case .switchWorkspaceSlot:
            self = .switchWorkspaceSlot(slotNumber: try requireInteger())
        case .moveToWorkspace:
            self = .moveToWorkspace(workspaceNumber: try requireInteger())
        case .moveToWorkspaceUp:
            try requireNoArguments()
            self = .moveToWorkspaceUp
        case .moveToWorkspaceDown:
            try requireNoArguments()
            self = .moveToWorkspaceDown
        case .moveToWorkspaceOnMonitor:
            let arguments = try requireWorkspaceAndDirection()
            self = .moveToWorkspaceOnMonitor(
                workspaceNumber: arguments.workspaceNumber,
                direction: arguments.direction
            )
        case .moveToWorkspaceSlot:
            self = .moveToWorkspaceSlot(slotNumber: try requireInteger())
        case .moveToMonitor:
            self = .moveToMonitor(direction: try requireDirection())
        case .focusMonitorPrevious:
            try requireNoArguments()
            self = .focusMonitorPrevious
        case .focusMonitorNext:
            try requireNoArguments()
            self = .focusMonitorNext
        case .focusMonitorLast:
            try requireNoArguments()
            self = .focusMonitorLast
        case .moveColumn:
            self = .moveColumn(direction: try requireDirection())
        case .moveColumnToFirst:
            try requireNoArguments()
            self = .moveColumnToFirst
        case .moveColumnToLast:
            try requireNoArguments()
            self = .moveColumnToLast
        case .moveColumnToIndex:
            self = .moveColumnToIndex(columnIndex: try requireInteger())
        case .moveColumnToWorkspace:
            self = .moveColumnToWorkspace(workspaceNumber: try requireInteger())
        case .moveColumnToWorkspaceUp:
            try requireNoArguments()
            self = .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            try requireNoArguments()
            self = .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            try requireNoArguments()
            self = .toggleColumnTabbed
        case .cycleSizeForward:
            try requireNoArguments()
            self = .cycleSizeForward
        case .cycleSizeBackward:
            try requireNoArguments()
            self = .cycleSizeBackward
        case .cycleWindowPrimarySpanForward:
            try requireNoArguments()
            self = .cycleWindowPrimarySpanForward
        case .cycleWindowPrimarySpanBackward:
            try requireNoArguments()
            self = .cycleWindowPrimarySpanBackward
        case .cycleWindowSecondarySpanForward:
            try requireNoArguments()
            self = .cycleWindowSecondarySpanForward
        case .cycleWindowSecondarySpanBackward:
            try requireNoArguments()
            self = .cycleWindowSecondarySpanBackward
        case .toggleContainerFullPrimarySpan:
            try requireNoArguments()
            self = .toggleContainerFullPrimarySpan
        case .expandContainerToAvailablePrimarySpan:
            try requireNoArguments()
            self = .expandContainerToAvailablePrimarySpan
        case .resetWindowSecondarySpan:
            try requireNoArguments()
            self = .resetWindowSecondarySpan
        case .setContainerPrimarySpan:
            self = .setContainerPrimarySpan(change: try requireSizeChange())
        case .setWindowPrimarySpan:
            self = .setWindowPrimarySpan(change: try requireSizeChange())
        case .setWindowSecondarySpan:
            self = .setWindowSecondarySpan(change: try requireSizeChange())
        case .swapWorkspaceWithMonitor:
            self = .swapWorkspaceWithMonitor(direction: try requireDirection())
        case .balanceSizes:
            try requireNoArguments()
            self = .balanceSizes
        case .moveToRoot:
            try requireNoArguments()
            self = .moveToRoot
        case .toggleSplit:
            try requireNoArguments()
            self = .toggleSplit
        case .swapSplit:
            try requireNoArguments()
            self = .swapSplit
        case .resize:
            let arguments = try requireResizeArguments()
            self = .resize(axis: arguments.axis, operation: arguments.operation)
        case .resizeFocused:
            self = .resizeFocused(operation: try requireResizeOperation())
        case .preselect:
            self = .preselect(direction: try requireDirection())
        case .preselectClear:
            try requireNoArguments()
            self = .preselectClear
        case .openCommandPalette:
            try requireNoArguments()
            self = .openCommandPalette
        case .raiseAllFloatingWindows:
            try requireNoArguments()
            self = .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            try requireNoArguments()
            self = .rescueOffscreenWindows
        case .toggleWorkspaceLayout:
            try requireNoArguments()
            self = .toggleWorkspaceLayout
        case .setWorkspaceLayout:
            self = .setWorkspaceLayout(layout: try requireLayout())
        case .toggleFullscreen:
            try requireNoArguments()
            self = .toggleFullscreen
        case .toggleNativeFullscreen:
            try requireNoArguments()
            self = .toggleNativeFullscreen
        case .toggleOverview:
            try requireNoArguments()
            self = .toggleOverview
        case .toggleSystemStats:
            try requireNoArguments()
            self = .toggleSystemStats
        case .toggleQuakeTerminal:
            try requireNoArguments()
            self = .toggleQuakeTerminal
        case .toggleWorkspaceBar:
            try requireNoArguments()
            self = .toggleWorkspaceBar
        case .hiddenBarPanel:
            try requireNoArguments()
            self = .hiddenBarPanel
        case .toggleFocusedWindowFloating:
            try requireNoArguments()
            self = .toggleFocusedWindowFloating
        case .closeFocusedWindow:
            try requireNoArguments()
            self = .closeFocusedWindow
        case .scratchpadAssign:
            self = try .scratchpadAssign(index: requireInteger())
        case .scratchpadToggle:
            self = try .scratchpadToggle(index: requireInteger())
        case .openMenuAnywhere:
            try requireNoArguments()
            self = .openMenuAnywhere
        }
    }
}
