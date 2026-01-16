import Foundation

enum LayoutCompatibility: String {
    case shared = "Shared"
    case niri = "Niri"
    case dwindle = "Dwindle"
}

enum HotkeyCommand: Codable, Equatable, Hashable {
    case focus(Direction)
    case focusPrevious
    case move(Direction)
    case swap(Direction)
    case moveToWorkspace(Int)
    case moveWindowToWorkspaceUp
    case moveWindowToWorkspaceDown
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case switchWorkspace(Int)
    case switchWorkspaceNext
    case switchWorkspacePrevious
    case moveToMonitor(Direction)
    case focusMonitor(Direction)
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case moveColumnToMonitor(Direction)
    case toggleFullscreen
    case toggleNativeFullscreen
    case moveColumn(Direction)
    case consumeWindow(Direction)
    case expelWindow(Direction)
    case toggleColumnTabbed

    case focusDownOrLeft
    case focusUpOrRight
    case focusColumnFirst
    case focusColumnLast
    case focusColumn(Int)
    case focusWindowTop
    case focusWindowBottom

    case cycleColumnWidthForward
    case cycleColumnWidthBackward
    case toggleColumnFullWidth

    case moveWorkspaceToMonitor(Direction)
    case moveWorkspaceToMonitorNext
    case moveWorkspaceToMonitorPrevious
    case swapWorkspaceWithMonitor(Direction)

    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resizeInDirection(Direction, Bool)
    case preselect(Direction)
    case preselectClear

    case summonWorkspace(Int)
    case workspaceBackAndForth
    case focusWorkspaceAnywhere(Int)
    case moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction)

    case openWindowFinder

    case raiseAllFloatingWindows

    case openMenuAnywhere
    case openMenuPalette

    case toggleHiddenBar
    case toggleQuakeTerminal
    case toggleWorkspaceLayout

    var displayName: String {
        switch self {
        case let .focus(dir): "Focus \(dir.displayName)"
        case .focusPrevious: "Focus Previous Window"
        case let .move(dir): "Move \(dir.displayName)"
        case let .swap(dir): "Swap \(dir.displayName)"
        case let .moveToWorkspace(idx): "Move to Workspace \(idx + 1)"
        case .moveWindowToWorkspaceUp: "Move Window to Workspace Up"
        case .moveWindowToWorkspaceDown: "Move Window to Workspace Down"
        case let .moveColumnToWorkspace(idx): "Move Column to Workspace \(idx + 1)"
        case .moveColumnToWorkspaceUp: "Move Column to Workspace Up"
        case .moveColumnToWorkspaceDown: "Move Column to Workspace Down"
        case let .switchWorkspace(idx): "Switch to Workspace \(idx + 1)"
        case .switchWorkspaceNext: "Switch to Next Workspace"
        case .switchWorkspacePrevious: "Switch to Previous Workspace"
        case let .moveToMonitor(dir): "Move to \(dir.displayName) Monitor"
        case let .focusMonitor(dir): "Focus \(dir.displayName) Monitor"
        case .focusMonitorPrevious: "Focus Previous Monitor"
        case .focusMonitorNext: "Focus Next Monitor"
        case .focusMonitorLast: "Focus Last Monitor"
        case let .moveColumnToMonitor(dir): "Move Column to \(dir.displayName) Monitor"
        case .toggleFullscreen: "Toggle Fullscreen"
        case .toggleNativeFullscreen: "Toggle Native Fullscreen"
        case let .moveColumn(dir): "Move Column \(dir.displayName)"
        case let .consumeWindow(dir): "Consume Window from \(dir.displayName)"
        case let .expelWindow(dir): "Expel Window to \(dir.displayName)"
        case .toggleColumnTabbed: "Toggle Column Tabbed"
        case .focusDownOrLeft: "Traverse Backward"
        case .focusUpOrRight: "Traverse Forward"
        case .focusColumnFirst: "Focus First Column"
        case .focusColumnLast: "Focus Last Column"
        case let .focusColumn(idx): "Focus Column \(idx + 1)"
        case .focusWindowTop: "Focus Top Window"
        case .focusWindowBottom: "Focus Bottom Window"
        case .cycleColumnWidthForward: "Cycle Column Width Forward"
        case .cycleColumnWidthBackward: "Cycle Column Width Backward"
        case .toggleColumnFullWidth: "Toggle Column Full Width"
        case let .moveWorkspaceToMonitor(dir): "Move Workspace to \(dir.displayName) Monitor"
        case .moveWorkspaceToMonitorNext: "Move Workspace to Next Monitor"
        case .moveWorkspaceToMonitorPrevious: "Move Workspace to Previous Monitor"
        case let .swapWorkspaceWithMonitor(dir): "Swap Workspace with \(dir.displayName) Monitor"
        case .balanceSizes: "Balance Sizes"
        case .moveToRoot: "Move to Root"
        case .toggleSplit: "Toggle Split"
        case .swapSplit: "Swap Split"
        case let .resizeInDirection(dir, grow): "\(grow ? "Grow" : "Shrink") \(dir.displayName)"
        case let .preselect(dir): "Preselect \(dir.displayName)"
        case .preselectClear: "Clear Preselection"
        case let .summonWorkspace(idx): "Summon Workspace \(idx + 1)"
        case .workspaceBackAndForth: "Switch to Previous Workspace"
        case let .focusWorkspaceAnywhere(idx): "Focus Workspace \(idx + 1) Anywhere"
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir): "Move Window to Workspace \(wsIdx + 1) on \(monDir.displayName) Monitor"
        case .openWindowFinder: "Open Window Finder"
        case .raiseAllFloatingWindows: "Raise All Floating Windows"
        case .openMenuAnywhere: "Open Menu Anywhere"
        case .openMenuPalette: "Open Menu Palette"
        case .toggleHiddenBar: "Toggle Hidden Bar"
        case .toggleQuakeTerminal: "Toggle Quake Terminal"
        case .toggleWorkspaceLayout: "Toggle Workspace Layout"
        }
    }

    var layoutCompatibility: LayoutCompatibility {
        switch self {
        case .moveToRoot, .toggleSplit, .swapSplit, .preselect, .preselectClear, .resizeInDirection:
            .dwindle

        case .moveColumn, .moveColumnToWorkspace, .moveColumnToWorkspaceUp, .moveColumnToWorkspaceDown,
             .moveColumnToMonitor, .toggleColumnFullWidth, .toggleColumnTabbed,
             .consumeWindow, .expelWindow,
             .focusPrevious, .focusDownOrLeft, .focusUpOrRight,
             .focusColumnFirst, .focusColumnLast, .focusColumn,
             .focusWindowTop, .focusWindowBottom,
             .move:
            .niri

        default:
            .shared
        }
    }
}
