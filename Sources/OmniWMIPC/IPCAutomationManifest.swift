// SPDX-License-Identifier: GPL-2.0-only
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
    public let actionWords: [String]
    public let path: String
    public let name: IPCWorkspaceActionName
    public let summary: String
    public let arguments: [String]

    public init(
        actionWords: [String],
        name: IPCWorkspaceActionName,
        summary: String,
        arguments: [String] = []
    ) {
        self.actionWords = actionWords
        path = Self.makePath(actionWords: actionWords, arguments: arguments)
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }

    private static func makePath(actionWords: [String], arguments: [String]) -> String {
        let parts = ["workspace"] + actionWords + arguments.map { "<\($0)>" }
        return parts.joined(separator: " ")
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
    private struct Payload: Codable {
        let windowFieldCatalog: [String]
        let workspaceFieldCatalog: [String]
        let displayFieldCatalog: [String]
        let queryDescriptors: [IPCQueryDescriptor]
        let commandDescriptors: [IPCCommandDescriptor]
        let workspaceActionDescriptors: [IPCWorkspaceActionDescriptor]
        let windowActionDescriptors: [IPCWindowActionDescriptor]
        let ruleActionDescriptors: [IPCRuleActionDescriptor]
        let subscriptionDescriptors: [IPCSubscriptionDescriptor]
    }

    private static let payload: Payload = loadPayload()

    public static var windowFieldCatalog: [String] { payload.windowFieldCatalog }
    public static var workspaceFieldCatalog: [String] { payload.workspaceFieldCatalog }
    public static var displayFieldCatalog: [String] { payload.displayFieldCatalog }
    public static var queryDescriptors: [IPCQueryDescriptor] { payload.queryDescriptors }
    public static var commandDescriptors: [IPCCommandDescriptor] { payload.commandDescriptors }
    public static var workspaceActionDescriptors: [IPCWorkspaceActionDescriptor] {
        payload.workspaceActionDescriptors
    }
    public static var windowActionDescriptors: [IPCWindowActionDescriptor] {
        payload.windowActionDescriptors
    }
    public static var ruleActionDescriptors: [IPCRuleActionDescriptor] {
        payload.ruleActionDescriptors
    }
    public static var subscriptionDescriptors: [IPCSubscriptionDescriptor] {
        payload.subscriptionDescriptors
    }

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

    public static func workspaceActionDescriptors(matching actionWords: [String]) -> [IPCWorkspaceActionDescriptor] {
        workspaceActionDescriptors
            .sorted { $0.path < $1.path }
            .filter { descriptor in
                guard actionWords.count >= descriptor.actionWords.count else { return false }
                return Array(actionWords.prefix(descriptor.actionWords.count)) == descriptor.actionWords
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

    private static func loadPayload() -> Payload {
        guard let json = ZigIPCSupport.automationManifestJSON(),
              let data = json.data(using: .utf8)
        else {
            preconditionFailure("Failed to load IPC automation manifest JSON from Zig")
        }

        do {
            return try IPCWire.makeDecoder().decode(Payload.self, from: data)
        } catch {
            preconditionFailure("Failed to decode IPC automation manifest JSON: \(error)")
        }
    }
}
