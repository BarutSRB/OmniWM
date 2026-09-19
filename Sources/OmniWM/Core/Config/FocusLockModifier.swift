// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon

enum FocusLockModifier: String, CaseIterable, Codable {
    case off
    case option
    case leftOption
    case rightOption
    case command
    case leftCommand
    case rightCommand
    case control
    case leftControl
    case rightControl
    case shift
    case leftShift
    case rightShift

    var displayName: String {
        switch self {
        case .off: "Off"
        case .option: "Option"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .command: "Command"
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        case .control: "Control"
        case .leftControl: "Left Control"
        case .rightControl: "Right Control"
        case .shift: "Shift"
        case .leftShift: "Left Shift"
        case .rightShift: "Right Shift"
        }
    }

    func isHeld(inRawFlags rawFlags: UInt64) -> Bool {
        guard let mask = modifierMask, rawFlags & mask.independent != 0 else { return false }
        switch side {
        case .either: return true
        case .left: return rawFlags & mask.left != 0 && rawFlags & mask.right == 0
        case .right: return rawFlags & mask.right != 0 && rawFlags & mask.left == 0
        }
    }

    private var side: ModifierSide {
        switch self {
        case .leftOption,
             .leftCommand,
             .leftControl,
             .leftShift:
            .left
        case .rightOption,
             .rightCommand,
             .rightControl,
             .rightShift:
            .right
        default:
            .either
        }
    }

    private var carbonKey: UInt32? {
        switch self {
        case .off: nil
        case .option,
             .leftOption,
             .rightOption:
            UInt32(optionKey)
        case .command,
             .leftCommand,
             .rightCommand:
            UInt32(cmdKey)
        case .control,
             .leftControl,
             .rightControl:
            UInt32(controlKey)
        case .shift,
             .leftShift,
             .rightShift:
            UInt32(shiftKey)
        }
    }

    private var modifierMask: ModifierFlagMask? {
        guard let carbonKey else { return nil }
        return ModifierFlagMask.all.first { $0.carbon == carbonKey }
    }
}
