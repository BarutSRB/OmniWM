import Foundation

public enum IPCAutomationLayoutCompatibility: String, Codable, CaseIterable, Equatable, Sendable {
    case shared
    case niri
    case dwindle
}

public enum IPCQuerySelectorName: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case window
    case workspace
    case display
    case focused
    case visible
    case floating
    case scratchpad
    case app
    case bundleId = "bundle-id"
    case current
    case main

    public var flag: String {
        "--\(rawValue)"
    }

    public var expectsValue: Bool {
        switch self {
        case .window, .workspace, .display, .app, .bundleId:
            true
        case .focused, .visible, .floating, .scratchpad, .current, .main:
            false
        }
    }
}

public enum IPCCommandArgumentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case direction
    case workspaceNumber = "workspace-number"
    case columnIndex = "column-index"
    case layout
    case resizeOperation = "resize-operation"

    public var usagePlaceholder: String {
        switch self {
        case .direction:
            "<left|right|up|down>"
        case .workspaceNumber, .columnIndex:
            "<number>"
        case .layout:
            "<default|niri|dwindle>"
        case .resizeOperation:
            "<grow|shrink>"
        }
    }
}

public struct IPCQuerySelectorDescriptor: Codable, Equatable, Sendable {
    public let name: IPCQuerySelectorName
    public let summary: String

    public init(name: IPCQuerySelectorName, summary: String) {
        self.name = name
        self.summary = summary
    }
}

public struct IPCQueryDescriptor: Codable, Equatable, Sendable {
    public let name: IPCQueryName
    public let summary: String
    public let selectors: [IPCQuerySelectorDescriptor]
    public let fields: [String]

    public init(
        name: IPCQueryName,
        summary: String,
        selectors: [IPCQuerySelectorDescriptor] = [],
        fields: [String] = []
    ) {
        self.name = name
        self.summary = summary
        self.selectors = selectors
        self.fields = fields
    }
}

public struct IPCCommandArgumentDescriptor: Codable, Equatable, Sendable {
    public let kind: IPCCommandArgumentKind
    public let summary: String

    public init(kind: IPCCommandArgumentKind, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

public struct IPCCommandDescriptor: Codable, Equatable, Sendable {
    public let commandWords: [String]
    public let path: String
    public let name: IPCCommandName
    public let summary: String
    public let arguments: [IPCCommandArgumentDescriptor]
    public let layoutCompatibility: IPCAutomationLayoutCompatibility

    public init(
        commandWords: [String],
        name: IPCCommandName,
        summary: String,
        arguments: [IPCCommandArgumentDescriptor] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) {
        self.commandWords = commandWords
        self.path = IPCCommandDescriptor.makePath(commandWords: commandWords, arguments: arguments)
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.layoutCompatibility = layoutCompatibility
    }

    private static func makePath(
        commandWords: [String],
        arguments: [IPCCommandArgumentDescriptor]
    ) -> String {
        let parts = ["command"] + commandWords + arguments.map(\.kind.usagePlaceholder)
        return parts.joined(separator: " ")
    }
}

public struct IPCWorkspaceActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCWorkspaceActionName
    public let summary: String
    public let arguments: [String]

    public init(
        path: String,
        name: IPCWorkspaceActionName,
        summary: String,
        arguments: [String] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}

public struct IPCWindowActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCWindowActionName
    public let summary: String
    public let arguments: [String]

    public init(
        path: String,
        name: IPCWindowActionName,
        summary: String,
        arguments: [String] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}

public struct IPCRuleActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCRuleActionName
    public let summary: String
    public let arguments: [String]
    public let options: [IPCRuleActionOptionDescriptor]

    public init(
        path: String,
        name: IPCRuleActionName,
        summary: String,
        arguments: [String] = [],
        options: [IPCRuleActionOptionDescriptor] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.options = options
    }
}

public struct IPCRuleActionOptionDescriptor: Codable, Equatable, Sendable {
    public let flag: String
    public let summary: String
    public let valuePlaceholder: String?
    public let exclusiveGroup: String?

    public init(
        flag: String,
        summary: String,
        valuePlaceholder: String? = nil,
        exclusiveGroup: String? = nil
    ) {
        self.flag = flag
        self.summary = summary
        self.valuePlaceholder = valuePlaceholder
        self.exclusiveGroup = exclusiveGroup
    }
}

public struct IPCSubscriptionDescriptor: Codable, Equatable, Sendable {
    public let channel: IPCSubscriptionChannel
    public let summary: String
    public let resultKind: IPCResultKind

