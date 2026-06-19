// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation

enum ModifierSide: Equatable, Hashable {
    case either
    case left
    case right
}

struct SidedModifiers: Equatable, Hashable {
    var left: UInt32
    var right: UInt32

    init(left: UInt32 = 0, right: UInt32 = 0) {
        self.left = left
        self.right = right
    }

    static let none = SidedModifiers()

    var isEmpty: Bool {
        left == 0 && right == 0
    }

    func side(for modifier: UInt32) -> ModifierSide {
        if left & modifier != 0 { return .left }
        if right & modifier != 0 { return .right }
        return .either
    }
}

struct KeyBinding: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let sidedModifiers: SidedModifiers

    static let unassigned = KeyBinding(keyCode: UInt32.max, modifiers: 0)

    init(keyCode: UInt32, modifiers: UInt32, sidedModifiers: SidedModifiers = .none) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.sidedModifiers = sidedModifiers
    }

    var isUnassigned: Bool {
        keyCode == UInt32.max && modifiers == 0
    }

    var side: ModifierSide {
        if sidedModifiers.isEmpty { return .either }
        if sidedModifiers.left == modifiers, sidedModifiers.right == 0 { return .left }
        if sidedModifiers.right == modifiers, sidedModifiers.left == 0 { return .right }
        return .either
    }

    func settingSide(_ side: ModifierSide) -> KeyBinding {
        let sided: SidedModifiers
        switch side {
        case .either: sided = .none
        case .left: sided = SidedModifiers(left: modifiers)
        case .right: sided = SidedModifiers(right: modifiers)
        }
        return KeyBinding(keyCode: keyCode, modifiers: modifiers, sidedModifiers: sided)
    }

    var displayString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.displayString(keyCode: keyCode, modifiers: modifiers, sides: sidedModifiers)
    }

    var humanReadableString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.humanReadableString(keyCode: keyCode, modifiers: modifiers, sides: sidedModifiers)
    }

    func conflicts(with other: KeyBinding) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        guard keyCode == other.keyCode, modifiers == other.modifiers else { return false }
        var remaining = modifiers
        while remaining != 0 {
            let bit = remaining & (0 &- remaining)
            remaining &= remaining - 1
            let lhs = sidedModifiers.side(for: bit)
            let rhs = other.sidedModifiers.side(for: bit)
            if lhs != .either, rhs != .either, lhs != rhs { return false }
        }
        return true
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, left, right
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let binding = KeySymbolMapper.fromHumanReadable(string)
        {
            self = binding
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        sidedModifiers = SidedModifiers(
            left: try container.decodeIfPresent(UInt32.self, forKey: .left) ?? 0,
            right: try container.decodeIfPresent(UInt32.self, forKey: .right) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        if isUnassigned || KeySymbolMapper.keyName(keyCode) != "?" {
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
            if sidedModifiers.left != 0 {
                try container.encode(sidedModifiers.left, forKey: .left)
            }
            if sidedModifiers.right != 0 {
                try container.encode(sidedModifiers.right, forKey: .right)
            }
        }
    }
}

enum SystemHyperTrigger: Equatable, Hashable {
    case none
    case key(UInt32)
    case mouseButton(Int64)

    static let `default`: SystemHyperTrigger = .none

    static let selectableKeyCodes: [UInt32] = [
        UInt32(kVK_CapsLock),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
        UInt32(kVK_RightOption), UInt32(kVK_RightCommand),
        UInt32(kVK_RightControl), UInt32(kVK_RightShift)
    ]

    static let selectableMouseButtons: [Int64] = [3, 4, 5]

    var isEnabled: Bool {
        self != .none
    }

    var isSupported: Bool {
        switch self {
        case .none:
            return true
        case let .key(keyCode):
            return Self.selectableKeyCodes.contains(keyCode)
        case let .mouseButton(button):
            return Self.selectableMouseButtons.contains(button)
        }
    }

    var displayString: String {
        switch self {
        case .none:
            return "None"
        case let .key(keyCode):
            return KeySymbolMapper.keySymbol(keyCode)
        case let .mouseButton(button):
            return "Mouse \(button)"
        }
    }

    var humanReadableString: String {
        switch self {
        case .none:
            return "None"
        case let .key(keyCode):
            return KeySymbolMapper.keyName(keyCode)
        case let .mouseButton(button):
            return "MouseButton\(button)"
        }
    }

    var keyboardKeyCode: UInt32? {
        guard case let .key(keyCode) = self else { return nil }
        return keyCode
    }

