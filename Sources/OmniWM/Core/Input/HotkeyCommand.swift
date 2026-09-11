// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

struct PhysicalHotkeyTrigger: Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let isRepeat: Bool
}

struct HotkeyInvocation: Equatable, Sendable {
    let command: HotkeyCommand
    let trigger: PhysicalHotkeyTrigger?

    init(command: HotkeyCommand, trigger: PhysicalHotkeyTrigger? = nil) {
        self.command = command
        self.trigger = trigger
    }
}

enum LayoutCompatibility: String {
    case shared = "Shared"
    case niri = "Niri"
    case dwindle = "Dwindle"
}

enum HotkeyCommand: Equatable, Hashable {
    case focus(Direction)
    case move(Direction)
    case monitorFocus(IPCMonitorFocusCommand)
    case fullscreen(IPCFullscreenCommand)
    case moveColumn(Direction)

    case openCommandPalette

    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case windowState(IPCWindowStateCommand)

    case openMenuAnywhere

    case presentation(IPCPresentationCommand)
    case focusNavigation(FocusNavigationAction)
    case windowMovement(WindowMovementAction)
    case column(ColumnAction)
    case workspace(WorkspaceAction)
    case sizing(SizingAction)
    case dwindle(DwindleAction)
    case scratchpad(ScratchpadAction)

    var displayName: String {
        ActionCatalog.title(for: self) ?? String(describing: self)
    }

    var layoutCompatibility: LayoutCompatibility {
        ActionCatalog.layoutCompatibility(for: self) ?? .shared
    }
}
