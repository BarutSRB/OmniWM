// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

struct CLISubscriptionArguments {
    let request: IPCSubscribeRequest
    let reconnect: Bool
    let execArguments: [String]?
}

struct CLISubscriptionParser {
    private var channels: [IPCSubscriptionChannel] = []
    private var allChannels = false
    private var sendInitial = true
    private var reconnect = false
    private var sawChannelList = false
    private var execArguments: [String]?

    static func parse(arguments: [String], allowExec: Bool) throws -> CLISubscriptionArguments {
        var parser = Self()
        try parser.read(arguments: arguments, allowExec: allowExec)
        guard parser.allChannels || !parser.channels.isEmpty else {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        if allowExec, parser.execArguments == nil {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        return CLISubscriptionArguments(
            request: IPCSubscribeRequest(
                channels: parser.channels,
                allChannels: parser.allChannels,
                sendInitial: parser.sendInitial
            ),
            reconnect: parser.reconnect,
            execArguments: parser.execArguments
        )
    }

    private mutating func read(arguments: [String], allowExec: Bool) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            if allowExec, argument == "--exec" {
                let remaining = Array(arguments.dropFirst(index + 1))
                guard !remaining.isEmpty, execArguments == nil else {
                    throw CLIParseError.usage(CLIParser.usageText)
                }
                execArguments = remaining
                index = arguments.count
                break
            }

            switch argument {
            case "--all":
                guard !allChannels else { throw CLIParseError.usage(CLIParser.usageText) }
                allChannels = true
                index += 1
            case "--no-send-initial":
                guard sendInitial else { throw CLIParseError.usage(CLIParser.usageText) }
                sendInitial = false
                index += 1
            case "--reconnect":
                guard !reconnect else { throw CLIParseError.usage(CLIParser.usageText) }
                reconnect = true
                index += 1
            default:
                guard !argument.hasPrefix("--"), !sawChannelList else {
                    throw CLIParseError.usage(CLIParser.usageText)
                }
                channels = try Self.parseChannels(argument)
                sawChannelList = true
                index += 1
            }
        }
    }

    private static func parseChannels(_ argument: String) throws -> [IPCSubscriptionChannel] {
        let parsedChannels = argument
            .split(separator: ",")
            .map(String.init)
        guard !parsedChannels.isEmpty else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        let resolvedChannels = parsedChannels.compactMap(IPCSubscriptionChannel.init(rawValue:))
        guard resolvedChannels.count == parsedChannels.count else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return resolvedChannels
    }
}