    public init(channel: IPCSubscriptionChannel, summary: String, resultKind: IPCResultKind) {
        self.channel = channel
        self.summary = summary
        self.resultKind = resultKind
    }
}

public enum IPCAutomationManifest {
    private static let directionArgument = IPCCommandArgumentDescriptor(
        kind: .direction,
        summary: "Direction argument."
    )
    private static let workspaceNumberArgument = IPCCommandArgumentDescriptor(
        kind: .workspaceNumber,
        summary: "One-based workspace number."
    )
    private static let columnIndexArgument = IPCCommandArgumentDescriptor(
        kind: .columnIndex,
        summary: "One-based column index."
    )
    private static let layoutArgument = IPCCommandArgumentDescriptor(
        kind: .layout,
        summary: "Workspace layout selection."
    )
    private static let resizeOperationArgument = IPCCommandArgumentDescriptor(
        kind: .resizeOperation,
        summary: "Resize direction mode."
    )

    private static func command(
        _ commandWords: [String],
        name: IPCCommandName,
        summary: String,
        arguments: [IPCCommandArgumentDescriptor] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) -> IPCCommandDescriptor {
        IPCCommandDescriptor(
            commandWords: commandWords,
            name: name,
            summary: summary,
            arguments: arguments,
            layoutCompatibility: layoutCompatibility
        )
    }

    public static let windowFieldCatalog: [String] = [
        "id",
        "pid",
        "workspace",
        "display",
        "app",
        "title",
        "frame",
        "mode",
        "layout-reason",
        "manual-override",
        "is-focused",
        "is-visible",
        "is-scratchpad",
        "hidden-reason",
    ]

    public static let workspaceFieldCatalog: [String] = [
        "id",
        "raw-name",
        "display-name",
        "number",
        "layout",
        "display",
        "is-focused",
        "is-visible",
        "is-current",
        "window-counts",
        "focused-window-id",
    ]

    public static let displayFieldCatalog: [String] = [
        "id",
        "name",
        "is-main",
        "is-current",
        "frame",
        "visible-frame",
        "has-notch",
        "orientation",
        "active-workspace",
    ]

    public static let queryDescriptors: [IPCQueryDescriptor] = [
        IPCQueryDescriptor(
            name: .workspaceBar,
            summary: "Return the workspace bar projection for every monitor."
        ),
        IPCQueryDescriptor(
            name: .activeWorkspace,
            summary: "Return the current interaction monitor and active workspace snapshot."
        ),
        IPCQueryDescriptor(
            name: .focusedMonitor,
            summary: "Return the current interaction monitor and its active workspace snapshot."
        ),
        IPCQueryDescriptor(
            name: .apps,
            summary: "Return the managed app summary used by OmniWM surfaces."
        ),
        IPCQueryDescriptor(
            name: .focusedWindow,
            summary: "Return the focused managed window snapshot."
        ),
        IPCQueryDescriptor(
            name: .windows,
            summary: "Return managed OmniWM windows only.",
            selectors: [
                .init(name: .window, summary: "Filter by a session-scoped opaque window id."),
                .init(name: .workspace, summary: "Filter by workspace raw name, display name, or id."),
                .init(name: .display, summary: "Filter by display name or display id."),
                .init(name: .focused, summary: "Only include the focused managed window."),
                .init(name: .visible, summary: "Only include windows on visible workspaces that are not hidden."),
                .init(name: .floating, summary: "Only include floating managed windows."),
                .init(name: .scratchpad, summary: "Only include the scratchpad window."),
                .init(name: .app, summary: "Filter by application display name."),
                .init(name: .bundleId, summary: "Filter by application bundle identifier."),
            ],
            fields: windowFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .workspaces,
            summary: "Return configured workspaces with live occupancy and monitor assignment.",
            selectors: [
                .init(name: .workspace, summary: "Filter by workspace raw name, display name, or id."),
                .init(name: .display, summary: "Filter by active monitor name or display id."),
                .init(name: .current, summary: "Only include the interaction monitor's active workspace."),
                .init(name: .visible, summary: "Only include visible workspaces."),
                .init(name: .focused, summary: "Only include the workspace containing the focused managed window."),
            ],
            fields: workspaceFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .displays,
            summary: "Return connected displays with live geometry and active workspace state.",
            selectors: [
                .init(name: .display, summary: "Filter by display name or display id."),
                .init(name: .main, summary: "Only include the main display."),
                .init(name: .current, summary: "Only include the interaction display."),
            ],
            fields: displayFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .rules,
            summary: "Return persisted user window rules with normalized public fields."
        ),
        IPCQueryDescriptor(
            name: .ruleActions,
            summary: "Return the public persisted-rule action registry."
        ),
        IPCQueryDescriptor(
            name: .queries,
            summary: "Return the public automation query registry."
        ),
        IPCQueryDescriptor(
            name: .commands,
            summary: "Return the public automation command registry."
        ),
        IPCQueryDescriptor(
            name: .subscriptions,
            summary: "Return the public subscription registry."
        ),
        IPCQueryDescriptor(
            name: .capabilities,
            summary: "Return protocol, command, query, selector, and subscription capabilities."
        ),
        IPCQueryDescriptor(
            name: .focusedWindowDecision,
            summary: "Return the focused window rule/debug decision snapshot."
        ),
    ]

