// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Carbon
import GhosttyKit

enum QuakeGhosttyInputBridge {
    static var keyboardLayoutID: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIDPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceID = unsafeBitCast(sourceIDPointer, to: CFString.self)
            return sourceID as String
        }

        return nil
    }

    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(rawValue: mods)
    }

    static func modifierAction(for event: NSEvent) -> ghostty_input_action_e? {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return nil
        }

        let mods = ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        return action
    }

    static func committedText(from value: Any) -> String? {
        switch value {
        case let value as NSAttributedString:
            value.string
        case let value as String:
            value
        default:
            nil
        }
    }
}

extension NSEvent {
    func quakeTranslationModifiers(surface: ghostty_surface_t) -> NSEvent.ModifierFlags {
        let translatedGhostty = QuakeGhosttyInputBridge.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                QuakeGhosttyInputBridge.ghosttyMods(modifierFlags)
            )
        )

        var translated = modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translatedGhostty.contains(flag) {
                translated.insert(flag)
            } else {
                translated.remove(flag)
            }
        }

        return translated
    }

    func quakeTranslationEvent(surface: ghostty_surface_t) -> NSEvent {
        let translatedModifiers = quakeTranslationModifiers(surface: surface)
        guard translatedModifiers != modifierFlags else { return self }

        return NSEvent.keyEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: translatedModifiers,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: characters(byApplyingModifiers: translatedModifiers) ?? "",
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
            isARepeat: isARepeat,
            keyCode: keyCode
        ) ?? self
    }

    func quakeGhosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = QuakeGhosttyInputBridge.ghosttyMods(modifierFlags)
        keyEvent.consumed_mods = QuakeGhosttyInputBridge.ghosttyMods(
            (translationMods ?? modifierFlags).subtracting([.control, .command])
        )
        keyEvent.unshifted_codepoint = 0

        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }

        return keyEvent
    }

    var quakeGhosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
