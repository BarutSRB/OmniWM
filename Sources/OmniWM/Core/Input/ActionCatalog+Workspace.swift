// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendWorkspaceNumberBindings(_ specs: inout [ActionSpec]) {
        for (idx, code) in digitCodes.enumerated() {
            specs.append(
                action(
                    id: "switchWorkspace.\(idx)",
                    command: .workspace(.switchTo(idx)),
                    category: .workspace,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey))
                )
            )
            specs.append(
                action(
                    id: "moveToWorkspace.\(idx)",
                    command: .workspace(.moveTo(idx)),
                    category: .workspace,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | shiftKey))
                )
            )
        }
    }

    static func appendWorkspaceSlotBindings(_ specs: inout [ActionSpec]) {
        for slot in workspaceSlotRange {
            specs.append(contentsOf: [
                action(
                    id: "switchWorkspaceSlot.\(slot)",
                    command: .workspace(.switchSlot(slot)),
                    category: .workspace,
                    binding: .unassigned,
                    keywords: ["slot", "position", "monitor"]
                ),
                action(
                    id: "moveToWorkspaceSlot.\(slot)",
                    command: .workspace(.moveToSlot(slot)),
                    category: .workspace,
                    binding: .unassigned,
                    keywords: ["slot", "position", "monitor"]
                )
            ])
        }
    }

    static func appendWorkspaceHistoryBinding(_ specs: inout [ActionSpec]) {
        specs.append(
            action(
                id: "workspaceBackAndForth",
                command: .workspace(.backAndForth),
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | controlKey)),
                keywords: ["back and forth", "previous workspace"]
            )
        )
    }

    static func appendWorkspaceCycleBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "switchWorkspace.next",
                command: .workspace(.next),
                category: .workspace,
                binding: .unassigned
            ),
            action(
                id: "switchWorkspace.previous",
                command: .workspace(.previous),
                category: .workspace,
                binding: .unassigned
            )
        ])
    }

    static func appendWorkspaceTransferBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "moveWindowToWorkspaceUp",
                command: .workspace(.moveUp),
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | controlKey | shiftKey))
            ),
            action(
                id: "moveWindowToWorkspaceDown",
                command: .workspace(.moveDown),
                category: .workspace,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_DownArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            action(
                id: "moveColumnToWorkspaceUp",
                command: .column(.moveToWorkspaceUp),
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_PageUp), modifiers: UInt32(optionKey | controlKey | shiftKey))
            ),
            action(
                id: "moveColumnToWorkspaceDown",
                command: .column(.moveToWorkspaceDown),
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_PageDown), modifiers: UInt32(optionKey | controlKey | shiftKey))
            )
        ])
    }
}
