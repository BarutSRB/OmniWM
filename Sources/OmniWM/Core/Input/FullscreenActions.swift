// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension IPCFullscreenCommand {
    func actionDisplayName() -> String {
        switch self {
        case .managed: "Toggle Fullscreen"
        case .native: "Toggle Native Fullscreen"
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let binding: KeyBinding
        switch self {
        case .managed:
            id = "toggleFullscreen"
            binding = KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
        case .native:
            id = "toggleNativeFullscreen"
            binding = .unassigned
        }
        return ActionCatalog.action(
            id: id,
            command: .fullscreen(self),
            category: .layout,
            binding: binding
        )
    }
}
