// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension IPCMonitorFocusCommand {
    func actionDisplayName() -> String {
        switch self {
        case .previous: "Focus Previous Monitor"
        case .next: "Focus Next Monitor"
        case .last: "Focus Last Monitor"
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let binding: KeyBinding
        switch self {
        case .previous:
            id = "focusMonitorPrevious"
            binding = .unassigned
        case .next:
            id = "focusMonitorNext"
            binding = KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | cmdKey))
        case .last:
            id = "focusMonitorLast"
            binding = KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | cmdKey))
        }
        return ActionCatalog.action(
            id: id,
            command: .monitorFocus(self),
            category: .monitor,
            binding: binding
        )
    }
}
