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

    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit

    case summonWorkspace(Int)

    case openWindowFinder

    case raiseAllFloatingWindows

    case openMenuAnywhere
    case openMenuPalette

    case toggleHiddenBar

    var id: String {
        switch self {
        case let .focus(dir): "focus.\(dir.rawValue)"
        case .focusPrevious: "focusPrevious"
        case let .move(dir): "move.\(dir.rawValue)"
        case let .swap(dir): "swap.\(dir.rawValue)"
        case let .moveToWorkspace(idx): "moveToWorkspace.\(idx)"
        case .moveWindowToWorkspaceUp: "moveWindowToWorkspaceUp"
        case .moveWindowToWorkspaceDown: "moveWindowToWorkspaceDown"
        case let .moveColumnToWorkspace(idx): "moveColumnToWorkspace.\(idx)"
        case .moveColumnToWorkspaceUp: "moveColumnToWorkspaceUp"
        case .moveColumnToWorkspaceDown: "moveColumnToWorkspaceDown"
        case let .switchWorkspace(idx): "switchWorkspace.\(idx)"
        case let .moveToMonitor(dir): "moveToMonitor.\(dir.rawValue)"
        case let .focusMonitor(dir): "focusMonitor.\(dir.rawValue)"
        case .focusMonitorPrevious: "focusMonitorPrevious"
        case .focusMonitorNext: "focusMonitorNext"
        case .focusMonitorLast: "focusMonitorLast"
        case let .moveColumnToMonitor(dir): "moveColumnToMonitor.\(dir.rawValue)"
        case .toggleFullscreen: "toggleFullscreen"
        case .toggleNativeFullscreen: "toggleNativeFullscreen"
        case let .moveColumn(dir): "moveColumn.\(dir.rawValue)"
        case let .consumeWindow(dir): "consumeWindow.\(dir.rawValue)"
        case let .expelWindow(dir): "expelWindow.\(dir.rawValue)"
        case .toggleColumnTabbed: "toggleColumnTabbed"
        case .focusDownOrLeft: "focusDownOrLeft"
        case .focusUpOrRight: "focusUpOrRight"
        case .focusColumnFirst: "focusColumnFirst"
        case .focusColumnLast: "focusColumnLast"
        case let .focusColumn(idx): "focusColumn.\(idx)"
        case .focusWindowTop: "focusWindowTop"
        case .focusWindowBottom: "focusWindowBottom"
        case .cycleColumnWidthForward: "cycleColumnWidthForward"
        case .cycleColumnWidthBackward: "cycleColumnWidthBackward"
        case .toggleColumnFullWidth: "toggleColumnFullWidth"
        case let .moveWorkspaceToMonitor(dir): "moveWorkspaceToMonitor.\(dir.rawValue)"
        case .balanceSizes: "balanceSizes"
        case .moveToRoot: "moveToRoot"
        case .toggleSplit: "toggleSplit"
        case .swapSplit: "swapSplit"
        case let .summonWorkspace(idx): "summonWorkspace.\(idx)"
        case .openWindowFinder: "openWindowFinder"
        case .raiseAllFloatingWindows: "raiseAllFloatingWindows"
        case .openMenuAnywhere: "openMenuAnywhere"
        case .openMenuPalette: "openMenuPalette"
        case .toggleHiddenBar: "toggleHiddenBar"
        }
    }

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
        case .balanceSizes: "Balance Sizes"
        case .moveToRoot: "Move to Root"
        case .toggleSplit: "Toggle Split"
        case .swapSplit: "Swap Split"
        case let .summonWorkspace(idx): "Summon Workspace \(idx + 1)"
        case .openWindowFinder: "Open Window Finder"
        case .raiseAllFloatingWindows: "Raise All Floating Windows"
        case .openMenuAnywhere: "Open Menu Anywhere"
        case .openMenuPalette: "Open Menu Palette"
        case .toggleHiddenBar: "Toggle Hidden Bar"
        }
    }

    var layoutCompatibility: LayoutCompatibility {
        switch self {
        case .moveToRoot, .toggleSplit, .swapSplit:
            .dwindle

        case .moveColumn, .moveColumnToWorkspace, .moveColumnToWorkspaceUp, .moveColumnToWorkspaceDown,
             .moveColumnToMonitor, .toggleColumnFullWidth, .toggleColumnTabbed,
             .consumeWindow, .expelWindow,
             .focusPrevious, .focusDownOrLeft, .focusUpOrRight,
             .focusColumnFirst, .focusColumnLast, .focusColumn,
             .focusWindowTop, .focusWindowBottom:
            .niri

        default:
            .shared
        }
    }
}