    var mouseButtonNumber: Int64? {
        guard case let .mouseButton(button) = self else { return nil }
        return button
    }

    var requiresCapsLockRemap: Bool {
        keyboardKeyCode == UInt32(kVK_CapsLock)
    }

    static func fromHumanReadable(_ string: String) -> SystemHyperTrigger? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.localizedCaseInsensitiveCompare("None") == .orderedSame {
            return SystemHyperTrigger.none
        }

        let compactMouse = trimmed.replacingOccurrences(of: " ", with: "")
        if compactMouse.lowercased().hasPrefix("mousebutton"),
           let button = Int64(compactMouse.dropFirst("MouseButton".count))
        {
            let trigger = SystemHyperTrigger.mouseButton(button)
            return trigger.isSupported ? trigger : nil
        }

        if let keyCode = KeySymbolMapper.keyCode(named: trimmed) {
            let trigger = SystemHyperTrigger.key(keyCode)
            return trigger.isSupported ? trigger : nil
        }

        return nil
    }
}

extension SystemHyperTrigger: Codable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let trigger = SystemHyperTrigger.fromHumanReadable(string)
        {
            self = trigger
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Invalid system Hyper trigger")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(humanReadableString)
    }
}

enum HotkeyTrigger: Equatable, Hashable {
    case unassigned
    case chord(KeyBinding)

    var isUnassigned: Bool {
        switch self {
        case .unassigned:
            return true
        case let .chord(binding):
            return binding.isUnassigned
        }
    }

    var displayString: String {
        switch self {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return binding.displayString
        }
    }

    var humanReadableString: String {
        switch self {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return binding.humanReadableString
        }
    }

    var chordBinding: KeyBinding? {
        guard case let .chord(binding) = self, !binding.isUnassigned else { return nil }
        return binding
    }

    func conflicts(with other: HotkeyTrigger) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        switch (self, other) {
        case let (.chord(lhs), .chord(rhs)):
            return lhs.conflicts(with: rhs)
        default:
            return false
        }
    }

    static func fromHumanReadable(_ string: String) -> HotkeyTrigger? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Unassigned" { return .unassigned }
        if let binding = KeySymbolMapper.fromHumanReadable(trimmed) {
            return binding.isUnassigned ? .unassigned : .chord(binding)
        }
        return nil
    }
}

extension HotkeyTrigger: Codable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let trigger = HotkeyTrigger.fromHumanReadable(string)
        {
            self = trigger
            return
        }
        let binding = try KeyBinding(from: decoder)
        self = binding.isUnassigned ? .unassigned : .chord(binding)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .unassigned:
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        case let .chord(binding):
            try binding.encode(to: encoder)
        }
    }
}

struct HotkeyBinding: Codable, Equatable, Identifiable {
    let id: String
    let command: HotkeyCommand
    var binding: HotkeyTrigger

    var category: HotkeyCategory {
        ActionCatalog.category(for: id) ?? .focus
    }

    init(id: String, command: HotkeyCommand, binding: KeyBinding) {
        self.init(id: id, command: command, trigger: binding.isUnassigned ? .unassigned : .chord(binding))
    }

    init(id: String, command: HotkeyCommand, trigger: HotkeyTrigger) {
        self.id = id
        self.command = command
        binding = HotkeyBindingRegistry.canonicalizeTrigger(trigger)
    }
}

extension HotkeyBinding {
    private enum CodingKeys: String, CodingKey {
        case id, bindings, binding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let trigger = try container.decodeIfPresent(HotkeyTrigger.self, forKey: .binding)
            ?? HotkeyBindingRegistry.firstTrigger(
                from: try container.decodeIfPresent([KeyBinding].self, forKey: .bindings) ?? []
            )
            ?? .unassigned
        guard let command = HotkeyBindingRegistry.command(for: id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Unknown hotkey binding id: \(id)"
            )
        }
        self = HotkeyBinding(id: id, command: command, trigger: trigger)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
    }
}

struct PersistedHotkeyBinding: Codable, Equatable {
    let id: String
    let binding: HotkeyTrigger

    private enum CodingKeys: String, CodingKey {
        case id, bindings, binding
    }

    init(id: String, binding: KeyBinding) {
        self.init(id: id, trigger: binding.isUnassigned ? .unassigned : .chord(binding))
    }

    init(id: String, trigger: HotkeyTrigger) {
        self.id = id
        binding = HotkeyBindingRegistry.canonicalizeTrigger(trigger)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        binding = try container.decodeIfPresent(HotkeyTrigger.self, forKey: .binding)
            ?? HotkeyBindingRegistry.firstTrigger(
                from: try container.decodeIfPresent([KeyBinding].self, forKey: .bindings) ?? []
            )
            ?? .unassigned
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
    }
}

