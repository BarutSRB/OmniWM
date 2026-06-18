import Carbon
import Foundation

enum KeySymbolMapper {
    private struct KeyDescriptor {
        let compact: String
        let name: String
    }

    private static func descriptor(_ compact: String, _ name: String? = nil) -> KeyDescriptor {
        KeyDescriptor(compact: compact, name: name ?? compact)
    }

    private static let keyDescriptors: [UInt32: KeyDescriptor] = [
        UInt32(kVK_ANSI_A): descriptor("A"),
        UInt32(kVK_ANSI_B): descriptor("B"),
        UInt32(kVK_ANSI_C): descriptor("C"),
        UInt32(kVK_ANSI_D): descriptor("D"),
        UInt32(kVK_ANSI_E): descriptor("E"),
        UInt32(kVK_ANSI_F): descriptor("F"),
        UInt32(kVK_ANSI_G): descriptor("G"),
        UInt32(kVK_ANSI_H): descriptor("H"),
        UInt32(kVK_ANSI_I): descriptor("I"),
        UInt32(kVK_ANSI_J): descriptor("J"),
        UInt32(kVK_ANSI_K): descriptor("K"),
        UInt32(kVK_ANSI_L): descriptor("L"),
        UInt32(kVK_ANSI_M): descriptor("M"),
        UInt32(kVK_ANSI_N): descriptor("N"),
        UInt32(kVK_ANSI_O): descriptor("O"),
        UInt32(kVK_ANSI_P): descriptor("P"),
        UInt32(kVK_ANSI_Q): descriptor("Q"),
        UInt32(kVK_ANSI_R): descriptor("R"),
        UInt32(kVK_ANSI_S): descriptor("S"),
        UInt32(kVK_ANSI_T): descriptor("T"),
        UInt32(kVK_ANSI_U): descriptor("U"),
        UInt32(kVK_ANSI_V): descriptor("V"),
        UInt32(kVK_ANSI_W): descriptor("W"),
        UInt32(kVK_ANSI_X): descriptor("X"),
        UInt32(kVK_ANSI_Y): descriptor("Y"),
        UInt32(kVK_ANSI_Z): descriptor("Z"),
        UInt32(kVK_ANSI_0): descriptor("0"),
        UInt32(kVK_ANSI_1): descriptor("1"),
        UInt32(kVK_ANSI_2): descriptor("2"),
        UInt32(kVK_ANSI_3): descriptor("3"),
        UInt32(kVK_ANSI_4): descriptor("4"),
        UInt32(kVK_ANSI_5): descriptor("5"),
        UInt32(kVK_ANSI_6): descriptor("6"),
        UInt32(kVK_ANSI_7): descriptor("7"),
        UInt32(kVK_ANSI_8): descriptor("8"),
        UInt32(kVK_ANSI_9): descriptor("9"),
        UInt32(kVK_Return): descriptor("↩", "Return"),
        UInt32(kVK_Tab): descriptor("⇥", "Tab"),
        UInt32(kVK_Space): descriptor("Space"),
        UInt32(kVK_Delete): descriptor("⌫", "Delete"),
        UInt32(kVK_Escape): descriptor("⎋", "Escape"),
        UInt32(kVK_LeftArrow): descriptor("←", "Left Arrow"),
        UInt32(kVK_RightArrow): descriptor("→", "Right Arrow"),
        UInt32(kVK_UpArrow): descriptor("↑", "Up Arrow"),
        UInt32(kVK_DownArrow): descriptor("↓", "Down Arrow"),
        UInt32(kVK_Home): descriptor("↖", "Home"),
        UInt32(kVK_End): descriptor("↘", "End"),
        UInt32(kVK_PageUp): descriptor("⇞", "Page Up"),
        UInt32(kVK_PageDown): descriptor("⇟", "Page Down"),
        UInt32(kVK_ForwardDelete): descriptor("⌦", "Forward Delete"),
        UInt32(kVK_F1): descriptor("F1"),
        UInt32(kVK_F2): descriptor("F2"),
        UInt32(kVK_F3): descriptor("F3"),
        UInt32(kVK_F4): descriptor("F4"),
        UInt32(kVK_F5): descriptor("F5"),
        UInt32(kVK_F6): descriptor("F6"),
        UInt32(kVK_F7): descriptor("F7"),
        UInt32(kVK_F8): descriptor("F8"),
        UInt32(kVK_F9): descriptor("F9"),
        UInt32(kVK_F10): descriptor("F10"),
        UInt32(kVK_F11): descriptor("F11"),
        UInt32(kVK_F12): descriptor("F12"),
        UInt32(kVK_F13): descriptor("F13"),
        UInt32(kVK_F14): descriptor("F14"),
        UInt32(kVK_F15): descriptor("F15"),
        UInt32(kVK_F16): descriptor("F16"),
        UInt32(kVK_F17): descriptor("F17"),
        UInt32(kVK_F18): descriptor("F18"),
        UInt32(kVK_F19): descriptor("F19"),
        UInt32(kVK_F20): descriptor("F20"),
        UInt32(kVK_CapsLock): descriptor("CapsLock", "Caps Lock"),
        UInt32(kVK_Shift): descriptor("LeftShift", "Left Shift"),
        UInt32(kVK_RightShift): descriptor("RightShift", "Right Shift"),
        UInt32(kVK_Control): descriptor("LeftControl", "Left Control"),
        UInt32(kVK_RightControl): descriptor("RightControl", "Right Control"),
        UInt32(kVK_Option): descriptor("LeftOption", "Left Option"),
        UInt32(kVK_RightOption): descriptor("RightOption", "Right Option"),
        UInt32(kVK_Command): descriptor("LeftCommand", "Left Command"),
        UInt32(kVK_RightCommand): descriptor("RightCommand", "Right Command"),
        UInt32(kVK_ANSI_Equal): descriptor("=", "Equal"),
        UInt32(kVK_ANSI_Minus): descriptor("-", "Minus"),
        UInt32(kVK_ANSI_LeftBracket): descriptor("[", "Left Bracket"),
        UInt32(kVK_ANSI_RightBracket): descriptor("]", "Right Bracket"),
        UInt32(kVK_ANSI_Semicolon): descriptor(";", "Semicolon"),
        UInt32(kVK_ANSI_Quote): descriptor("'", "Quote"),
        UInt32(kVK_ANSI_Comma): descriptor(",", "Comma"),
        UInt32(kVK_ANSI_Period): descriptor(".", "Period"),
        UInt32(kVK_ANSI_Slash): descriptor("/", "Slash"),
        UInt32(kVK_ANSI_Backslash): descriptor("\\", "Backslash"),
        UInt32(kVK_ANSI_Grave): descriptor("`", "Grave"),
        UInt32(kVK_ANSI_Keypad0): descriptor("KP0", "Keypad 0"),
        UInt32(kVK_ANSI_Keypad1): descriptor("KP1", "Keypad 1"),
        UInt32(kVK_ANSI_Keypad2): descriptor("KP2", "Keypad 2"),
        UInt32(kVK_ANSI_Keypad3): descriptor("KP3", "Keypad 3"),
        UInt32(kVK_ANSI_Keypad4): descriptor("KP4", "Keypad 4"),
        UInt32(kVK_ANSI_Keypad5): descriptor("KP5", "Keypad 5"),
        UInt32(kVK_ANSI_Keypad6): descriptor("KP6", "Keypad 6"),
        UInt32(kVK_ANSI_Keypad7): descriptor("KP7", "Keypad 7"),
        UInt32(kVK_ANSI_Keypad8): descriptor("KP8", "Keypad 8"),
        UInt32(kVK_ANSI_Keypad9): descriptor("KP9", "Keypad 9"),
        UInt32(kVK_ANSI_KeypadDecimal): descriptor("KP.", "Keypad Decimal"),
        UInt32(kVK_ANSI_KeypadMultiply): descriptor("KP*", "Keypad Multiply"),
        UInt32(kVK_ANSI_KeypadPlus): descriptor("KP+", "Keypad Plus"),
        UInt32(kVK_ANSI_KeypadClear): descriptor("KPClear", "Keypad Clear"),
        UInt32(kVK_ANSI_KeypadDivide): descriptor("KP/", "Keypad Divide"),
        UInt32(kVK_ANSI_KeypadEnter): descriptor("KPEnter", "Keypad Enter"),
        UInt32(kVK_ANSI_KeypadMinus): descriptor("KP-", "Keypad Minus"),
        UInt32(kVK_ANSI_KeypadEquals): descriptor("KP=", "Keypad Equals")
    ]

