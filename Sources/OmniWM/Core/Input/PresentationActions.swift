// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension IPCPresentationCommand {
    func actionDisplayName() -> String {
        switch self {
        case .overview: "Toggle Overview"
        case .systemStats: "Toggle System Stats"
        case .quakeTerminal: "Toggle Quake Terminal"
        case .workspaceBar: "Toggle Workspace Bar"
        case .hiddenBar: "Toggle Hidden Icons Bar"
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let keywords: [String]
        let binding: KeyBinding
        switch self {
        case .overview:
            id = "toggleOverview"
            keywords = ["overview"]
            binding = KeyBinding(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | shiftKey))
        case .systemStats:
            id = "toggleSystemStats"
            keywords = ["stats", "system", "cpu", "memory", "gpu", "disk", "fetch"]
            binding = .unassigned
        case .quakeTerminal:
            id = "toggleQuakeTerminal"
            keywords = ["quake", "terminal"]
            binding = KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey))
        case .workspaceBar:
            id = "toggleWorkspaceBarVisibility"
            keywords = ["workspace bar", "bar"]
            binding = .unassigned
        case .hiddenBar:
            id = "toggleHiddenBarPanel"
            keywords = ["hidden bar", "icons", "menu bar"]
            binding = .unassigned
        }
        return ActionCatalog.action(
            id: id,
            command: .presentation(self),
            category: .focus,
            binding: binding,
            keywords: keywords
        )
    }
}
