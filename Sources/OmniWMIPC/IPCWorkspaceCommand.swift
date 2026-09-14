// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

public enum IPCWorkspaceCommandName: String, CaseIterable, Hashable, Sendable {
    case switchTo = "switch-workspace"
    case next = "switch-workspace-next"
    case previous = "switch-workspace-previous"
    case backAndForth = "switch-workspace-back-and-forth"
    case switchAnywhere = "switch-workspace-anywhere"
    case switchSlot = "switch-workspace-slot"
    case moveTo = "move-to-workspace"
    case moveUp = "move-to-workspace-up"
    case moveDown = "move-to-workspace-down"
    case moveToOnMonitor = "move-to-workspace-on-monitor"
    case moveToSlot = "move-to-workspace-slot"
    case moveToMonitor = "move-to-monitor"
}

public enum IPCWorkspaceCommand: Equatable, Sendable {
    case switchTo(workspaceNumber: Int)
    case next
    case previous
    case backAndForth
    case switchAnywhere(workspaceNumber: Int)
    case switchSlot(slotNumber: Int)
    case moveTo(workspaceNumber: Int)
    case moveUp
    case moveDown
    case moveToOnMonitor(workspaceNumber: Int, direction: IPCDirection)
    case moveToSlot(slotNumber: Int)
    case moveToMonitor(direction: IPCDirection)

    public var name: IPCWorkspaceCommandName {
        switch self {
        case .switchTo:
            .switchTo
        case .next:
            .next
        case .previous:
            .previous
        case .backAndForth:
            .backAndForth
        case .switchAnywhere:
            .switchAnywhere
        case .switchSlot:
            .switchSlot
        case .moveTo:
            .moveTo
        case .moveUp:
            .moveUp
        case .moveDown:
            .moveDown
        case .moveToOnMonitor:
            .moveToOnMonitor
        case .moveToSlot:
            .moveToSlot
        case .moveToMonitor:
            .moveToMonitor
        }
    }

    init(name: IPCWorkspaceCommandName, arguments: IPCCommandArgumentSource) throws {
        switch name {
        case .switchTo:
            self = try .switchTo(workspaceNumber: arguments.integer(.workspaceNumber))
        case .next:
            self = try arguments.requireNoArguments(.next)
        case .previous:
            self = try arguments.requireNoArguments(.previous)
        case .backAndForth:
            self = try arguments.requireNoArguments(.backAndForth)
        case .switchAnywhere:
            self = try .switchAnywhere(workspaceNumber: arguments.integer(.workspaceNumber))
        case .switchSlot:
            self = try .switchSlot(slotNumber: arguments.integer(.slotNumber))
        case .moveTo:
            self = try .moveTo(workspaceNumber: arguments.integer(.workspaceNumber))
        case .moveUp:
            self = try arguments.requireNoArguments(.moveUp)
        case .moveDown:
            self = try arguments.requireNoArguments(.moveDown)
        case .moveToOnMonitor:
            let values = try arguments.workspaceAndDirection()
            self = .moveToOnMonitor(workspaceNumber: values.workspaceNumber, direction: values.direction)
        case .moveToSlot:
            self = try .moveToSlot(slotNumber: arguments.integer(.slotNumber))
        case .moveToMonitor:
            self = try .moveToMonitor(direction: arguments.direction())
        }
    }

    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .switchTo(workspaceNumber):
            try writer.encode(integer: workspaceNumber, field: .workspaceNumber)
        case let .switchAnywhere(workspaceNumber):
            try writer.encode(integer: workspaceNumber, field: .workspaceNumber)
        case let .switchSlot(slotNumber):
            try writer.encode(integer: slotNumber, field: .slotNumber)
        case let .moveTo(workspaceNumber):
            try writer.encode(integer: workspaceNumber, field: .workspaceNumber)
        case let .moveToOnMonitor(workspaceNumber, direction):
            try writer.encode(workspaceNumber: workspaceNumber, direction: direction)
        case let .moveToSlot(slotNumber):
            try writer.encode(integer: slotNumber, field: .slotNumber)
        case let .moveToMonitor(direction):
            try writer.encode(direction: direction)
        case .next,
             .previous,
             .backAndForth,
             .moveUp,
             .moveDown:
            break
        }
    }
}