enum HotkeyBindingRegistry {
    private static let commandPaletteID = "openCommandPalette"
    private static let legacyCommandPaletteIDs = (
        windowFinder: "openWindowFinder",
        menuPalette: "openMenuPalette"
    )
    private static let defaultBindings = DefaultHotkeyBindings.all()
    private static let bindingsByID = Dictionary(
        defaultBindings.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func defaults() -> [HotkeyBinding] {
        defaultBindings
    }

    static func command(for id: String) -> HotkeyCommand? {
        bindingsByID[id]?.command
    }

    static func makeBinding(id: String, binding: KeyBinding) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, binding: binding)
    }

    static func makeBinding(id: String, trigger: HotkeyTrigger) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, trigger: trigger)
    }

    static func canonicalize(_ persisted: [PersistedHotkeyBinding]) -> [HotkeyBinding] {
        var overrides: [String: HotkeyTrigger] = [:]
        var explicitOverrideIDs: Set<String> = []
        var commandPaletteOverridePresent = false
        var legacyWindowFinderBinding: HotkeyTrigger?
        var legacyMenuPaletteBinding: HotkeyTrigger?

        for entry in persisted {
            let normalizedBinding = canonicalizeTrigger(entry.binding)
            if isLegacyWorkspaceDefault(id: entry.id, trigger: normalizedBinding) {
                continue
            }

            switch entry.id {
            case commandPaletteID:
                commandPaletteOverridePresent = true
                explicitOverrideIDs.insert(commandPaletteID)
                overrides[commandPaletteID] = normalizedBinding
            case legacyCommandPaletteIDs.windowFinder:
                legacyWindowFinderBinding = normalizedBinding.isUnassigned ? nil : normalizedBinding
            case legacyCommandPaletteIDs.menuPalette:
                legacyMenuPaletteBinding = normalizedBinding.isUnassigned ? nil : normalizedBinding
            default:
                guard bindingsByID[entry.id] != nil else { continue }
                explicitOverrideIDs.insert(entry.id)
                overrides[entry.id] = normalizedBinding
            }
        }

        if !commandPaletteOverridePresent, let legacyBinding = legacyWindowFinderBinding ?? legacyMenuPaletteBinding {
            explicitOverrideIDs.insert(commandPaletteID)
            overrides[commandPaletteID] = legacyBinding
        }

        return defaultBindings.map { binding in
            guard explicitOverrideIDs.contains(binding.id) else { return binding }
            let override = overrides[binding.id] ?? .unassigned
            return HotkeyBinding(id: binding.id, command: binding.command, trigger: override)
        }
    }

    static func migrateLegacyDefaultWorkspaceBindings(_ bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        bindings.map { binding in
            guard isLegacyWorkspaceDefault(id: binding.id, trigger: binding.binding),
                  let defaultBinding = bindingsByID[binding.id]
            else { return binding }
            return defaultBinding
        }
    }

    static func canonicalizeBinding(_ binding: KeyBinding) -> KeyBinding {
        binding.isUnassigned ? .unassigned : binding
    }

    static func canonicalizeTrigger(_ trigger: HotkeyTrigger) -> HotkeyTrigger {
        switch trigger {
        case .unassigned:
            return .unassigned
        case let .chord(binding):
            return binding.isUnassigned ? .unassigned : .chord(binding)
        }
    }

    static func firstTrigger(from bindings: [KeyBinding]) -> HotkeyTrigger? {
        bindings.first { !$0.isUnassigned }.map(HotkeyTrigger.chord)
    }

    private static func isLegacyWorkspaceDefault(id: String, trigger: HotkeyTrigger) -> Bool {
        guard case let .chord(binding) = trigger else { return false }
        let digitCodes = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]
        for (workspace, keyCode) in digitCodes.enumerated() {
            if id == "switchWorkspace.\(workspace)" {
                return binding == KeyBinding(keyCode: keyCode, modifiers: UInt32(optionKey))
            }
            if id == "moveToWorkspace.\(workspace)" {
                return binding == KeyBinding(keyCode: keyCode, modifiers: UInt32(optionKey | shiftKey))
            }
        }
        return false
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

private extension Array where Element: Equatable {
    func isStrictPrefix(of other: [Element]) -> Bool {
        count < other.count && zip(self, other).allSatisfy { $0 == $1 }
    }
}
