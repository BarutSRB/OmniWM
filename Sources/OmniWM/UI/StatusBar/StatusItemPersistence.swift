// SPDX-License-Identifier: GPL-2.0-only
import AppKit

enum StatusItemPersistence {
    enum OwnedItem: CaseIterable {
        case main
        case hiddenBarSeparator

        var autosaveName: String {
            switch self {
            case .main:
                "omniwm_main"
            case .hiddenBarSeparator:
                "omniwm_hiddenbar_separator"
            }
        }
    }

    private static let preferredPositionKeyPrefix = "NSStatusItem Preferred Position"
    private static let visibilityKeyPrefixes = [
        "NSStatusItem Visible",
        "NSStatusItem Visible Preference",
        "NSStatusItem Visibility"
    ]

    @MainActor
    static func configureMandatoryItem(
        _ statusItem: NSStatusItem,
        as ownedItem: OwnedItem
    ) {
        statusItem.autosaveName = ownedItem.autosaveName
        statusItem.behavior = []
        statusItem.isVisible = true
    }

    @discardableResult
    static func repairOwnedRestoreState(
        defaults: UserDefaults = .standard,
        screenFrames: [CGRect]
    ) -> Bool {
        let didClearPositions = clearInvalidOwnedPreferredPositions(
            defaults: defaults,
            screenFrames: screenFrames
        )
        let didClearVisibility = clearInvalidOwnedVisibilityPreferences(defaults: defaults)
        return didClearPositions || didClearVisibility
    }

    static func clearOwnedRestoreState(defaults: UserDefaults = .standard) {
        clearOwnedPreferredPositions(defaults: defaults)
        clearOwnedVisibilityPreferences(defaults: defaults)
    }

    @discardableResult
    static func clearInvalidOwnedPreferredPositions(
        defaults: UserDefaults = .standard,
        screenFrames: [CGRect]
    ) -> Bool {
        let shouldClear = OwnedItem.allCases.contains { item in
            let key = preferredPositionKey(for: item.autosaveName)
            return !storedPreferredPositionCanBeKept(defaults.object(forKey: key), screenFrames: screenFrames)
        }
        guard shouldClear else { return false }

        clearOwnedPreferredPositions(defaults: defaults)
        return true
    }

    static func clearOwnedPreferredPositions(defaults: UserDefaults = .standard) {
        for item in OwnedItem.allCases {
            defaults.removeObject(forKey: preferredPositionKey(for: item.autosaveName))
        }
    }

    @discardableResult
    static func clearInvalidOwnedVisibilityPreferences(defaults: UserDefaults = .standard) -> Bool {
        var didClear = false
        for item in OwnedItem.allCases where visibilityPreferencesNeedRepair(for: item, defaults: defaults) {
            clearVisibilityPreferences(for: item, defaults: defaults)
            didClear = true
        }
        return didClear
    }

    static func clearOwnedVisibilityPreferences(defaults: UserDefaults = .standard) {
        for item in OwnedItem.allCases {
            clearVisibilityPreferences(for: item, defaults: defaults)
        }
    }

    static func preferredPositionKey(for autosaveName: String) -> String {
        "\(preferredPositionKeyPrefix) \(autosaveName)"
    }

    static func visibilityKeys(for autosaveName: String) -> [String] {
        visibilityKeyPrefixes.map { "\($0) \(autosaveName)" }
    }

    static func storedPreferredPositionCanBeKept(
        _ storedValue: Any?,
        screenFrames: [CGRect]
    ) -> Bool {
        guard !screenFrames.isEmpty else { return true }
        guard let storedValue else { return true }
        guard let positionX = preferredPositionX(from: storedValue) else { return false }
        return preferredPositionXCanBeKept(positionX, screenFrames: screenFrames)
    }

    static func preferredPositionXCanBeKept(
        _ positionX: CGFloat,
        screenFrames: [CGRect]
    ) -> Bool {
        guard positionX.isFinite else { return false }

        let validRanges = screenFrames.compactMap(Self.validScreenXRange)
        guard !validRanges.isEmpty else { return true }

        return validRanges.contains { $0.contains(positionX) }
    }

    static func storedVisibilityPreferenceCanBeKept(_ storedValue: Any?) -> Bool {
        switch visibilityPreferenceState(from: storedValue) {
        case .absent, .visible:
            true
        case .hidden, .malformed:
            false
        }
    }

    private static func visibilityPreferencesNeedRepair(
        for item: OwnedItem,
        defaults: UserDefaults
    ) -> Bool {
        visibilityKeys(for: item.autosaveName).contains {
            !storedVisibilityPreferenceCanBeKept(defaults.object(forKey: $0))
        }
    }

    private static func clearVisibilityPreferences(
        for item: OwnedItem,
        defaults: UserDefaults
    ) {
        for key in visibilityKeys(for: item.autosaveName) {
            defaults.removeObject(forKey: key)
        }
    }

    private enum VisibilityPreferenceState {
        case absent
        case visible
        case hidden
        case malformed
    }

    private static func visibilityPreferenceState(from storedValue: Any?) -> VisibilityPreferenceState {
        guard let storedValue else { return .absent }
        guard let number = storedValue as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return .malformed
        }
        return number.boolValue ? .visible : .hidden
    }

    private static func preferredPositionX(from storedValue: Any) -> CGFloat? {
        guard let number = storedValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return CGFloat(value)
    }

    private static func validScreenXRange(_ frame: CGRect) -> Range<CGFloat>? {
        guard frame.width > 0,
              frame.minX.isFinite,
              frame.maxX.isFinite,
              frame.minX < frame.maxX
        else {
            return nil
        }
        return frame.minX ..< frame.maxX
    }
}
