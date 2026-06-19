// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

enum MouseResizeModifierKey: String, CaseIterable, Codable {
    case option
    case control
    case command
    case shift
    case controlOption
    case optionCommand
    case optionShift
    case controlCommand
    case controlShift
    case commandShift
    case controlOptionCommand
    case controlOptionShift
    case optionCommandShift
    case controlCommandShift
    case controlOptionCommandShift

    var displayName: String {
        switch self {
        case .option: "Option"
        case .control: "Control"
        case .command: "Command"
        case .shift: "Shift"
        case .controlOption: "Control+Option"
        case .optionCommand: "Option+Command"
        case .optionShift: "Option+Shift"
        case .controlCommand: "Control+Command"
        case .controlShift: "Control+Shift"
        case .commandShift: "Command+Shift"
        case .controlOptionCommand: "Control+Option+Command"
        case .controlOptionShift: "Control+Option+Shift"
        case .optionCommandShift: "Option+Command+Shift"
        case .controlCommandShift: "Control+Command+Shift"
        case .controlOptionCommandShift: "Control+Option+Command+Shift"
        }
    }
}
