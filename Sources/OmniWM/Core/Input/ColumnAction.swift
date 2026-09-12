// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

enum ColumnAction: Equatable, Hashable {
    case moveToFirst
    case moveToLast
    case moveToIndex(Int)
    case moveToWorkspace(Int)
    case moveToWorkspaceUp
    case moveToWorkspaceDown
    case toggleTabbed
}

extension ColumnAction {
    func actionDisplayName() -> String {
        switch self {
        case let .moveToWorkspace(idx): "Move Column to Workspace \(idx + 1)"
        case .moveToWorkspaceUp: "Move Column to Workspace Up"
        case .moveToWorkspaceDown: "Move Column to Workspace Down"
        case .moveToFirst: "Move Column to First"
        case .moveToLast: "Move Column to Last"
        case let .moveToIndex(idx): "Move Column to Index \(idx)"
        case .toggleTabbed: "Toggle Column Tabbed"
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .moveToFirst:
            .column(.moveToFirst)
        case .moveToLast:
            .column(.moveToLast)
        case .moveToIndex:
            .column(.moveToIndex)
        case .moveToWorkspace:
            .column(.moveToWorkspace)
        case .moveToWorkspaceUp:
            .column(.moveToWorkspaceUp)
        case .moveToWorkspaceDown:
            .column(.moveToWorkspaceDown)
        case .toggleTabbed:
            .column(.toggleTabbed)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .moveToFirst,
             .moveToLast,
             .moveToIndex,
             .moveToWorkspace,
             .moveToWorkspaceUp,
             .moveToWorkspaceDown,
             .toggleTabbed:
            .niri
        }
    }
}
