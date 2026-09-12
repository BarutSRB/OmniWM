// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

enum WorkspaceAction: Equatable, Hashable {
    case moveTo(Int)
    case moveUp
    case moveDown
    case moveToMonitor(Direction)
    case switchTo(Int)
    case switchSlot(Int)
    case moveToSlot(Int)
    case next
    case previous
    case moveWorkspaceToMonitor(Direction)
    case swapWithMonitor(Direction)
    case backAndForth
    case toggleLayout
}

extension WorkspaceAction {
    func actionDisplayName() -> String {
        switch self {
        case let .moveTo(idx): "Move to Workspace \(idx + 1)"
        case .moveUp: "Move Window to Workspace Up"
        case .moveDown: "Move Window to Workspace Down"
        case let .switchTo(idx): "Switch to Workspace \(idx + 1)"
        case let .switchSlot(slot): "Switch to Workspace Slot \(slot)"
        case let .moveToSlot(slot): "Move to Workspace Slot \(slot)"
        case .next: "Switch to Next Workspace"
        case .previous: "Switch to Previous Workspace"
        case let .moveToMonitor(dir): "Move Window to \(dir.displayName) Monitor"
        case let .moveWorkspaceToMonitor(dir): "Move Workspace to \(dir.displayName) Monitor"
        case let .swapWithMonitor(dir): "Swap Workspace with \(dir.displayName) Monitor"
        case .backAndForth: "Switch to Last Active Workspace"
        case .toggleLayout: "Toggle Workspace Layout"
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .switchTo:
            .workspace(.switchTo)
        case .switchSlot:
            .workspace(.switchSlot)
        case .moveToSlot:
            .workspace(.moveToSlot)
        case .next:
            .workspace(.next)
        case .previous:
            .workspace(.previous)
        case .backAndForth:
            .workspace(.backAndForth)
        case .moveTo:
            .workspace(.moveTo)
        case .moveUp:
            .workspace(.moveUp)
        case .moveDown:
            .workspace(.moveDown)
        case .moveToMonitor:
            .workspace(.moveToMonitor)
        case .moveWorkspaceToMonitor:
            nil
        case .swapWithMonitor:
            .swapWorkspaceWithMonitor
        case .toggleLayout:
            .workspaceLayout(.toggle)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .moveTo,
             .moveUp,
             .moveDown,
             .moveToMonitor,
             .switchTo,
             .switchSlot,
             .moveToSlot,
             .next,
             .previous,
             .moveWorkspaceToMonitor,
             .swapWithMonitor,
             .backAndForth,
             .toggleLayout:
            .shared
        }
    }
}
