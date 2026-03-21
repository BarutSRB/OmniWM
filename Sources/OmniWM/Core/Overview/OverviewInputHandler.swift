import AppKit
import Carbon
import Foundation

@MainActor
final class OverviewInputHandler {
    enum KeyAction: Equatable {
        case clearSearchOrDismiss
        case activateSelection
        case navigate(Direction)
        case deleteBackward
        case appendToSearch(String)
        case consume
    }

    struct KeyHandlingResult: Equatable {
        let action: KeyAction
        let shouldConsume: Bool
    }

    private enum KeyCode {
        static let escape = UInt16(kVK_Escape)
        static let returnKey = UInt16(kVK_Return)
        static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
        static let leftArrow = UInt16(kVK_LeftArrow)
        static let rightArrow = UInt16(kVK_RightArrow)
        static let downArrow = UInt16(kVK_DownArrow)
        static let upArrow = UInt16(kVK_UpArrow)
        static let tab = UInt16(kVK_Tab)
        static let delete = UInt16(kVK_Delete)
    }

    private weak var controller: OverviewController?

    var searchQuery: String = ""

    init(controller: OverviewController) {
        self.controller = controller
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        guard controller.state.isOpen else { return false }

        let result = Self.keyHandlingResult(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            searchQuery: searchQuery
        )
        guard result.shouldConsume else { return false }

        switch result.action {
        case .clearSearchOrDismiss:
            if !searchQuery.isEmpty {
                searchQuery = ""
                controller.updateSearchQuery("")
            } else {
                controller.dismiss(reason: .cancel)
            }
        case .activateSelection:
            controller.activateSelectedWindow()
        case let .navigate(direction):
            controller.navigateSelection(direction)
        case .deleteBackward:
            if !searchQuery.isEmpty {
                searchQuery = String(searchQuery.dropLast())
                controller.updateSearchQuery(searchQuery)
            }
        case let .appendToSearch(text):
            searchQuery += text
            controller.updateSearchQuery(searchQuery)
        case .consume:
            break
        }
        return true
    }

    static func keyHandlingResult(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        searchQuery _: String
    ) -> KeyHandlingResult {
        let relevantModifiers = modifierFlags.intersection([.shift, .command, .control, .option])

        switch keyCode {
        case KeyCode.escape:
            return .init(action: .clearSearchOrDismiss, shouldConsume: true)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .activateSelection, shouldConsume: true)
        case KeyCode.leftArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.left), shouldConsume: true)
        case KeyCode.rightArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.right), shouldConsume: true)
        case KeyCode.downArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.down), shouldConsume: true)
        case KeyCode.upArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.up), shouldConsume: true)
        case KeyCode.tab:
            guard relevantModifiers.isEmpty || relevantModifiers == .shift else { break }
            let direction: Direction = relevantModifiers.contains(.shift) ? .left : .right
            return .init(action: .navigate(direction), shouldConsume: true)
        case KeyCode.delete:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .deleteBackward, shouldConsume: true)
        default:
            if relevantModifiers.intersection([.command, .control, .option]).isEmpty,
               let charactersIgnoringModifiers,
               let character = charactersIgnoringModifiers.first,
               charactersIgnoringModifiers.count == 1,
               (character.isLetter || character.isNumber || character == " ")
            {
                return .init(action: .appendToSearch(String(character)), shouldConsume: true)
            }
        }

        return .init(action: .consume, shouldConsume: true)
    }

    func handleMouseMoved(at point: CGPoint, in layout: inout OverviewLayout) {
        let isCloseButton = layout.isCloseButtonAt(point: point)
        if let window = layout.windowAt(point: point) {
            layout.setHovered(handle: window.handle, closeButtonHovered: isCloseButton)
        } else {
            layout.setHovered(handle: nil)
        }
    }

    func handleMouseDown(at point: CGPoint, in layout: OverviewLayout) {
        guard let controller else { return }

        if layout.isCloseButtonAt(point: point) {
            if let window = layout.windowAt(point: point) {
                controller.closeWindow(window.handle)
            }
            return
        }

        if let window = layout.windowAt(point: point) {
            controller.selectAndActivateWindow(window.handle)
            return
        }

        controller.dismiss(reason: .cancel)
    }

    func handleScroll(delta: CGFloat) {
        controller?.adjustScrollOffset(by: delta)
    }

    func reset() {
        searchQuery = ""
    }

    func matchingWindows(in layout: OverviewLayout) -> [OverviewWindowItem] {
        layout.allWindows.filter(\.matchesSearch)
    }

    func selectFirstMatch(in layout: inout OverviewLayout) {
        let matching = matchingWindows(in: layout)
        if let first = matching.first {
            layout.setSelected(handle: first.handle)
        } else {
            layout.setSelected(handle: nil)
        }
    }

    func autoSelectOnSearch(in layout: inout OverviewLayout) {
        guard !searchQuery.isEmpty else { return }

        let matching = matchingWindows(in: layout)

        if layout.selectedWindow() == nil || !(layout.selectedWindow()?.matchesSearch ?? false) {
            if let first = matching.first {
                layout.setSelected(handle: first.handle)
            }
        }
    }
}
