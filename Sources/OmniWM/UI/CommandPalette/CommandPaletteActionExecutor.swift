// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
final class CommandPaletteActionExecutor {
    private let environment: CommandPaletteEnvironment
    private let focusSession: CommandPaletteFocusSession

    init(environment: CommandPaletteEnvironment, focusSession: CommandPaletteFocusSession) {
        self.environment = environment
        self.focusSession = focusSession
    }

    enum Action {
        case navigateWindow(WMController, WindowHandle)
        case summonWindowRight(WMController, WindowHandle, CommandPaletteSummonAnchor)
        case pressMenu(CommandPaletteFocusTarget, AXUIElement)
        case copyClipboard(WMController, UUID)
        case pasteClipboard(WMController, UUID, CommandPaletteClipboardPasteTarget?)
    }

    func perform(_ action: Action) {
        switch action {
        case let .navigateWindow(wmController, handle):
            environment.navigateToWindow(wmController, handle)
        case let .summonWindowRight(wmController, handle, summonAnchor):
            environment.summonWindowRight(
                wmController,
                handle,
                summonAnchor.token,
                summonAnchor.workspaceId
            )
        case let .pressMenu(target, element):
            _ = focusSession.focus(target: target)
            environment.scheduleMenuAction { [environment] in
                environment.performMenuAction(element)
            }
        case let .copyClipboard(wmController, id):
            Task { @MainActor [environment] in
                _ = await environment.copyClipboardItem(wmController, id)
            }
        case let .pasteClipboard(wmController, id, target):
            Task { @MainActor [weak self, environment] in
                guard await environment.copyClipboardItem(wmController, id),
                      let self,
                      let target,
                      !environment.isLockScreenActive(wmController),
                      environment.isAccessibilityTrusted(),
                      !environment.isSecureInputActive(),
                      self.focusSession.focus(target: target.focusTarget)
                else {
                    return
                }
                environment.scheduleClipboardPaste {
                    guard environment.isAccessibilityTrusted(),
                          !environment.isSecureInputActive(),
                          environment.frontmostApplication()?.processIdentifier == target.focusTarget.app
                          .processIdentifier
                    else {
                        return
                    }
                    if let expectedWindowId = target.expectedWindowId,
                       environment.focusedWindowID(target.focusTarget.app.processIdentifier) != expectedWindowId
                    {
                        return
                    }
                    environment.postPasteShortcut()
                }
            }
        }
    }
}
