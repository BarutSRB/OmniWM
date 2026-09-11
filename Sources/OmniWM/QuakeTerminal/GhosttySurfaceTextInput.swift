// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import GhosttyKit

@MainActor
final class GhosttySurfaceTextInput {
    private weak var view: GhosttySurfaceView?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?

    init(view: GhosttySurfaceView) {
        self.view = view
    }

    private var ghosttySurface: ghostty_surface_t? {
        view?.ghosttySurface
    }

    func keyDown(with event: NSEvent) {
        guard let surface = ghosttySurface else {
            view?.interpretKeyEvents([event])
            return
        }

        let translationEvent = event.quakeTranslationEvent(surface: surface)
        let markedTextBefore = markedText.length > 0
        let keyboardLayoutBefore = markedTextBefore ? nil : QuakeGhosttyInputBridge.keyboardLayoutID
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        lastPerformKeyEvent = nil

        view?.interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardLayoutBefore != QuakeGhosttyInputBridge.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text
                )
            }
            return
        }

        _ = keyAction(
            action,
            event: event,
            translationEvent: translationEvent,
            text: translationEvent.quakeGhosttyCharacters,
            composing: markedText.length > 0 || markedTextBefore
        )
    }

    func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    func flagsChanged(with event: NSEvent) {
        if hasMarkedText() { return }
        guard let action = QuakeGhosttyInputBridge.modifierAction(for: event) else { return }
        _ = keyAction(action, event: event)
    }

    func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard view?.window?.firstResponder === view, view?.window?.isKeyWindow == true else { return false }

        if keyEventIsBinding(event) {
            keyDown(with: event)
            return true
        }

        guard let equivalent = QuakeGhosttyInputBridge.keyEquivalentCharacters(
            for: event,
            lastPerformKeyEvent: &lastPerformKeyEvent
        ) else { return false }

        guard let translatedEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else {
            return false
        }

        keyDown(with: translatedEvent)
        return true
    }

    func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp
        {
            NSApp.sendEvent(current)
            return
        }

        switch selector {
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            performBindingAction("scroll_to_top")
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            performBindingAction("scroll_to_bottom")
        default:
            break
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = QuakeGhosttyInputBridge.committedText(from: string) else { return }

        unmarkText()

        if var accumulated = keyTextAccumulator {
            accumulated.append(text)
            keyTextAccumulator = accumulated
            return
        }

        sendSurfaceText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: value)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            return
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface = ghosttySurface else { return false }

        var keyEvent = event.quakeGhosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        if let text,
           !text.isEmpty,
           let codepoint = text.utf8.first,
           codepoint >= 0x20
        {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }

        return ghostty_surface_key(surface, keyEvent)
    }

    private func keyEventIsBinding(_ event: NSEvent) -> Bool {
        guard let surface = ghosttySurface else { return false }

        var keyEvent = event.quakeGhosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        let text = event.characters ?? ""
        return text.withCString { ptr in
            var bindingFlags = ghostty_binding_flags_e(0)
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &bindingFlags)
        }
    }

    private func sendSurfaceText(_ text: String) {
        guard let surface = ghosttySurface else { return }

        let length = text.utf8.count
        guard length > 0 else { return }

        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(length))
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        if markedText.length > 0 {
            let text = markedText.string

            guard let surface = ghosttySurface else { return }
            let length = text.utf8.count
            guard length > 0 else { return }

            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(length))
            }
        } else if clearIfNeeded {
            guard let surface = ghosttySurface else { return }
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private func performBindingAction(_ action: String) {
        guard let surface = ghosttySurface else { return }
        let length = action.utf8.count
        guard length > 0 else { return }

        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(length))
        }
    }
}
