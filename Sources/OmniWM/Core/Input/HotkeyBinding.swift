import Carbon
import Foundation

struct KeyBinding: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let unassigned = KeyBinding(keyCode: UInt32.max, modifiers: 0)

    var isUnassigned: Bool {
        keyCode == UInt32.max && modifiers == 0
    }

    var displayString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    func conflicts(with other: KeyBinding) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
}

struct HotkeyBinding: Codable, Identifiable {
    let id: String
    let command: HotkeyCommand
    var binding: KeyBinding

    var category: HotkeyCategory {
        switch command {
        case .moveColumnToWorkspace, .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp, .moveToWorkspace,
             .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp, .summonWorkspace,
             .switchWorkspace:
            .workspace
        case .focus, .focusColumn, .focusColumnFirst, .focusColumnLast,
             .focusDownOrLeft, .focusPrevious, .focusUpOrRight, .focusWindowBottom, .focusWindowTop,
             .openWindowFinder, .openMenuAnywhere, .openMenuPalette:
            .focus
        case .move, .swap:
            .move
        case .focusMonitor, .focusMonitorLast, .focusMonitorNext, .focusMonitorPrevious, .moveColumnToMonitor,
             .moveToMonitor, .moveWorkspaceToMonitor:
            .monitor
        case .balanceSizes, .raiseAllFloatingWindows, .toggleFullscreen, .toggleNativeFullscreen:
            .layout
        case .consumeWindow, .cycleColumnWidthBackward, .cycleColumnWidthForward, .expelWindow,
             .moveColumn, .toggleColumnFullWidth, .toggleColumnTabbed:
            .column
        }
    }
}

enum HotkeyCategory: String, CaseIterable {
    case workspace = "Workspace"
    case focus = "Focus"
    case move = "Move Window"
    case monitor = "Monitor"
    case layout = "Layout"
    case column = "Column"
}