    static let hyperModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    static func modifierSymbols(_ modifiers: UInt32) -> String {
        if modifiers == hyperModifiers { return "Hyper+" }
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    static func keySymbol(_ keyCode: UInt32) -> String {
        keyDescriptors[keyCode]?.compact ?? "?"
    }

    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierSymbols(modifiers) + keySymbol(keyCode)
    }

    static func modifierNames(_ modifiers: UInt32) -> String {
        if modifiers == hyperModifiers { return "Hyper" }
        var names: [String] = []
        if modifiers & UInt32(controlKey) != 0 { names.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { names.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { names.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { names.append("Command") }
        return names.joined(separator: "+")
    }

    static func keyName(_ keyCode: UInt32) -> String {
        keyDescriptors[keyCode]?.name ?? "?"
    }

    static func humanReadableString(keyCode: UInt32, modifiers: UInt32) -> String {
        let mods = modifierNames(modifiers)
        let key = keyName(keyCode)
        return mods.isEmpty ? key : mods + "+" + key
    }

    static let nameToKeyCode: [String: UInt32] = {
        var names = Dictionary(uniqueKeysWithValues: keyDescriptors.map { ($0.value.name, $0.key) })
        for (keyCode, descriptor) in keyDescriptors {
            names[descriptor.compact] = keyCode
        }
        return names
    }()

    private static let normalizedNameToKeyCode: [String: UInt32] = {
        Dictionary(nameToKeyCode.map { (normalizeName($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }()

    static func keyCode(named name: String) -> UInt32? {
        nameToKeyCode[name] ?? normalizedNameToKeyCode[normalizeName(name)]
    }

    static let nameToModifier: [String: UInt32] = [
        "Control": UInt32(controlKey),
        "Option": UInt32(optionKey),
        "Shift": UInt32(shiftKey),
        "Command": UInt32(cmdKey),
        "Hyper": hyperModifiers
    ]

    private static let normalizedNameToModifier: [String: UInt32] = {
        Dictionary(uniqueKeysWithValues: nameToModifier.map { (normalizeName($0.key), $0.value) })
    }()

    static func fromHumanReadable(_ string: String) -> KeyBinding? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveCompare("Unassigned") == .orderedSame { return .unassigned }
        let parts = trimmed.components(separatedBy: "+").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let keyPart = parts.last, let keyCode = keyCode(named: keyPart) else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            guard let flag = nameToModifier[part] ?? normalizedNameToModifier[normalizeName(part)] else { return nil }
            modifiers |= flag
        }
        return KeyBinding(keyCode: keyCode, modifiers: modifiers)
    }

    private static func normalizeName(_ name: String) -> String {
        name
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}
