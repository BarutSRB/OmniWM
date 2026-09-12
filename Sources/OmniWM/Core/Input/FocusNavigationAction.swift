// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

enum FocusNavigationAction: Equatable, Hashable {
    case previous
    case downOrLeft
    case upOrRight
    case windowInColumn(Int)
    case windowTop
    case windowBottom
    case windowDownOrTop
    case windowUpOrBottom
    case windowOrWorkspaceDown
    case windowOrWorkspaceUp
    case columnFirst
    case columnLast
    case column(Int)
    case centerColumn
    case centerVisibleColumns
}

extension FocusNavigationAction {
    func actionDisplayName() -> String {
        switch self {
        case .previous: "Focus Previous Window"
        case .downOrLeft: "Traverse Backward"
        case .upOrRight: "Traverse Forward"
        case let .windowInColumn(idx): "Focus Window \(idx) in Column"
        case .windowTop: "Focus Top Window"
        case .windowBottom: "Focus Bottom Window"
        case .windowDownOrTop: "Focus Down or Top"
        case .windowUpOrBottom: "Focus Up or Bottom"
        case .windowOrWorkspaceDown: "Focus Window or Workspace Down"
        case .windowOrWorkspaceUp: "Focus Window or Workspace Up"
        case .columnFirst: "Focus First Column"
        case .columnLast: "Focus Last Column"
        case let .column(idx): "Focus Column \(idx + 1)"
        case .centerColumn: "Center Column"
        case .centerVisibleColumns: "Center Visible Columns"
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .previous:
            .focus(.previous)
        case .downOrLeft:
            .focus(.downOrLeft)
        case .upOrRight:
            .focus(.upOrRight)
        case .windowInColumn:
            .focus(.windowInColumn)
        case .windowTop:
            .focus(.windowTop)
        case .windowBottom:
            .focus(.windowBottom)
        case .windowDownOrTop:
            .focus(.windowDownOrTop)
        case .windowUpOrBottom:
            .focus(.windowUpOrBottom)
        case .windowOrWorkspaceDown:
            .focus(.windowOrWorkspaceDown)
        case .windowOrWorkspaceUp:
            .focus(.windowOrWorkspaceUp)
        case .column:
            .focus(.column)
        case .columnFirst:
            .focus(.columnFirst)
        case .columnLast:
            .focus(.columnLast)
        case .centerColumn:
            .focus(.centerColumn)
        case .centerVisibleColumns:
            .focus(.centerVisibleColumns)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .previous,
             .windowDownOrTop,
             .windowUpOrBottom:
            .shared
        case .downOrLeft,
             .upOrRight,
             .windowInColumn,
             .windowTop,
             .windowBottom,
             .windowOrWorkspaceDown,
             .windowOrWorkspaceUp,
             .columnFirst,
             .columnLast,
             .column,
             .centerColumn,
             .centerVisibleColumns:
            .niri
        }
    }
}
