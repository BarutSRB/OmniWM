import Carbon
import OmniWMIPC

enum HotkeyVisibility: String {
    case normal
    case advanced
    case hidden
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
    private static let digitCodes: [UInt32] = [
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
        specs.map { spec in
            HotkeyBinding(
                id: spec.id,
                command: spec.command,
                binding: spec.defaultBinding
            )
        }
    }

    static func matchesSearch(_ query: String, binding: HotkeyBinding) -> Bool {
        let normalizedQuery = normalizedSearchTerm(query)
        guard !normalizedQuery.isEmpty else { return true }

        guard let spec = spec(for: binding.id) else {
            return binding.command.displayName.localizedCaseInsensitiveContains(query)
                || binding.command.layoutCompatibility.rawValue.localizedCaseInsensitiveContains(query)
                || binding.binding.displayString.localizedCaseInsensitiveContains(query)
                || binding.binding.humanReadableString.localizedCaseInsensitiveContains(query)
        }

        return spec.searchTerms.contains { normalizedSearchTerm($0).contains(normalizedQuery) }
            || normalizedSearchTerm(binding.binding.displayString).contains(normalizedQuery)
            || normalizedSearchTerm(binding.binding.humanReadableString).contains(normalizedQuery)
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

        for (idx, code) in digitCodes.enumerated() {
            specs.append(
                action(
                    id: "switchWorkspace.\(idx)",
                    command: .switchWorkspace(idx),
                    category: .workspace,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey))
                )
            )
            specs.append(
                action(
                    id: "moveToWorkspace.\(idx)",
                    command: .moveToWorkspace(idx),
                    category: .workspace,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | shiftKey))
                )
            )
        }

        specs.append(
            action(
                id: "workspaceBackAndForth",
                command: .workspaceBackAndForth,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | controlKey)),
                keywords: ["back and forth", "previous workspace"]
            )
        )

        specs.append(contentsOf: [
            action(
                id: "switchWorkspace.next",
                command: .switchWorkspaceNext,
                category: .workspace,
                binding: .unassigned
            ),
            action(
                id: "switchWorkspace.previous",
                command: .switchWorkspacePrevious,
                category: .workspace,
                binding: .unassigned
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "focus.left",
                command: .focus(.left),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focus.down",
                command: .focus(.down),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focus.up",
                command: .focus(.up),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focus.right",
                command: .focus(.right),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey))
            )
        ])

        specs.append(
            action(
                id: "focusPrevious",
                command: .focusPrevious,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)),
                keywords: ["last focused", "recent window"]
            )
        )

        specs.append(contentsOf: [
            action(
                id: "focusDownOrLeft",
                command: .focusDownOrLeft,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusUpOrRight",
                command: .focusUpOrRight,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowTop",
                command: .focusWindowTop,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowBottom",
                command: .focusWindowBottom,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowDownOrTop",
                command: .focusWindowDownOrTop,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowUpOrBottom",
                command: .focusWindowUpOrBottom,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowOrWorkspaceDown",
                command: .focusWindowOrWorkspaceDown,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "focusWindowOrWorkspaceUp",
                command: .focusWindowOrWorkspaceUp,
                category: .focus,
                binding: .unassigned,
                visibility: .advanced
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "centerColumn",
                command: .centerColumn,
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "centerVisibleColumns",
                command: .centerVisibleColumns,
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "moveWindowToWorkspaceUp",
                command: .moveWindowToWorkspaceUp,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | controlKey | shiftKey))
            ),
            action(
                id: "moveWindowToWorkspaceDown",
                command: .moveWindowToWorkspaceDown,
                category: .workspace,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_DownArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            action(
                id: "moveColumnToWorkspaceUp",
                command: .moveColumnToWorkspaceUp,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_PageUp), modifiers: UInt32(optionKey | controlKey | shiftKey))
            ),
            action(
                id: "moveColumnToWorkspaceDown",
                command: .moveColumnToWorkspaceDown,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_PageDown), modifiers: UInt32(optionKey | controlKey | shiftKey))
            )
        ])

        for idx in 0 ..< 9 {
            specs.append(
                action(
                    id: "moveColumnToWorkspace.\(idx)",
                    command: .moveColumnToWorkspace(idx),
                    category: .workspace,
                    binding: .unassigned,
                    visibility: .advanced
                )
            )
        }

        specs.append(contentsOf: [
            action(
                id: "move.left",
                command: .move(.left),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "move.down",
                command: .move(.down),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "move.up",
                command: .move(.up),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "move.right",
                command: .move(.right),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | shiftKey))
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "moveWindowDown",
                command: .moveWindowDown,
                category: .move,
                binding: .unassigned,
                visibility: .hidden
            ),
            action(
                id: "moveWindowUp",
                command: .moveWindowUp,
                category: .move,
                binding: .unassigned,
                visibility: .hidden
            ),
            action(
                id: "moveWindowDownOrToWorkspaceDown",
                command: .moveWindowDownOrToWorkspaceDown,
                category: .move,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "moveWindowUpOrToWorkspaceUp",
                command: .moveWindowUpOrToWorkspaceUp,
                category: .move,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "consumeOrExpelWindowLeft",
                command: .consumeOrExpelWindowLeft,
                category: .move,
                binding: .unassigned,
                visibility: .hidden
            ),
            action(
                id: "consumeOrExpelWindowRight",
                command: .consumeOrExpelWindowRight,
                category: .move,
                binding: .unassigned,
                visibility: .hidden
            ),
            action(
                id: "consumeWindowIntoColumn",
                command: .consumeWindowIntoColumn,
                category: .move,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "expelWindowFromColumn",
                command: .expelWindowFromColumn,
                category: .move,
                binding: .unassigned,
                visibility: .advanced
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "focusMonitorNext",
                command: .focusMonitorNext,
                category: .monitor,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | cmdKey))
            ),
            action(
                id: "focusMonitorPrevious",
                command: .focusMonitorPrevious,
                category: .monitor,
                binding: .unassigned
            ),
            action(
                id: "focusMonitorLast",
                command: .focusMonitorLast,
                category: .monitor,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | cmdKey))
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "toggleFullscreen",
                command: .toggleFullscreen,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
            ),
            action(
                id: "toggleNativeFullscreen",
                command: .toggleNativeFullscreen,
                category: .layout,
                binding: .unassigned
            ),
            action(
                id: "moveColumn.left",
                command: .moveColumn(.left),
                category: .column,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_LeftArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            action(
                id: "moveColumn.right",
                command: .moveColumn(.right),
                category: .column,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_RightArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            action(
                id: "moveColumnToFirst",
                command: .moveColumnToFirst,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "moveColumnToLast",
                command: .moveColumnToLast,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "toggleColumnTabbed",
                command: .toggleColumnTabbed,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focusColumnFirst",
                command: .focusColumnFirst,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focusColumnLast",
                command: .focusColumnLast,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey))
            )
        ])

        for (idx, code) in digitCodes.enumerated() {
            specs.append(
                action(
                    id: "focusColumn.\(idx)",
                    command: .focusColumn(idx),
                    category: .focus,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | controlKey)),
                    visibility: .advanced
                )
            )
        }

        for idx in 1 ... 9 {
            specs.append(
                action(
                    id: "focusWindowInColumn.\(idx)",
                    command: .focusWindowInColumn(idx),
                    category: .focus,
                    binding: .unassigned,
                    visibility: .advanced
                )
            )
        }

        for idx in 1 ... 9 {
            specs.append(
                action(
                    id: "moveColumnToIndex.\(idx)",
                    command: .moveColumnToIndex(idx),
                    category: .column,
                    binding: .unassigned,
                    visibility: .advanced
                )
            )
        }

        specs.append(contentsOf: [
            action(
                id: "cycleColumnWidthForward",
                command: .cycleColumnWidthForward,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey)),
                visibility: .advanced
            ),
            action(
                id: "cycleColumnWidthBackward",
                command: .cycleColumnWidthBackward,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey)),
                visibility: .advanced
            ),
            action(
                id: "cycleWindowWidthForward",
                command: .cycleWindowWidthForward,
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowWidthBackward",
                command: .cycleWindowWidthBackward,
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowHeightForward",
                command: .cycleWindowHeightForward,
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowHeightBackward",
                command: .cycleWindowHeightBackward,
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "toggleColumnFullWidth",
                command: .toggleColumnFullWidth,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "expandColumnToAvailableWidth",
                command: .expandColumnToAvailableWidth,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | controlKey)),
                visibility: .advanced
            ),
            action(
                id: "resetWindowHeight",
                command: .resetWindowHeight,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | controlKey)),
                visibility: .advanced
            ),
            action(
                id: "setColumnWidth.decrease10Percent",
                command: .setColumnWidth(.adjustProportion(-10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey)),
                visibility: .advanced,
                keywords: ["shrink column", "resize column"]
            ),
            action(
                id: "setColumnWidth.increase10Percent",
                command: .setColumnWidth(.adjustProportion(10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey)),
                visibility: .advanced,
                keywords: ["grow column", "resize column"]
            ),
            action(
                id: "setWindowWidth.decrease10Percent",
                command: .setWindowWidth(.adjustProportion(-10)),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["shrink window", "resize window"]
            ),
            action(
                id: "setWindowWidth.increase10Percent",
                command: .setWindowWidth(.adjustProportion(10)),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["grow window", "resize window"]
            ),
            action(
                id: "setWindowHeight.decrease10Percent",
                command: .setWindowHeight(.adjustProportion(-10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey | shiftKey)),
                visibility: .advanced,
                keywords: ["shorter window", "resize window"]
            ),
            action(
                id: "setWindowHeight.increase10Percent",
                command: .setWindowHeight(.adjustProportion(10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey | shiftKey)),
                visibility: .advanced,
                keywords: ["taller window", "resize window"]
            ),
            action(
                id: "balanceSizes",
                command: .balanceSizes,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(id: "moveToRoot", command: .moveToRoot, category: .layout, binding: .unassigned),
            action(id: "toggleSplit", command: .toggleSplit, category: .layout, binding: .unassigned),
            action(id: "swapSplit", command: .swapSplit, category: .layout, binding: .unassigned)
        ])

        specs.append(contentsOf: [
            action(
                id: "resizeGrow.left",
                command: .resizeInDirection(.left, true),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "grow"]
            ),
            action(
                id: "resizeGrow.right",
                command: .resizeInDirection(.right, true),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "grow"]
            ),
            action(
                id: "resizeGrow.up",
                command: .resizeInDirection(.up, true),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "grow"]
            ),
            action(
                id: "resizeGrow.down",
                command: .resizeInDirection(.down, true),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "grow"]
            ),
            action(
                id: "resizeShrink.left",
                command: .resizeInDirection(.left, false),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "shrink"]
            ),
            action(
                id: "resizeShrink.right",
                command: .resizeInDirection(.right, false),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "shrink"]
            ),
            action(
                id: "resizeShrink.up",
                command: .resizeInDirection(.up, false),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "shrink"]
            ),
            action(
                id: "resizeShrink.down",
                command: .resizeInDirection(.down, false),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "shrink"]
            ),
            action(
                id: "preselect.left",
                command: .preselect(.left),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselect.right",
                command: .preselect(.right),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselect.up",
                command: .preselect(.up),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselect.down",
                command: .preselect(.down),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselectClear",
                command: .preselectClear,
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "openCommandPalette",
                command: .openCommandPalette,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
                keywords: ["palette", "search", "commands", "menu"]
            ),
            action(
                id: "raiseAllFloatingWindows",
                command: .raiseAllFloatingWindows,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["float", "floating", "raise"]
            ),
            action(
                id: "rescueOffscreenWindows",
                command: .rescueOffscreenWindows,
                category: .layout,
                binding: .unassigned,
                keywords: ["rescue", "offscreen", "off-screen"]
            ),
            action(
                id: "toggleFocusedWindowFloating",
                command: .toggleFocusedWindowFloating,
                category: .layout,
                binding: .unassigned,
                keywords: ["float", "floating"]
            ),
            action(
                id: "assignFocusedWindowToScratchpad",
                command: .assignFocusedWindowToScratchpad,
                category: .layout,
                binding: .unassigned,
                keywords: ["scratchpad"]
            ),
            action(
                id: "toggleScratchpadWindow",
                command: .toggleScratchpadWindow,
                category: .layout,
                binding: .unassigned,
                keywords: ["scratchpad"]
            ),
            action(
                id: "openMenuAnywhere",
                command: .openMenuAnywhere,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)),
                keywords: ["menu", "anywhere"]
            ),
            action(
                id: "toggleWorkspaceBarVisibility",
                command: .toggleWorkspaceBarVisibility,
                category: .focus,
                binding: .unassigned,
                keywords: ["workspace bar", "bar"]
            ),
            action(
                id: "toggleHiddenBar",
                command: .toggleHiddenBar,
                category: .focus,
                binding: .unassigned,
                keywords: ["hidden bar", "bar"]
            ),
            action(
                id: "toggleQuakeTerminal",
                command: .toggleQuakeTerminal,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey)),
                keywords: ["quake", "terminal"]
            ),
            action(
                id: "toggleWorkspaceLayout",
                command: .toggleWorkspaceLayout,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["layout", "niri", "dwindle"]
            ),
            action(
                id: "toggleOverview",
                command: .toggleOverview,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["overview"]
            )
        ])

        return specs
    }

    private static func action(
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
        case .moveToRoot,
             .toggleSplit,
             .swapSplit,
             .preselect,
             .preselectClear,
             .resizeInDirection:
            .dwindle

        case .moveWindowDown,
             .moveWindowUp,
             .moveWindowDownOrToWorkspaceDown,
             .moveWindowUpOrToWorkspaceUp,
             .consumeOrExpelWindowLeft,
             .consumeOrExpelWindowRight,
             .consumeWindowIntoColumn,
             .expelWindowFromColumn,
             .moveColumn,
             .moveColumnToFirst,
             .moveColumnToLast,
             .moveColumnToIndex,
             .moveColumnToWorkspace,
             .moveColumnToWorkspaceUp,
             .moveColumnToWorkspaceDown,
             .toggleColumnFullWidth,
             .toggleColumnTabbed,
             .cycleWindowWidthForward,
             .cycleWindowWidthBackward,
             .cycleWindowHeightForward,
             .cycleWindowHeightBackward,
             .expandColumnToAvailableWidth,
             .resetWindowHeight,
             .setColumnWidth,
             .setWindowWidth,
             .setWindowHeight,
             .focusPrevious,
             .focusDownOrLeft,
             .focusUpOrRight,
             .focusWindowInColumn,
             .focusWindowTop,
             .focusWindowBottom,
             .focusWindowDownOrTop,
             .focusWindowUpOrBottom,
             .focusWindowOrWorkspaceDown,
             .focusWindowOrWorkspaceUp,
             .focusColumnFirst,
             .focusColumnLast,
             .focusColumn:
            .niri

        case .centerColumn,
             .centerVisibleColumns:
            .niri

        case .focus,
             .toggleFullscreen,
             .cycleColumnWidthForward,
             .cycleColumnWidthBackward,
             .balanceSizes,
             .move,
             .moveToWorkspace,
             .moveWindowToWorkspaceUp,
             .moveWindowToWorkspaceDown,
             .switchWorkspace,
             .switchWorkspaceNext,
             .switchWorkspacePrevious,
             .focusMonitorPrevious,
             .focusMonitorNext,
             .focusMonitorLast,
             .toggleNativeFullscreen,
             .swapWorkspaceWithMonitor,
             .workspaceBackAndForth,
             .focusWorkspaceAnywhere,
             .moveWindowToWorkspaceOnMonitor,
             .openCommandPalette,
             .raiseAllFloatingWindows,
             .rescueOffscreenWindows,
             .toggleFocusedWindowFloating,
             .assignFocusedWindowToScratchpad,
             .toggleScratchpadWindow,
             .openMenuAnywhere,
             .toggleWorkspaceBarVisibility,
             .toggleHiddenBar,
             .toggleQuakeTerminal,
             .toggleWorkspaceLayout,
             .toggleOverview:
            .shared
        }
    }

    private static func displayName(for command: HotkeyCommand) -> String {
        switch command {
        case let .focus(dir): "Focus \(dir.displayName)"
        case .focusPrevious: "Focus Previous Window"
        case let .move(dir): "Move \(dir.displayName)"
        case let .moveToWorkspace(idx): "Move to Workspace \(idx + 1)"
        case .moveWindowToWorkspaceUp: "Move Window to Workspace Up"
        case .moveWindowToWorkspaceDown: "Move Window to Workspace Down"
        case let .moveColumnToWorkspace(idx): "Move Column to Workspace \(idx + 1)"
        case .moveColumnToWorkspaceUp: "Move Column to Workspace Up"
        case .moveColumnToWorkspaceDown: "Move Column to Workspace Down"
        case let .switchWorkspace(idx): "Switch to Workspace \(idx + 1)"
        case .switchWorkspaceNext: "Switch to Next Workspace"
        case .switchWorkspacePrevious: "Switch to Previous Workspace"
        case .focusMonitorPrevious: "Focus Previous Monitor"
        case .focusMonitorNext: "Focus Next Monitor"
        case .focusMonitorLast: "Focus Last Monitor"
        case .toggleFullscreen: "Toggle Fullscreen"
        case .toggleNativeFullscreen: "Toggle Native Fullscreen"
        case let .moveColumn(dir): "Move Column \(dir.displayName)"
        case .moveColumnToFirst: "Move Column to First"
        case .moveColumnToLast: "Move Column to Last"
        case let .moveColumnToIndex(idx): "Move Column to Index \(idx)"
        case .moveWindowDown: "Move Window Down"
        case .moveWindowUp: "Move Window Up"
        case .moveWindowDownOrToWorkspaceDown: "Move Window Down or to Workspace Down"
        case .moveWindowUpOrToWorkspaceUp: "Move Window Up or to Workspace Up"
        case .consumeOrExpelWindowLeft: "Consume or Expel Window Left"
        case .consumeOrExpelWindowRight: "Consume or Expel Window Right"
        case .consumeWindowIntoColumn: "Consume Window into Column"
        case .expelWindowFromColumn: "Expel Window from Column"
        case .toggleColumnTabbed: "Toggle Column Tabbed"
        case .focusDownOrLeft: "Traverse Backward"
        case .focusUpOrRight: "Traverse Forward"
        case let .focusWindowInColumn(idx): "Focus Window \(idx) in Column"
        case .focusWindowTop: "Focus Top Window"
        case .focusWindowBottom: "Focus Bottom Window"
        case .focusWindowDownOrTop: "Focus Down or Top"
        case .focusWindowUpOrBottom: "Focus Up or Bottom"
        case .focusWindowOrWorkspaceDown: "Focus Window or Workspace Down"
        case .focusWindowOrWorkspaceUp: "Focus Window or Workspace Up"
        case .focusColumnFirst: "Focus First Column"
        case .focusColumnLast: "Focus Last Column"
        case let .focusColumn(idx): "Focus Column \(idx + 1)"
        case .centerColumn: "Center Column"
        case .centerVisibleColumns: "Center Visible Columns"
        case .cycleColumnWidthForward: "Cycle Column Width Forward"
        case .cycleColumnWidthBackward: "Cycle Column Width Backward"
        case .cycleWindowWidthForward: "Cycle Window Width Forward"
        case .cycleWindowWidthBackward: "Cycle Window Width Backward"
        case .cycleWindowHeightForward: "Cycle Window Height Forward"
        case .cycleWindowHeightBackward: "Cycle Window Height Backward"
        case .toggleColumnFullWidth: "Toggle Column Full Width"
        case .expandColumnToAvailableWidth: "Expand Column to Available Width"
        case .resetWindowHeight: "Reset Window Height"
        case let .setColumnWidth(change): "Set Column Width \(sizeChangeDisplayName(change))"
        case let .setWindowWidth(change): "Set Window Width \(sizeChangeDisplayName(change))"
        case let .setWindowHeight(change): "Set Window Height \(sizeChangeDisplayName(change))"
        case let .swapWorkspaceWithMonitor(dir): "Swap Workspace with \(dir.displayName) Monitor"
        case .balanceSizes: "Balance Sizes"
        case .moveToRoot: "Move to Root"
        case .toggleSplit: "Toggle Split"
        case .swapSplit: "Swap Split"
        case let .resizeInDirection(dir, grow): "\(grow ? "Grow" : "Shrink") \(dir.displayName)"
        case let .preselect(dir): "Preselect \(dir.displayName)"
        case .preselectClear: "Clear Preselection"
        case .workspaceBackAndForth: "Switch to Last Active Workspace"
        case let .focusWorkspaceAnywhere(idx): "Focus Workspace \(idx + 1) Anywhere"
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir): "Move Window to Workspace \(wsIdx + 1) on \(monDir.displayName) Monitor"
        case .openCommandPalette: "Toggle Command Palette"
        case .raiseAllFloatingWindows: "Raise All Floating Windows"
        case .rescueOffscreenWindows: "Rescue Off-Screen Floating Windows"
        case .toggleFocusedWindowFloating: "Toggle Focused Window Floating"
        case .assignFocusedWindowToScratchpad: "Assign Focused Window to Scratchpad"
        case .toggleScratchpadWindow: "Toggle Scratchpad Window"
        case .openMenuAnywhere: "Open Menu Anywhere"
        case .toggleWorkspaceBarVisibility: "Toggle Workspace Bar"
        case .toggleHiddenBar: "Toggle Hidden Bar"
        case .toggleQuakeTerminal: "Toggle Quake Terminal"
        case .toggleWorkspaceLayout: "Toggle Workspace Layout"
        case .toggleOverview: "Toggle Overview"
        }
    }

    private static func ipcCommandName(for command: HotkeyCommand) -> IPCCommandName? {
        switch command {
        case .focus:
            .focus
        case .focusPrevious:
            .focusPrevious
        case .focusDownOrLeft:
            .focusDownOrLeft
        case .focusUpOrRight:
            .focusUpOrRight
        case .focusWindowInColumn:
            .focusWindowInColumn
        case .focusWindowTop:
            .focusWindowTop
        case .focusWindowBottom:
            .focusWindowBottom
        case .focusWindowDownOrTop:
            .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            .focusWindowOrWorkspaceUp
        case .focusColumn:
            .focusColumn
        case .focusColumnFirst:
            .focusColumnFirst
        case .focusColumnLast:
            .focusColumnLast
        case .centerColumn:
            .centerColumn
        case .centerVisibleColumns:
            .centerVisibleColumns
        case .move:
            .move
        case .moveWindowDown:
            .moveWindowDown
        case .moveWindowUp:
            .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            .expelWindowFromColumn
        case .switchWorkspace:
            .switchWorkspace
        case .switchWorkspaceNext:
            .switchWorkspaceNext
        case .switchWorkspacePrevious:
            .switchWorkspacePrevious
        case .workspaceBackAndForth:
            .switchWorkspaceBackAndForth
        case .focusWorkspaceAnywhere:
            .switchWorkspaceAnywhere
        case .moveToWorkspace:
            .moveToWorkspace
        case .moveWindowToWorkspaceUp:
            .moveToWorkspaceUp
        case .moveWindowToWorkspaceDown:
            .moveToWorkspaceDown
        case .moveWindowToWorkspaceOnMonitor:
            .moveToWorkspaceOnMonitor
        case .focusMonitorPrevious:
            .focusMonitorPrevious
        case .focusMonitorNext:
            .focusMonitorNext
        case .focusMonitorLast:
            .focusMonitorLast
        case .moveColumn:
            .moveColumn
        case .moveColumnToFirst:
            .moveColumnToFirst
        case .moveColumnToLast:
            .moveColumnToLast
        case .moveColumnToIndex:
            .moveColumnToIndex
        case .moveColumnToWorkspace:
            .moveColumnToWorkspace
        case .moveColumnToWorkspaceUp:
            .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            .toggleColumnTabbed
        case .cycleColumnWidthForward:
            .cycleColumnWidthForward
        case .cycleColumnWidthBackward:
            .cycleColumnWidthBackward
        case .cycleWindowWidthForward:
            .cycleWindowWidthForward
        case .cycleWindowWidthBackward:
            .cycleWindowWidthBackward
        case .cycleWindowHeightForward:
            .cycleWindowHeightForward
        case .cycleWindowHeightBackward:
            .cycleWindowHeightBackward
        case .toggleColumnFullWidth:
            .toggleColumnFullWidth
        case .expandColumnToAvailableWidth:
            .expandColumnToAvailableWidth
        case .resetWindowHeight:
            .resetWindowHeight
        case .setColumnWidth:
            .setColumnWidth
        case .setWindowWidth:
            .setWindowWidth
        case .setWindowHeight:
            .setWindowHeight
        case .swapWorkspaceWithMonitor:
            .swapWorkspaceWithMonitor
        case .balanceSizes:
            .balanceSizes
        case .moveToRoot:
            .moveToRoot
        case .toggleSplit:
            .toggleSplit
        case .swapSplit:
            .swapSplit
        case .resizeInDirection:
            .resize
        case .preselect:
            .preselect
        case .preselectClear:
            .preselectClear
        case .openCommandPalette:
            .openCommandPalette
        case .raiseAllFloatingWindows:
            .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            .rescueOffscreenWindows
        case .toggleWorkspaceLayout:
            .toggleWorkspaceLayout
        case .toggleFullscreen:
            .toggleFullscreen
        case .toggleNativeFullscreen:
            .toggleNativeFullscreen
        case .toggleOverview:
            .toggleOverview
        case .toggleQuakeTerminal:
            .toggleQuakeTerminal
        case .toggleWorkspaceBarVisibility:
            .toggleWorkspaceBar
        case .toggleHiddenBar:
            .toggleHiddenBar
        case .toggleFocusedWindowFloating:
            .toggleFocusedWindowFloating
        case .assignFocusedWindowToScratchpad:
            .scratchpadAssign
        case .toggleScratchpadWindow:
            .scratchpadToggle
        case .openMenuAnywhere:
            .openMenuAnywhere
        }
    }

    private static func sizeChangeDisplayName(_ change: NiriSizeChange) -> String {
        switch change {
        case let .setFixed(value):
            "Fixed \(Int(value))px"
        case let .setProportion(value):
            "\(Int(value))%"
        case let .adjustFixed(value):
            "\(value >= 0 ? "+" : "")\(Int(value))px"
        case let .adjustProportion(value):
            "\(value >= 0 ? "+" : "")\(Int(value))%"
        }
    }
}
