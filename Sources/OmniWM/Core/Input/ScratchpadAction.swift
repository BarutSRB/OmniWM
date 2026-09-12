// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

enum ScratchpadAction: Equatable, Hashable {
    case assign(Int)
    case toggle(Int)
}

extension ScratchpadAction {
    func actionDisplayName() -> String {
        switch self {
        case let .assign(index): "Assign Focused Window to Scratchpad \(index)"
        case let .toggle(index): "Toggle Scratchpad \(index)"
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .assign:
            .scratchpad(.assign)
        case .toggle:
            .scratchpad(.toggle)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .assign,
             .toggle:
            .shared
        }
    }
}