    public static let commandDescriptors: [IPCCommandDescriptor] = [
        command(["focus"], name: .focus, summary: "Focus a neighboring window.", arguments: [directionArgument]),
        command(["focus", "previous"], name: .focusPrevious, summary: "Focus the previously focused window.", layoutCompatibility: .niri),
        command(["focus", "down-or-left"], name: .focusDownOrLeft, summary: "Traverse backward through the active Niri workspace.", layoutCompatibility: .niri),
        command(["focus", "up-or-right"], name: .focusUpOrRight, summary: "Traverse forward through the active Niri workspace.", layoutCompatibility: .niri),
        command(["focus-column"], name: .focusColumn, summary: "Focus a Niri column by one-based index.", arguments: [columnIndexArgument], layoutCompatibility: .niri),
        command(["focus-column", "first"], name: .focusColumnFirst, summary: "Focus the first Niri column.", layoutCompatibility: .niri),
        command(["focus-column", "last"], name: .focusColumnLast, summary: "Focus the last Niri column.", layoutCompatibility: .niri),
        command(["move"], name: .move, summary: "Move the focused window in the given direction.", arguments: [directionArgument]),
        command(["switch-workspace"], name: .switchWorkspace, summary: "Switch to a workspace on the interaction monitor by one-based index.", arguments: [workspaceNumberArgument]),
        command(["switch-workspace", "next"], name: .switchWorkspaceNext, summary: "Switch to the next workspace on the current monitor."),
        command(["switch-workspace", "prev"], name: .switchWorkspacePrevious, summary: "Switch to the previous workspace on the current monitor."),
        command(["switch-workspace", "back-and-forth"], name: .switchWorkspaceBackAndForth, summary: "Switch to the previously active workspace on the current monitor."),
        command(["switch-workspace", "anywhere"], name: .switchWorkspaceAnywhere, summary: "Focus a workspace by one-based index across all monitors.", arguments: [workspaceNumberArgument]),
        command(["move-to-workspace"], name: .moveToWorkspace, summary: "Move the focused window to a workspace by one-based index.", arguments: [workspaceNumberArgument]),
        command(["move-to-workspace", "up"], name: .moveToWorkspaceUp, summary: "Move the focused window to the adjacent workspace above."),
        command(["move-to-workspace", "down"], name: .moveToWorkspaceDown, summary: "Move the focused window to the adjacent workspace below."),
        command(["move-to-workspace", "on-monitor"], name: .moveToWorkspaceOnMonitor, summary: "Move the focused window to a workspace on an adjacent monitor.", arguments: [workspaceNumberArgument, directionArgument]),
        command(["focus-monitor", "prev"], name: .focusMonitorPrevious, summary: "Move interaction focus to the previous monitor."),
        command(["focus-monitor", "next"], name: .focusMonitorNext, summary: "Move interaction focus to the next monitor."),
        command(["focus-monitor", "last"], name: .focusMonitorLast, summary: "Move interaction focus back to the previous monitor."),
        command(["move-column"], name: .moveColumn, summary: "Move the focused Niri column in the given direction.", arguments: [directionArgument], layoutCompatibility: .niri),
        command(["move-column-to-workspace"], name: .moveColumnToWorkspace, summary: "Move the focused Niri column to a workspace by one-based index.", arguments: [workspaceNumberArgument], layoutCompatibility: .niri),
        command(["move-column-to-workspace", "up"], name: .moveColumnToWorkspaceUp, summary: "Move the focused Niri column to the adjacent workspace above.", layoutCompatibility: .niri),
        command(["move-column-to-workspace", "down"], name: .moveColumnToWorkspaceDown, summary: "Move the focused Niri column to the adjacent workspace below.", layoutCompatibility: .niri),
        command(["toggle-column-tabbed"], name: .toggleColumnTabbed, summary: "Toggle tabbed mode for the focused Niri column.", layoutCompatibility: .niri),
        command(["cycle-column-width", "forward"], name: .cycleColumnWidthForward, summary: "Cycle column width presets forward."),
        command(["cycle-column-width", "backward"], name: .cycleColumnWidthBackward, summary: "Cycle column width presets backward."),
        command(["toggle-column-full-width"], name: .toggleColumnFullWidth, summary: "Toggle full-width mode for the focused Niri column.", layoutCompatibility: .niri),
        command(["swap-workspace-with-monitor"], name: .swapWorkspaceWithMonitor, summary: "Swap the active workspace with the active workspace on an adjacent monitor.", arguments: [directionArgument]),
        command(["balance-sizes"], name: .balanceSizes, summary: "Balance layout sizes in the active workspace."),
        command(["move-to-root"], name: .moveToRoot, summary: "Move the selected Dwindle window to the root split.", layoutCompatibility: .dwindle),
        command(["toggle-split"], name: .toggleSplit, summary: "Toggle the active Dwindle split orientation.", layoutCompatibility: .dwindle),
        command(["swap-split"], name: .swapSplit, summary: "Swap the active Dwindle split.", layoutCompatibility: .dwindle),
        command(["resize"], name: .resize, summary: "Resize the selected Dwindle window.", arguments: [directionArgument, resizeOperationArgument], layoutCompatibility: .dwindle),
        command(["preselect"], name: .preselect, summary: "Set the Dwindle preselection direction.", arguments: [directionArgument], layoutCompatibility: .dwindle),
        command(["preselect", "clear"], name: .preselectClear, summary: "Clear the Dwindle preselection.", layoutCompatibility: .dwindle),
        command(["open-command-palette"], name: .openCommandPalette, summary: "Toggle the command palette."),
        command(["raise-all-floating-windows"], name: .raiseAllFloatingWindows, summary: "Raise all visible floating windows."),
        command(["toggle-focused-window-floating"], name: .toggleFocusedWindowFloating, summary: "Toggle the focused managed window between tiled and floating."),
        command(["scratchpad", "assign"], name: .scratchpadAssign, summary: "Assign the focused managed window to the scratchpad."),
        command(["scratchpad", "toggle"], name: .scratchpadToggle, summary: "Show or hide the scratchpad window."),
        command(["open-menu-anywhere"], name: .openMenuAnywhere, summary: "Open the menu surface anywhere."),
        command(["toggle-workspace-bar"], name: .toggleWorkspaceBar, summary: "Toggle runtime workspace bar visibility."),
        command(["toggle-hidden-bar"], name: .toggleHiddenBar, summary: "Toggle the hidden bar surface."),
        command(["toggle-quake-terminal"], name: .toggleQuakeTerminal, summary: "Toggle the configured Quake terminal."),
        command(["toggle-workspace-layout"], name: .toggleWorkspaceLayout, summary: "Toggle the current workspace between Niri and Dwindle."),
        command(["set-workspace-layout"], name: .setWorkspaceLayout, summary: "Set the current workspace layout explicitly.", arguments: [layoutArgument]),
        command(["toggle-fullscreen"], name: .toggleFullscreen, summary: "Toggle OmniWM-managed fullscreen."),
        command(["toggle-native-fullscreen"], name: .toggleNativeFullscreen, summary: "Toggle native macOS fullscreen."),
        command(["toggle-overview"], name: .toggleOverview, summary: "Toggle the overview surface."),
    ]

