// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

public enum IPCScratchpadCommandName: String, CaseIterable, Hashable, Sendable {
    case assign = "scratchpad-assign"
    case toggle = "scratchpad-toggle"
}

public enum IPCScratchpadCommand: Equatable, Sendable {
    case assign(index: Int)
    case toggle(index: Int)

    public var name: IPCScratchpadCommandName {
        switch self {
        case .assign:
            .assign
        case .toggle:
            .toggle
        }
    }

    init(name: IPCScratchpadCommandName, arguments: IPCCommandArgumentSource) throws {
        switch name {
        case .assign:
            self = try .assign(index: arguments.integer(.scratchpadIndex))
        case .toggle:
            self = try .toggle(index: arguments.integer(.scratchpadIndex))
        }
    }

    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .assign(index):
            try writer.encode(integer: index, field: .scratchpadIndex)
        case let .toggle(index):
            try writer.encode(integer: index, field: .scratchpadIndex)
        }
    }
}
