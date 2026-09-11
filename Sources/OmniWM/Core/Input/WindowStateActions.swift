// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension IPCWindowStateCommand {
    func actionDisplayName() -> String {
        switch self {
        case .toggleFloating: "Toggle Focused Window Floating"
        case .close: "Close Focused Window"
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let binding: KeyBinding
        let keywords: [String]
        let category: HotkeyCategory
        switch self {
        case .toggleFloating:
            id = "toggleFocusedWindowFloating"
            binding = .unassigned
            keywords = ["float", "floating"]
            category = .layout
        case .close:
            id = "closeFocusedWindow"
            binding = .unassigned
            keywords = ["close", "quit", "window"]
            category = .focus
        }
        return ActionCatalog.action(
            id: id,
            command: .windowState(self),
            category: category,
            binding: binding,
            keywords: keywords
        )
    }
}
