// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

private final class CommandPaletteActionBox: @unchecked Sendable {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }
}

@MainActor
struct CommandPaletteEnvironment {
    var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var runningApplication: (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
    var ownBundleIdentifier: () -> String? = { Bundle.main.bundleIdentifier }
    var fetchMenuItems: (pid_t) -> [MenuItemModel] = { MenuAnywhereFetcher().fetchMenuItemsSync(for: $0) }
    var activateOmniWM: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var navigateToWindow: (WMController, WindowHandle) -> Void = { controller, handle in
        controller.navigateToCommandPaletteWindow(handle)
    }

    var summonWindowRight: (WMController, WindowHandle, WindowToken, WorkspaceDescriptor.ID) -> Void = {
        controller,
        handle,
        anchorToken,
        anchorWorkspaceId in
        controller.summonCommandPaletteWindowRight(
            handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }

    var scheduleMenuAction: (@escaping () -> Void) -> Void = { action in
        let box = CommandPaletteActionBox(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            box.action()
        }
    }

    var performMenuAction: (AXUIElement) -> Void = { element in
        performAXAction(element, kAXPressAction as CFString, noteKey: "performPressFailed")
    }

    var clipboardItems: (WMController) -> [ClipboardPaletteItem] = { controller in
        controller.clipboardPaletteItems()
    }

    var isClipboardHistoryEnabled: (WMController) -> Bool = { controller in
        controller.settings.clipboard.historyEnabled
    }

    var setClipboardHistoryEnabled: (WMController, Bool) -> Void = { controller, isEnabled in
        controller.setClipboardHistoryEnabled(isEnabled)
    }

    var copyClipboardItem: (WMController, UUID) async -> Bool = { controller, id in
        await controller.copyClipboardItem(id: id)
    }

    var deleteClipboardItem: (WMController, UUID) async -> [ClipboardPaletteItem] = { controller, id in
        await controller.deleteClipboardItem(id: id)
    }

    var clearClipboardHistory: (WMController) async -> [ClipboardPaletteItem] = { controller in
        await controller.clearClipboardHistory()
    }

    var confirmClearClipboardHistory: () -> Bool = {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear Clipboard History?"
        alert.informativeText = "This removes OmniWM's saved clipboard history. The current system clipboard is unchanged."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var scheduleClipboardPaste: (@escaping () -> Void) -> Void = { action in
        let box = CommandPaletteActionBox(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            box.action()
        }
    }

    var postPasteShortcut: () -> Void = {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    var isSecureInputActive: () -> Bool = {
        IsSecureEventInputEnabled()
    }

    var isAccessibilityTrusted: () -> Bool = {
        AXIsProcessTrusted()
    }

    var isLockScreenActive: (WMController) -> Bool = { controller in
        controller.isLockScreenActive
    }

    var focusedWindowID: (pid_t) -> CGWindowID? = { pid in
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return getWindowId(from: unsafeDowncast(windowValue, to: AXUIElement.self))
    }
}
