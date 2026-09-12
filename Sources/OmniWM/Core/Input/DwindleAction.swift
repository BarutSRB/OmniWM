// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

enum DwindleAction: Equatable, Hashable {
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resizeAlongAxis(DwindleOrientation, Bool)
    case resizeFocusedWindow(Bool)
    case preselect(Direction)
    case preselectClear
}

extension DwindleAction {
    func actionDisplayName() -> String {
        switch self {
        case .moveToRoot: "Move to Root"
        case .toggleSplit: "Toggle Split"
        case .swapSplit: "Swap Split"
        case let .resizeAlongAxis(orientation, grow):
            "\(grow ? "Grow" : "Shrink") \(orientation == .horizontal ? "Horizontally" : "Vertically")"
        case let .resizeFocusedWindow(grow): "\(grow ? "Grow" : "Shrink") Focused Window"
        case let .preselect(dir): "Preselect \(dir.displayName)"
        case .preselectClear: "Clear Preselection"
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .moveToRoot:
            .dwindle(.moveToRoot)
        case .toggleSplit:
            .dwindle(.toggleSplit)
        case .swapSplit:
            .dwindle(.swapSplit)
        case .resizeAlongAxis:
            .dwindle(.resize)
        case .resizeFocusedWindow:
            .dwindle(.resizeFocused)
        case .preselect:
            .dwindle(.preselect)
        case .preselectClear:
            .dwindle(.preselectClear)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .moveToRoot,
             .toggleSplit,
             .swapSplit,
             .resizeAlongAxis,
             .resizeFocusedWindow,
             .preselect,
             .preselectClear:
            .dwindle
        }
    }
}
