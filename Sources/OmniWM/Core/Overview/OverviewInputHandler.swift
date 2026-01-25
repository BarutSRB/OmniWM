import AppKit
import Foundation

@MainActor
final class OverviewInputHandler {
    private weak var controller: OverviewController?

    var searchQuery: String = ""

    init(controller: OverviewController) {
        self.controller = controller
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        guard controller.state.isOpen else { return false }

        switch event.keyCode {
        case 53:
            if !searchQuery.isEmpty {
                searchQuery = ""
                controller.updateSearchQuery("")
            } else {
                controller.dismiss()
            }
            return true

        case 36, 76:
            controller.activateSelectedWindow()
            return true

        case 123:
            controller.navigateSelection(.left)
            return true

        case 124:
            controller.navigateSelection(.right)
            return true

        case 125:
            controller.navigateSelection(.down)
            return true

        case 126:
            controller.navigateSelection(.up)
            return true

        case 48:
            let direction: Direction = event.modifierFlags.contains(.shift) ? .left : .right
            controller.navigateSelection(direction)
            return true

        case 51:
            if !searchQuery.isEmpty {
                searchQuery = String(searchQuery.dropLast())
                controller.updateSearchQuery(searchQuery)
            }
            return true

        default:
            if let characters = event.charactersIgnoringModifiers,
               !characters.isEmpty,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            {
                let char = characters.first!
                if char.isLetter || char.isNumber || char == " " {
                    searchQuery += String(char)
                    controller.updateSearchQuery(searchQuery)
                    return true
                }
            }
        }
        return false
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

        controller.dismiss()
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
