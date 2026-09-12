// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
final class CommandPalettePanel {
    private(set) var panel: NSPanel?
    private let motionPolicy: MotionPolicy
    private let ownedWindowRegistry: OwnedWindowRegistry

    init(motionPolicy: MotionPolicy, ownedWindowRegistry: OwnedWindowRegistry) {
        self.motionPolicy = motionPolicy
        self.ownedWindowRegistry = ownedWindowRegistry
    }

    func create(controller: CommandPaletteController) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.delegate = controller
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace]

        let hostingView = NSHostingView(rootView: CommandPaletteView(
            controller: controller,
            motionPolicy: motionPolicy
        ))
        panel.contentView = hostingView

        ownedWindowRegistry.register(panel)
        self.panel = panel
    }

    func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else { return }

        let panelWidth: CGFloat = 620
        let panelHeight: CGFloat = 430
        let x = screen.frame.midX - panelWidth / 2
        let y = screen.frame.midY - panelHeight / 2 + 80
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.isEditable {
            return textField
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    func focusSearchField() {
        guard let contentView = panel?.contentView,
              let textField = findTextField(in: contentView)
        else {
            return
        }
        panel?.makeFirstResponder(textField)
    }
}
