// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

struct CLIQueryArguments {
    private let descriptor: IPCQueryDescriptor
    private var selectors = IPCQuerySelectors()
    private var fields: [String] = []
    private var seenSelectors: Set<IPCQuerySelectorName> = []
    private var sawFields = false

    static func parse(arguments: [String]) throws -> IPCQueryRequest {
        guard let rawName = arguments.first else {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        guard let queryName = IPCQueryName(rawValue: rawName),
              let descriptor = IPCAutomationManifest.queryDescriptor(for: queryName)
        else {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        var parsed = Self(descriptor: descriptor)
        try parsed.read(arguments: arguments)
        return IPCQueryRequest(name: queryName, selectors: parsed.selectors, fields: parsed.fields)
    }

    private mutating func read(arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--fields" {
                try readFields(arguments: arguments, index: &index)
                continue
            }

            guard argument.hasPrefix("--") else {
                throw CLIParseError.usage(CLIParser.usageText)
            }

            let selectorName = String(argument.dropFirst(2))
            guard let selector = IPCQuerySelectorName(rawValue: selectorName),
                  descriptor.selectors.contains(where: { $0.name == selector }),
                  seenSelectors.insert(selector).inserted
            else {
                throw CLIParseError.usage(CLIParser.usageText)
            }

            if selector.expectsValue {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CLIParseError.usage(CLIParser.usageText)
                }
                selectors = selectors.setting(selector, value: arguments[index + 1])
                index += 2
            } else {
                selectors = selectors.setting(selector)
                index += 1
            }
        }
    }

    private mutating func readFields(arguments: [String], index: inout Int) throws {
        guard !sawFields, index + 1 < arguments.count else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        let parsedFields = arguments[index + 1]
            .split(separator: ",")
            .map(String.init)
        guard !parsedFields.isEmpty,
              !descriptor.fields.isEmpty,
              parsedFields.allSatisfy({ descriptor.fields.contains($0) })
        else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        fields = parsedFields
        sawFields = true
        index += 2
    }
}
