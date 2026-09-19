// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum IssueHotkeyContext {
    static func resolve(text: String, bindings: [HotkeyBinding]) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for token in chordTokens(in: text) {
            guard let parsed = parseChord(token), seen.insert(token.lowercased()).inserted else { continue }
            let command = bindings
                .first { $0.binding.chordBinding?.conflicts(with: parsed) == true }?
                .command.displayName
            lines.append(
                command.map { "- \"\(token)\" is bound to: \($0)" }
                    ?? "- \"\(token)\" is not bound to any command"
            )
        }
        return lines.isEmpty ? "" : (["KNOWN SHORTCUTS:"] + lines).joined(separator: "\n")
    }

    private static func chordTokens(in text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:()\"'")) }
            .filter { $0.contains("+") }
    }

    private static func parseChord(_ token: String) -> KeyBinding? {
        let parts = token.split(separator: "+").map { synonym(String($0)) }
        guard parts.count >= 2,
              let binding = KeySymbolMapper.fromHumanReadable(parts.joined(separator: "+")),
              !binding.isUnassigned,
              binding.modifiers != 0
        else { return nil }
        return binding
    }

    private static func synonym(_ part: String) -> String {
        switch part.lowercased() {
        case "alt",
             "opt",
             "option": "Option"
        case "cmd",
             "command",
             "win",
             "super",
             "meta": "Command"
        case "ctrl",
             "control": "Control"
        case "shift": "Shift"
        case "enter",
             "return": "Return"
        case "esc",
             "escape": "Escape"
        case "del",
             "delete": "Delete"
        case "right",
             "rightarrow",
             "→": "Right Arrow"
        case "left",
             "leftarrow",
             "←": "Left Arrow"
        case "up",
             "uparrow",
             "↑": "Up Arrow"
        case "down",
             "downarrow",
             "↓": "Down Arrow"
        case "space",
             "spacebar": "Space"
        case "tab": "Tab"
        default: part
        }
    }
}
