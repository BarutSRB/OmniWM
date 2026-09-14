// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendDirectionalFocusBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "focus.left",
                command: .focus(.left),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focus.down",
                command: .focus(.down),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey)),
                keywords: ["group", "tab", "cycle"]
            ),
            action(
                id: "focus.up",
                command: .focus(.up),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey)),
                keywords: ["group", "tab", "cycle"]
            ),
            action(
                id: "focus.right",
                command: .focus(.right),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey))
            )
        ])
    }

    static func appendFocusHistoryBinding(_ specs: inout [ActionSpec]) {
        specs.append(
            action(
                id: "focusPrevious",
                command: .focusNavigation(.previous),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)),
                keywords: ["last focused", "recent window"]
            )
        )
    }

    static func appendTraversalFocusBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "focusDownOrLeft",
                command: .focusNavigation(.downOrLeft),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusUpOrRight",
                command: .focusNavigation(.upOrRight),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            )
        ])
    }

    static func appendWindowFocusBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "focusWindowTop",
                command: .focusNavigation(.windowTop),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowBottom",
                command: .focusNavigation(.windowBottom),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowDownOrTop",
                command: .focusNavigation(.windowDownOrTop),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["wrap", "group", "tab", "cycle"]
            ),
            action(
                id: "focusWindowUpOrBottom",
                command: .focusNavigation(.windowUpOrBottom),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["wrap", "group", "tab", "cycle"]
            )
        ])
    }

    static func appendWorkspaceEdgeFocusBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "focusWindowOrWorkspaceDown",
                command: .focusNavigation(.windowOrWorkspaceDown),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowOrWorkspaceUp",
                command: .focusNavigation(.windowOrWorkspaceUp),
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            )
        ])
    }

    static func appendCenteringBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "centerColumn",
                command: .focusNavigation(.centerColumn),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "centerVisibleColumns",
                command: .focusNavigation(.centerVisibleColumns),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            )
        ])
    }

    static func appendColumnIndexFocusBindings(_ specs: inout [ActionSpec]) {
        for (idx, code) in digitCodes.enumerated() {
            specs.append(
                action(
                    id: "focusColumn.\(idx)",
                    command: .focusNavigation(.column(idx)),
                    category: .focus,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | controlKey)),
                    visibility: .advanced
                )
            )
        }
    }

    static func appendWindowIndexFocusBindings(_ specs: inout [ActionSpec]) {
        for idx in 1 ... 9 {
            specs.append(
                action(
                    id: "focusWindowInColumn.\(idx)",
                    command: .focusNavigation(.windowInColumn(idx)),
                    category: .focus,
                    binding: .unassigned,
                    visibility: .advanced
                )
            )
        }
    }
}
