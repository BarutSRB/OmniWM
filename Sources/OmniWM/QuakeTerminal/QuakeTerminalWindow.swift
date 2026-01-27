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
            case 17: // Cmd+T
                tabController?.requestNewTab()
                return true
            case 13: // Cmd+W
                tabController?.requestCloseActiveTab()
                return true
            case 2: // Cmd+D
                tabController?.splitActivePane(direction: .horizontal)
                return true
            case 18...25: // Cmd+1 through Cmd+8 (keycodes 18-25)
                tabController?.selectTab(at: Int(keyCode) - 18)
                return true
            case 26: // Cmd+9
                tabController?.selectTab(at: Int(keyCode) - 18)
                return true
            default:
                break
            }
        }

        if flags == [.command, .option] {
            switch keyCode {
            case 123: // Cmd+Option+Left
                tabController?.navigatePane(direction: .left)
                return true
            case 124: // Cmd+Option+Right
                tabController?.navigatePane(direction: .right)
                return true
            case 125: // Cmd+Option+Down
                tabController?.navigatePane(direction: .down)
                return true
            case 126: // Cmd+Option+Up
                tabController?.navigatePane(direction: .up)
                return true
            default:
                break
            }
        }

        if flags == [.command, .shift] {
            switch keyCode {
            case 30: // Cmd+Shift+]
                tabController?.selectNextTab()
                return true
            case 33: // Cmd+Shift+[
                tabController?.selectPreviousTab()
                return true
            case 2: // Cmd+Shift+D
                tabController?.splitActivePane(direction: .vertical)
                return true
            case 13: // Cmd+Shift+W
                tabController?.closeActivePane()
                return true
            case 24: // Cmd+Shift+= (equalize)
                tabController?.equalizeSplits()
                return true
            default:
                break
            }
        }

        if flags == .control && keyCode == 48 { // Ctrl+Tab
            tabController?.selectNextTab()
            return true
        }

        if flags == [.control, .shift] && keyCode == 48 { // Ctrl+Shift+Tab
            tabController?.selectPreviousTab()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