    public static let workspaceActionDescriptors: [IPCWorkspaceActionDescriptor] = [
        .init(
            path: "workspace focus-name <name>",
            name: .focusName,
            summary: "Focus a workspace by raw name or configured display name.",
            arguments: ["name"]
        ),
    ]

    public static let windowActionDescriptors: [IPCWindowActionDescriptor] = [
        .init(
            path: "window focus <opaque-id>",
            name: .focus,
            summary: "Focus a managed window by session-scoped opaque id.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window navigate <opaque-id>",
            name: .navigate,
            summary: "Navigate to a managed window by session-scoped opaque id.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window summon-right <opaque-id>",
            name: .summonRight,
            summary: "Summon a managed window to the right of the focused window.",
            arguments: ["opaque-id"]
        ),
    ]

    public static let ruleActionDescriptors: [IPCRuleActionDescriptor] = [
        .init(
            path: "rule add --bundle-id <bundle-id> [options]",
            name: .add,
            summary: "Append a new persisted user rule.",
            arguments: ["bundle-id"]
        ),
        .init(
            path: "rule replace <rule-id> --bundle-id <bundle-id> [options]",
            name: .replace,
            summary: "Replace a persisted user rule in place.",
            arguments: ["rule-id", "bundle-id"]
        ),
        .init(
            path: "rule remove <rule-id>",
            name: .remove,
            summary: "Remove a persisted user rule.",
            arguments: ["rule-id"]
        ),
        .init(
            path: "rule move <rule-id> <position>",
            name: .move,
            summary: "Move a persisted user rule to a one-based position.",
            arguments: ["rule-id", "position"]
        ),
        .init(
            path: "rule apply [--focused|--window <opaque-id>|--pid <pid>]",
            name: .apply,
            summary: "Reapply the current rule set to a focused window, explicit window id, or process.",
            options: [
                .init(
                    flag: "--focused",
                    summary: "Reapply rules to the currently focused automation target.",
                    exclusiveGroup: "target"
                ),
                .init(
                    flag: "--window",
                    summary: "Reapply rules to a specific managed window by opaque id.",
                    valuePlaceholder: "<opaque-id>",
                    exclusiveGroup: "target"
                ),
                .init(
                    flag: "--pid",
                    summary: "Reapply rules to all managed windows for a process id.",
                    valuePlaceholder: "<pid>",
                    exclusiveGroup: "target"
                ),
            ]
        ),
    ]

