// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import OmniWMIPC

enum HotkeyVisibility: String {
    case normal
    case advanced
    case unassignable
}

struct ActionSpec: Equatable {
    let id: String
    let command: HotkeyCommand
    let title: String
    let keywords: [String]
    let category: HotkeyCategory
    let visibility: HotkeyVisibility
    let layoutCompatibility: LayoutCompatibility
    let defaultBinding: KeyBinding
    let ipcCommandName: IPCCommandName?

    var ipcDescriptor: IPCCommandDescriptor? {
        ipcCommandName.flatMap(IPCAutomationManifest.commandDescriptor(for:))
    }

    var searchTerms: [String] {
        ActionCatalog.uniqueTerms(
            [title, id, layoutCompatibility.rawValue]
                + keywords
                + (ipcDescriptor.map { [$0.path] + $0.commandWords } ?? [])
        )
    }
}

enum ActionCatalog {
    static let workspaceSlotRange = 1 ... 9

    static let digitCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
    ]

    private static let specs: [ActionSpec] = buildSpecs()
    private static let specsByID = Dictionary(
        uniqueKeysWithValues: specs.map { ($0.id, $0) }
    )

    static func allSpecs() -> [ActionSpec] {
        specs
    }

    static func spec(for id: String) -> ActionSpec? {
        specsByID[id]
    }

    static func spec(for command: HotkeyCommand) -> ActionSpec? {
        specs.first { $0.command == command }
    }

    static func title(for command: HotkeyCommand) -> String? {
        spec(for: command)?.title
    }

    static func layoutCompatibility(for command: HotkeyCommand) -> LayoutCompatibility? {
        spec(for: command)?.layoutCompatibility
    }

    static func category(for id: String) -> HotkeyCategory? {
        spec(for: id)?.category
    }

    static func visibility(for id: String) -> HotkeyVisibility? {
        spec(for: id)?.visibility
    }

    static func defaultHotkeyBindings() -> [HotkeyBinding] {
        specs.filter { $0.visibility != .unassignable }.map { spec in
            HotkeyBinding(
                id: spec.id,
                command: spec.command,
                binding: spec.defaultBinding
            )
        }
    }

    static func uniqueTerms(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { raw in
            let normalized = normalizedSearchTerm(raw)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return raw
        }
    }

    static func normalizedSearchTerm(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildSpecs() -> [ActionSpec] {
        var specs: [ActionSpec] = []

        appendScratchpadBindings(&specs)
        appendWorkspaceNumberBindings(&specs)
        appendWorkspaceSlotBindings(&specs)
        appendWorkspaceHistoryBinding(&specs)
        appendWorkspaceCycleBindings(&specs)
        appendDirectionalFocusBindings(&specs)
        appendFocusHistoryBinding(&specs)
        appendTraversalFocusBindings(&specs)
        appendWindowFocusBindings(&specs)
        appendWorkspaceEdgeFocusBindings(&specs)
        appendCenteringBindings(&specs)
        appendWorkspaceTransferBindings(&specs)
        appendColumnWorkspaceBindings(&specs)
        appendDirectionalMoveBindings(&specs)
        appendWindowReorderBindings(&specs)
        appendColumnMembershipBindings(&specs)
        appendMonitorFocusBindings(&specs)
        appendWorkspaceMonitorBindings(&specs)
        appendWindowMonitorBindings(&specs)
        appendFullscreenBindings(&specs)
        appendDirectionalColumnBindings(&specs)
        appendColumnOrderBindings(&specs)
        appendColumnEdgeFocusBindings(&specs)
        appendColumnIndexFocusBindings(&specs)
        appendWindowIndexFocusBindings(&specs)
        appendColumnIndexMoveBindings(&specs)
        appendSizeCycleBindings(&specs)
        appendWindowSpanCycleBindings(&specs)
        appendContainerSpanBindings(&specs)
        appendSpanAdjustmentBindings(&specs)
        appendSplitStructureBindings(&specs)
        appendAxisResizeBindings(&specs)
        appendFocusedResizeBindings(&specs)
        appendPreselectionBindings(&specs)
        appendPresentationBindings(&specs)

        return specs
    }

    static func action(
        id: String,
        command: HotkeyCommand,
        category: HotkeyCategory,
        binding: KeyBinding,
        visibility: HotkeyVisibility = .normal,
        keywords: [String] = []
    ) -> ActionSpec {
        let title = displayName(for: command)
        return ActionSpec(
            id: id,
            command: command,
            title: title,
            keywords: uniqueTerms(keywords + [title, id]),
            category: category,
            visibility: visibility,
            layoutCompatibility: compatibility(for: command),
            defaultBinding: binding,
            ipcCommandName: ipcCommandName(for: command)
        )
    }

    private static func compatibility(for command: HotkeyCommand) -> LayoutCompatibility {
        switch command {
        case .moveColumn(.up),
             .moveColumn(.down):
            .dwindle
        case .focus,
             .move,
             .moveColumn(.left),
             .moveColumn(.right),
             .monitorFocus,
             .fullscreen,
             .openCommandPalette,
             .raiseAllFloatingWindows,
             .rescueOffscreenWindows,
             .windowState,
             .openMenuAnywhere,
             .presentation:
            .shared
        case let .focusNavigation(action):
            action.compatibility
        case let .windowMovement(action):
            action.compatibility
        case let .column(action):
            action.compatibility
        case let .workspace(action):
            action.compatibility
        case let .sizing(action):
            action.compatibility
        case let .dwindle(action):
            action.compatibility
        case let .scratchpad(action):
            action.compatibility
        }
    }

    private static func displayName(for command: HotkeyCommand) -> String {
        switch command {
        case let .focus(dir): "Focus \(dir.displayName)"
        case let .move(dir): "Move \(dir.displayName)"
        case let .monitorFocus(command): command.actionDisplayName()
        case let .fullscreen(command): command.actionDisplayName()
        case let .moveColumn(dir): "Move Container \(dir.displayName)"
        case .openCommandPalette: "Toggle Command Palette"
        case .raiseAllFloatingWindows: "Raise All Floating Windows"
        case .rescueOffscreenWindows: "Rescue Off-Screen Floating Windows"
        case let .windowState(command): command.actionDisplayName()
        case .openMenuAnywhere: "Open Menu Anywhere"
        case let .presentation(command): command.actionDisplayName()
        case let .focusNavigation(action):
            action.actionDisplayName()
        case let .windowMovement(action):
            action.actionDisplayName()
        case let .column(action):
            action.actionDisplayName()
        case let .workspace(action):
            action.actionDisplayName()
        case let .sizing(action):
            action.actionDisplayName()
        case let .dwindle(action):
            action.actionDisplayName()
        case let .scratchpad(action):
            action.actionDisplayName()
        }
    }

    private static func ipcCommandName(for command: HotkeyCommand) -> IPCCommandName? {
        switch command {
        case .focus:
            .focus(.spatial)
        case .move:
            .windowMovement(.spatial)
        case let .monitorFocus(command):
            .monitorFocus(command)
        case .moveColumn:
            .column(.move)
        case .openCommandPalette:
            .openCommandPalette
        case .raiseAllFloatingWindows:
            .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            .rescueOffscreenWindows
        case let .fullscreen(command):
            .fullscreen(command)
        case let .presentation(command):
            .presentation(command)
        case let .windowState(command):
            .windowState(command)
        case .openMenuAnywhere:
            .openMenuAnywhere
        case let .focusNavigation(action):
            action.ipcCommandName()
        case let .windowMovement(action):
            action.ipcCommandName()
        case let .column(action):
            action.ipcCommandName()
        case let .workspace(action):
            action.ipcCommandName()
        case let .sizing(action):
            action.ipcCommandName()
        case let .dwindle(action):
            action.ipcCommandName()
        case let .scratchpad(action):
            action.ipcCommandName()
        }
    }
}
