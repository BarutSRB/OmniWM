// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum SidedHyperBindingDetector {
    static func issues(currentBindings: [HotkeyBinding]) -> [DiagnosticsIssue] {
        currentBindings.compactMap { binding in
            guard case let .chord(chord) = binding.binding,
                  !chord.isUnassigned,
                  !chord.sidedModifiers.isEmpty,
                  chord.modifiers == KeySymbolMapper.hyperModifiers
            else { return nil }
            let side = chord.sidedModifiers.left != 0 ? "Left" : "Right"
            return DiagnosticsIssue(kind: .hotkeySidedHyper(
                actionID: binding.id,
                command: binding.command.displayName,
                chord: chord.displayString,
                side: side
            ))
        }
    }
}
