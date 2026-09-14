// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa

final class QuakeTerminalWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    var initialFrame: NSRect?
    var isAnimating: Bool = false
    weak var tabController: QuakeTerminalTabs?

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        setup()
    }

    private func setup() {
        identifier = NSUserInterfaceItemIdentifier(rawValue: "com.omniwm.quakeTerminal")
        setAccessibilitySubrole(.floatingWindow)
        styleMask.remove(.titled)
        styleMask.insert(.nonactivatingPanel)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if isAnimating {
            super.setFrame(initialFrame ?? frameRect, display: flag)
        } else {
            super.setFrame(frameRect, display: flag)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        guard let shortcut = QuakeTerminalShortcut.decode(keyCode: keyCode, modifiers: flags) else {
            return super.performKeyEquivalent(with: event)
        }

        switch shortcut {
        case let .selectTab(index):
            tabController?.selectTab(at: index)
        case let .splitPane(direction):
            tabController?.splitActivePane(direction: direction)
        case .closeTab:
            tabController?.requestCloseActiveTab()
        case .newTab:
            tabController?.requestNewTab()
        case let .navigatePane(direction):
            tabController?.navigatePane(direction: direction)
        case .nextTab:
            tabController?.selectNextTab()
        case .previousTab:
            tabController?.selectPreviousTab()
        case .closePane:
            tabController?.closeActivePane()
        case .equalizeSplits:
            tabController?.equalizeSplits()
        }
        return true
    }
}

enum QuakeTerminalShortcut: Equatable {
    case selectTab(Int)
    case splitPane(SplitDirection)
    case closeTab
    case newTab
    case navigatePane(NavigationDirection)
    case nextTab
    case previousTab
    case closePane
    case equalizeSplits

    private static let tabIndexByDigitKeyCode: [UInt16: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8
    ]

    static func tabIndex(forDigitKeyCode keyCode: UInt16) -> Int? {
        tabIndexByDigitKeyCode[keyCode]
    }

    static func decode(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> QuakeTerminalShortcut? {
        if modifiers == .command, let tabIndex = tabIndex(forDigitKeyCode: keyCode) {
            return .selectTab(tabIndex)
        }

        return switch modifiers {
        case .command:
            switch keyCode {
            case 2: .splitPane(.horizontal)
            case 13: .closeTab
            case 17: .newTab
            default: nil
            }
        case [.command, .option]:
            switch keyCode {
            case 123: .navigatePane(.left)
            case 124: .navigatePane(.right)
            case 125: .navigatePane(.down)
            case 126: .navigatePane(.up)
            default: nil
            }
        case [.command, .shift]:
            switch keyCode {
            case 30: .nextTab
            case 33: .previousTab
            case 2: .splitPane(.vertical)
            case 13: .closePane
            case 24: .equalizeSplits
            default: nil
            }
        case .control:
            keyCode == 48 ? .nextTab : nil
        case [.control, .shift]:
            keyCode == 48 ? .previousTab : nil
        default:
            nil
        }
    }
}
