// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum AppBootstrapDecision: Equatable {
    case boot
    case requireDisplaysHaveSeparateSpacesDisabled
}

struct DisplaysHaveSeparateSpacesRequirement {
    static let domainName = "com.apple.spaces"
    static let spansDisplaysKey = "spans-displays"

    var defaultsProvider: () -> UserDefaults?

    init(defaultsProvider: @escaping () -> UserDefaults? = {
        UserDefaults(suiteName: domainName)
    }) {
        self.defaultsProvider = defaultsProvider
    }

    func isSatisfied() -> Bool {
        guard let defaults = defaultsProvider(),
              defaults.object(forKey: Self.spansDisplaysKey) != nil
        else {
            return false
        }

        return defaults.bool(forKey: Self.spansDisplaysKey)
    }
}

enum AppBootstrapPlanner {
    static func decision(
        spacesRequirement: DisplaysHaveSeparateSpacesRequirement = .init()
    ) -> AppBootstrapDecision {
        guard spacesRequirement.isSatisfied() else {
            return .requireDisplaysHaveSeparateSpacesDisabled
        }
        return .boot
    }
}
