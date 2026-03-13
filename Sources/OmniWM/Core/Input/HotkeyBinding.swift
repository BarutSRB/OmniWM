import Carbon
import Foundation

struct KeyBinding: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let unassigned = KeyBinding(keyCode: UInt32.max, modifiers: 0)

    var isUnassigned: Bool {
        keyCode == UInt32.max && modifiers == 0
    }

    var displayString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var humanReadableString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.humanReadableString(keyCode: keyCode, modifiers: modifiers)
    }

    func conflicts(with other: KeyBinding) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let binding = KeySymbolMapper.fromHumanReadable(string) {
            self = binding
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
    }

    func encode(to encoder: Encoder) throws {
        if isUnassigned || KeySymbolMapper.keyName(keyCode) != "?" {
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        }
    }
}

struct HotkeyBinding: Codable, Equatable, Identifiable {
    let id: String
    let command: HotkeyCommand
    var binding: KeyBinding

    var category: HotkeyCategory {
        switch command {
        case .moveColumnToWorkspace, .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp, .moveToWorkspace,
             .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp, .summonWorkspace,
             .switchWorkspace, .switchWorkspaceNext, .switchWorkspacePrevious, .workspaceBackAndForth,
             .focusWorkspaceAnywhere:
            .workspace
        case .focus, .focusColumn, .focusColumnFirst, .focusColumnLast,
             .focusDownOrLeft, .focusPrevious, .focusUpOrRight, .focusWindowBottom, .focusWindowTop,
             .openMenuAnywhere, .openMenuPalette, .openWindowFinder, .toggleHiddenBar, .toggleQuakeTerminal,
             .toggleOverview:
            .focus
        case .move:
            .move
        case .focusMonitor, .focusMonitorLast, .focusMonitorNext, .focusMonitorPrevious, .moveColumnToMonitor,
             .moveToMonitor, .moveWorkspaceToMonitor, .moveWorkspaceToMonitorNext, .moveWorkspaceToMonitorPrevious,
             .swapWorkspaceWithMonitor, .moveWindowToWorkspaceOnMonitor:
            .monitor
        case .balanceSizes, .moveToRoot, .raiseAllFloatingWindows, .toggleFullscreen, .toggleNativeFullscreen,
             .toggleSplit, .swapSplit, .resizeInDirection, .preselect, .preselectClear, .toggleWorkspaceLayout:
            .layout
        case .cycleColumnWidthBackward, .cycleColumnWidthForward, .moveColumn, .toggleColumnFullWidth,
             .toggleColumnTabbed:
            .column
        }
    }
}

extension HotkeyBinding {
    private enum CodingKeys: String, CodingKey {
        case id, binding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let binding = try container.decode(KeyBinding.self, forKey: .binding)
        guard let resolved = HotkeyBindingRegistry.makeBinding(id: id, binding: binding) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Unknown hotkey binding id: \(id)"
            )
        }
        self = resolved
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
    }
}

struct PersistedHotkeyBinding: Codable, Equatable {
    let id: String
    let binding: KeyBinding
}

enum HotkeyBindingRegistry {
    private static let defaultBindings = DefaultHotkeyBindings.all()
    private static let bindingsByID = Dictionary(
        defaultBindings.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func defaults() -> [HotkeyBinding] {
        defaultBindings
    }

    static func makeBinding(id: String, binding: KeyBinding) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, binding: binding)
    }

    static func canonicalize(_ persisted: [PersistedHotkeyBinding]) -> [HotkeyBinding] {
        var overrides: [String: KeyBinding] = [:]
        for entry in persisted where bindingsByID[entry.id] != nil {
            overrides[entry.id] = entry.binding
        }

        return defaultBindings.map { binding in
            guard let override = overrides[binding.id] else { return binding }
            return HotkeyBinding(id: binding.id, command: binding.command, binding: override)
        }
    }

    static func decodePersistedBindings(from data: Data) -> [HotkeyBinding]? {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in rawArray {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return canonicalize(persisted)
    }

    static func canonicalizedJSONArray(from rawArray: Any) -> Any {
        guard let entries = rawArray as? [Any] else {
            return encodedJSONArray(for: defaultBindings)
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in entries {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return encodedJSONArray(for: canonicalize(persisted))
    }

    private static func encodedJSONArray(for bindings: [HotkeyBinding]) -> Any {
        guard let data = try? JSONEncoder().encode(bindings),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }
        return json
    }
}

enum HotkeyCategory: String, CaseIterable {
    case workspace = "Workspace"
    case focus = "Focus"
    case move = "Move Window"
    case monitor = "Monitor"
    case layout = "Layout"
    case column = "Column"
}
