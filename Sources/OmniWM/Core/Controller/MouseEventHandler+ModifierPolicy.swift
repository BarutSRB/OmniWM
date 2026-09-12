// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    nonisolated static let relevantModifierFlags: CGEventFlags = [
        .maskAlternate,
        .maskShift,
        .maskControl,
        .maskCommand
    ]

    nonisolated static func mouseMoveMode(
        modifiers: CGEventFlags,
        required: CGEventFlags?
    ) -> MouseMoveMode? {
        guard let required, !required.isEmpty else { return nil }
        let relevantModifiers = modifiers.intersection(Self.relevantModifierFlags)
        if relevantModifiers == required {
            return .swap
        }
        if relevantModifiers == required.union(.maskShift) {
            return .insert
        }
        return nil
    }

    nonisolated static func modifierFlagsMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifiers.intersection(Self.relevantModifierFlags) == required
    }
}
