// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

enum WindowMovementAction: Equatable, Hashable {
    case down
    case up
    case downOrToWorkspaceDown
    case upOrToWorkspaceUp
    case consumeOrExpelLeft
    case consumeOrExpelRight
    case consumeIntoColumn
    case expelFromColumn
}

extension WindowMovementAction {
    func actionDisplayName() -> String {
        switch self {
        case .down: "Reorder Window Down"
        case .up: "Reorder Window Up"
        case .downOrToWorkspaceDown: "Move Window Down or to Workspace Down"
        case .upOrToWorkspaceUp: "Move Window Up or to Workspace Up"
        case .consumeOrExpelLeft: "Consume or Expel Window Left"
        case .consumeOrExpelRight: "Consume or Expel Window Right"
        case .consumeIntoColumn: "Consume Window into Column"
        case .expelFromColumn: "Expel Window from Column"
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .down:
            .windowMovement(.down)
        case .up:
            .windowMovement(.up)
        case .downOrToWorkspaceDown:
            .windowMovement(.downOrToWorkspaceDown)
        case .upOrToWorkspaceUp:
            .windowMovement(.upOrToWorkspaceUp)
        case .consumeOrExpelLeft:
            .windowMovement(.consumeOrExpelLeft)
        case .consumeOrExpelRight:
            .windowMovement(.consumeOrExpelRight)
        case .consumeIntoColumn:
            .windowMovement(.consumeIntoColumn)
        case .expelFromColumn:
            .windowMovement(.expelFromColumn)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .down,
             .up:
            .shared
        case .downOrToWorkspaceDown,
             .upOrToWorkspaceUp,
             .consumeOrExpelLeft,
             .consumeOrExpelRight,
             .consumeIntoColumn,
             .expelFromColumn:
            .niri
        }
    }
}
