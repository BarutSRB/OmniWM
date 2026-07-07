// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum WorkspaceBarRevealModifier: String, CaseIterable, Codable {
    case off
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
        case .off: "Off"
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

    func isHeld(inRawFlags rawFlags: UInt64) -> Bool {
        let required = cgEventFlags.rawValue
        return required != 0 && rawFlags & required == required
    }

    private var cgEventFlags: CGEventFlags {
        switch self {
        case .off: []
        case .option: .maskAlternate
        case .control: .maskControl
        case .command: .maskCommand
        case .shift: .maskShift
        case .controlOption: [.maskControl, .maskAlternate]
        case .optionCommand: [.maskAlternate, .maskCommand]
        case .optionShift: [.maskAlternate, .maskShift]
        case .controlCommand: [.maskControl, .maskCommand]
        case .controlShift: [.maskControl, .maskShift]
        case .commandShift: [.maskCommand, .maskShift]
        case .controlOptionCommand: [.maskControl, .maskAlternate, .maskCommand]
        case .controlOptionShift: [.maskControl, .maskAlternate, .maskShift]
        case .optionCommandShift: [.maskAlternate, .maskCommand, .maskShift]
        case .controlCommandShift: [.maskControl, .maskCommand, .maskShift]
        case .controlOptionCommandShift: [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        }
    }
}