    public static let subscriptionDescriptors: [IPCSubscriptionDescriptor] = [
        .init(channel: .focus, summary: "Focused window snapshot updates.", resultKind: .focusedWindow),
        .init(
            channel: .workspaceBar,
            summary: "Workspace bar projection updates.",
            resultKind: .workspaceBar
        ),
        .init(
            channel: .activeWorkspace,
            summary: "Interaction monitor and active workspace updates.",
            resultKind: .activeWorkspace
        ),
        .init(
            channel: .focusedMonitor,
            summary: "Focused monitor updates for the current interaction target.",
            resultKind: .focusedMonitor
        ),
        .init(
            channel: .windowsChanged,
            summary: "Managed window inventory updates.",
            resultKind: .windows
        ),
        .init(
            channel: .displayChanged,
            summary: "Display state updates.",
            resultKind: .displays
        ),
        .init(
            channel: .layoutChanged,
            summary: "Workspace layout updates.",
            resultKind: .workspaces
        ),
    ]

    public static func queryDescriptor(for name: IPCQueryName) -> IPCQueryDescriptor? {
        queryDescriptors.first { $0.name == name }
    }

    public static func commandDescriptor(for name: IPCCommandName) -> IPCCommandDescriptor? {
        commandDescriptors.first { $0.name == name }
    }

    public static func ruleActionDescriptor(for name: IPCRuleActionName) -> IPCRuleActionDescriptor? {
        ruleActionDescriptors.first { $0.name == name }
    }

    public static func commandDescriptors(matching commandWords: [String]) -> [IPCCommandDescriptor] {
        commandDescriptors
            .sorted {
                if $0.commandWords.count != $1.commandWords.count {
                    return $0.commandWords.count > $1.commandWords.count
                }
                return $0.path < $1.path
            }
            .filter { descriptor in
                guard commandWords.count >= descriptor.commandWords.count else { return false }
                return Array(commandWords.prefix(descriptor.commandWords.count)) == descriptor.commandWords
            }
    }

    public static func subscriptionDescriptor(for channel: IPCSubscriptionChannel) -> IPCSubscriptionDescriptor? {
        subscriptionDescriptors.first { $0.channel == channel }
    }

    public static func expandedChannels(for request: IPCSubscribeRequest) -> [IPCSubscriptionChannel] {
        let channels = request.allChannels ? IPCSubscriptionChannel.allCases : request.channels
        var seen: Set<IPCSubscriptionChannel> = []
        return channels.filter { seen.insert($0).inserted }
    }
}
