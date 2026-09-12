// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation

enum SystemHyperTrigger: Equatable, Hashable {
    case none
    case key(UInt32)
    case mouseButton(Int64)

    static let `default`: SystemHyperTrigger = .none

    static let selectableKeyCodes: [UInt32] = [
        UInt32(kVK_CapsLock),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Command), UInt32(kVK_RightCommand)
    ]

    static let selectableMouseButtons: [Int64] = [3, 4, 5]

    var isEnabled: Bool {
        self != .none
    }

    var isSupported: Bool {
        switch self {
        case .none:
            return true
        case let .key(keyCode):
            return Self.selectableKeyCodes.contains(keyCode)
        case let .mouseButton(button):
            return Self.selectableMouseButtons.contains(button)
        }
    }

    var displayString: String {
        switch self {
        case .none:
            return "None"
        case let .key(keyCode):
            return KeySymbolMapper.keySymbol(keyCode)
        case let .mouseButton(button):
            return "Mouse \(button)"
        }
    }

    var humanReadableString: String {
        switch self {
        case .none:
            return "None"
        case let .key(keyCode):
            return KeySymbolMapper.keyName(keyCode)
        case let .mouseButton(button):
            return "MouseButton\(button)"
        }
    }

    var keyboardKeyCode: UInt32? {
        guard case let .key(keyCode) = self else { return nil }
        return keyCode
    }

    var mouseButtonNumber: Int64? {
        guard case let .mouseButton(button) = self else { return nil }
        return button
    }

    var requiresCapsLockRemap: Bool {
        keyboardKeyCode == UInt32(kVK_CapsLock)
    }

    static func fromHumanReadable(_ string: String) -> SystemHyperTrigger? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.localizedCaseInsensitiveCompare("None") == .orderedSame {
            return SystemHyperTrigger.none
        }

        let compactMouse = trimmed.replacingOccurrences(of: " ", with: "")
        if compactMouse.lowercased().hasPrefix("mousebutton"),
           let button = Int64(compactMouse.dropFirst("MouseButton".count))
        {
            let trigger = SystemHyperTrigger.mouseButton(button)
            return trigger.isSupported ? trigger : nil
        }

        if let keyCode = KeySymbolMapper.keyCode(named: trimmed) {
            let trigger = SystemHyperTrigger.key(keyCode)
            return trigger.isSupported ? trigger : nil
        }

        return nil
    }
}

extension SystemHyperTrigger: Codable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let trigger = SystemHyperTrigger.fromHumanReadable(string)
        {
            self = trigger
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Invalid system Hyper trigger")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(humanReadableString)
    }
}
