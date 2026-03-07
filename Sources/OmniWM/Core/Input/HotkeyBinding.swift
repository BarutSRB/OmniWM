import Carbon
import Foundation

struct KeyBinding: Equatable, Hashable {
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

    var humanReadableString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.humanReadableString(keyCode: keyCode, modifiers: modifiers)
    }

    func conflicts(with other: KeyBinding) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let binding = KeySymbolMapper.fromHumanReadable(string) {
            self = binding
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
    }

    func encode(to encoder: Encoder) throws {
        if isUnassigned || KeySymbolMapper.keyName(keyCode) != "?" {
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        }
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
             .switchWorkspace, .switchWorkspaceNext, .switchWorkspacePrevious, .workspaceBackAndForth,
             .focusWorkspaceAnywhere:
            .workspace
        case .focus, .focusColumn, .focusColumnFirst, .focusColumnLast,
             .focusDownOrLeft, .focusPrevious, .focusUpOrRight, .focusWindowBottom, .focusWindowTop,
             .openMenuAnywhere, .openMenuPalette, .openWindowFinder, .toggleHiddenBar, .toggleQuakeTerminal,
             .toggleOverview:
            .focus
        case .move, .swap:
            .move
        case .focusMonitor, .focusMonitorLast, .focusMonitorNext, .focusMonitorPrevious, .moveColumnToMonitor,
             .moveToMonitor, .moveWorkspaceToMonitor, .moveWorkspaceToMonitorNext, .moveWorkspaceToMonitorPrevious,
             .swapWorkspaceWithMonitor, .moveWindowToWorkspaceOnMonitor:
            .monitor
        case .balanceSizes, .moveToRoot, .raiseAllFloatingWindows, .toggleFullscreen, .toggleNativeFullscreen,
             .toggleSplit, .swapSplit, .resizeInDirection, .preselect, .preselectClear, .toggleWorkspaceLayout:
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
