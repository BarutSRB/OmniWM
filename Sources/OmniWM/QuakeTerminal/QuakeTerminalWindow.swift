// SPDX-License-Identifier: GPL-2.0-only
import Cocoa

final class QuakeTerminalWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var initialFrame: NSRect?
    var isAnimating: Bool = false
    weak var tabController: QuakeTerminalController?

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

        if flags == .command {
            switch keyCode {
            case 17:
                tabController?.requestNewTab()
                return true
            case 13:
                tabController?.requestCloseActiveTab()
                return true
            case 2:
                tabController?.splitActivePane(direction: .horizontal)
                return true
            case 18...25:
                tabController?.selectTab(at: Int(keyCode) - 18)
                return true
            case 26:
                tabController?.selectTab(at: Int(keyCode) - 18)
                return true
            default:
                break
            }
        }

        if flags == [.command, .option] {
            switch keyCode {
            case 123:
                tabController?.navigatePane(direction: .left)
                return true
            case 124:
                tabController?.navigatePane(direction: .right)
                return true
            case 125:
                tabController?.navigatePane(direction: .down)
                return true
            case 126:
                tabController?.navigatePane(direction: .up)
                return true
            default:
                break
            }
        }

        if flags == [.command, .shift] {
            switch keyCode {
            case 30:
                tabController?.selectNextTab()
                return true
            case 33:
                tabController?.selectPreviousTab()
                return true
            case 2:
                tabController?.splitActivePane(direction: .vertical)
                return true
            case 13:
                tabController?.closeActivePane()
                return true
            case 24:
                tabController?.equalizeSplits()
                return true
            default:
                break
            }
        }

        if flags == .control && keyCode == 48 {
            tabController?.selectNextTab()
            return true
        }

        if flags == [.control, .shift] && keyCode == 48 {
            tabController?.selectPreviousTab()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
